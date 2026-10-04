import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FakeMainTabPreferencesStore extends InMemorySharedPreferencesStore {
  FakeMainTabPreferencesStore({this.rejectWrites = false}) : super.empty();

  bool rejectWrites;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (rejectWrites) return false;
    return super.setValue(valueType, key, value);
  }
}
