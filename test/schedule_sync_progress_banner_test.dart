import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/schedule_sync_progress.dart';
import 'package:time_manager/widgets/schedule_sync_progress_banner.dart';

void main() {
  testWidgets('底部同步进度显示阶段和日期计数', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Colors.white)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ScheduleSyncProgressBanner(
                  progress: const ScheduleSyncProgress(
                    message: '覆盖拉取：正在拉取日程 3/10',
                    completed: 2,
                    total: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('覆盖拉取：正在拉取日程 3/10'), findsOneWidget);
    expect(find.text('2/10'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
