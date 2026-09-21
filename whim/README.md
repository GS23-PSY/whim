# whim

인스타에서 저장한 장소를 지도 위에 올려놓고, 내 저장이 몰려 있는 동네를 알려주는 앱.
Android only. 명세는 `whim-mvp-spec.md`가 유일한 기준이다.

현재 **Phase 1(담기만)** 까지 구현됐다. 공유 수신 → 장소 검색 → Firestore 저장 →
목록. 지도와 구역은 Phase 2다.

## 실행

API 키는 저장소에 넣지 않는다. `--dart-define`으로만 주입한다.

```bash
flutter run --dart-define=KAKAO_REST_API_KEY=<REST API 키> --dart-define=KAKAO_NATIVE_APP_KEY=<네이티브 앱 키>
```

```bash
flutter build apk --debug --dart-define=KAKAO_REST_API_KEY=<REST API 키> --dart-define=KAKAO_NATIVE_APP_KEY=<네이티브 앱 키>
```

키를 빼고 실행해도 앱은 뜬다. REST 키가 없으면 검색이 `검색 키가 없습니다`로
실패하고, 네이티브 앱 키가 없으면 지도 탭에 안내만 뜬다. 담기와 목록은 그대로
동작한다 — 유일한 유입 경로인 담기를 지도 때문에 막지 않는다.

