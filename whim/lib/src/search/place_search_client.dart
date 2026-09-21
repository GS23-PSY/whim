import '../pins/pin.dart';

/// 검색 결과 후보 하나. 담기 시트에서 탭하면 이 값이 그대로 Pin이 된다.
class PlaceCandidate {
  const PlaceCandidate({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.address,
    required this.category,
    this.placeUrl,
  });

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String address;
  final PinCategory category;
  final String? placeUrl;
}

/// 장소 검색 공급자를 갈아끼울 수 있게 한 겹 둔다. 카카오 로컬의 응답 데이터
/// 저장 허용 범위가 아직 확정되지 않아, 공급자를 바꿔야 할 가능성이 남아 있다.
abstract interface class PlaceSearchClient {
  Future<List<PlaceCandidate>> search(String query);
}

/// 사용자에게 보여줄 수 있는 검색 실패. [message]는 그대로 시트에 띄운다.
class PlaceSearchException implements Exception {
  const PlaceSearchException(this.message);

  final String message;

  @override
  String toString() => 'PlaceSearchException: $message';
}
