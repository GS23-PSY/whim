import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pin.dart';
import 'pin_repository.dart';

/// 담아둔 핀을 최신순으로 보여준다. 지도는 Phase 2다.
///
/// 스펙 S4의 필터(전체/미방문/방문)와 지역별 그룹은 넣지 않았다. visitedAt은
/// Phase 3의 방문 토글이 생겨야 값이 채워지고, 지역 그룹은 Phase 2의 구역
/// 계산이 있어야 한다. 지금 만들면 아무 일도 하지 않는 버튼만 생긴다.
class PinList extends ConsumerWidget {
  const PinList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pins = ref.watch(pinsProvider);

    return switch (pins) {
      AsyncData(value: final list) when list.isEmpty => const _Notice(
        '아직 담은 곳이 없어요.\n인스타그램에서 장소를 공유해보세요.',
      ),
      AsyncData(value: final list) => ListView.separated(
        itemCount: list.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) => _PinTile(pin: list[index]),
      ),
      // 오프라인 캐시가 있어도 실패할 수 있다. 목록이 안 보이는 것은 사용자에게
      // 보이는 실패라 화면에 쓴다(스펙 §10).
      AsyncError() => const _Notice('목록을 불러오지 못했어요.'),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

class _PinTile extends ConsumerWidget {
  const _PinTile({required this.pin});

  final Pin pin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey(pin.id),
      // 오른쪽에서 왼쪽으로만. 양방향이면 목록을 넘기다 실수로 지운다.
      direction: DismissDirection.endToStart,
      background: ColoredBox(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
      onDismissed: (_) => _delete(context, ref),
      child: ListTile(
        title: Text(pin.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          pin.memo?.isNotEmpty ?? false
              ? '${pin.address}\n${pin.memo}'
              : pin.address,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: pin.memo?.isNotEmpty ?? false,
        trailing: Text(
          pin.category.wire,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }

  /// 저장한 장소를 잃는 것이 이 앱에서 가장 나쁜 일이라, 실수로 스와이프한
  /// 경우를 되돌릴 수 있게 한다. 되돌리면 문서 id는 새로 생기지만 createdAt을
  /// 그대로 다시 쓰므로 목록 순서는 원래대로 돌아온다.
  void _delete(BuildContext context, WidgetRef ref) {
    final repository = ref.read(pinRepositoryProvider);
    repository.delete(pin.id);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${pin.name} 삭제했어요'),
        action: SnackBarAction(
          label: '되돌리기',
          onPressed: () => repository.add(pin),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
