import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth.dart';
import '../pins/pin_repository.dart';

/// 파일럿 판단에 쓰는 두 숫자를 한 문서에 요약해 둔다.
///
/// 스펙 §6이 정한 기준은 둘뿐이다 — 담기 완료율 70%, 저장→방문 전환율 30%.
/// 앱 안에 어드민 화면을 만들 이유가 없다. 파일럿 참가자 15명이 각자
/// `stats/{uid}` 문서 하나를 갱신하면, 콘솔에서 그 컬렉션만 열어 15줄을
/// 한눈에 본다.
///
/// 집계는 기기에서 한다. Cloud Functions는 요금제와 CLI가 따라붙는데,
/// 원본(events, pins)이 이미 기기 캐시에 있어 서버를 쓸 이유가 없다.
class PilotStats {
  PilotStats(this._firestore, this._uid);

  final FirebaseFirestore _firestore;
  final String _uid;

  DocumentReference<Map<String, dynamic>> get _summary =>
      _firestore.collection('stats').doc(_uid);

  CollectionReference<Map<String, dynamic>> get _userCollection =>
      _firestore.collection('users').doc(_uid).collection('events');

  /// 캐시에서 세고 요약만 덮어쓴다. 앱 시작과 담기·방문 직후에 부른다.
  ///
  /// 실패해도 사용자에게 보이지 않는다. 지표를 못 갱신한 것이지 담기가
  /// 실패한 것이 아니다(스펙 §10).
  void publish() {
    unawaited(
      Future(() async {
        try {
          final events = await _userCollection.get(
            // 이미 로컬에 있는 것으로 센다. 서버를 왕복해봐야 같은 값이다.
            const GetOptions(source: Source.cache),
          );

          var created = 0;
          var abandoned = 0;
          for (final doc in events.docs) {
            switch (doc.data()['name']) {
              case 'pin_created':
                created++;
              case 'pin_create_abandoned':
                abandoned++;
            }
          }

          final pins = await _firestore
              .collection('users')
              .doc(_uid)
              .collection('pins')
              .get(const GetOptions(source: Source.cache));
          final total = pins.docs.length;
          final visited = pins.docs
              .where((doc) => doc.data()['visitedAt'] != null)
              .length;

          final summary = {
            'updatedAt': Timestamp.now(),
            // 담기 완료율 = pin_created / (pin_created + pin_create_abandoned)
            'pinCreated': created,
            'pinAbandoned': abandoned,
            'captureRate': _rate(created, created + abandoned),
            // 저장→방문 전환율 = 방문 표시된 핀 / 전체 핀
            'pins': total,
            'visitedPins': visited,
            'visitRate': _rate(visited, total),
          };

          await _summary.set(summary);
          // 콘솔을 열지 않고 기기에서 바로 확인할 수 있게 남긴다.
          // adb logcat | grep "지표 요약"
          if (kDebugMode) debugPrint('[whim] 지표 요약 $_uid: $summary');
        } catch (error, stackTrace) {
          developer.log('지표 요약 실패', error: error, stackTrace: stackTrace);
        }
      }),
    );
  }

  /// 분모가 0이면 비율이 없다. 0%로 적으면 "아직 아무것도 안 함"과
  /// "전부 실패"가 같아 보인다.
  double? _rate(int numerator, int denominator) =>
      denominator == 0 ? null : (numerator / denominator * 100).roundToDouble();
}

final pilotStatsProvider = Provider<PilotStats>(
  (ref) => PilotStats(ref.watch(firestoreProvider), ref.watch(uidProvider)),
);
