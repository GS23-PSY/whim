import '../pins/pin.dart';
import 'geo.dart';
import 'zone.dart';

/// 스펙 §5: 도보 5분 거리. 튜닝할 수 있게 상수로 둔다.
const zoneEpsMeters = 400.0;

/// 이보다 적게 뭉친 핀은 구역을 만들지 않고 개별 핀으로만 남는다.
const zoneMinPoints = 3;

/// 핀 묶음을 구역으로 나눈다. 서버 없이 기기에서 계산한다(스펙 §5).
///
/// DBSCAN을 쓰는 이유는 구역 개수를 미리 정하지 않아도 되고, 어디에도 속하지
/// 않는 외딴 핀을 억지로 묶지 않기 때문이다. 핀 100개 이하를 가정하므로
/// 이웃 탐색은 전수 비교로 둔다 — 인덱스를 만들 이유가 없다.
class ZoneResult {
  const ZoneResult({required this.zones, required this.loosePins});

  final List<Zone> zones;

  /// 어느 구역에도 들어가지 않은 핀. 지도에는 그대로 개별 표시한다.
  final List<Pin> loosePins;
}

ZoneResult calculateZones(
  List<Pin> pins, {
  double epsMeters = zoneEpsMeters,
  int minPoints = zoneMinPoints,
}) {
  // -1은 아직 어느 구역에도 넣지 않았다는 뜻이다.
  final clusterOf = List<int>.filled(pins.length, -1);
  var clusterCount = 0;

  for (var i = 0; i < pins.length; i++) {
    if (clusterOf[i] != -1) continue;

    final neighbours = _neighbours(pins, i, epsMeters);
    // 자신을 포함해 minPoints를 못 채우면 핵심 핀이 아니다. 나중에 다른
    // 핵심 핀의 이웃으로 끌려 들어올 수는 있다.
    if (neighbours.length < minPoints) continue;

    final cluster = clusterCount++;
    clusterOf[i] = cluster;

    // 핵심 핀에서 이웃을 타고 번져 나간다. 도보권이 사슬처럼 이어지면 한
    // 동네로 본다 — 400m마다 끊어 부르는 것이 사람의 감각과 더 멀다.
    final queue = [...neighbours];
    while (queue.isNotEmpty) {
      final j = queue.removeLast();
      if (clusterOf[j] != -1) continue;
      clusterOf[j] = cluster;

      final next = _neighbours(pins, j, epsMeters);
      if (next.length >= minPoints) queue.addAll(next);
    }
  }

  final grouped = List.generate(clusterCount, (_) => <Pin>[]);
  final loose = <Pin>[];
  for (var i = 0; i < pins.length; i++) {
    final cluster = clusterOf[i];
    if (cluster == -1) {
      loose.add(pins[i]);
    } else {
      grouped[cluster].add(pins[i]);
    }
  }

  final zones = <Zone>[];
  for (final members in grouped) {
    // 경계 핀만 모여 minPoints를 못 채우는 경우가 남을 수 있다.
    if (members.length < minPoints) {
      loose.addAll(members);
      continue;
    }
    zones.add(
      Zone(id: _zoneId(members), name: zoneNameOf(members), pins: members),
    );
  }

  // 핀이 많은 동네가 먼저 보여야 한다.
  zones.sort((a, b) => b.pinCount.compareTo(a.pinCount));
  return ZoneResult(zones: zones, loosePins: loose);
}

List<int> _neighbours(List<Pin> pins, int index, double epsMeters) {
  final found = <int>[];
  for (var i = 0; i < pins.length; i++) {
    if (distanceMeters(pins[index], pins[i]) <= epsMeters) found.add(i);
  }
  return found;
}

/// 두 핀 사이의 거리(m).
double distanceMeters(Pin a, Pin b) =>
    distanceBetween(a.lat, a.lng, b.lat, b.lng);

/// 핀 id를 정렬해 이어 붙인다. 같은 묶음이면 계산 순서와 무관하게 같은 값이다.
String _zoneId(List<Pin> pins) {
  final ids = pins.map((pin) => pin.id).toList()..sort();
  return ids.join('|').hashCode.toRadixString(16);
}

/// 스펙 §5: 구역 이름은 핀 주소의 최빈 동 이름.
///
/// 도로명 주소에는 동이 없어서(`서울 성동구 아차산로 7`) 꽤 자주 실패한다.
/// 그때는 구·시 이름으로 떨어뜨린다 — 이름 없는 구역보다 낫다.
String zoneNameOf(List<Pin> pins) {
  final addresses = pins.map((pin) => pin.address);

  final dong = _mostCommon(addresses, _dongOf);
  if (dong != null) return dong;

  final district = _mostCommon(addresses, _districtOf);
  return district ?? '';
}

/// `성수동2가` → `성수동`, `잠실2동` → `잠실2동`.
///
/// 주소를 토막 단위로 본다. 문자열 전체에 정규식을 걸면 `성동구`의 `성`+`동`을
/// 동 이름으로 잡는다.
final _dongToken = RegExp(r'^([가-힣]{1,5}\d*동)(?:\d+가)?$');

/// 동을 못 찾았을 때 쓸 `성동구`, `청주시`, `영월군`.
final _districtToken = RegExp(r'^[가-힣]{2,6}[구시군]$');

String? _dongOf(String token) => _dongToken.firstMatch(token)?.group(1);

String? _districtOf(String token) =>
    _districtToken.hasMatch(token) ? token : null;

String? _mostCommon(
  Iterable<String> addresses,
  String? Function(String token) pick,
) {
  final counts = <String, int>{};
  for (final address in addresses) {
    for (final token in address.split(RegExp(r'\s+'))) {
      final name = pick(token);
      if (name == null) continue;
      counts[name] = (counts[name] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return null;

  final sorted = counts.entries.toList()
    // 동점이면 이름이 짧은 쪽이 대개 상위 행정구역이라 그쪽을 쓴다.
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.length.compareTo(b.key.length);
    });
  return sorted.first.key;
}
