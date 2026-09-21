import '../pins/pin.dart';

/// 공유 텍스트에서 뽑아낸 담기 힌트.
///
/// 스펙 S1은 "장소명 후보를 추출해 검색창에 미리 채운다 (실패해도 됨)"이다.
/// 인스타그램이 이 앱의 핵심 유입 경로인데 인스타 캡션은 장소명이 문장 속에
/// 섞여 들어온다. 길다는 이유로 버리면 프리필이 늘 비어 있게 되므로, 길면
/// 버리지 않고 조사·서술어를 걷어낸 뒤 단어 경계에서 자른다 — 사용자가
/// 고칠 수 있는 값이 빈 칸보다 낫다.
class SharedPlaceHint {
  const SharedPlaceHint({
    required this.query,
    required this.sourceType,
    this.sourceUrl,
  });

  /// 검색창에 미리 채울 장소명 후보. 끝까지 못 뽑았으면 빈 문자열.
  final String query;

  /// 스펙 §4 pins.sourceType, §6 이벤트 파라미터.
  final PinSourceType sourceType;

  /// 스펙 §4 pins.sourceUrl. 공유 문구에 URL이 없으면 null.
  final String? sourceUrl;

  bool get hasQuery => query.isNotEmpty;
}

/// 검색어 길이 상한. 카카오에 등록된 장소명은 대개 20자 안쪽이다.
const _maxQueryLength = 25;

/// 후보 하나와 신뢰도.
///
/// 같은 자리의 텍스트라도 출처에 따라 믿을 수 있는 정도가 다르다. 네이버·
/// 카카오 공유의 첫 줄은 앱이 만든 장소명이지만, 인스타의 첫 줄은 사람이 쓴
/// 문장이다. 그래서 위치가 아니라 점수로 고른다.
class _Candidate {
  const _Candidate(this.text, this.score);

  final String text;
  final int score;
}

const _scoreQuoted = 100;

/// 네이버·카카오·직접 입력의 첫 줄.
const _scoreTrustedFirstLine = 80;

/// 인스타 첫 줄이 문장이 아니라 이름처럼 보일 때.
const _scoreCaptionName = 55;

/// 지역·지점 접미가 들어간 해시태그(#성수동카페).
const _scorePlaceTag = 50;

/// 그 밖의 해시태그(#어니언성수).
const _scoreTag = 40;

/// 긴 캡션에서 추려낸 구절.
const _scoreCaption = 30;

/// 마지막 수단들. 이것마저 없으면 빈 칸으로 두고 사용자가 입력한다.
const _scoreMention = 25;
const _scoreGenericTag = 15;

final _urlPattern = RegExp(r'https?://\S+');
final _hashtagPattern = RegExp(r'#([^\s#@]+)');
final _mentionPattern = RegExp(r'@([A-Za-z0-9._]+)');

/// 공유 문구에 늘 끼어드는 앱 이름과 안내 문구. 검색어에 남으면 결과가 0건이 된다.
final _boilerplatePattern = RegExp(
  r'네이버\s*지도|카카오\s*맵|카카오\s*지도|kakaomap|naver\s*map'
  r'|에서\s*확인하기|확인하기|공유하기|길찾기',
  caseSensitive: false,
);

/// 공유 문구가 장소명을 따옴표로 감싸는 경우. 여는 따옴표 앞에 공백이나 줄
/// 시작을 요구해 `Joe's`처럼 말 중간에 낀 어퍼스트로피를 후보로 잡지 않는다.
final _quotedPattern = RegExp(
  '(?:^|\\s)[\'"‘“「『](.{1,$_maxQueryLength}?)'
  '[\'"’”」』]',
  multiLine: true,
);

/// 캡션은 첫 구절 뒤에 이모지·설명·문장부호가 따라온다. 거기서 끊는다.
/// 두 번째 갈래가 이모지와 그림문자를 전부 잡는다.
final _phraseBreak = RegExp(
  "[.!?…‥~\\n·|•/]"
  "|[^\\s가-힣ㄱ-ㅎㅏ-ㅣa-zA-Z0-9&\\-()'\",]",
);

/// 한국어 캡션의 서술어 어미. 이런 토큰은 장소명이 아니다.
final _predicateEnding = RegExp(
  r'(는데|던데|어요|아요|예요|에요|해요|했어요?|합니다|입니다|네요|더라|드라'
  r'|거든요?|같아요?|겠다|왔어요?|갔어요?|있어요?|없어요?|이야|스럽다|하다|했다'
  r'|이다|였다|뻤다|쳤다|린다|한다)$',
);

/// 캡션에서만 떼어낸다. 장소명에 붙은 조사는 검색을 방해한다(베이글이 → 베이글).
final _particleEnding = RegExp(r'(이|가|은|는|을|를|도|의|에|에서|으로|로|와|과|랑|이랑)$');

