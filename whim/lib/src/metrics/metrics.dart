import 'dart:async';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth.dart';
import '../pins/pin.dart';
import '../pins/pin_repository.dart';

/// 담기를 포기한 지점. 스펙 §6 pin_create_abandoned의 stage 파라미터.
///
/// 담기 완료율이 70% 아래면 플로우를 다시 만들어야 하는데, 어디서 새는지
/// 모르면 무엇을 고칠지 알 수 없다. 검색 전에 닫는 것(장소명 추출 실패)과
/// 후보를 보고도 닫는 것(후보가 틀림)은 전혀 다른 문제다.
enum AbandonStage {
  /// 후보가 뜨기 전에 닫았다. 프리필이 비었거나 검색이 느렸다.
  beforeSearch('before_search'),

  /// 후보를 보여줬는데 하나도 고르지 않았다. 후보 품질 문제다.
  resultsShown('results_shown'),

  /// 검색이 실패했거나 결과가 0건이었다. 탭할 것이 없었다.
  searchFailed('search_failed');

  const AbandonStage(this.wire);

  final String wire;
}

/// 스펙 §6의 이벤트를 Analytics와 Firestore 양쪽에 남긴다.
///
/// Analytics는 대시보드용이고 Firestore는 직접 계산용이다. 파일럿 15명
/// 규모에서는 Analytics 콘솔의 집계 지연·샘플링을 기다릴 수 없어, 담기
/// 완료율을 직접 세려면 원본 이벤트가 필요하다.
class Metrics {
  Metrics(this._analytics, this._firestore, this._uid);

  final FirebaseAnalytics _analytics;
  final FirebaseFirestore _firestore;
  final String _uid;

  /// 스펙 §6 app_open. 담기 완료율이 아니라 "외출 1회당 호출률"의 분모다.
  void appOpen({required bool fromShare}) {
    _log('app_open', {'trigger': fromShare ? 'share' : 'launcher'});
  }

  /// [secondsToConfirm]은 공유를 받은 시각부터 저장이 끝난 시각까지다.
  /// 3초를 넘는지 보는 것이 Phase 1의 합격 기준이다.
  void pinCreated({
    required PinSourceType sourceType,
    required double secondsToConfirm,
  }) {
    _log('pin_created', {
      'sourceType': sourceType.wire,
      // 소수 셋째 자리까지면 충분하다. 그대로 넘기면 Analytics에서 읽기 어렵다.
      'secondsToConfirm': double.parse(secondsToConfirm.toStringAsFixed(3)),
    });
  }

  /// 스펙 §6 zone_viewed. 구역이 의미 있는 묶음인지 본다 — 아무도 열어보지
  /// 않으면 DBSCAN 파라미터부터 다시 잡아야 한다.
  void zoneViewed({required int pinCount}) {
    _log('zone_viewed', {'pinCount': pinCount});
  }

  /// 스펙 §6 outing_started. 담아둔 곳이 실제 외출로 이어지는지 본다.
  void outingStarted({
    required String zoneId,
    required int budgetMin,
    required int shownPinCount,
  }) {
    _log('outing_started', {
      'zoneId': zoneId,
      'budgetMin': budgetMin,
      'shownPinCount': shownPinCount,
    });
  }

  /// 스펙 §6 pin_visited. 저장→방문 전환율(목표 30%)의 분자다.
  ///
  /// [fromOuting]은 Analytics가 불리언을 받지 않아 1/0으로 보낸다.
  void pinVisited({required int daysSinceSaved, required bool fromOuting}) {
    _log('pin_visited', {
      'daysSinceSaved': daysSinceSaved,
      'fromOuting': fromOuting ? 1 : 0,
    });
  }

  void pinCreateAbandoned({
    required PinSourceType sourceType,
    required AbandonStage stage,
  }) {
    _log('pin_create_abandoned', {
      'sourceType': sourceType.wire,
      'stage': stage.wire,
    });
  }

  /// 계측 실패는 사용자에게 보이지 않아야 한다(스펙 §10). 담기를 막지 않도록
  /// 어느 쪽도 기다리지 않는다.
  void _log(String name, Map<String, Object> parameters) {
    _fireAndForget(
      'analytics $name',
      () => _analytics.logEvent(name: name, parameters: parameters),
    );

    _fireAndForget(
      'event 저장 $name',
      () => _firestore.collection('users').doc(_uid).collection('events').add({
        'name': name,
        ...parameters,
        // pins와 같은 이유로 기기 시각을 쓴다. 오프라인에서도 값이 남아야 한다.
        'createdAt': Timestamp.now(),
      }),
    );
  }

  void _fireAndForget(String what, Future<Object?> Function() action) {
    unawaited(
      Future(() async {
        try {
          await action();
        } catch (error, stackTrace) {
          developer.log('$what 실패', error: error, stackTrace: stackTrace);
        }
      }),
    );
  }
}

final analyticsProvider = Provider<FirebaseAnalytics>(
  (ref) => FirebaseAnalytics.instance,
);

final metricsProvider = Provider<Metrics>(
  (ref) => Metrics(
    ref.watch(analyticsProvider),
    ref.watch(firestoreProvider),
    ref.watch(uidProvider),
  ),
);
