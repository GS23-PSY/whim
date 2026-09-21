import 'dart:math' as math;

import '../pins/pin.dart';
import 'geo.dart';

/// 핀이 몰려 있는 동네 하나. 스펙 §5의 DBSCAN 결과다.
///
/// 저장은 하지 않는다. 핀 100개 이하를 가정하므로 화면을 그릴 때마다 다시
/// 계산하는 편이 pins.zoneId를 최신으로 유지하는 것보다 단순하다.
class Zone {
  const Zone({required this.id, required this.name, required this.pins});

  /// 같은 핀 묶음이면 같은 값이 나온다. 구역을 탭해 상세로 들어갈 때(S3)
  /// 순서가 바뀌어도 같은 구역을 가리키게 하려면 내용으로 만들어야 한다.
  final String id;

  /// 구역 핀들의 주소에서 뽑은 최빈 동 이름.
  final String name;

  final List<Pin> pins;

  int get pinCount => pins.length;

  /// 지도에서 구역을 가리킬 한 점. 무게중심이면 충분하다.
  double get centerLat =>
      pins.fold<double>(0, (sum, pin) => sum + pin.lat) / pins.length;

  double get centerLng =>
      pins.fold<double>(0, (sum, pin) => sum + pin.lng) / pins.length;

  /// 지도에 색 면으로 그릴 원의 반지름(m).
  ///
  /// 핀 3개가 한 골목에 모여 있으면 실제 반경이 50m도 안 돼 점처럼 보인다.
  /// "이 동네에 모여 있다"가 읽혀야 하므로 여유를 주고 최소 크기를 둔다.
  double get radiusMeters {
    final furthest = pins
        .map((pin) => distanceBetween(centerLat, centerLng, pin.lat, pin.lng))
        .reduce(math.max);
    return math.max(furthest + _zonePadding, _minZoneRadius);
  }
}

/// 가장 바깥 핀이 면 안에 넉넉히 들어오도록 더하는 여유(m).
const _zonePadding = 120.0;

/// 이보다 작으면 지도에서 구역으로 보이지 않는다(m).
const _minZoneRadius = 220.0;
