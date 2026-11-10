import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/services/menu_bar_target_store.dart';
import 'package:time_manager/theme/app_theme.dart';
import 'package:time_manager/widgets/menu_bar_target_dial.dart';

final _categories = <Category>[
  Category(
    id: 'c1',
    name: '工作',
    color: const Color(0xFF4DA8EE),
    subCategories: ['开会', '写周报'],
  ),
  Category(id: 'c2', name: '休息', color: const Color(0xFF96B462)),
  Category(
    id: 'c3',
    name: '学习',
    color: const Color(0xFF9575CD),
    subCategories: ['看书'],
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  MenuBarTarget? initialTarget,
  bool enabled = true,
  List<Category>? categories,
  required void Function(Category, String?) onWrite,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 368,
            height: MenuBarTargetDial.height,
            child: MenuBarTargetDial(
              categories: categories ?? _categories,
              initialTarget: initialTarget,
              enabled: enabled,
              onWrite: onWrite,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

FixedExtentScrollController _controller(WidgetTester tester, Key key) {
  final wheel = tester.widget<ListWheelScrollView>(find.byKey(key));
  return wheel.controller! as FixedExtentScrollController;
}

int? _subItemCount(WidgetTester tester) {
  final wheel = tester.widget<ListWheelScrollView>(
    find.byKey(MenuBarTargetDial.subWheelKey),
  );
  return (wheel.childDelegate as ListWheelChildBuilderDelegate).childCount;
}

Finder _cue({required bool above}) => find.byKey(
      ValueKey<String>(
        above ? 'menu-bar-dial-cue-above' : 'menu-bar-dial-cue-below',
      ),
    );

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('按记住的目标初始定位', (tester) async {
    var writes = 0;
    await _pump(
      tester,
      initialTarget: const MenuBarTarget(categoryId: 'c2', categoryName: '休息'),
      onWrite: (_, __) => writes++,
    );

    expect(_controller(tester, MenuBarTargetDial.categoryWheelKey).initialItem, 1);
    expect(_subItemCount(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    expect(writes, 0);
    await _unmount(tester);
  });

  testWidgets('id 失效时按分类名兜底', (tester) async {
    await _pump(
      tester,
      initialTarget: const MenuBarTarget(
        categoryId: 'gone',
        categoryName: '休息',
      ),
      onWrite: (_, __) {},
    );

    expect(_controller(tester, MenuBarTargetDial.categoryWheelKey).initialItem, 1);
    await _unmount(tester);
  });

  testWidgets('都不命中回到第一个分类', (tester) async {
    await _pump(
      tester,
      initialTarget: const MenuBarTarget(
        categoryId: 'gone',
        categoryName: '不存在',
      ),
      onWrite: (_, __) {},
    );

    expect(_controller(tester, MenuBarTargetDial.categoryWheelKey).initialItem, 0);
    expect(_subItemCount(tester), 3);
    expect(find.text(MenuBarTargetDial.wholeCategoryLabel), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('转子事件盘停下会写入分类 + 子事件', (tester) async {
    Category? writtenCategory;
    String? writtenSub;
    await _pump(
      tester,
      onWrite: (category, sub) {
        writtenCategory = category;
        writtenSub = sub;
      },
    );

    _controller(tester, MenuBarTargetDial.subWheelKey).jumpToItem(1);
    await tester.pump();
    expect(writtenCategory, isNull);

    await tester.pump(
      MenuBarTargetDial.settleDelay + const Duration(milliseconds: 100),
    );
    expect(writtenCategory?.id, 'c1');
    expect(writtenSub, '开会');
    await _unmount(tester);
  });

  testWidgets('切到没有子事件的分类，停下直接写入', (tester) async {
    Category? writtenCategory;
    String? writtenSub;
    await _pump(
      tester,
      onWrite: (category, sub) {
        writtenCategory = category;
        writtenSub = sub;
      },
    );

    _controller(tester, MenuBarTargetDial.categoryWheelKey).jumpToItem(1);
    await tester.pump();
    await tester.pump(
      MenuBarTargetDial.settleDelay + const Duration(milliseconds: 100),
    );

    expect(writtenCategory?.id, 'c2');
    expect(writtenSub, isNull);
    await _unmount(tester);
  });

  testWidgets('切到有子事件的分类不会抢写', (tester) async {
    var writes = 0;
    await _pump(
      tester,
      initialTarget: const MenuBarTarget(categoryId: 'c2', categoryName: '休息'),
      onWrite: (_, __) => writes++,
    );

    _controller(tester, MenuBarTargetDial.categoryWheelKey).jumpToItem(0);
    await tester.pump();
    await tester.pump(
      MenuBarTargetDial.settleDelay + const Duration(milliseconds: 200),
    );

    expect(writes, 0);
    expect(_subItemCount(tester), 3);
    await _unmount(tester);
  });

  testWidgets('点中间项立即写入，点两侧项只居中', (tester) async {
    Category? writtenCategory;
    String? writtenSub;
    await _pump(
      tester,
      onWrite: (category, sub) {
        writtenCategory = category;
        writtenSub = sub;
      },
    );

    await tester.tap(find.text('休息'));
    await tester.pumpAndSettle();
    expect(writtenCategory, isNull);
    expect(
      _controller(tester, MenuBarTargetDial.categoryWheelKey).selectedItem,
      1,
    );

    await tester.tap(find.text('休息'));
    await tester.pump();
    expect(writtenCategory?.id, 'c2');
    expect(writtenSub, isNull);
    await _unmount(tester);
  });

  testWidgets('禁用时不写入', (tester) async {
    var writes = 0;
    await _pump(tester, enabled: false, onWrite: (_, __) => writes++);

    _controller(tester, MenuBarTargetDial.subWheelKey).jumpToItem(1);
    await tester.pump();
    await tester.pump(
      MenuBarTargetDial.settleDelay + const Duration(milliseconds: 100),
    );
    expect(writes, 0);
    await _unmount(tester);
  });

  testWidgets('一次显示 7 行', (tester) async {
    await _pump(tester, onWrite: (_, __) {});

    expect(MenuBarTargetDial.height, 308);
    final wheel = tester.widget<ListWheelScrollView>(
      find.byKey(MenuBarTargetDial.categoryWheelKey),
    );
    expect(wheel.itemExtent, 44);
    expect(MenuBarTargetDial.height / wheel.itemExtent, 7);

    // 只有 3 个分类，上下都没有被挤出去的项，不该出现方向提示。
    expect(_cue(above: true), findsNothing);
    expect(_cue(above: false), findsNothing);
    await _unmount(tester);
  });

  testWidgets('子事件超过可见行数时按方向显示提示', (tester) async {
    final categories = <Category>[
      Category(
        id: 'long',
        name: '长列表',
        color: const Color(0xFF4DA8EE),
        subCategories: <String>[
          '一', '二', '三', '四', '五', '六', '七', '八', '九',
        ],
      ),
    ];
    await _pump(tester, categories: categories, onWrite: (_, __) {});
    final sub = _controller(tester, MenuBarTargetDial.subWheelKey);

    // 第 0 项「整个分类」：只在下面还有项。
    expect(_cue(above: true), findsNothing);
    expect(_cue(above: false), findsOneWidget);

    // 中间项（第 5 项）：上下都还有。
    sub.jumpToItem(5);
    await tester.pump();
    expect(_cue(above: true), findsOneWidget);
    expect(_cue(above: false), findsOneWidget);

    // 最后一项：只在上面还有。
    sub.jumpToItem(9);
    await tester.pump();
    expect(_cue(above: true), findsOneWidget);
    expect(_cue(above: false), findsNothing);
    await _unmount(tester);
  });

  testWidgets('方向提示不吃点击', (tester) async {
    final categories = <Category>[
      Category(
        id: 'long',
        name: '长列表',
        color: const Color(0xFF4DA8EE),
        subCategories: <String>[
          '一', '二', '三', '四', '五', '六', '七', '八', '九',
        ],
      ),
    ];
    await _pump(tester, categories: categories, onWrite: (_, __) {});

    await tester.tap(_cue(above: false), warnIfMissed: false);
    await tester.pump();
    // 点箭头不写入、也不改变选中项。
    expect(
      _controller(tester, MenuBarTargetDial.subWheelKey).selectedItem,
      0,
    );
    await _unmount(tester);
  });

  testWidgets('鼠标拖拽可以转动转盘', (tester) async {
    await _pump(tester, onWrite: (_, __) {});
    final before =
        _controller(tester, MenuBarTargetDial.categoryWheelKey).selectedItem;

    await tester.drag(
      find.byKey(MenuBarTargetDial.categoryWheelKey),
      const Offset(0, -60),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final after =
        _controller(tester, MenuBarTargetDial.categoryWheelKey).selectedItem;
    expect(after, isNot(before));
    await _unmount(tester);
  });
}