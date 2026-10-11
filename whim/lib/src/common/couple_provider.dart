import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 인스턴스를 제공하는 Provider
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in ProviderScope');
});

/// 현재 선택된 커플 ID(C01~C08)를 관리하는 NotifierProvider
final selectedCoupleProvider = NotifierProvider<SelectedCoupleNotifier, String>(() {
  return SelectedCoupleNotifier();
});

class SelectedCoupleNotifier extends Notifier<String> {
  late final SharedPreferences _prefs;
  static const String _key = 'selected_couple_id';

  @override
  String build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return _prefs.getString(_key) ?? 'C01';
  }

  /// 선택된 커플 ID를 변경하고 로컬 저장소(SharedPreferences)에 영구 저장합니다.
  Future<void> setCouple(String coupleId) async {
    state = coupleId;
    await _prefs.setString(_key, coupleId);
  }
}