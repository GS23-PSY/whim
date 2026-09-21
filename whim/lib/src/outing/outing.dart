import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth.dart';
import '../common/failure_reporter.dart';
import '../pins/pin_repository.dart';

/// 스펙 S3의 시간 예산.
///
/// [maxPins]는 스펙이 정해주지 않은 값이다. 한 곳에서 머무는 시간과 이동을
/// 합쳐 40분쯤으로 보고 잡았다. 많이 보여주면 고르는 데 시간을 쓰게 되고,
/// 적게 보여주면 지금 문 닫은 곳만 남을 수 있다. 실사용에서 조정한다.
enum OutingBudget {
  twoHours(120, '2시간', 3),
  threeHours(180, '3시간', 5),
  fourPlus(240, '4시간+', 0);

  const OutingBudget(this.minutes, this.label, this.maxPins);

  final int minutes;
  final String label;

  /// 0이면 제한 없이 그 구역의 미방문 핀을 전부 보여준다.
  final int maxPins;
}

/// 스펙 §4 users/{uid}/outings/{outingId}.
///
/// 외출 기록은 사용자에게 보여주는 화면이 없다. 저장→방문 전환이 "지금 가기"를
/// 타고 일어났는지 나중에 세기 위한 원장이다.
class OutingRepository {
  OutingRepository(this._firestore, this._uid, this._failures);

  final FirebaseFirestore _firestore;
  final String _uid;
  final FailureReporter _failures;

  CollectionReference<Map<String, dynamic>> get _outings =>
      _firestore.collection('users').doc(_uid).collection('outings');

  /// 외출을 시작하고 문서 id를 돌려준다. 담기와 같은 이유로 서버를 기다리지
  /// 않는다 — 길 위에서 누르는 버튼이다.
  String start({
    required String zoneId,
    required int budgetMin,
    required List<String> shownPinIds,
  }) {
    final doc = _outings.doc();
    unawaited(
      doc
          .set({
            'startedAt': Timestamp.now(),
            'endedAt': null,
            'zoneId': zoneId,
            'budgetMin': budgetMin,
            'shownPinIds': shownPinIds,
            'visitedPinIds': <String>[],
          })
          .catchError((Object error, StackTrace stackTrace) {
            _failures.report('외출 기록을 저장하지 못했어요', error, stackTrace);
          }),
    );
    return doc.id;
  }

  /// 이번 외출에서 다녀온 곳을 쌓는다. 같은 핀을 두 번 눌러도 중복되지 않게
  /// arrayUnion을 쓴다.
  void addVisited(String outingId, String pinId) {
    unawaited(
      _outings
          .doc(outingId)
          .update({
            'visitedPinIds': FieldValue.arrayUnion([pinId]),
          })
          .catchError((Object error, StackTrace stackTrace) {
            _failures.report('방문 기록을 저장하지 못했어요', error, stackTrace);
          }),
    );
  }
}

final outingRepositoryProvider = Provider<OutingRepository>(
  (ref) => OutingRepository(
    ref.watch(firestoreProvider),
    ref.watch(uidProvider),
    ref.watch(failureReporterProvider),
  ),
);
