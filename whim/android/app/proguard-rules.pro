# 카카오 지도 SDK는 난독화·축소 대상에서 제외해야 한다(공식 문서 요구).
# 릴리스 빌드에서 지도가 인증 단계에서 죽는 것을 막는다.
-keep class com.kakao.vectormap.** { *; }
-keep interface com.kakao.vectormap.**
