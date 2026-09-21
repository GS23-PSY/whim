import 'dart:developer' as developer;

import 'package:geolocator/geolocator.dart';

/// 지금 내 위치. 못 받으면 null이다.
///
/// 위치를 못 받는다고 "지금 가기"를 막지 않는다. 권한을 거부했거나 실내라
/// GPS가 안 잡히는 경우가 흔한데, 그때는 구역 중심을 기준으로 가까운 순을
/// 내면 목록의 쓸모가 크게 떨어지지 않는다 — 구역 자체가 도보 5분 범위다.
Future<({double lat, double lng})?> currentLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }

    final position = await Geolocator.getCurrentPosition(
      // 동네 안에서 순서를 가릴 정도면 된다. 정확도를 올리면 그만큼 오래
      // 기다리게 되고, 지금 가기는 기다릴 화면이 아니다.
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 6),
      ),
    );
    return (lat: position.latitude, lng: position.longitude);
  } catch (error, stackTrace) {
    developer.log('현재 위치 실패', error: error, stackTrace: stackTrace);
    return null;
  }
}
