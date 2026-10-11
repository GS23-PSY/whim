import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';

import '../common/couple_provider.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';
import '../zones/zone_calculator.dart';
import '../zones/zone_detail_screen.dart';

/// 스펙 §10: 키는 저장소에 넣지 않는다.
/// flutter run --dart-define=KAKAO_NATIVE_APP_KEY=...
///
/// 장소 검색에 쓰는 REST 키와 다른 키다. 카카오 지도 SDK는 네이티브 앱 키만
/// 받고, REST 키를 넣으면 인증이 거부된다.
const kakaoNativeAppKey = String.fromEnvironment('KAKAO_NATIVE_APP_KEY');

bool get hasKakaoMapKey => kakaoNativeAppKey.isNotEmpty;

/// 지도 위젯이 만들어지기 전에 한 번 인증해야 한다.
///
/// 키가 없거나 인증이 실패해도 담기와 목록은 그대로 동작해야 하므로 앱을
/// 멈추지 않는다. 지도는 스펙 S2의 홈이지만, 유일한 유입 경로인 담기를
/// 지도 때문에 막는 것이 훨씬 나쁘다.
Future<void> initKakaoMapSdk() async {
  if (!hasKakaoMapKey) return;
  try {
    // SDK 초기화 전후로 키 해시 자동 생성을 유도하거나 로그를 확인합니다.
    await KakaoMapSdk.instance.initialize(kakaoNativeAppKey);
  } catch (error, stackTrace) {
    developer.log('카카오맵 SDK 초기화 실패: $error', error: error, stackTrace: stackTrace);
  }
}

/// 지도에서 올라온 클릭이 핀인지 구역인지 id로 가린다.
const _pinPoiPrefix = 'pin_';
const _zonePoiPrefix = 'zone_';

/// 핀이 하나도 없을 때의 초기 위치(서울시청).
const _defaultCenter = LatLng(37.5666, 126.9784);
const _defaultZoom = 13;

/// 이 줌보다 멀리서 보면 구역에 속한 핀의 이름표를 감춘다.
///
/// 한 동네에 모인 상호명은 멀리서 보면 서로 겹쳐 글씨가 뭉개진다(실사용
/// 데이터에서 확인). 그 거리에서 필요한 정보는 개별 상호가 아니라 "이 동네에
/// N곳"이고, 그건 구역 이름표가 이미 말해준다. 가까이 가면 다시 보인다.
const _pinNameZoom = 15;

/// 담아둔 핀을 지도에 올리고, 핀이 몰린 동네를 색 면으로 강조한다(스펙 S2).
class PinMap extends ConsumerStatefulWidget {
  const PinMap({super.key});

  @override
  ConsumerState<PinMap> createState() => _PinMapState();
}

class _PinMapState extends ConsumerState<PinMap> {
  KakaoMapController? _controller;

  /// 지도에 올라간 마커. 핀 문서 id로 찾는다. 핀이 늘거나 줄 때 전부 다시
  /// 그리지 않고 달라진 것만 손보기 위해 들고 있는다.
  final Map<String, Poi> _markers = {};

  /// 마커를 그릴 때의 방문 여부. 방문 표시가 바뀌면 색을 바꿔야 해서 그때만
  /// 다시 그린다(스펙 S2: 미방문 진한 색 / 방문 흐린 색).
  final Map<String, bool> _markerVisited = {};

  /// 구역 id로 찾는 색 면과 이름표. 구역은 핀이 하나만 늘어도 묶음이 달라질
  /// 수 있어 마커보다 자주 바뀐다.
  final Map<String, Polygon<BasePoint>> _zoneShapes = {};
  final Map<String, Poi> _zoneLabels = {};

  /// 구역에 속한 핀. 멀리서 볼 때 감출 대상이다. 어느 구역에도 없는 핀은
  /// 감추면 지도에서 사라져 버리므로 그대로 둔다.
  final Set<String> _zonedPinIds = {};

  /// 특정 핀 기준으로 반경 900m 필터링된 핀 ID 목록 (null이면 전체 표시)
  Set<String>? _filteredPinIds;

  int _zoom = _defaultZoom;

  /// 카메라는 첫 로딩에서만 전체 핀에 맞춘다. 계속 맞추면 사용자가 지도를
  /// 움직일 때마다 되돌아간다.
  bool _cameraFitted = false;

