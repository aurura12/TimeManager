import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/event_label_style.dart';
import 'package:time_manager/providers/event_label_style_provider.dart';
import 'package:time_manager/providers/time_provider.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/theme/app_tokens.dart';
import 'package:time_manager/widgets/event_label_text.dart';
import 'package:time_manager/widgets/time_grid.dart';

/// TimeProvider 初始化会尝试恢复 Google 登录态，这里给出不联网的 fake。
class _FakeGoogleSignInPlatform extends GoogleSignInPlatform {
  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    return null;
  }

  @override
  bool supportsAuthenticate() => false;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) {
    throw UnimplementedError();
  }

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async {
    return null;
  }

  @override
  Future<void> clearAuthorizationToken(
      ClearAuthorizationTokenParams params) async {}

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

void _installPluginMocks({Map<String, Object> prefs = const {}}) {
  SharedPreferences.setMockInitialValues(prefs);
  GoogleSignInPlatform.instance = _FakeGoogleSignInPlatform();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('home_widget'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => null,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/time_manager_label_test',
  );
}

Future<void> _pumpUntilReady(WidgetTester tester, TimeProvider provider) async {
  for (var i = 0; i < 40 && !provider.isInitialLoadFinished; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(provider.isInitialLoadFinished, isTrue, reason: 'TimeProvider 初始化未完成');
}

/// 把分类/日程的防抖定时器跑干净，避免测试结束时有 pending timer。
Future<void> _drainPendingSync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 5));
  await tester.pump();
}

