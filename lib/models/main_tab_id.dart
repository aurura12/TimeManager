/// 主导航的稳定标识。显示顺序与页面身份分开，排序不会交换页面状态。
enum MainTabId {
  record('record', '记录'),
  diary('diary', '日记'),
  travel('travel', '出行'),
  checkIn('check_in', '打卡'),
  target('target', '目标'),
  profile('profile', '我的');

  const MainTabId(this.id, this.label);

  final String id;
  final String label;

  static MainTabId? fromId(Object? id) {
    for (final tab in values) {
      if (tab.id == id) return tab;
    }
    return null;
  }
}