  @override
  Widget build(BuildContext context) {
    if (!hasKakaoMapKey) {
      return const _MapNotice(
        '지도 키가 없어요.\n--dart-define=KAKAO_NATIVE_APP_KEY 로 실행해주세요.',
      );
    }

    // 담기로 핀이 늘거나 지도 데이터가 바뀌면 바로 반영
    ref.listen(pinsProvider, (previous, next) {
      final pins = next.value;
      if (pins != null) unawaited(_syncMarkers(pins));
    });

    // 커플이 변경되면 900m 필터를 자동으로 해제하여 데이터가 꼬이지 않게 함
    ref.listen(selectedCoupleProvider, (previous, next) {
      if (previous != next) {
        setState(() {
          _filteredPinIds = null;
          _cameraFitted = false; // 커플 변경 시 카메라를 새 커플 핀에 맞춤
        });
      }
    });

    // 현재 선택된 커플 ID에 해당하는 핀들만 가져옵니다.
    final allPins = ref.watch(pinsProvider).value ?? const <Pin>[];
    final currentCoupleId = ref.watch(selectedCoupleProvider);

    // 커플 번호별 필터링 + 900m 반경 필터링 적용
    final pins = allPins.where((pin) {
      if (pin.coupleId != currentCoupleId) return false;
      if (_filteredPinIds != null && !_filteredPinIds!.contains(pin.id)) {
        return false;
      }
      return true;
    }).toList();

    // 핀 목록이 바뀔 때 마커를 즉시 동기화하도록 호출
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller != null) {
        unawaited(_syncMarkers(pins));
      }
    });

    return Stack(
      children: [
        _map(pins),
        // 반경 필터가 걸려있을 때 해제할 수 있는 버튼을 상단에 노출
        if (_filteredPinIds != null)
          Positioned(
            left: 16,
            top: 16,
            child: Chip(
              backgroundColor: Colors.amber[100],
              label: const Text('900m 반경 필터 적용중'),
              deleteIcon: const Icon(Icons.close),
              onDeleted: () {
                setState(() {
                  _filteredPinIds = null;
                  _cameraFitted = false;
                });
              },
            ),
          ),
        if (pins.isEmpty && _filteredPinIds == null)
          const Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: _EmptyHint('인스타그램에서 장소를 공유하면 여기 지도에 쌓입니다.'),
          ),
      ],
    );
  }

  Widget _map(List<Pin> pins) {
    return KakaoMap(
      option: KakaoMapOption(
        position: pins.isEmpty
            ? _defaultCenter
            : LatLng(pins.first.lat, pins.first.lng),
        zoomLevel: _defaultZoom,
      ),
      onPoiClick: _onPoiClick,
      onCameraMoveEnd: (position, gestureType) {
        if (position.zoomLevel == _zoom) return;
        _zoom = position.zoomLevel;
        unawaited(_applyZoomVisibility());
      },
      onMapReady: (controller) {
        _controller = controller;
        unawaited(controller.labelLayer.setClickable(true));
        unawaited(_syncMarkers(pins));
      },
    );
  }

  void _onPoiClick(LabelController labelController, Poi poi) {
    final id = poi.id;
    if (id.startsWith(_zonePoiPrefix)) {
      _showZone(id.substring(_zonePoiPrefix.length));
      return;
    }
    if (!id.startsWith(_pinPoiPrefix)) return;

    final pinId = id.substring(_pinPoiPrefix.length);
    for (final pin in ref.read(pinsProvider).value ?? const <Pin>[]) {
      if (pin.id == pinId) {
        _showPin(pin);
        return;
      }
    }
  }

  Future<void> _syncMarkers(List<Pin> pins) async {
    final controller = _controller;
    if (controller == null) return;

    final ids = {for (final pin in pins) pin.id};
    for (final entry in _markers.entries.toList()) {
      if (ids.contains(entry.key)) continue;
      await controller.labelLayer.removePoi(entry.value);
      _markers.remove(entry.key);
      _markerVisited.remove(entry.key);
    }

    for (final pin in pins) {
      final drawn = _markers[pin.id];
      if (drawn != null && _markerVisited[pin.id] == pin.isVisited) continue;
      if (drawn != null) await controller.labelLayer.removePoi(drawn);

      _markers[pin.id] = await controller.labelLayer.addPoi(
        LatLng(pin.lat, pin.lng),
        style: pin.isVisited ? _visitedMarkerStyle : _markerStyle,
        text: pin.name,
        id: '$_pinPoiPrefix${pin.id}',
      );
      _markerVisited[pin.id] = pin.isVisited;
    }

    await _syncZones(controller, pins);

    if (!_cameraFitted && pins.isNotEmpty) {
      _cameraFitted = true;
      await controller.moveCamera(
        CameraUpdate.fitMapPoints([
          for (final pin in pins) LatLng(pin.lat, pin.lng),
        ], padding: 64),
      );
      _zoom = (await controller.getCameraPosition()).zoomLevel;
    }

    await _applyZoomVisibility();
  }

  Future<void> _applyZoomVisibility() async {
    final showNames = _zoom >= _pinNameZoom;
    for (final entry in _markers.entries) {
      final shouldShow = showNames || !_zonedPinIds.contains(entry.key);
      if (entry.value.visible == shouldShow) continue;
      if (shouldShow) {
        await entry.value.show();
      } else {
        await entry.value.hide();
      }
    }
  }

  Future<void> _syncZones(KakaoMapController controller, List<Pin> pins) async {
    final zones = calculateZones(pins).zones;
    final ids = {for (final zone in zones) zone.id};

    _zonedPinIds
      ..clear()
      ..addAll([
        for (final zone in zones)
          for (final pin in zone.pins) pin.id,
      ]);

    for (final entry in _zoneShapes.entries.toList()) {
      if (ids.contains(entry.key)) continue;
      await controller.shapeLayer.removePolygonShape(entry.value);
      _zoneShapes.remove(entry.key);
    }
    for (final entry in _zoneLabels.entries.toList()) {
      if (ids.contains(entry.key)) continue;
      await controller.labelLayer.removePoi(entry.value);
      _zoneLabels.remove(entry.key);
    }

    for (final zone in zones) {
      if (_zoneShapes.containsKey(zone.id)) continue;

      _zoneShapes[zone.id] = await controller.shapeLayer.addPolygonShape(
        CirclePoint(zone.radiusMeters, LatLng(zone.centerLat, zone.centerLng)),
        _zoneStyle,
      );
      _zoneLabels[zone.id] = await controller.labelLayer.addPoi(
        LatLng(zone.centerLat, zone.centerLng),
        style: _zoneLabelStyle,
        text: zone.name.isEmpty
            ? '${zone.pinCount}곳'
            : '${zone.name} ${zone.pinCount}곳',
        id: '$_zonePoiPrefix${zone.id}',
      );
    }
  }

  void _showZone(String zoneId) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ZoneDetailScreen(zoneId: zoneId),
      ),
    );
  }

  /// 핀 클릭 시 하단 알림에 900m 반경 필터 버튼을 추가합니다.
  void _showPin(Pin pin) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pin.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(pin.address, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                setState(() {
                  final currentCoupleId = ref.read(selectedCoupleProvider);
                  final allPins = ref.read(pinsProvider).value ?? const <Pin>[];
                  
                  // 선택한 핀 기준 반경 900m 이내인 핀만 필터링 세트에 담음
                  _filteredPinIds = {
                    for (final p in allPins)
                      if (p.coupleId == currentCoupleId &&
                          _calculateDistanceMeters(pin.lat, pin.lng, p.lat, p.lng) <= 900)
                        p.id
                  };
                  _cameraFitted = false; // 필터 결과에 맞춰 카메라 포커스 재조정
                });
              },
              child: const Text('900m 내만'),
            ),
          ],
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  double _calculateDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadius = 6371000.0; // meters
    final dLat = (lat2 - lat1) * (math.pi / 180.0);
    final dLon = (lon2 - lon1) * (math.pi / 180.0);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * (math.pi / 180.0)) *
            math.cos(lat2 * (math.pi / 180.0)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.asin(math.sqrt(a));

    return earthRadius * c;
  }
}

final _markerStyle = PoiStyle(
  textStyle: const [
    PoiTextStyle(
      color: Color(0xFF1A365D),
      size: 22,
      stroke: 3,
      strokeColor: Colors.white,
    ),
  ],
);

final _visitedMarkerStyle = PoiStyle(
  textStyle: const [
    PoiTextStyle(
      color: Color(0xFF9AA5B1),
      size: 22,
      stroke: 3,
      strokeColor: Colors.white,
    ),
  ],
);

final _zoneStyle = PolygonStyle(
  const Color(0x332B6CB0),
  strokeWidth: 2,
  strokeColor: const Color(0x992B6CB0),
);

final _zoneLabelStyle = PoiStyle(
  textStyle: const [
    PoiTextStyle(
      color: Color(0xFF2B6CB0),
      size: 28,
      stroke: 4,
      strokeColor: Colors.white,
    ),
  ],
);

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.surface.withValues(alpha: 0.94),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}

class _MapNotice extends StatelessWidget {
  const _MapNotice(this.message);

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