| 키 | 받는 곳 | 쓰는 곳 |
|---|---|---|
| `KAKAO_REST_API_KEY` | [카카오 디벨로퍼스](https://developers.kakao.com) 내 애플리케이션 → 앱 키 → REST API 키 | 장소 키워드 검색 |
| `KAKAO_NATIVE_APP_KEY` | 같은 화면의 **네이티브 앱 키** (REST 키와 다른 키다) | 지도 SDK |

### 지도 SDK 키 해시 등록

카카오 지도 SDK는 앱 키만으로는 인증되지 않는다. 카카오 디벨로퍼스 →
내 애플리케이션 → 플랫폼 → Android에 패키지명 `com.whim.app`과 **키 해시**를
등록해야 한다. 디버그 키 해시는 다음으로 뽑는다.

```bash
keytool -exportcert -alias androiddebugkey -keystore ~/.android/debug.keystore -storepass android -keypass android | openssl sha1 -binary | openssl base64
```

카카오맵 무료 쿼터(지도 SDK 일 30만 건)는 **개발자 계정에서 첫 번째로 활성화한
앱에만** 제공된다. whim 앱에 카카오맵을 활성화해 두어야 한다.

## 필요한 환경

- Flutter 3.47.5 / Dart 3.13.4 (stable)
- JDK 17
- Android SDK: `platforms/android-37.0`, `build-tools/37.0.0`, `ndk/28.2.13676358`
- minSdk 24 / targetSdk 36 / **compileSdk 37** (`receive_sharing_intent` 1.9.0 요구)

## Firebase

`android/app/google-services.json`은 저장소에 포함돼 있다. 이 파일의 값은 클라이언트
식별자일 뿐이고, 실제 접근 통제는 Firestore 보안 규칙이 한다.

규칙은 `firestore.rules`에 있고 **콘솔에 직접 붙여넣어 게시한다**(Firebase CLI를 쓰지
않는다). uid가 곧 소유권이라 남의 `users/{uid}` 아래는 읽기도 막는다.

## 릴리스 빌드 (Play 내부 테스트)

```bash
flutter build appbundle --dart-define=KAKAO_REST_API_KEY=<REST API 키> --dart-define=KAKAO_NATIVE_APP_KEY=<네이티브 앱 키>
```

결과물은 `build/app/outputs/bundle/release/app-release.aab`.

서명 정보는 저장소에 없다. `android/key.properties`(gitignore됨)가 키스토어
경로와 비밀번호를 담고, 키스토어 자체는 저장소 밖(`C:\dev\whim-release.jks`)에
둔다. 이 파일이 없으면 릴리스 서명만 실패하고 디버그 빌드는 그대로 된다.

> **키스토어와 비밀번호를 잃어버리면 같은 앱을 다시 업데이트할 수 없다.**
> 두 개를 함께 백업해 둘 것.

릴리스 빌드는 디버그와 서명 키가 다르므로 **카카오 디벨로퍼스에 릴리스 키
해시를 따로 등록**해야 지도가 뜬다. Play App Signing을 쓰면 구글이 다시
서명하므로, Play Console > 앱 무결성에서 **앱 서명 키의 SHA-1로 만든 해시도**
등록해야 한다.

```bash
keytool -exportcert -alias whim -keystore C:\dev\whim-release.jks | openssl sha1 -binary | openssl base64
```

## 테스트

```bash
flutter test
```

공유 텍스트 파서만 테스트한다(스펙 §10은 DBSCAN만 요구하지만, 인스타·네이버·카카오의
공유 문구 형태가 제각각이라 회귀를 막을 장치가 필요하다).

## 공유 인텐트를 손으로 넣어 테스트하기

인스타 없이 담기 플로우를 확인할 때 쓴다. **Git Bash에서 실행한다** — PowerShell로
보내면 한글이 깨지고, 공백은 기기 셸에서 다시 쪼개지므로 따옴표를 겹쳐 쓴다.

```bash
adb shell am start -n com.whim.app/.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "'블루보틀 성수 : 네이버 지도 https://naver.me/5AbCdEfG'"
```

계측 이벤트를 눈으로 보려면 Analytics 로그를 켠다.

```bash
adb shell setprop log.tag.FA VERBOSE
```

```bash
adb logcat -d | grep -E "pin_created|pin_create_abandoned|app_open"
```

## 계측

스펙 §6의 이벤트를 Analytics와 Firestore `users/{uid}/events` 양쪽에 남긴다.
Phase 1에서 남는 것은 셋이다.

| 이벤트 | 파라미터 |
|---|---|
| `pin_created` | `sourceType`, `secondsToConfirm` |
| `pin_create_abandoned` | `sourceType`, `stage` (`before_search` / `results_shown` / `search_failed`) |
| `app_open` | `trigger` (`share` / `launcher`) |

`secondsToConfirm`은 공유 수신부터 저장 완료까지다. 콜드 스타트는 `main()` 진입
시각을 시작점으로 쓴다(공유를 탭한 시각은 앱이 알 수 없다).

**담기 완료율 = `pin_created` ÷ (`pin_created` + `pin_create_abandoned`)** 가 70%
아래면 다른 어떤 기능보다 먼저 공유 플로우를 다시 만든다.

## 구조

```
lib/
  main.dart              앱 시작, 익명 로그인, 공유 수신 -> 담기 시트 연결
  src/auth/              Firebase Auth 익명 로그인
  src/capture/           담기 바텀시트 (검색 -> 후보 -> 탭 저장)
  src/metrics/           스펙 §6 이벤트
  src/pins/              Pin 모델, Firestore 저장소, 목록 화면
  src/search/            장소 검색 (카카오 로컬) + 공급자 교체용 인터페이스
  src/share/             공유 인텐트 수신, 공유 텍스트에서 장소명 추출
firestore.rules          콘솔에 붙여넣는 보안 규칙
```

## 개발 시 주의

- **프로젝트 경로에 한글을 넣지 말 것.** AGP가 non-ASCII 경로를 거부하고,
  분석 서버도 깨진다. `C:\dev\whim`에서 작업한다
- 같은 이유로 Windows에서 `flutter test`가 한글 `TEMP` 경로에서 죽는다.
  `TMP`/`TEMP`를 ASCII 경로로 지정한다
- 기능 하나 = 커밋 하나 (스펙 §10)

## Phase 1 합격 기준

인스타그램에서 실제로 공유해 **담기가 3초 안에 끝나는지** 직접 재본다.
넘으면 Phase 2로 가지 않고 여기서 고친다.
