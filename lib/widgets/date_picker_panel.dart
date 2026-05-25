import 'package:flutter/material.dart';

/// 顶部展开的日期选择器，支持月历网格与跨年月份滑动切换。
class DatePickerPanel extends StatefulWidget {
  final DateTime initialDate;
  final ValueChanged<DateTime> onDateSelected;
  final VoidCallback? onClose;

  const DatePickerPanel({
    super.key,
    required this.initialDate,
    required this.onDateSelected,
    this.onClose,
  });

  static const int startYear = 2000;
  static const int endYear = 2100;
  static const int totalMonths = (endYear - startYear + 1) * 12;
  static const Color themeGreen = Color(0xFFADD896);

  @override
  State<DatePickerPanel> createState() => _DatePickerPanelState();
}

enum _StripItemType { year, month }

class _StripItem {
  final _StripItemType type;
  final int year;
  final int? month;
  final int? monthGlobalIndex;

  const _StripItem.year(this.year)
      : type = _StripItemType.year,
        month = null,
        monthGlobalIndex = null;

  const _StripItem.month(this.year, this.month, this.monthGlobalIndex)
      : type = _StripItemType.month;
}

class _DatePickerPanelState extends State<DatePickerPanel> {
  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  static const _selectedDayColor = Colors.white;
  static const _todayColor = Color(0xFF8AAF6A);
  static const _textColor = Colors.black87;
  static const _textColorSecondary = Colors.black54;
  static const _monthItemWidth = 52.0;
  static const _yearItemWidth = 52.0;

  late final List<_StripItem> _stripItems;
  late DateTime _displayedMonth;
  late final ScrollController _monthScrollController;

  @override
  void initState() {
    super.initState();
    _stripItems = _buildStripItems();
    _displayedMonth = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
    );
    _monthScrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToMonth(_monthIndexFromDate(widget.initialDate), animate: false);
    });
  }

  @override
  void dispose() {
    _monthScrollController.dispose();
    super.dispose();
  }

  List<_StripItem> _buildStripItems() {
    final items = <_StripItem>[];
    for (int i = 0; i < DatePickerPanel.totalMonths; i++) {
      final year = DatePickerPanel.startYear + i ~/ 12;
      final month = i % 12 + 1;
      if (month == 1) {
        items.add(_StripItem.year(year));
      }
      items.add(_StripItem.month(year, month, i));
    }
    return items;
  }

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  int _monthIndexFromDate(DateTime date) =>
      (date.year - DatePickerPanel.startYear) * 12 + (date.month - 1);

  DateTime _dateFromMonthIndex(int index) => DateTime(
        DatePickerPanel.startYear + index ~/ 12,
        index % 12 + 1,
      );

  int _stripIndexForMonth(int monthGlobalIndex) =>
      monthGlobalIndex + (monthGlobalIndex ~/ 12) + 1;

  double _itemWidth(_StripItem item) =>
      item.type == _StripItemType.year ? _yearItemWidth : _monthItemWidth;

  void _scrollToMonth(int monthGlobalIndex, {bool animate = true}) {
    if (!_monthScrollController.hasClients) return;
    final stripIndex = _stripIndexForMonth(monthGlobalIndex);
    double offset = 0;
    for (int i = 0; i < stripIndex; i++) {
      offset += _itemWidth(_stripItems[i]) + 8;
    }
    offset += _itemWidth(_stripItems[stripIndex]) / 2;
  final viewport = _monthScrollController.position.viewportDimension;
    offset -= viewport / 2;
    final maxExtent = _monthScrollController.position.maxScrollExtent;
    offset = offset.clamp(0.0, maxExtent);
    if (animate) {
      _monthScrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _monthScrollController.jumpTo(offset);
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  void _selectDay(int day) {
    final date = DateTime(_displayedMonth.year, _displayedMonth.month, day);
    widget.onDateSelected(date);
    widget.onClose?.call();
  }

  void _selectMonth(int monthGlobalIndex) {
    setState(() => _displayedMonth = _dateFromMonthIndex(monthGlobalIndex));
    _scrollToMonth(monthGlobalIndex);
  }

  @override
  Widget build(BuildContext context) {
    final year = _displayedMonth.year;
    final month = _displayedMonth.month;
    final daysInMonth = _daysInMonth(year, month);
    final leadingEmpty = DateTime(year, month, 1).weekday - 1;
    final currentDate = DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    );

    return Material(
      color: DatePickerPanel.themeGreen,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: _weekdays
                  .map((d) => SizedBox(
                        width: 36,
                        child: Text(
                          d,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _textColorSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1,
              ),
              itemCount: leadingEmpty + daysInMonth,
              itemBuilder: (context, index) {
                if (index < leadingEmpty) return const SizedBox();
                final day = index - leadingEmpty + 1;
                final date = DateTime(year, month, day);
                final isCurrent = _isSameDay(date, currentDate);
                final isToday = _isSameDay(date, _today);

                Color? bgColor;
                Color textColor = _textColor;
                if (isCurrent) {
                  bgColor = _selectedDayColor;
                } else if (isToday) {
                  bgColor = _todayColor;
                }

                return GestureDetector(
                  onTap: () => _selectDay(day),
                  behavior: HitTestBehavior.opaque,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: bgColor,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '$day',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 15,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 40,
              child: ListView.builder(
                controller: _monthScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: _stripItems.length,
                itemBuilder: (context, index) {
                  final item = _stripItems[index];

                  if (item.type == _StripItemType.year) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: _yearItemWidth,
                        child: Center(
                          child: Text(
                            '${item.year}',
                            style: const TextStyle(
                              color: _textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  final isActive = item.year == year && item.month == month;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _selectMonth(item.monthGlobalIndex!),
                      child: Container(
                        width: _monthItemWidth,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: isActive
                              ? Colors.black.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isActive
                                ? Colors.transparent
                                : Colors.black.withValues(alpha: 0.25),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${item.month}月',
                          style: TextStyle(
                            color: _textColor,
                            fontSize: 14,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
