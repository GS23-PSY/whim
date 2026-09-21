import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../pins/pin.dart';
import 'place_search_client.dart';

/// 스펙 §10: 키는 저장소에 넣지 않는다.
/// flutter run --dart-define=KAKAO_REST_API_KEY=...
const kakaoRestApiKey = String.fromEnvironment('KAKAO_REST_API_KEY');

/// 스펙 S1은 후보 3~5개. 더 받아도 시트에서 스크롤을 유발해 탭 수가 늘어난다.
const _candidateCount = 5;

/// 검색이 무한정 매달려 있으면 사용자는 그냥 시트를 닫는다. 끊어서 재시도할
/// 여지를 주는 편이 낫다. 3초 목표를 이미 넘긴 구간이라 넉넉하게만 잡는다.
const _timeout = Duration(seconds: 8);

/// 카카오 카테고리 그룹 코드 → 스펙 §4의 5개 카테고리.
/// 코드가 없는 장소(빈 문자열)도 흔해서 기본값은 기타다.
const _categoryByGroupCode = <String, PinCategory>{
  'FD6': PinCategory.restaurant,
  'CE7': PinCategory.cafe,
  'MT1': PinCategory.shopping,
  'CS2': PinCategory.shopping,
  'AT4': PinCategory.sightseeing,
  'CT1': PinCategory.sightseeing,
};

class KakaoLocalClient implements PlaceSearchClient {
  KakaoLocalClient(this._httpClient, this._apiKey);

  final http.Client _httpClient;
  final String _apiKey;

  @override
  Future<List<PlaceCandidate>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    if (_apiKey.isEmpty) {
      throw const PlaceSearchException(
        '검색 키가 없습니다. --dart-define=KAKAO_REST_API_KEY 로 실행해주세요.',
      );
    }

    final uri = Uri.https('dapi.kakao.com', '/v2/local/search/keyword.json', {
      'query': trimmed,
      'size': '$_candidateCount',
    });

    final http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: {'Authorization': 'KakaoAK $_apiKey'})
          .timeout(_timeout);
    } catch (_) {
      throw const PlaceSearchException('검색에 실패했어요. 다시 시도해주세요.');
    }

    switch (response.statusCode) {
      case 200:
        break;
      case 401:
      case 403:
        throw const PlaceSearchException('검색 키가 거부됐습니다.');
      case 429:
        throw const PlaceSearchException('오늘 검색 한도를 넘었어요.');
      default:
        throw const PlaceSearchException('검색에 실패했어요. 다시 시도해주세요.');
    }

    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final documents = (body as Map<String, dynamic>)['documents'] as List?;
    if (documents == null) return const [];

    return documents
        .cast<Map<String, dynamic>>()
        .map(_toCandidate)
        .nonNulls
        .toList();
  }

  PlaceCandidate? _toCandidate(Map<String, dynamic> document) {
    // x가 경도, y가 위도다. 둘 다 문자열로 온다.
    final lng = double.tryParse(document['x'] as String? ?? '');
    final lat = double.tryParse(document['y'] as String? ?? '');
    final name = document['place_name'] as String?;
    if (lat == null || lng == null || name == null || name.isEmpty) return null;

    final roadAddress = document['road_address_name'] as String?;
    final jibunAddress = document['address_name'] as String?;

    return PlaceCandidate(
      id: document['id'] as String? ?? '',
      name: name,
      lat: lat,
      lng: lng,
      // 도로명이 비어 있는 장소가 있어 지번 주소로 떨어뜨린다.
      address: (roadAddress?.isNotEmpty ?? false)
          ? roadAddress!
          : (jibunAddress ?? ''),
      category:
          _categoryByGroupCode[document['category_group_code'] as String?] ??
          PinCategory.etc,
      placeUrl: document['place_url'] as String?,
    );
  }
}

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final placeSearchClientProvider = Provider<PlaceSearchClient>(
  (ref) => KakaoLocalClient(ref.watch(httpClientProvider), kakaoRestApiKey),
);
