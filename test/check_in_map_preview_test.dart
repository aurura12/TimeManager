import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/check_in_record.dart';
import 'package:time_manager/widgets/check_in_map_preview.dart';

class _FailingTileProvider extends TileProvider {
  int requestCount = 0;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requestCount++;
    return _FailingImageProvider();
  }
}

class _SuccessfulTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(TileProvider.transparentImage);
  }
}

class _FailingImageProvider extends ImageProvider<_FailingImageProvider> {
  @override
  Future<_FailingImageProvider> obtainKey(ImageConfiguration configuration) =>
      Future<_FailingImageProvider>.error(
        StateError('simulated tile request failure'),
      );

  @override
  ImageStreamCompleter loadImage(
    _FailingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(StateError('simulated tile request failure')),
    );
  }
}

CheckInRecord _record() {
  return CheckInRecord(
    id: 'record-1',
    goalId: 'goal-1',
    userId: 'user-1',
    userEmail: 'user@example.com',
    timestamp: DateTime(2026, 1, 1),
    latitude: 39.9042,
    longitude: 116.4074,
  );
}

void main() {
  testWidgets('瓦片请求失败时显示统一覆盖层和手动重试入口', (tester) async {
    final provider = _FailingTileProvider();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 240,
            child: CheckInMapPreview(
              records: [_record()],
              showLegend: false,
              tileProvider: provider,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(provider.requestCount, greaterThan(0));
    expect(find.text('地图加载失败'), findsOneWidget);
    expect(find.text('重试地图'), findsOneWidget);

    final requestCountBeforeManualRetry = provider.requestCount;
    await tester.tap(find.text('重试地图'));
    await tester.pump();
    expect(find.text('正在重试地图…'), findsOneWidget);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(provider.requestCount, greaterThan(requestCountBeforeManualRetry));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('地图显示服务 attribution，展开后可看到隐私说明', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 240,
            child: CheckInMapPreview(
              records: [_record()],
              showLegend: false,
              tileProvider: _SuccessfulTileProvider(),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    final attribution = find.byKey(
      const ValueKey<String>('map-attribution-button'),
    );
    expect(attribution, findsOneWidget);

    await tester.tap(attribution);
    await tester.pump();

    expect(find.textContaining('加载地图瓦片时'), findsOneWidget);
    expect(find.textContaining('高德地图'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