/// 캡션 앞뒤에 붙는 군더더기. 장소를 가리키지 않는다.
const _fillerWords = {
  '오늘',
  '어제',
  '방금',
  '이번에',
  '여기',
  '거기',
  '진짜',
  '완전',
  '너무',
  '정말',
  '제일',
  '그냥',
  '우리',
  '다들',
  '요즘',
  '드디어',
  '역시',
};

/// 끝에 붙으면 검색어를 망치는 표현.
const _trailingNoise = {
  '추천',
  '추천합니다',
  '최고',
  '존맛',
  '존맛탱',
  '맛집',
  '후기',
  '내돈내산',
  '방문',
  '오픈',
  '신상',
  '가봤어요',
  '다녀왔어요',
};

/// 어느 게시물에나 붙는 태그. 검색어로 쓰면 아무 곳이나 나온다.
const _genericTags = {
  '맛집',
  '카페',
  '디저트',
  '베이커리',
  '추천',
  '일상',
  '데일리',
  '소통',
  '맞팔',
  '선팔',
  '좋아요',
  '팔로우',
  '먹스타그램',
  '맛스타그램',
  '카페스타그램',
  '인스타',
  '인스타그램',
  '존맛',
  '존맛탱',
  'jmt',
  '내돈내산',
  '광고',
  '협찬',
  'ootd',
  '오오티디',
  '여행',
  '주말',
  '데이트',
  '핫플',
};

/// 지역·지점을 가리키는 접미가 들어 있으면 장소를 가리킬 확률이 높다.
final _placeishTag = RegExp(r'[가-힣]{1,4}(동|로|길|역|점|리|읍|면)');

/// 앱 이름을 지우면 남는 구분 기호들. 검색어 양끝에서 털어낸다.
const _edgeJunk =
    ' \t|:-–—·,./!?[](){}<>'
    '"\'‘’“”「」『』';

/// URL 끝에 붙은 문장 부호만 털어낸다. `/`는 경로의 일부라 건드리지 않는다.
const _urlTrailingJunk = '.,;:!?)]}>"\'”’';

/// 공유된 원문 한 덩어리를 담기 시트가 바로 쓸 수 있는 힌트로 바꾼다.
SharedPlaceHint parseSharedText(String raw) {
  final urlMatch = _urlPattern.firstMatch(raw);
  final sourceUrl = urlMatch == null
      ? null
      : _trimEnd(urlMatch[0]!, _urlTrailingJunk);
  final sourceType = _sourceTypeOf(sourceUrl);

  final withoutUrls = raw.replaceAll(_urlPattern, ' ');
  final prose = withoutUrls
      .replaceAll(_hashtagPattern, ' ')
      .replaceAll(_mentionPattern, ' ')
      .replaceAll(_boilerplatePattern, ' ');

  final candidates = [
    ..._fromQuote(prose),
    ..._fromFirstLine(prose, sourceType),
    // 해시태그와 멘션은 prose에서 지워지므로 원문에서 다시 긁는다.
    ..._fromHashtags(withoutUrls),
    ..._fromMentions(withoutUrls),
  ];

  return SharedPlaceHint(
    query: _best(candidates),
    sourceType: sourceType,
    sourceUrl: sourceUrl,
  );
}

/// 점수가 가장 높은 후보를 쓴다. 길면 버리지 않고 단어 경계에서 자른다.
String _best(List<_Candidate> candidates) {
  _Candidate? best;
  for (final candidate in candidates) {
    final text = _capWords(_normalize(candidate.text));
    // 한 글자는 검색해도 의미가 없다.
    if (text.length < 2) continue;
    if (best == null || candidate.score > best.score) {
      best = _Candidate(text, candidate.score);
    }
  }
  return best?.text ?? '';
}

Iterable<_Candidate> _fromQuote(String prose) {
  final quoted = _quotedPattern.firstMatch(prose)?[1];
  return quoted == null ? const [] : [_Candidate(quoted, _scoreQuoted)];
}

Iterable<_Candidate> _fromFirstLine(String prose, PinSourceType sourceType) {
  final firstLine = prose
      .split('\n')
      .map(_normalize)
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (firstLine.isEmpty) return const [];

  // 네이버·카카오 공유의 첫 줄은 앱이 넣은 장소명이고, URL 없이 들어온 텍스트는
  // 사용자가 직접 장소명을 적은 것이다. 둘 다 그대로 믿는다.
  if (sourceType != PinSourceType.instagram) {
    return [
      _Candidate(
        _trimTrailingNoise(_firstPhrase(firstLine)),
        _scoreTrustedFirstLine,
      ),
    ];
  }

  // 인스타 첫 줄은 사람이 쓴 캡션이다. 이름처럼 보이는 짧은 줄만 믿고,
  // 문장이면 조사·서술어를 걷어낸 구절로 낮춰 잡는다.
  if (firstLine.length <= 15 && !_looksLikeSentence(firstLine)) {
    return [_Candidate(_trimTrailingNoise(firstLine), _scoreCaptionName)];
  }
  final phrase = _captionPhrase(firstLine);
  return phrase.isEmpty ? const [] : [_Candidate(phrase, _scoreCaption)];
}

