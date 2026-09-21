import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../metrics/metrics.dart';
import '../metrics/pilot_stats.dart';
import '../outing/outing.dart';
import '../outing/outing_screen.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';
import 'zone_providers.dart';

/// 스펙 S3의 구역 상세. 지도에서 구역을 탭하면 열린다.
///
/// 구역을 통째로 넘겨받지 않고 id로 다시 찾는다. 방문 표시를 누르면 핀이
/// 바뀌는데, 스냅샷을 들고 있으면 화면이 옛 값을 보여준다.
class ZoneDetailScreen extends ConsumerStatefulWidget {
  const ZoneDetailScreen({required this.zoneId, super.key});

  final String zoneId;

  @override
  ConsumerState<ZoneDetailScreen> createState() => _ZoneDetailScreenState();
}

class _ZoneDetailScreenState extends ConsumerState<ZoneDetailScreen> {
  @override
  void initState() {
    super.initState();
    // 화면을 연 순간에 한 번만 남긴다(스펙 §6 zone_viewed). build에서 남기면
    // 방문 표시를 누를 때마다 다시 세어 "열어본 횟수"가 아니게 된다.
    final zone = ref.read(zoneByIdProvider(widget.zoneId));
    if (zone != null) {
      ref.read(metricsProvider).zoneViewed(pinCount: zone.pinCount);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zone = ref.watch(zoneByIdProvider(widget.zoneId));

    if (zone == null) {
      // 핀을 지우면 남은 핀이 minPoints를 못 채워 구역이 흩어질 수 있다.
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('이 구역은 더 이상 없어요.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(zone.name.isEmpty ? '이 동네' : zone.name)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '여기 ${zone.pinCount}곳 저장해뒀어요',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: zone.pins.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _ZonePinTile(pin: zone.pins[index]),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton(
                onPressed: () => _startOuting(context),
                child: const Text('지금 가기'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 시간 예산을 고르면 바로 코스 화면으로 넘어간다. 스펙 S3의 유일한 선택지라
  /// 시트 하나로 끝낸다.
  Future<void> _startOuting(BuildContext context) async {
    final budget = await showModalBottomSheet<OutingBudget>(
      context: context,
      useSafeArea: true,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('얼마나 걸을 수 있어요?'),
          ),
          for (final budget in OutingBudget.values)
            ListTile(
              title: Text(budget.label),
              onTap: () => Navigator.of(context).pop(budget),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );

    if (budget == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            OutingScreen(zoneId: widget.zoneId, budget: budget),
      ),
    );
  }
}

class _ZonePinTile extends ConsumerWidget {
  const _ZonePinTile({required this.pin});

  final Pin pin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 방문한 곳은 흐리게. 다음에 갈 곳이 먼저 눈에 들어와야 한다(스펙 S2와
    // 같은 규칙을 목록에도 쓴다).
    final muted = theme.colorScheme.outline;

    return ListTile(
      leading: Icon(
        _iconOf(pin.category),
        color: pin.isVisited ? muted : theme.colorScheme.primary,
      ),
      title: Text(
        pin.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: pin.isVisited ? TextStyle(color: muted) : null,
      ),
      subtitle: Text(
        pin.memo?.isNotEmpty ?? false
            ? '${pin.address}\n${pin.memo}'
            : pin.address,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: pin.memo?.isNotEmpty ?? false,
      trailing: IconButton(
        tooltip: pin.isVisited ? '방문 취소' : '다녀왔어요',
        icon: Icon(
          pin.isVisited ? Icons.check_circle : Icons.check_circle_outline,
          color: pin.isVisited ? theme.colorScheme.primary : muted,
        ),
        onPressed: () => _toggleVisited(ref),
      ),
    );
  }

  void _toggleVisited(WidgetRef ref) {
    final visited = !pin.isVisited;
    ref.read(pinRepositoryProvider).setVisited(pin.id, visited: visited);

    // 취소는 오조작 되돌리기라 지표에 넣지 않는다. 방문만 남긴다.
    if (!visited) return;
    ref
        .read(metricsProvider)
        .pinVisited(
          daysSinceSaved: DateTime.now().difference(pin.createdAt).inDays,
          // 지금 가기(스펙 S3 버튼)를 타고 온 방문은 다음 단계에서 구분한다.
          fromOuting: false,
        );
    ref.read(pilotStatsProvider).publish();
  }
}

/// 스펙 S3의 카테고리 아이콘. 썸네일은 담기 경로에서 이미지를 받지 않아
/// 채울 값이 없다.
IconData _iconOf(PinCategory category) => switch (category) {
  PinCategory.restaurant => Icons.restaurant,
  PinCategory.cafe => Icons.local_cafe,
  PinCategory.shopping => Icons.shopping_bag_outlined,
  PinCategory.sightseeing => Icons.photo_camera_outlined,
  PinCategory.etc => Icons.place_outlined,
};