Future<void> _pumpLabel(
  WidgetTester tester, {
  required String text,
  required int maxLines,
  double width = 56,
  String? detail,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: EventLabelText(
              text: text,
              maxLines: maxLines,
              detail: detail,
              style: AppText.gridLabel,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('EventLabelStyleProvider', () {
    test('默认两行', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = EventLabelStyleProvider();
      await provider.ready;
      expect(provider.style, EventLabelStyle.twoLines);
      expect(provider.style.maxLines, 2);
    });

    test('切换后落盘，重新读取仍是新值', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = EventLabelStyleProvider();
      await provider.ready;
      await provider.setStyle(EventLabelStyle.singleLine);
      expect(provider.style, EventLabelStyle.singleLine);

      final reloaded = EventLabelStyleProvider();
      await reloaded.ready;
      expect(reloaded.style, EventLabelStyle.singleLine,
          reason: '设置要能跨启动保留');
    });

    test('脏数据回落到两行，不抛异常', () async {
      SharedPreferences.setMockInitialValues(
          {EventLabelStyleProvider.storageKey: 'thirdOption'});
      final provider = EventLabelStyleProvider();
      await provider.ready;
      expect(provider.style, EventLabelStyle.twoLines);
    });
  });

  group('EventLabelText', () {
    testWidgets('名字放得下时不挂任何提示', (tester) async {
      await _pumpLabel(tester, text: '学习', maxLines: 1);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('单行被截断时挂提示，长按看到完整名称', (tester) async {
      const longName = '和导师讨论论文数据分析';
      await _pumpLabel(tester, text: longName, maxLines: 1);
      expect(find.byType(Tooltip), findsOneWidget,
          reason: '56px 单行放不下 12 个字，应该提供查看入口');
      expect(find.text(longName), findsOneWidget);

      await tester.longPress(find.byType(EventLabelText));
      await tester.pumpAndSettle();

      // 气泡里再渲染一份完整名称
      expect(find.text(longName), findsNWidgets(2),
          reason: '长按后应弹出包含完整名称的气泡');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('两行模式下同样宽度能多放字，短名不再挂提示', (tester) async {
      const name = '和导师讨论数据';
      await _pumpLabel(tester, text: name, maxLines: 2);
      final label = tester.widget<Text>(find.text(name));
      expect(label.maxLines, 2);
      expect(find.byType(Tooltip), findsNothing,
          reason: '两行能放下 7 个字时不该再弹提示');
    });

    testWidgets('两行也放不下时仍然可以长按查看', (tester) async {
      const longName = '和导师讨论毕业论文的数据分析细节';
      await _pumpLabel(tester, text: longName, maxLines: 2, detail: '09:10–09:30 · 学习');
      expect(find.byType(Tooltip), findsOneWidget);

      await tester.longPress(find.byType(EventLabelText));
      await tester.pumpAndSettle();
      expect(find.text('$longName\n09:10–09:30 · 学习'), findsOneWidget,
          reason: '气泡里要带上时间段与事件名');
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('时间网格接入显示偏好', () {
    Future<TimeProvider> pumpGrid(
      WidgetTester tester, {
      EventLabelStyle? style,
      List<Offset>? selectionEvents,
    }) async {
      _installPluginMocks(prefs: {
        'categories': [
          jsonEncode(Category(
            name: '学习',
            color: Colors.amber,
            updatedAt: 100,
          ).toJson()),
        ],
      });
      final provider = TimeProvider();
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);

      EventLabelStyleProvider? labelProvider;
      if (style != null) {
        labelProvider = EventLabelStyleProvider();
        await labelProvider.ready;
        await labelProvider.setStyle(style);
      }

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<TimeProvider>.value(value: provider),
            if (labelProvider != null)
              ChangeNotifierProvider<EventLabelStyleProvider?>.value(
                value: labelProvider,
              ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SizedBox(
                width: 300,
                height: 400,
                child: TimeGrid(
                  gridKey: GlobalKey(),
                  controller: scrollController,
                  dragStartIndex: null,
                  dragEndIndex: null,
                  onTapDown: (position) => selectionEvents?.add(position),
                  onPanStart: (position) => selectionEvents?.add(position),
                  onPanUpdate: (position) => selectionEvents?.add(position),
                  onRemoveSlot: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await _pumpUntilReady(tester, provider);
      await tester.pump();
      return provider;
    }

    Future<Text> seedAndReadLabel(
      WidgetTester tester,
      TimeProvider provider,
      EventLabelStyle? style,
    ) async {
      provider.assignCategoryToSlots(
        {0},
        Category(name: '和导师讨论数据', color: Colors.blue, updatedAt: 100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return tester.widget<Text>(
        find.descendant(
          of: find.byType(TimeGrid),
          matching: find.text('和导师讨论数据'),
        ),
      );
    }

    testWidgets('未注册偏好 Provider 时按默认两行渲染', (tester) async {
      final provider = await pumpGrid(tester);
      final label = await seedAndReadLabel(tester, provider, null);
      expect(label.maxLines, 2);
      await _drainPendingSync(tester);
    });

    testWidgets('选单行后网格标签只渲染一行', (tester) async {
      final provider = await pumpGrid(tester, style: EventLabelStyle.singleLine);
      final label = await seedAndReadLabel(
          tester, provider, EventLabelStyle.singleLine);
      expect(label.maxLines, 1,
          reason: '单行偏好必须真正传到 TimeGrid 的标签上');
      await _drainPendingSync(tester);
    });

    testWidgets('选两行后网格标签渲染两行', (tester) async {
      final provider = await pumpGrid(tester, style: EventLabelStyle.twoLines);
      final label = await seedAndReadLabel(
          tester, provider, EventLabelStyle.twoLines);
      expect(label.maxLines, 2);
      await _drainPendingSync(tester);
    });

    testWidgets('挂了长按提示的格子仍然可以拖选', (tester) async {
      final selectionEvents = <Offset>[];
      final provider = await pumpGrid(
        tester,
        style: EventLabelStyle.singleLine,
        selectionEvents: selectionEvents,
      );
      // 名字长到必然截断，这一格会挂上 Tooltip
      provider.assignCategoryToSlots(
        {0},
        Category(
          name: '和导师讨论毕业论文的数据分析细节',
          color: Colors.blue,
          updatedAt: 100,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Tooltip), findsWidgets,
          reason: '前提：这一格必须已经挂了提示');

      // 从文字上往下拖一格：长按识别器不能把拖选抢走
      selectionEvents.clear();
      final labelRect =
          tester.getRect(find.text('和导师讨论毕业论文的数据分析细节').first);
      await tester.dragFrom(labelRect.center, const Offset(0, AppSizes.gridRow));
      await tester.pump();

      expect(selectionEvents, isNotEmpty,
          reason: '拖选回调必须照常触发，长按提示不能吞掉手势');
      await _drainPendingSync(tester);
    });
  });
}
