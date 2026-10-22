// Preference stores that do not work, for the tests of a device that cannot
// keep what it learns of its harness.  They stand in for the platform's store
// under `SharedPreferencesStorePlatform.instance`; give a test its own with
//
//     SharedPreferencesStorePlatform.instance = StrippedStore();
//     SharedPreferences.resetStatic();
//
// and `resetStatic()` again afterwards, since `SharedPreferences.getInstance`
// is left waiting for ever after an Error.

// The in-memory store comes with `shared_preferences`.
// ignore_for_file: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// A store that fails the way the Android plugin did in release builds made
/// with `shared_preferences_android` 2.5.0: R8 renamed the Kotlin classes the
/// plugin looks up by name through JNI, so its first call died with a
/// `NoSuchMethodError`.  That is an Error, not an Exception, which
/// `SharedPreferences.getInstance` does not even catch.
class StrippedStore extends InMemorySharedPreferencesStore {
  StrippedStore() : super.empty();

  @override
  Future<Map<String, Object>> getAll() async =>
      throw NoSuchMethodError.withInvocation(
        this,
        Invocation.method(#getAll, const []),
      );
}

/// A store that is open but does not take a write: its answer is `false`,
/// with nothing raised, as the platform's is, or it raises.
class RefusingStore extends InMemorySharedPreferencesStore {
  RefusingStore() : super.empty();

  bool refuse = true;
  bool fail = false;

  /// Keys (as the platform names them, `flutter.` first) that are refused
  /// while everything else is taken.
  final Set<String> refuseKeys = {};

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (fail) throw StateError('disk full');
    if (refuse || refuseKeys.contains(key)) return false;
    return super.setValue(valueType, key, value);
  }
}
