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

  void _previousMonth() {
    final newIndex = _monthIndexFromDate(_displayedMonth) - 1;
    if (newIndex >= 0) {
      _selectMonth(newIndex);
    }
  }

  void _nextMonth() {
    final newIndex = _monthIndexFromDate(_displayedMonth) + 1;
    if (newIndex < DatePickerPanel.totalMonths) {
      _selectMonth(newIndex);
    }
  }

  void _goToToday() {
    final today = DateTime.now();
    final todayMonth = DateTime(today.year, today.month);
    final newIndex = _monthIndexFromDate(todayMonth);
    _selectMonth(newIndex);
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _displayedMonth.year == now.year && _displayedMonth.month == now.month;
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelBg = isDark ? const Color(0xFF2D3A2E) : DatePickerPanel.themeGreen;
    final selectedDayColor = isDark ? const Color(0xFF6B7B6C) : Colors.white;
    final todayColor = isDark ? const Color(0xFF6B8F5A) : const Color(0xFF8AAF6A);
    final textColor = isDark ? Colors.white70 : Colors.black87;
    final textColorSecondary = isDark ? Colors.white54 : Colors.black54;
    final monthActiveBg = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.12);
    final monthBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.25)
        : Colors.black.withValues(alpha: 0.25);

    return Material(
      color: panelBg,
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
                          style: TextStyle(
                            color: textColorSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity == null) return;
                if (details.primaryVelocity! < -50) {
                  _nextMonth();
                } else if (details.primaryVelocity! > 50) {
                  _previousMonth();
                }
              },
              child: GridView.builder(
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
                  Color cellTextColor = textColor;
                  if (isCurrent) {
                    bgColor = selectedDayColor;
                  } else if (isToday) {
                    bgColor = todayColor;
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
                            color: cellTextColor,
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
                            style: TextStyle(
                              color: textColor,
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
                              ? monthActiveBg
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isActive
                                ? Colors.transparent
                                : monthBorderColor,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${item.month}月',
                          style: TextStyle(
                            color: textColor,
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
            if (!_isCurrentMonth) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  onPressed: _goToToday,
                  icon: Icon(Icons.today, size: 16, color: textColor),
                  label: Text(
                    '返回今天',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    backgroundColor: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.05),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
