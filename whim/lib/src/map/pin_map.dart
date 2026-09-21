import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';

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
    await KakaoMapSdk.instance.initialize(kakaoNativeAppKey);
  } catch (error, stackTrace) {
    developer.log('카카오맵 SDK 초기화 실패', error: error, stackTrace: stackTrace);
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

    // 담기로 핀이 늘면 지도에도 바로 올라와야 한다.
    ref.listen(pinsProvider, (previous, next) {
      final pins = next.value;
      if (pins != null) unawaited(_syncMarkers(pins));
    });

    final pins = ref.watch(pinsProvider).value ?? const <Pin>[];

    return Stack(
      children: [
        _map(pins),
        // 첫 실행에는 지도만 덩그러니 떠서 무엇을 해야 하는지 알 수 없다.
        // 지도를 가리지 않게 위에 한 줄만 올린다.
        if (pins.isEmpty)
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
        // 지도가 뜨는 순간 엉뚱한 곳을 비추지 않도록 가장 최근에 담은 핀을
        // 중심으로 시작한다. 카메라는 마커를 올린 뒤 전체에 맞춘다.
        position: pins.isEmpty
            ? _defaultCenter
            : LatLng(pins.first.lat, pins.first.lng),
        zoomLevel: _defaultZoom,
      ),
      // 개별 Poi의 onClick은 호출되지 않는다(기기에서 확인). 클릭은 지도
      // 위젯으로 한 번에 올라오므로 id를 보고 무엇을 눌렀는지 가린다.
      onPoiClick: _onPoiClick,
      onCameraMoveEnd: (position, gestureType) {
        if (position.zoomLevel == _zoom) return;
        _zoom = position.zoomLevel;
        unawaited(_applyZoomVisibility());
      },
      onMapReady: (controller) {
        _controller = controller;
        // 기본 라벨 레이어는 클릭을 받지 않는다. 켜지 않으면 마커도 구역도
        // 눌리지 않는다(기기에서 확인).
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
      // 카메라를 코드로 옮길 때는 onCameraMoveEnd가 오지 않을 수 있어 직접 읽는다.
      _zoom = (await controller.getCameraPosition()).zoomLevel;
    }

    await _applyZoomVisibility();
  }

  /// 줌에 따라 구역 안 핀의 이름표를 감추거나 되살린다.
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

  /// 스펙 S2: 밀집 구역을 색 면으로 강조한다.
  ///
  /// 구역은 저장하지 않고 핀이 바뀔 때마다 다시 계산한다(스펙 §5). 핀 100개
  /// 이하라 계산보다 지도에 다시 그리는 비용이 크므로, 달라진 구역만 손본다.
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

  void _showPin(Pin pin) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${pin.name}\n${pin.address}'),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

/// 아이콘 이미지를 묶지 않는다. 지도에서 필요한 것은 "어디에 무엇을 담아뒀나"라
/// 점 하나보다 상호명이 그대로 보이는 쪽이 그 일을 한다. 흰 테두리는 어떤
/// 지도 배경 위에서도 글씨가 읽히게 한다.
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

/// 이미 다녀온 곳은 흐리게(스펙 S2). 지도를 열었을 때 다음에 갈 곳이 먼저
/// 눈에 들어와야 한다.
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

/// 구역은 배경이지 주인공이 아니다. 옅게 깔아 그 위의 상호명이 읽히게 한다.
final _zoneStyle = PolygonStyle(
  const Color(0x332B6CB0),
  strokeWidth: 2,
  strokeColor: const Color(0x992B6CB0),
);

/// 구역 이름은 개별 핀보다 크게, 같은 계열의 진한 색으로 둔다.
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
