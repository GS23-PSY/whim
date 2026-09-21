import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pins/pin_repository.dart';
import 'zone.dart';
import 'zone_calculator.dart';

/// 구역은 저장하지 않고 핀에서 다시 계산한다(스펙 §5). 계산기는 순수 Dart로
/// 두고 Riverpod 연결만 여기서 한다 — 테스트가 계산기만 보면 되게 한다.
final zonesProvider = Provider<ZoneResult>(
  (ref) => calculateZones(ref.watch(pinsProvider).value ?? const []),
);

/// 구역 상세(스펙 S3)는 id로 구역을 다시 찾는다. 화면이 Zone 스냅샷을 들고
/// 있으면 방문 표시를 눌러도 화면이 옛 값을 보여준다.
final zoneByIdProvider = Provider.family<Zone?, String>((ref, zoneId) {
  for (final zone in ref.watch(zonesProvider).zones) {
    if (zone.id == zoneId) return zone;
  }
  return null;
});
