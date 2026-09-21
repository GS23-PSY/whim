import 'package:cloud_firestore/cloud_firestore.dart';

/// 스펙 §4의 category 값. Firestore에는 [wire] 문자열 그대로 들어간다.
enum PinCategory {
  restaurant('음식점'),
  cafe('카페'),
  shopping('쇼핑'),
  sightseeing('관광'),
  etc('기타');

  const PinCategory(this.wire);

  final String wire;

  static PinCategory fromWire(String? value) => PinCategory.values.firstWhere(
    (category) => category.wire == value,
    orElse: () => PinCategory.etc,
  );
}

/// 핀이 어느 앱에서 공유돼 들어왔는지. 담기 완료율을 유입 경로별로 나눠 보려면
/// 필요하다 (스펙 §6의 sourceType 파라미터).
enum PinSourceType {
  instagram('instagram'),
  naver('naver'),
  kakao('kakao'),
  manual('manual');

  const PinSourceType(this.wire);

  final String wire;

  static PinSourceType fromWire(String? value) =>
      PinSourceType.values.firstWhere(
        (source) => source.wire == value,
        orElse: () => PinSourceType.manual,
      );
}

class Pin {
  const Pin({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.address,
    required this.category,
    required this.sourceType,
    required this.createdAt,
    this.sourceUrl,
    this.thumbnailUrl,
    this.memo,
    this.visitedAt,
    this.zoneId,
  });

  factory Pin.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    return Pin(
      id: doc.id,
      name: data['name'] as String? ?? '',
      lat: (data['lat'] as num?)?.toDouble() ?? 0,
      lng: (data['lng'] as num?)?.toDouble() ?? 0,
      address: data['address'] as String? ?? '',
      category: PinCategory.fromWire(data['category'] as String?),
      sourceType: PinSourceType.fromWire(data['sourceType'] as String?),
      sourceUrl: data['sourceUrl'] as String?,
      thumbnailUrl: data['thumbnailUrl'] as String?,
      memo: data['memo'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      visitedAt: (data['visitedAt'] as Timestamp?)?.toDate(),
      zoneId: data['zoneId'] as String?,
    );
  }

  final String id;
  final String name;
  final double lat;
  final double lng;
  final String address;
  final PinCategory category;
  final PinSourceType sourceType;
  final String? sourceUrl;
  final String? thumbnailUrl;
  final String? memo;
  final DateTime createdAt;
  final DateTime? visitedAt;
  final String? zoneId;

  bool get isVisited => visitedAt != null;

  Map<String, dynamic> toMap() => {
    'name': name,
    'lat': lat,
    'lng': lng,
    'address': address,
    'category': category.wire,
    'sourceType': sourceType.wire,
    'sourceUrl': sourceUrl,
    'thumbnailUrl': thumbnailUrl,
    'memo': memo,
    // serverTimestamp를 쓰면 오프라인에서 값이 null로 남아 목록 정렬이 흔들린다.
    // 담기는 지하철·건물 안에서도 끝나야 하므로 기기 시각을 쓴다.
    'createdAt': Timestamp.fromDate(createdAt),
    'visitedAt': visitedAt == null ? null : Timestamp.fromDate(visitedAt!),
    'zoneId': zoneId,
  };
}
