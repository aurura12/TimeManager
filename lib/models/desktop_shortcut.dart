import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 稳定的命令身份；本机偏好使用 name，不依赖页面或标签的显示顺序。
enum DesktopShortcutActionType {
  openSearch('全局搜索', '主页面：搜索所有模块的记录'),
  searchPage('当前页搜索', '记录、日记及其他模块的对应内容'),
  newItem('新建', '出行记录、打卡目标或时间目标'),
  openSettings('打开设置', '打开应用设置'),
  undo('撤销', '记录页：撤销最近一次时间块编辑'),
  redo('重做', '记录页：恢复刚撤销的时间块编辑'),
  previousDay('前一天', '记录页、日记页；输入框和选择控件内不切日期'),
  nextDay('后一天', '记录页、日记页；输入框和选择控件内不切日期'),
  today('回今天', '记录页、日记页'),
  saveForm('保存表单', '目标、打卡目标、出行编辑和快捷键设置'),
  tab1('切换第 1 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  tab2('切换第 2 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  tab3('切换第 3 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  tab4('切换第 4 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  tab5('切换第 5 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  tab6('切换第 6 个标签', '按当前显示顺序切换，隐藏标签不占位置'),
  escape('关闭临时状态', '关闭可取消弹层、日期面板、刷子或时间选择');

  const DesktopShortcutActionType(this.label, this.description);
  final String label;
  final String description;
}

/// primary 在 macOS 上是 Command，在 Windows 上是 Control。
class DesktopKeyBinding {
  const DesktopKeyBinding(this.key,
      {this.primary = false, this.shift = false, this.alt = false});

  final LogicalKeyboardKey key;
  final bool primary;
  final bool shift;
  final bool alt;

  bool get hasModifier => primary || alt;

  SingleActivator activator({required bool macOS}) => SingleActivator(
        key,
        meta: macOS && primary,
        control: !macOS && primary,
        shift: shift,
        alt: alt,
        includeRepeats: false,
      );

  String label({required bool macOS}) => [
        if (primary) macOS ? '⌘' : 'Ctrl',
        if (alt) macOS ? 'Option' : 'Alt',
        if (shift) 'Shift',
        switch (key) {
          LogicalKeyboardKey.arrowLeft => '←',
          LogicalKeyboardKey.arrowRight => '→',
          LogicalKeyboardKey.escape => 'Esc',
          LogicalKeyboardKey.enter => 'Enter',
          LogicalKeyboardKey.comma => ',',
          _ => key.keyLabel.toUpperCase(),
        },
      ].join('+');

  Map<String, Object> toJson() => {
        'key': key.keyId,
        'primary': primary,
        'shift': shift,
        'alt': alt,
      };

  static DesktopKeyBinding? fromJson(Object? value) {
    if (value is! Map || value['key'] is! int) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(value['key'] as int);
    if (key == null || key.keyLabel.isEmpty) return null;
    for (final field in ['primary', 'shift', 'alt']) {
      if (value[field] is! bool) return null;
    }
    return DesktopKeyBinding(key,
        primary: value['primary'] as bool,
        shift: value['shift'] as bool,
        alt: value['alt'] as bool);
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopKeyBinding &&
      key == other.key &&
      primary == other.primary &&
      shift == other.shift &&
      alt == other.alt;

  @override
  int get hashCode => Object.hash(key, primary, shift, alt);
}

Map<DesktopShortcutActionType, DesktopKeyBinding?> defaultDesktopBindings() => {
      DesktopShortcutActionType.openSearch:
          const DesktopKeyBinding(LogicalKeyboardKey.keyK, primary: true),
      DesktopShortcutActionType.searchPage:
          const DesktopKeyBinding(LogicalKeyboardKey.keyF, primary: true),
      DesktopShortcutActionType.newItem:
          const DesktopKeyBinding(LogicalKeyboardKey.keyN, primary: true),
      DesktopShortcutActionType.openSettings:
          const DesktopKeyBinding(LogicalKeyboardKey.comma, primary: true),
      DesktopShortcutActionType.undo:
          const DesktopKeyBinding(LogicalKeyboardKey.keyZ, primary: true),
      DesktopShortcutActionType.redo: const DesktopKeyBinding(
          LogicalKeyboardKey.keyZ,
          primary: true,
          shift: true),
      DesktopShortcutActionType.previousDay:
          const DesktopKeyBinding(LogicalKeyboardKey.arrowLeft),
      DesktopShortcutActionType.nextDay:
          const DesktopKeyBinding(LogicalKeyboardKey.arrowRight),
      DesktopShortcutActionType.today:
          const DesktopKeyBinding(LogicalKeyboardKey.keyT),
      DesktopShortcutActionType.saveForm:
          const DesktopKeyBinding(LogicalKeyboardKey.enter, primary: true),
      DesktopShortcutActionType.tab1:
          const DesktopKeyBinding(LogicalKeyboardKey.digit1, primary: true),
      DesktopShortcutActionType.tab2:
          const DesktopKeyBinding(LogicalKeyboardKey.digit2, primary: true),
      DesktopShortcutActionType.tab3:
          const DesktopKeyBinding(LogicalKeyboardKey.digit3, primary: true),
      DesktopShortcutActionType.tab4:
          const DesktopKeyBinding(LogicalKeyboardKey.digit4, primary: true),
      DesktopShortcutActionType.tab5:
          const DesktopKeyBinding(LogicalKeyboardKey.digit5, primary: true),
      DesktopShortcutActionType.tab6:
          const DesktopKeyBinding(LogicalKeyboardKey.digit6, primary: true),
      DesktopShortcutActionType.escape:
          const DesktopKeyBinding(LogicalKeyboardKey.escape),
    };

String? validateDesktopBinding(
    DesktopShortcutActionType action,
    DesktopKeyBinding binding,
    Map<DesktopShortcutActionType, DesktopKeyBinding?> bindings) {
  // 裸字母只保留既有的日期操作；其它命令必须有修饰键或使用功能键。
  final functionKey = binding.key.keyId >= LogicalKeyboardKey.f1.keyId &&
      binding.key.keyId <= LogicalKeyboardKey.f12.keyId;
  if (!binding.hasModifier &&
      !functionKey &&
      binding != defaultDesktopBindings()[action]) {
    return '请使用 Ctrl / ⌘、Alt / Option 组合键或 F1–F12';
  }
  if (binding.primary && !binding.alt) {
    const reserved = [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyV,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyQ,
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.keyM,
    ];
    if (reserved.contains(binding.key)) return '这个组合键用于文字编辑或系统操作';
    if (binding.key == LogicalKeyboardKey.keyZ &&
        action != DesktopShortcutActionType.undo &&
        action != DesktopShortcutActionType.redo) {
      return '这个组合键保留给撤销 / 重做';
    }
    // Windows 的 Ctrl+Y 是默认重做的兼容入口，不能再分配给其它命令。
    if (binding.key == LogicalKeyboardKey.keyY &&
        !binding.shift &&
        action != DesktopShortcutActionType.redo &&
        bindings[DesktopShortcutActionType.redo] ==
            defaultDesktopBindings()[DesktopShortcutActionType.redo]) {
      return 'Ctrl+Y 已用于重做';
    }
  }
  if (binding.key == LogicalKeyboardKey.tab ||
      binding.key == LogicalKeyboardKey.space ||
      (binding.alt && binding.key == LogicalKeyboardKey.f4)) {
    return '这个按键用于焦点切换或系统操作';
  }
  for (final entry in bindings.entries) {
    if (entry.key != action && entry.value == binding) {
      return '与“${entry.key.label}”冲突，请换一个组合键';
    }
  }
  return null;
}
