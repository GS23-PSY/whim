$env:JAVA_HOME = "C:\dev\jdk17"
$env:ANDROID_HOME = "C:\dev\android-sdk"
$env:ANDROID_SDK_ROOT = "C:\dev\android-sdk"
$env:PATH = "C:\dev\flutter\bin;C:\dev\jdk17\bin;C:\dev\android-sdk\platform-tools;C:\dev\android-sdk\cmdline-tools\latest\bin;" + $env:PATH

# flutter_tester가 한글 TEMP 경로에서 죽는다 (flutter test 로드 실패). ASCII로 고정.
$env:TMP = "C:\dev\tmp"
$env:TEMP = "C:\dev\tmp"

