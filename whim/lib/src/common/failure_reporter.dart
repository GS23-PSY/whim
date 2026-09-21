import 'dart:async';
import 'dart:developer' as developer;

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 저장이 끝내 실패했을 때 사용자에게 알리는 통로.
///
/// 담기·삭제·방문 표시는 모두 서버를 기다리지 않는다(길 위에서 눌리는
/// 버튼이라 그래야 한다). 대신 영구 실패가 조용히 묻히면 사용자는 담았다고
/// 믿은 곳이 사라진 것을 한참 뒤에야 안다 — 이 앱에서 가장 나쁜 실패다.
///
/// 오프라인은 실패가 아니다. Firestore가 큐에 넣고 나중에 보낸다. 여기 오는
/// 것은 권한·인증처럼 기다려도 해결되지 않는 것들이다.
class FailureReporter {
  final _controller = StreamController<String>.broadcast();

  Stream<String> get messages => _controller.stream;

  void report(String message, Object error, StackTrace stackTrace) {
    developer.log(message, error: error, stackTrace: stackTrace);
    // 크래시는 아니지만 사용자 데이터가 걸린 실패다. 파일럿에서 몇 번
    // 일어나는지 봐야 규칙 문제인지 일시적 장애인지 가릴 수 있다.
    unawaited(
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: message,
        fatal: false,
      ),
    );
    if (!_controller.isClosed) _controller.add(message);
  }

  void dispose() => _controller.close();
}

final failureReporterProvider = Provider<FailureReporter>((ref) {
  final reporter = FailureReporter();
  ref.onDispose(reporter.dispose);
  return reporter;
});

final failureMessagesProvider = StreamProvider<String>(
  (ref) => ref.watch(failureReporterProvider).messages,
);
