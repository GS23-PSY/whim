import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/auth/auth.dart';
import 'src/capture/capture_sheet.dart';
import 'src/common/failure_reporter.dart';
import 'src/map/pin_map.dart';
import 'src/metrics/metrics.dart';
import 'src/metrics/pilot_stats.dart';
import 'src/pins/pin_list.dart';
import 'src/pins/pin_repository.dart';
import 'src/share/share_receiver.dart';
import 'src/share/share_text_parser.dart';

Future<void> main() async {
  // 공유로 콜드 스타트된 경우 secondsToConfirm의 시작점이다. Firebase 초기화와
  // 로그인 대기도 사용자가 겪는 마찰이라 그 앞에서 잡는다.
  final startedAt = DateTime.now();

  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // 파일럿에서 크래시가 조용히 사라지면 담기 완료율이 낮을 때 UX 문제인지
  // 크래시인지 구분할 수 없다. 네이티브 크래시는 SDK가 알아서 잡고, Dart
  // 쪽은 아래 두 갈래로 들어온다.
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  try {
    await ensureSignedIn();
  } catch (error) {
    // 첫 실행에 네트워크가 없으면 uid가 없어 아무것도 저장할 수 없다.
    // 사용자에게 보이는 실패라 화면으로 알린다.
    runApp(SignInFailedApp(error: error));
    return;
  }

  // 지도 SDK 인증은 첫 지도 위젯보다 먼저 끝나 있어야 한다.
  await initKakaoMapSdk();

  final initialShare = await ShareReceiver.readInitial();

  final container = ProviderContainer(
    overrides: [
      shareReceiverProvider.overrideWithValue(
        ShareReceiver(initialShare, startedAt),
      ),
    ],
  );
  container.read(pinRepositoryProvider).ensureUserDocument();
  container.read(metricsProvider).appOpen(fromShare: initialShare != null);
  // 파일럿 지표 요약(stats/{uid}). 지난 세션에서 쌓인 것까지 여기서 맞춘다.
  container.read(pilotStatsProvider).publish();

  runApp(
    UncontrolledProviderScope(container: container, child: const WhimApp()),
  );
}

class WhimApp extends StatelessWidget {
  const WhimApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'whim',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2B6CB0)),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _sheetOpen = false;

  /// 0 지도(스펙 S2의 홈), 1 목록(S4).
  int _tab = 0;

  Future<void> _capture(SharedPlaceHint hint, DateTime receivedAt) async {
    // 공유가 연달아 들어와도 시트는 하나만 띄운다.
    if (_sheetOpen) return;
    _sheetOpen = true;

    final session = CaptureSession(hint: hint, receivedAt: receivedAt);
    final savedName = await showCaptureSheet(context, session);
    _sheetOpen = false;

    // 담기 완료율(스펙 §6)의 분모와 분자가 여기서 갈린다. 드래그로 닫든
    // 뒤로 가기로 닫든 이 지점을 지나므로 한곳에서만 남긴다.
    final metrics = ref.read(metricsProvider);
    // 이미 담긴 곳을 다시 고른 경우는 새로 담은 것도 포기한 것도 아니라
    // 담기 완료율의 분자에도 분모에도 넣지 않는다.
    if (session.duplicate) {
      return;
    } else if (session.saved) {
      metrics.pinCreated(
        sourceType: hint.sourceType,
        secondsToConfirm: session.secondsToConfirm,
      );
    } else {
      metrics.pinCreateAbandoned(
        sourceType: hint.sourceType,
        stage: session.stage,
      );
    }
    // 담기 완료율이 바뀌었다. 방금 남긴 이벤트는 다음 갱신에 잡힐 수 있지만
    // 파일럿 판단에 필요한 정밀도는 그걸로 충분하다.
    ref.read(pilotStatsProvider).publish();

    if (!mounted || savedName == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$savedName 담았어요'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 공유가 들어오면 바로 담기 시트를 띄운다. 공유로 콜드 스타트된 경우도
    // 이 스트림의 첫 이벤트로 온다(ShareReceiver).
    ref.listen(incomingSharesProvider, (previous, next) {
      final share = next.value;
      if (share != null) {
        _capture(parseSharedText(share.text), share.receivedAt);
      }
    });

    // 저장이 끝내 실패하면 알린다. 조용히 묻히면 담았다고 믿은 곳이 사라진
    // 것을 한참 뒤에야 알게 된다.
    ref.listen(failureMessagesProvider, (previous, next) {
      final message = next.value;
      if (message == null || !mounted) return;
      final colors = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: TextStyle(color: colors.onErrorContainer),
          ),
          backgroundColor: colors.errorContainer,
          duration: const Duration(seconds: 4),
        ),
      );
    });

    return Scaffold(
      appBar: AppBar(title: const Text('whim')),
      // IndexedStack으로 지도를 살려 둔다. 탭을 옮길 때마다 지도를 새로 만들면
      // 로딩이 보이고 SDK 호출도 그만큼 늘어난다.
      body: IndexedStack(index: _tab, children: const [PinMap(), PinList()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: '지도',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_outlined),
            selectedIcon: Icon(Icons.list),
            label: '목록',
          ),
        ],
      ),
    );
  }
}

class SignInFailedApp extends StatelessWidget {
  const SignInFailedApp({required this.error, super.key});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('처음 실행할 때는 인터넷 연결이 필요해요.'),
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