/// 캡션에 장소명이 태그로 붙는 일이 많다(#어니언성수). 인스타에서 프리필을
/// 건질 수 있는 가장 확실한 자리다.
Iterable<_Candidate> _fromHashtags(String text) {
  return _hashtagPattern.allMatches(text).map((match) {
    final tag = match[1]!;
    if (_genericTags.contains(tag.toLowerCase())) {
      return _Candidate(tag, _scoreGenericTag);
    }
    return _Candidate(
      tag,
      _placeishTag.hasMatch(tag) ? _scorePlaceTag : _scoreTag,
    );
  });
}

/// 가게 계정을 태그한 경우(@onion_seongsu). 검색이 맞을 확률은 낮지만
/// 빈 칸보다는 사용자가 고칠 거리가 있는 편이 낫다.
Iterable<_Candidate> _fromMentions(String text) {
  return _mentionPattern
      .allMatches(text)
      .map(
        (match) => _Candidate(
          match[1]!.replaceAll(RegExp(r'[._]+'), ' '),
          _scoreMention,
        ),
      );
}

/// 문장에서 장소명만 남기려 한다. 조사·서술어·군더더기를 토큰 단위로 걷어낸다.
/// 형태소 분석이 아니라 어미 규칙이라 완벽하지 않다 — 사용자가 고칠 수 있는
/// 값을 만드는 것이 목적이다.
String _captionPhrase(String line) {
  final words = _firstPhrase(line)
      .split(' ')
      .where((word) => word.isNotEmpty)
      .where((word) => !_fillerWords.contains(word))
      .where((word) => !_predicateEnding.hasMatch(word))
      .map(_stripParticle)
      .where((word) => word.length >= 2)
      .toList();
  return _trimTrailingNoise(words.join(' '));
}

/// 이모지나 문장부호가 나오면 그 앞까지만 쓴다.
String _firstPhrase(String line) {
  final breakAt = _phraseBreak.firstMatch(line);
  return _normalize(breakAt == null ? line : line.substring(0, breakAt.start));
}

String _stripParticle(String word) {
  final stripped = word.replaceFirst(_particleEnding, '');
  // 조사를 떼서 한 글자가 되면 원래 단어가 조사로 끝난 게 아니었다는 뜻이다.
  return stripped.length >= 2 ? stripped : word;
}

bool _looksLikeSentence(String line) {
  final words = line.split(' ').where((word) => word.isNotEmpty);
  return words.isNotEmpty && _predicateEnding.hasMatch(words.last);
}

String _trimTrailingNoise(String value) {
  final words = value.split(' ').where((word) => word.isNotEmpty).toList();
  while (words.length > 1 && _trailingNoise.contains(words.last)) {
    words.removeLast();
  }
  return words.join(' ');
}

/// 길면 버리는 대신 단어 경계에서 자른다.
String _capWords(String value) {
  if (value.length <= _maxQueryLength) return value;

  final kept = <String>[];
  var length = 0;
  for (final word in value.split(' ')) {
    final next = kept.isEmpty ? word.length : length + 1 + word.length;
    if (next > _maxQueryLength) break;
    kept.add(word);
    length = next;
  }
  // 첫 단어부터 상한을 넘으면(해시태그 한 덩어리 등) 그대로 잘라낸다.
  return kept.isEmpty ? value.substring(0, _maxQueryLength) : kept.join(' ');
}

PinSourceType _sourceTypeOf(String? url) {
  final host = url == null ? '' : (Uri.tryParse(url)?.host.toLowerCase() ?? '');
  if (host.contains('instagram.com') || host.contains('instagr.am')) {
    return PinSourceType.instagram;
  }
  // naver.me는 네이버 지도 공유의 단축 링크다.
  if (host.contains('naver.me') || host.contains('naver.com')) {
    return PinSourceType.naver;
  }
  // kko.kr은 카카오맵 공유의 단축 링크다.
  if (host.contains('kakao.com') || host.contains('kko.kr')) {
    return PinSourceType.kakao;
  }
  // 출처를 모르는 링크나 직접 입력한 텍스트는 수동 담기와 같게 본다.
  return PinSourceType.manual;
}

String _normalize(String value) =>
    _trimChars(value.replaceAll(RegExp(r'\s+'), ' '), _edgeJunk);

String _trimChars(String value, String junk) {
  var start = 0;
  var end = value.length;
  while (start < end && junk.contains(value[start])) {
    start++;
  }
  while (end > start && junk.contains(value[end - 1])) {
    end--;
  }
  return value.substring(start, end);
}

String _trimEnd(String value, String junk) {
  var end = value.length;
  while (end > 0 && junk.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}
