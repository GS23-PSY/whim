import 'package:flutter_test/flutter_test.dart';
import 'package:whim/src/pins/pin.dart';
import 'package:whim/src/zones/zone_calculator.dart';

// 스펙 §10이 테스트를 요구하는 유일한 곳이다. 구역 계산이 틀리면 지도에서
// 동네가 엉뚱하게 묶이는데, 눈으로는 "원래 그런가 보다" 하고 넘어가게 된다.

/// 위도 0.001도는 약 111m, 경도 0.001도는 서울 위도에서 약 88m다.
const _seongsu = (lat: 37.5445, lng: 127.0557);
const _mangwon = (lat: 37.5556, lng: 126.9019);

Pin _pin(String id, double lat, double lng, {String address = ''}) => Pin(
  id: id,
  name: id,
  lat: lat,
  lng: lng,
  address: address,
  category: PinCategory.etc,
  sourceType: PinSourceType.manual,
  createdAt: DateTime(2026),
);

void main() {
  group('구역 묶기', () {
    test('400m 안에 3개가 모이면 구역이 된다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.001, _seongsu.lng),
        _pin('c', _seongsu.lat, _seongsu.lng + 0.001),
      ]);

      expect(result.zones, hasLength(1));
      expect(result.zones.single.pinCount, 3);
      expect(result.loosePins, isEmpty);
    });

    test('2개만 뭉치면 구역을 만들지 않는다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.001, _seongsu.lng),
      ]);

      expect(result.zones, isEmpty);
      expect(result.loosePins, hasLength(2));
    });

    test('멀리 떨어진 두 무리는 각각 구역이 된다', () {
      final result = calculateZones([
        for (var i = 0; i < 3; i++)
          _pin('성수$i', _seongsu.lat + i * 0.001, _seongsu.lng),
        for (var i = 0; i < 4; i++)
          _pin('망원$i', _mangwon.lat + i * 0.001, _mangwon.lng),
      ]);

      expect(result.zones, hasLength(2));
      // 핀이 많은 동네가 먼저 온다.
      expect(result.zones.first.pinCount, 4);
      expect(result.zones.last.pinCount, 3);
      expect(result.loosePins, isEmpty);
    });

    test('300m씩 이어지면 끝에서 끝이 900m여도 한 동네로 본다', () {
      // 도보권이 사슬처럼 이어지는 경우다. 400m마다 끊는 것이 오히려
      // 사람이 느끼는 동네와 멀다.
      final result = calculateZones([
        for (var i = 0; i < 4; i++)
          _pin('p$i', _seongsu.lat + i * 0.0027, _seongsu.lng),
      ]);

      expect(result.zones, hasLength(1));
      expect(result.zones.single.pinCount, 4);
    });

    test('eps 밖의 핀은 끌려 들어오지 않는다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.0009, _seongsu.lng),
        // a에서 약 610m, b에서도 약 510m라 어느 쪽의 이웃도 아니다.
        _pin('c', _seongsu.lat + 0.0055, _seongsu.lng),
      ]);

      expect(result.zones, isEmpty);
      expect(result.loosePins, hasLength(3));
    });

    test('핀이 없으면 구역도 없다', () {
      final result = calculateZones([]);

      expect(result.zones, isEmpty);
      expect(result.loosePins, isEmpty);
    });

    test('같은 묶음이면 순서가 달라도 구역 id가 같다', () {
      final pins = [
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.001, _seongsu.lng),
        _pin('c', _seongsu.lat, _seongsu.lng + 0.001),
      ];

      final forward = calculateZones(pins).zones.single;
      final backward = calculateZones(pins.reversed.toList()).zones.single;

      expect(forward.id, backward.id);
    });
  });

  group('구역 이름', () {
    test('지번 주소에서 최빈 동을 쓴다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng, address: '서울 성동구 성수동2가 1-1'),
        _pin(
          'b',
          _seongsu.lat + 0.001,
          _seongsu.lng,
          address: '서울 성동구 성수동1가 2-2',
        ),
        _pin(
          'c',
          _seongsu.lat,
          _seongsu.lng + 0.001,
          address: '서울 마포구 상수동 3-3',
        ),
      ]);

      expect(result.zones.single.name, '성수동');
    });

    test('도로명 주소뿐이면 구·시 이름으로 떨어뜨린다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng, address: '서울 성동구 아차산로 7'),
        _pin(
          'b',
          _seongsu.lat + 0.001,
          _seongsu.lng,
          address: '서울 성동구 성수이로 78',
        ),
        _pin(
          'c',
          _seongsu.lat,
          _seongsu.lng + 0.001,
          address: '서울 성동구 왕십리로5길 9',
        ),
      ]);

      expect(result.zones.single.name, '성동구');
    });

    test('주소가 비어 있으면 이름 없이 둔다', () {
      final result = calculateZones([
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.001, _seongsu.lng),
        _pin('c', _seongsu.lat, _seongsu.lng + 0.001),
      ]);

      expect(result.zones.single.name, isEmpty);
    });
  });

  group('거리', () {
    test('위도 0.001도는 약 111m다', () {
      final meters = distanceMeters(
        _pin('a', _seongsu.lat, _seongsu.lng),
        _pin('b', _seongsu.lat + 0.001, _seongsu.lng),
      );

      expect(meters, closeTo(111, 2));
    });
  });
}
