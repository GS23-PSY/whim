import 'package:flutter_test/flutter_test.dart';
import 'package:whim/src/pins/pin.dart';
import 'package:whim/src/share/share_text_parser.dart';

// 실제 앱들이 보내는 공유 문구 형태를 고정해 둔다. 담기 시트가 이 결과를
// 그대로 검색창에 넣으므로, 프리필이 조용히 망가지면 담기 성공률이 떨어진다.
void main() {
  group('인스타그램', () {
    test('링크만 오면 살릴 텍스트가 없어 빈 칸이다', () {
      final hint = parseSharedText(
        'https://www.instagram.com/p/C8xYzAbCdEf/?igsh=MWQ1ZGUx',
      );

      expect(hint.sourceType, PinSourceType.instagram);
      expect(
        hint.sourceUrl,
        'https://www.instagram.com/p/C8xYzAbCdEf/?igsh=MWQ1ZGUx',
      );
      expect(hint.query, isEmpty);
      expect(hint.hasQuery, isFalse);
    });

    test('캡션 첫 줄이 이름처럼 짧으면 해시태그보다 먼저 쓴다', () {
      final hint = parseSharedText(
        '어니언 성수\n'
        '#성수동카페 #베이글맛집\n'
        'https://www.instagram.com/reel/C8xYzAbCdEf/',
      );

      expect(hint.sourceType, PinSourceType.instagram);
      expect(hint.query, '어니언 성수');
    });

    test('긴 캡션이어도 버리지 않고 해시태그에서 장소를 건진다', () {
      final hint = parseSharedText(
        '오늘 성수동에서 제일 맛있는 베이글 먹었어요 🥯 웨이팅 30분 각오하고 가세요\n'
        '@onion_seongsu #성수동카페 #베이글맛집 #어니언\n'
        'https://www.instagram.com/reel/C8xYzAbCdEf/',
      );

      expect(hint.sourceType, PinSourceType.instagram);
      // 지역 접미(동)가 든 태그가 그냥 태그보다 장소를 가리킬 확률이 높다.
      expect(hint.query, '성수동카페');
    });

    test('해시태그가 없으면 캡션에서 조사·서술어를 걷어낸다', () {
      final hint = parseSharedText(
        '오늘 성수동 다녀왔는데 여기 베이글이 진짜 미쳤어요\n'
        'https://www.instagram.com/p/C8xYzAbCdEf/',
      );

      expect(hint.sourceType, PinSourceType.instagram);
      expect(hint.query, '성수동 베이글');
    });

    test('캡션 첫 줄이 문장이면 해시태그를 쓴다', () {
      final hint = parseSharedText(
        '여기 진짜 미쳤어요\n#어니언성수\nhttps://www.instagram.com/p/C8xYzAbCdEf/',
      );

      expect(hint.query, '어니언성수');
    });

    test('일반적인 태그만 있으면 그거라도 채운다', () {
      final hint = parseSharedText(
        '미쳤다\n#맛집 #일상\nhttps://www.instagram.com/p/C8xYzAbCdEf/',
      );

      // 검색 결과가 정확할 수는 없지만, 빈 칸이면 사용자가 처음부터 타이핑한다.
      expect(hint.query, '맛집');
    });

    test('건질 것이 멘션뿐이면 멘션을 쓴다', () {
      final hint = parseSharedText(
        '@onion_seongsu\nhttps://www.instagram.com/p/C8xYzAbCdEf/',
      );

      expect(hint.query, 'onion seongsu');
    });

    test('한 줄로 오는 캡션+링크에서도 캡션을 살린다', () {
      final hint = parseSharedText(
        '성수동 어니언 베이글 맛집 https://www.instagram.com/p/C8xYzAbCdEf/',
      );

      expect(hint.sourceType, PinSourceType.instagram);
      // 끝에 붙은 "맛집"은 검색어를 망치므로 떼어낸다.
      expect(hint.query, '성수동 어니언 베이글');
    });

    test('말 중간의 어퍼스트로피를 따옴표로 착각하지 않는다', () {
      final hint = parseSharedText(
        "Joe's pizza\nhttps://www.instagram.com/p/C8xYzAbCdEf/",
      );

      expect(hint.query, "Joe's pizza");
    });

    test('아주 긴 한 단어는 단어 경계가 없어 잘라 쓴다', () {
      final hint = parseSharedText(
        '#성수동에서제일맛있는베이글집어니언성수점추천합니다\n'
        'https://www.instagram.com/p/C8xYzAbCdEf/',
      );

      expect(hint.query.length, 25);
      expect(hint.query, startsWith('성수동에서제일'));
    });
  });

  group('네이버 지도', () {
    test('장소명 뒤에 앱 이름이 붙는 형태', () {
      final hint = parseSharedText(
        '성수동그옆집 : 네이버 지도\nhttps://naver.me/5AbCdEfG',
      );

      expect(hint.sourceType, PinSourceType.naver);
      expect(hint.sourceUrl, 'https://naver.me/5AbCdEfG');
      expect(hint.query, '성수동그옆집');
    });

    test('첫 줄이 앱 이름이면 다음 줄에서 찾는다', () {
      final hint = parseSharedText(
        '네이버 지도\n블루보틀 성수\nhttps://map.naver.com/p/entry/place/1234567',
      );

      expect(hint.sourceType, PinSourceType.naver);
      expect(hint.query, '블루보틀 성수');
    });

    test('따옴표로 감싼 장소명을 첫 줄보다 우선한다', () {
      final hint = parseSharedText(
        "네이버 지도에서 '어니언 성수' 확인하기\nhttps://naver.me/xyz",
      );

      expect(hint.query, '어니언 성수');
    });
  });

  group('카카오맵', () {
    test('앱 이름과 주소 줄을 걷어낸다', () {
      final hint = parseSharedText(
        '카카오맵 - 대림창고\n서울 성동구 성수이로 78\nhttps://kko.kr/AbCdEf',
      );

      expect(hint.sourceType, PinSourceType.kakao);
      expect(hint.query, '대림창고');
    });
  });

  group('그 밖', () {
    test('URL 없는 순수 텍스트는 수동 담기로 본다', () {
      final hint = parseSharedText('망원동 소금집델리');

      expect(hint.sourceType, PinSourceType.manual);
      expect(hint.sourceUrl, isNull);
      expect(hint.query, '망원동 소금집델리');
    });

    test('출처를 모르는 링크도 URL은 보존한다', () {
      final hint = parseSharedText('https://blog.example.com/seongsu-cafe');

      expect(hint.sourceType, PinSourceType.manual);
      expect(hint.sourceUrl, 'https://blog.example.com/seongsu-cafe');
      expect(hint.query, isEmpty);
    });

    test('URL 뒤에 붙은 문장 부호는 링크에서 떼어낸다', () {
      final hint = parseSharedText('여기 좋더라 (https://naver.me/abcdef).');

      expect(hint.sourceUrl, 'https://naver.me/abcdef');
      expect(hint.query, '여기 좋더라');
    });

    test('빈 공유는 조용히 빈 힌트가 된다', () {
      final hint = parseSharedText('   \n  ');

      expect(hint.sourceType, PinSourceType.manual);
      expect(hint.sourceUrl, isNull);
      expect(hint.query, isEmpty);
    });
  });
}
