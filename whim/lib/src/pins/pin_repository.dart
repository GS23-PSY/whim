import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth.dart';
import '../common/failure_reporter.dart';
import 'pin.dart';

class PinRepository {
  PinRepository(this._firestore, this._uid, this._failures);

  final FirebaseFirestore _firestore;
  final String _uid;
  final FailureReporter _failures;

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _firestore.collection('users').doc(_uid);

  CollectionReference<Map<String, dynamic>> get _pins =>
      _userDoc.collection('pins');

  /// 스펙 §4의 users/{uid}. 익명 계정마다 한 번만 만들면 되므로 merge로 쓴다.
  /// 앱 시작을 붙잡을 이유가 없어 서버 왕복을 기다리지 않는다.
  void ensureUserDocument() {
    unawaited(
      _userDoc
          .set({'createdAt': Timestamp.now()}, SetOptions(merge: true))
          .catchError((Object error, StackTrace stackTrace) {
            developer.log(
              'user 문서 생성 실패',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  Stream<List<Pin>> watchAll() => _pins
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(Pin.fromDoc).toList());

  /// 담기 완료 시각이 곧 secondsToConfirm의 끝이라, 서버 왕복을 기다리지 않고
  /// 로컬 쓰기가 끝나는 즉시 반환한다. 동기화는 Firestore 캐시가 맡는다.
  String add(Pin pin) {
    final doc = _pins.doc();
    unawaited(
      doc.set(pin.toMap()).catchError((Object error, StackTrace stackTrace) {
        _failures.report('${pin.name} 저장에 실패했어요', error, stackTrace);
      }),
    );
    return doc.id;
  }

  /// 방문 표시. 스펙 §6의 저장→방문 전환율이 여기서 나온다.
  ///
  /// 길 위에서 누르는 버튼이라 서버를 기다리지 않는다. 지하에서 눌러도
  /// 화면은 바로 바뀌고 동기화는 Firestore 캐시가 맡는다.
  void setVisited(String pinId, {required bool visited}) {
    unawaited(
      _pins
          .doc(pinId)
          .update({'visitedAt': visited ? Timestamp.now() : null})
          .catchError((Object error, StackTrace stackTrace) {
            _failures.report('방문 표시를 저장하지 못했어요', error, stackTrace);
          }),
    );
  }

  /// add와 같은 이유로 서버를 기다리지 않는다. 오프라인에서 지워도 목록은
  /// 즉시 반영되고, 실패하면 스트림이 핀을 되살려 사용자가 알게 된다.
  void delete(String pinId) {
    unawaited(
      _pins.doc(pinId).delete().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _failures.report('삭제하지 못했어요', error, stackTrace);
      }),
    );
  }
}

final firestoreProvider = Provider<FirebaseFirestore>((ref) {
  final firestore = FirebaseFirestore.instance;
  // 담기·목록 모두 오프라인에서 동작해야 한다 (스펙 §7).
  firestore.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  return firestore;
});

final pinRepositoryProvider = Provider<PinRepository>(
  (ref) => PinRepository(
    ref.watch(firestoreProvider),
    ref.watch(uidProvider),
    ref.watch(failureReporterProvider),
  ),
);

final pinsProvider = StreamProvider<List<Pin>>(
  (ref) => ref.watch(pinRepositoryProvider).watchAll(),
);
