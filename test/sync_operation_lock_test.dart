import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/sync_center_state.dart';
import 'package:time_manager/services/sync_operation_lock.dart';

void main() {
  test('同一模块的同步操作跨服务实例串行执行', () async {
    final events = <String>[];

    Future<int> run(String name, int value) {
      return SyncOperationLock.instance.run(
        SyncModule.diary,
        () async {
          events.add('$name:start');
          await Future<void>.delayed(const Duration(milliseconds: 10));
          events.add('$name:end');
          return value;
        },
      );
    }

    final first = run('first', 1);
    final second = run('second', 2);

    expect(await Future.wait([first, second]), [1, 2]);
    expect(events, ['first:start', 'first:end', 'second:start', 'second:end']);
  });
}
