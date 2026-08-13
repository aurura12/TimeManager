import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('关闭 Google 日历同步时使用正常中文提示', () {
    final source = File('lib/providers/time_provider.dart').readAsStringSync();

    expect(source, contains("'Google 日历同步已关闭'"));
    expect(source, isNot(contains('Google 鏃ュ巻鍚屾宸插叧闂?')));
  });
}
