import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../metrics/metrics.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';
import '../search/kakao_local_client.dart';
import '../search/place_search_client.dart';
import '../share/share_text_parser.dart';
import '../zones/geo.dart';

/// 담기 한 번의 진행 상태.
///
/// 시트가 저장으로 닫혔는지 포기로 닫혔는지, 포기라면 어디까지 갔는지를
/// 호출한 쪽이 알아야 pin_create_abandoned를 남길 수 있다. 시트는 후보 탭
/// 말고도 드래그·뒤로 가기로 닫히는데, 그때 반환값은 그냥 null이라
/// 반환값만으로는 stage를 알 수 없다.
class CaptureSession {
  CaptureSession({required this.hint, required this.receivedAt});

  final SharedPlaceHint hint;
  final DateTime receivedAt;

  /// 검색이 끝나기 전에 닫히는 경우가 기본값이다.
  AbandonStage stage = AbandonStage.beforeSearch;

  /// 저장이 끝난 시각. null이면 담기를 포기했다.
  DateTime? savedAt;

  /// 이미 담아둔 곳을 다시 고른 경우. 새로 저장하지도, 포기하지도 않았으므로
  /// 담기 완료율(스펙 §6)의 분자에도 분모에도 넣지 않는다.
  bool duplicate = false;

  bool get saved => savedAt != null;

  double get secondsToConfirm =>
      savedAt!.difference(receivedAt).inMilliseconds / 1000;
}

/// 담기 시트를 띄운다. 저장된 장소명을 돌려주고, 닫혔으면 null이다.
///
/// 스펙 S1의 목표는 탭 2회·3초다. 공유 앱 선택이 1회, 후보 탭이 1회다.
/// 그래서 시트는 열리는 즉시 프리필된 검색어로 검색을 시작하고, 후보를
/// 탭하면 그대로 저장하고 닫힌다. 확인 단계도 저장 버튼도 두지 않는다.
Future<String?> showCaptureSheet(BuildContext context, CaptureSession session) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => CaptureSheet(session: session),
  );
}

/// 같은 이름이 이 거리 안에 있으면 같은 곳으로 본다. 체인점 지점 간격보다는
/// 작고, 검색 결과의 좌표 오차보다는 크게 잡았다.
const _duplicateMeters = 50.0;

/// 타이핑마다 검색하면 카카오 할당량을 태우고 결과가 깜빡인다. 사용자가
/// 손을 멈춘 뒤에만 검색한다.
const _debounce = Duration(milliseconds: 400);

class CaptureSheet extends ConsumerStatefulWidget {
  const CaptureSheet({required this.session, super.key});

  final CaptureSession session;

  @override
  ConsumerState<CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends ConsumerState<CaptureSheet> {
  late final SharedPlaceHint _hint = widget.session.hint;

  late final TextEditingController _query = TextEditingController(
    text: _hint.query,
  );
  final TextEditingController _memo = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  Timer? _debounceTimer;

  /// null은 "아직 검색하지 않음"이다. 프리필이 없을 때의 첫 화면.
  AsyncValue<List<PlaceCandidate>>? _results;

  bool _memoOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 프리필이 있으면 사용자가 아무것도 하지 않아도 후보가 떠 있어야 한다.
    if (_hint.hasQuery) {
      _search();
      return;
    }
    _openKeyboard();
  }

