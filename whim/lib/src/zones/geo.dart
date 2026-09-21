import 'dart:math' as math;

/// 두 좌표 사이의 대권 거리(m).
///
/// 400m 규모에서는 평면 근사를 써도 오차가 무시할 만하지만, 식이 짧아 그냥
/// 하버사인을 쓴다.
double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  final dLat = _radians(lat2 - lat1);
  final dLng = _radians(lng2 - lng1);
  final h =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_radians(lat1)) *
          math.cos(_radians(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
}

double _radians(double degrees) => degrees * math.pi / 180;
