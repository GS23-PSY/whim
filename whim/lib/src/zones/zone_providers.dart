import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/couple_provider.dart'; // selectedCoupleProvider가 있는 경로
import '../pins/pin_repository.dart';
import 'zone.dart';
import 'zone_calculator.dart';

/// 구역은 저장하지 않고 핀에서 다시 계산한다(스펙 §5).
/// 현재 선택된 커플 ID에 해당하는 핀만 필터링하여 구역을 계산합니다.
final zonesProvider = Provider<ZoneResult>((ref) {
  final allPins = ref.watch(pinsProvider).value ?? const [];
  final selectedCoupleId = ref.watch(selectedCoupleProvider);

  // 현재 선택된 coupleId와 일치하는 핀만 필터링 (미분류 처리 정책에 따라 조건 조정 가능)
  final filteredPins = allPins.where((pin) => pin.coupleId == selectedCoupleId).toList();

  return calculateZones(filteredPins);
});

final zoneByIdProvider = Provider.family<Zone?, String>((ref, zoneId) {
  for (final zone in ref.watch(zonesProvider).zones) {
    if (zone.id == zoneId) return zone;
  }
  return null;
});