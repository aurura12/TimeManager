/// 事件名的显示方式（本机偏好，不随身份切换，也不进同步或备份）。
enum EventLabelStyle {
  /// 两行：用网格块的纵向富余换可见字数（默认）
  twoLines('twoLines', 2),

  /// 单行：保持视觉整齐，被省略的名字靠长按 / 悬停查看
  singleLine('singleLine', 1);

  const EventLabelStyle(this.id, this.maxLines);

  /// 持久化用的稳定标识，不要随枚举顺序变化
  final String id;

  /// 渲染时允许的最大行数
  final int maxLines;

  static EventLabelStyle fromId(Object? id) {
    for (final style in values) {
      if (style.id == id) return style;
    }
    return twoLines;
  }
}
