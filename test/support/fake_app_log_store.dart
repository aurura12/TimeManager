import 'package:time_manager/services/app_log_store.dart';

class FakeAppLogStore implements AppLogStore {
  FakeAppLogStore({
    List<String>? lines,
    this.throwOnWrite = false,
    this.throwOnRewrite = false,
  }) : lines = List<String>.of(lines ?? const []);

  final bool throwOnWrite;
  final bool throwOnRewrite;
  final List<String> lines;

  @override
  Future<List<String>> readLines() async => List<String>.of(lines);

  @override
  Future<void> appendLine(String line) async {
    if (throwOnWrite) throw StateError('write failed');
    lines.add(line);
  }

  @override
  Future<void> rewriteLines(List<String> newLines) async {
    if (throwOnWrite || throwOnRewrite) throw StateError('rewrite failed');
    lines
      ..clear()
      ..addAll(newLines);
  }

  @override
  Future<void> clear() async {
    if (throwOnWrite) throw StateError('clear failed');
    lines.clear();
  }
}