  /// 인스타그램은 캡션 없이 링크만 보내는 경우가 있어 프리필이 비게 된다.
  /// 그때 사용자가 할 일은 타이핑뿐이므로, 시트가 뜨는 것과 동시에 키보드까지
  /// 올려 둔다. 검색창을 탭하는 동작 하나를 없애는 것이 3초 목표에 직결된다.
  void _openKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queryFocus.requestFocus();
      // 시트 전환 애니메이션 중에 포커스를 받으면 포커스만 가고 키보드가
      // 올라오지 않는 경우가 있다. 플랫폼에 직접 한 번 더 요청한다.
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _query.dispose();
    _memo.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _search);
  }

  Future<void> _search() async {
    _debounceTimer?.cancel();
    final query = _query.text.trim();
    if (query.isEmpty) {
      setState(() => _results = null);
      return;
    }

    setState(() => _results = const AsyncValue.loading());
    try {
      final candidates = await ref
          .read(placeSearchClientProvider)
          .search(query);
      if (!mounted) return;
      // 결과가 0건이면 탭할 것이 없어 사용자에게는 실패와 같다.
      widget.session.stage = candidates.isEmpty
          ? AbandonStage.searchFailed
          : AbandonStage.resultsShown;
      setState(() => _results = AsyncValue.data(candidates));
    } on PlaceSearchException catch (error, stackTrace) {
      if (!mounted) return;
      widget.session.stage = AbandonStage.searchFailed;
      setState(() => _results = AsyncValue.error(error, stackTrace));
    }
  }

  void _save(PlaceCandidate candidate) {
    // 저장은 로컬 쓰기만 기다리면 끝난다(PinRepository.add). 연타로 두 번
    // 저장되는 것만 막고 바로 닫는다.
    if (_saving) return;
    _saving = true;

    // 같은 곳을 다시 담으면 목록에 똑같은 핀이 둘 생긴다. 파일럿에서 흔할
    // 일이라 막되, 헛수고했다는 느낌이 남지 않게 이미 담긴 것을 알려준다.
    if (_existingPinFor(candidate) != null) {
      widget.session.duplicate = true;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${candidate.name}은(는) 이미 담아둔 곳이에요'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    final memo = _memo.text.trim();
    ref
        .read(pinRepositoryProvider)
        .add(
          Pin(
            // 문서 id는 PinRepository.add가 만든다. 저장 경로에서는 쓰이지 않는다.
            id: '',
            name: candidate.name,
            lat: candidate.lat,
            lng: candidate.lng,
            address: candidate.address,
            category: candidate.category,
            sourceType: _hint.sourceType,
            sourceUrl: _hint.sourceUrl,
            memo: memo.isEmpty ? null : memo,
            createdAt: DateTime.now(),
          ),
        );

    // secondsToConfirm의 끝은 저장이 끝난 이 시점이다. 시트 닫힘 애니메이션이
    // 끝나는 시각을 쓰면 사용자가 체감하지 않는 시간이 섞인다.
    widget.session.savedAt = DateTime.now();
    Navigator.of(context).pop(candidate.name);
  }

  /// 이미 담아둔 핀인지 본다.
  ///
  /// 카카오 장소 id를 저장하지 않으므로(스펙 §4에 없는 필드다) 이름과 위치로
  /// 가린다. 같은 건물의 다른 가게는 이름이 달라 걸리지 않고, 같은 이름의
  /// 다른 지점은 50m 밖이라 걸리지 않는다.
  Pin? _existingPinFor(PlaceCandidate candidate) {
    for (final pin in ref.read(pinsProvider).value ?? const <Pin>[]) {
      if (pin.name != candidate.name) continue;
      final gap = distanceBetween(
        pin.lat,
        pin.lng,
        candidate.lat,
        candidate.lng,
      );
      if (gap <= _duplicateMeters) return pin;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 키보드가 올라와도 검색창과 후보가 가려지지 않게 한다.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _query,
              // 프리필이 있으면 포커스를 주지 않는다(initState). 키보드가 후보
              // 목록을 가리면 탭 한 번에 저장할 수 없다.
              focusNode: _queryFocus,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                hintText: '장소명을 입력하세요',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Flexible(
            child: _CandidateList(
              results: _results,
              onTap: _save,
              isSaved: (candidate) => _existingPinFor(candidate) != null,
            ),
          ),
          _MemoField(
            controller: _memo,
            open: _memoOpen,
            onOpen: () => setState(() => _memoOpen = true),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({
    required this.results,
    required this.onTap,
    required this.isSaved,
  });

  final AsyncValue<List<PlaceCandidate>>? results;
  final void Function(PlaceCandidate candidate) onTap;

  /// 이미 담아둔 곳이면 탭하기 전에 알려준다. 탭하고 나서 "이미 담았어요"를
  /// 보는 것보다 낫다.
  final bool Function(PlaceCandidate candidate) isSaved;

  @override
  Widget build(BuildContext context) {
    final results = this.results;
    if (results == null) {
      // 인스타 링크만 공유되면 여기로 온다. 왜 빈 칸인지 알려주지 않으면
      // 사용자는 앱이 고장난 줄 안다.
      return const _Notice('인스타 링크에는 장소명이 없어요.\n상호명을 입력하면 바로 찾아드려요.');
    }

    return switch (results) {
      AsyncLoading() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
      // 스펙 §10: 사용자에게 보이는 실패만 화면에 쓴다. 문구는 클라이언트가
      // 이미 사용자용으로 만들어 둔 것을 그대로 쓴다.
      AsyncError(:final error) => _Notice(
        error is PlaceSearchException ? error.message : '검색에 실패했어요.',
      ),
      AsyncData(value: final candidates) when candidates.isEmpty =>
        const _Notice('검색 결과가 없어요. 장소명을 고쳐보세요.'),
      AsyncData(value: final candidates) => ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: candidates.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final candidate = candidates[index];
          return ListTile(
            title: Text(
              candidate.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              candidate.address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              isSaved(candidate) ? '이미 담음' : candidate.category.wire,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            onTap: () => onTap(candidate),
          );
        },
      ),
    };
  }
}

/// 메모는 스펙 S1대로 접혀 있는 선택 입력이다. 기본 경로의 탭 수를 늘리지 않는다.
class _MemoField extends StatelessWidget {
  const _MemoField({
    required this.controller,
    required this.open,
    required this.onOpen,
  });

  final TextEditingController controller;
  final bool open;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (!open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.edit_note),
            label: const Text('메모 추가'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 2,
        minLines: 1,
        decoration: const InputDecoration(
          hintText: '메모 (선택)',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Text(message, textAlign: TextAlign.center),
    );
  }
}
