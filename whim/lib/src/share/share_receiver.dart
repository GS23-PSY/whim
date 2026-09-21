import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// 공유 한 건과 그것을 받은 시각.
///
/// [receivedAt]이 secondsToConfirm(스펙 §6)의 시작점이다. 담기 시트를 띄운
/// 시각이 아니라 공유가 들어온 시각이어야 한다 — 콜드 스타트와 검색 대기까지
/// 마찰에 포함해야 3초 목표를 정직하게 재는 것이 된다.
class ReceivedShare {
  const ReceivedShare(this.text, this.receivedAt);

  final String text;
  final DateTime receivedAt;
}

/// 다른 앱에서 공유된 텍스트/URL을 넘겨준다.
///
/// 콜드 스타트 공유는 main()에서 미리 읽어 넣는다 — 앱이 공유로 열렸는지를
/// 스트림 구독 시점이 아니라 시작 시점에 알아야 app_open trigger(스펙 §6)를
/// 남길 수 있고, 시트를 첫 프레임부터 띄울 수 있다.
class ShareReceiver {
  ShareReceiver(this._initialText, this._initialReceivedAt);

  final String? _initialText;

  /// 콜드 스타트에서는 공유 탭 시각을 알 수 없다. main() 진입 시각이 우리가
  /// 아는 가장 이른 시각이라 이것을 쓴다.
  final DateTime _initialReceivedAt;

  bool _initialDelivered = false;

  /// 스펙 §6 app_open의 trigger 파라미터. share인지 launcher인지.
  bool get launchedFromShare => _initialText != null;

  /// 콜드 스타트 공유를 먼저 한 번 흘리고, 이후 실행 중 들어오는 공유를 잇는다.
  Stream<ReceivedShare> shares() async* {
    final initialText = _initialText;
    if (!_initialDelivered && initialText != null) {
      _initialDelivered = true;
      yield ReceivedShare(initialText, _initialReceivedAt);
    }
    yield* ReceiveSharingIntent.instance
        .getMediaStream()
        .map(firstSharedText)
        .where((text) => text != null)
        .map((text) => ReceivedShare(text!, DateTime.now()));
  }

  /// 콜드 스타트로 전달된 공유를 읽고 소비 처리한다.
  static Future<String?> readInitial() async {
    final media = await ReceiveSharingIntent.instance.getInitialMedia();
    final text = firstSharedText(media);
    if (text != null) {
      // reset을 빼먹으면 핫 리스타트마다 같은 공유가 다시 배달된다.
      await ReceiveSharingIntent.instance.reset();
    }
    return text;
  }
}

/// 공유 목록에서 첫 텍스트/URL을 꺼낸다. 둘 다 내용이 [SharedMediaFile.path]에 온다.
String? firstSharedText(List<SharedMediaFile> media) {
  for (final file in media) {
    final isText =
        file.type == SharedMediaType.text || file.type == SharedMediaType.url;
    if (isText && file.path.trim().isNotEmpty) {
      final text = file.path.trim();
      _logRawShare(text);
      return text;
    }
  }
  return null;
}

/// 인스타그램이 실제로 무엇을 보내는지는 기기에서만 알 수 있다. 프리필이 비었을 때
/// 원인이 파서인지 애초에 캡션이 안 온 것인지 가리려면 원문이 필요하다.
/// adb logcat | grep "공유 원문"
void _logRawShare(String text) {
  if (kDebugMode) debugPrint('[whim] 공유 원문 <<<$text>>>');
}

/// main()에서 override된다.
final shareReceiverProvider = Provider<ShareReceiver>(
  (ref) => throw StateError('main()에서 override해야 한다'),
);

final incomingSharesProvider = StreamProvider<ReceivedShare>(
  (ref) => ref.watch(shareReceiverProvider).shares(),
);
