/// 打卡列表筛选：全部 / 乖乖 / 晶晶
enum CheckInViewFilter {
  all('全部'),
  guaiGuai('乖乖'),
  jingJing('晶晶');

  const CheckInViewFilter(this.label);
  final String label;
}
