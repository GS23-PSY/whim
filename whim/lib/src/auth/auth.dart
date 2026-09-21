import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 첫 실행에서만 네트워크를 탄다. FirebaseAuth가 익명 계정을 로컬에 보관하므로
/// 이후 실행은 대기 없이 바로 uid를 얻는다 — 공유 인텐트로 콜드 스타트될 때
/// 로그인 때문에 담기가 늦어지면 안 된다.
Future<User> ensureSignedIn() async {
  final auth = FirebaseAuth.instance;
  final existing = auth.currentUser;
  if (existing != null) return existing;
  final credential = await auth.signInAnonymously();
  return credential.user!;
}

final firebaseAuthProvider = Provider<FirebaseAuth>(
  (ref) => FirebaseAuth.instance,
);

/// main()이 runApp 전에 ensureSignedIn을 끝내므로 currentUser는 항상 있다.
final uidProvider = Provider<String>(
  (ref) => ref.watch(firebaseAuthProvider).currentUser!.uid,
);
