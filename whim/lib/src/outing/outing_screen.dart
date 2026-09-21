import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../metrics/metrics.dart';
import '../metrics/pilot_stats.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';
import '../zones/geo.dart';
import '../zones/zone_providers.dart';
import 'current_location.dart';
import 'outing.dart';

/// 스펙 S3의 [지금 가기] 결과 화면.
///
/// 경로를 그리지 않고 순서도 제안하지 않는다(스펙 S3). 가까운 순으로 늘어놓기만
/// 한다 — 어디부터 갈지는 사용자가 그 자리에서 정한다.
class OutingScreen extends ConsumerStatefulWidget {
  const OutingScreen({required this.zoneId, required this.budget, super.key});

  final String zoneId;
  final OutingBudget budget;

  @override
  ConsumerState<OutingScreen> createState() => _OutingScreenState();
}

class _OutingScreenState extends ConsumerState<OutingScreen> {
  /// 화면에 띄울 핀의 id와 거리. 순서는 화면에 들어온 뒤 한 번만 정한다 —
  /// 걸어가는 동안 순서가 계속 바뀌면 방금 본 목록을 다시 읽어야 한다.
  ///
  /// Pin을 통째로 들고 있으면 방문 표시를 눌러도 화면이 옛 값을 그린다.
  /// 순서만 얼리고 핀의 상태는 매번 다시 읽는다.
  List<({String pinId, double meters})>? _plan;

  /// 내 위치를 못 받아 구역 중심으로 정렬했는지. 사용자에게 알려줘야 목록
  /// 순서가 이상해 보일 때 이유를 안다.
  bool _fromZoneCenter = false;

  String? _outingId;

  @override
  void initState() {
    super.initState();
    _buildPlan();
  }

  Future<void> _buildPlan() async {
    final zone = ref.read(zoneByIdProvider(widget.zoneId));
    if (zone == null) {
      if (mounted) setState(() => _plan = const []);
      return;
    }

    final here = await currentLocation();
    if (!mounted) return;

    final origin = here ?? (lat: zone.centerLat, lng: zone.centerLng);
    final unvisited = zone.pins.where((pin) => !pin.isVisited).toList();

    final ranked =
        unvisited
            .map(
              (pin) => (
                pin: pin,
                meters: distanceBetween(
                  origin.lat,
                  origin.lng,
                  pin.lat,
                  pin.lng,
                ),
              ),
            )
            .toList()
          ..sort((a, b) => a.meters.compareTo(b.meters));

    final limit = widget.budget.maxPins;
    final shown = limit == 0 || ranked.length <= limit
        ? ranked
        : ranked.sublist(0, limit);

    setState(() {
      _plan = [
        for (final entry in shown) (pinId: entry.pin.id, meters: entry.meters),
      ];
      _fromZoneCenter = here == null;
    });

    if (shown.isEmpty) return;
    _outingId = ref
        .read(outingRepositoryProvider)
        .start(
          zoneId: widget.zoneId,
          budgetMin: widget.budget.minutes,
          shownPinIds: [for (final entry in shown) entry.pin.id],
        );
    ref
        .read(metricsProvider)
        .outingStarted(
          zoneId: widget.zoneId,
          budgetMin: widget.budget.minutes,
          shownPinCount: shown.length,
        );
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    // 방문 표시는 Firestore를 타고 돌아온다. 순서는 얼려도 상태는 여기서 읽는다.
    final pinById = {
      for (final pin in ref.watch(pinsProvider).value ?? const <Pin>[])
        pin.id: pin,
    };

    return Scaffold(
      appBar: AppBar(title: Text('${widget.budget.label} 코스')),
      body: switch (plan) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('여기 아직 안 가본 곳이 없어요.', textAlign: TextAlign.center),
          ),
        ),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                _fromZoneCenter
                    ? '가까운 순 ${plan.length}곳 (동네 중심 기준)'
                    : '가까운 순 ${plan.length}곳',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: plan.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final pin = pinById[plan[index].pinId];
                  // 코스를 보는 중에 그 핀이 지워졌을 수 있다.
                  if (pin == null) return const SizedBox.shrink();
                  return _OutingPinTile(
                    pin: pin,
                    meters: plan[index].meters,
                    onVisited: () => _markVisited(pin),
                  );
                },
              ),
            ),
          ],
        ),
      },
    );
  }

  void _markVisited(Pin pin) {
    ref.read(pinRepositoryProvider).setVisited(pin.id, visited: true);

    final outingId = _outingId;
    if (outingId != null) {
      ref.read(outingRepositoryProvider).addVisited(outingId, pin.id);
    }
    ref
        .read(metricsProvider)
        .pinVisited(
          daysSinceSaved: DateTime.now().difference(pin.createdAt).inDays,
          fromOuting: true,
        );
    ref.read(pilotStatsProvider).publish();

    // 목록에서 빼지 않는다. 걸어가는 중에 방금 누른 곳이 사라지면 잘못 눌렀을
    // 때 되돌릴 자리가 없어진다. 표시만 바뀌는데, 그 표시는 pinsProvider가
    // 돌려주는 값으로 그린다.
  }
}

class _OutingPinTile extends StatelessWidget {
  const _OutingPinTile({
    required this.pin,
    required this.meters,
    required this.onVisited,
  });

  final Pin pin;
  final double meters;
  final VoidCallback onVisited;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visited = pin.isVisited;

    return ListTile(
      title: Text(
        pin.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: visited ? TextStyle(color: theme.colorScheme.outline) : null,
      ),
      subtitle: Text(
        '${_readableDistance(meters)} · ${pin.address}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: visited
          ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
          : TextButton(onPressed: onVisited, child: const Text('다녀왔어요')),
    );
  }
}

String _readableDistance(double meters) {
  if (meters < 1000) return '${meters.round()}m';
  return '${(meters / 1000).toStringAsFixed(1)}km';
}
