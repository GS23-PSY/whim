import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/couple_provider.dart';
import '../metrics/metrics.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';
import '../search/kakao_local_client.dart';
import '../search/place_search_client.dart';
import '../share/share_text_parser.dart';
import '../zones/geo.dart';

/// 담기 한 번의 진행 상태.
class CaptureSession {
  CaptureSession({required this.hint, required this.receivedAt});

  final SharedPlaceHint hint;
  final DateTime receivedAt;

  AbandonStage stage = AbandonStage.beforeSearch;
  DateTime? savedAt;
  bool duplicate = false;

  bool get saved => savedAt != null;

  double get secondsToConfirm =>
      savedAt!.difference(receivedAt).inMilliseconds / 1000;
}

Future<String?> showCaptureSheet(BuildContext context, CaptureSession session) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => CaptureSheet(session: session),
  );
}

const _duplicateMeters = 50.0;
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
  AsyncValue<List<PlaceCandidate>>? _results;

  bool _memoOpen = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_hint.hasQuery) {
      _search();
      return;
    }
    _openKeyboard();
  }

  void _openKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queryFocus.requestFocus();
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

  /// 장소 후보를 탭했을 때 저장 처리를 수행합니다.
  void _save(PlaceCandidate candidate) {
    if (_saving) return;
    _saving = true;

    // 이미 같은 위치/이름으로 담아둔 핀이 있는지 검사합니다.
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

    // 1. 현재 선택된 커플 ID(C01~C08)를 가져옵니다.
    final currentCoupleId = ref.read(selectedCoupleProvider);
    final memo = _memo.text.trim();

    // 2. 핀 객체 생성 시 coupleId를 자동으로 바인딩하여 저장소에 추가합니다.
    ref
        .read(pinRepositoryProvider)
        .add(
          Pin(
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
            coupleId: currentCoupleId, // 커플 폴더 바인딩
          ),
        );

    widget.session.savedAt = DateTime.now();
    Navigator.of(context).pop(candidate.name);

    // 3. 저장 완료 시 현재 커플 폴더명을 포함한 토스트(스낵바)를 띄웁니다.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$currentCoupleId에 담았어요'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

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
  final bool Function(PlaceCandidate candidate) isSaved;

  @override
  Widget build(BuildContext context) {
    final results = this.results;
    if (results == null) {
      return const _Notice('인스타 링크에는 장소명이 없어요.\n상호명을 입력하면 바로 찾아드려요.');
    }

    return switch (results) {
      AsyncLoading() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      ),
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