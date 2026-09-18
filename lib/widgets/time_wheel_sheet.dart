import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 打开时/分滚轮面板，返回用户确认的时间；取消或下滑关闭返回 null。
///
/// 用来替代 `showTimePicker`：系统表盘要在 12 个位置之间拖拽、再点一次确定，
/// 而滚轮可以连续滚动，且面板里能同时看到当前结果。
Future<TimeOfDay?> showTimeWheelSheet(
  BuildContext context, {
  required TimeOfDay initialTime,
  String title = '选择时间',
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: AppRadius.rCard),
    ),
    builder: (_) => _TimeWheelSheet(initialTime: initialTime, title: title),
  );
}

class _TimeWheelSheet extends StatefulWidget {
  const _TimeWheelSheet({required this.initialTime, required this.title});

  final TimeOfDay initialTime;
  final String title;

  @override
  State<_TimeWheelSheet> createState() => _TimeWheelSheetState();
}

class _TimeWheelSheetState extends State<_TimeWheelSheet> {
  /// 滚轮单行高度。取 44 是为了让每行都不小于最小触摸目标。
  static const double _itemExtent = 44;

  /// 可见行数。取奇数，选中项才能落在正中间。
  static const int _visibleRows = 5;

  static const double _wheelHeight = _itemExtent * _visibleRows;

  static const int _hourCount = 24;
  static const int _minuteCount = 60;

  late final FixedExtentScrollController _hourController;
  late final FixedExtentScrollController _minuteController;
  late int _hour;
  late int _minute;

  @override
  void initState() {
    super.initState();
    _hour = widget.initialTime.hour;
    _minute = widget.initialTime.minute;
    _hourController = FixedExtentScrollController(initialItem: _hour);
    _minuteController = FixedExtentScrollController(initialItem: _minute);
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    super.dispose();
  }

  String get _label =>
      '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToolbar(context, colorScheme),
        Divider(height: AppSizes.hairline, color: colorScheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg),
          child: Text(
            _label,
            style: AppText.pageTitle.copyWith(color: colorScheme.onSurface),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: _wheelHeight,
          child: Stack(
            children: [
              _buildSelectionBand(colorScheme),
              Row(
                children: [
                  Expanded(child: _buildHourWheel(colorScheme)),
                  Text(
                    ':',
                    style: AppText.sectionTitle
                        .copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  Expanded(child: _buildMinuteWheel(colorScheme)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          Expanded(
            child: Text(
              widget.title,
              textAlign: TextAlign.center,
              style:
                  AppText.sectionTitle.copyWith(color: colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              TimeOfDay(hour: _hour, minute: _minute),
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 选中行的高亮带。放在滚轮下面，读起来像"这一行是当前值"。
  Widget _buildSelectionBand(ColorScheme colorScheme) {
    return Positioned(
      top: _itemExtent * ((_visibleRows - 1) ~/ 2),
      left: AppSpacing.xs,
      right: AppSpacing.xs,
      height: _itemExtent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.controlAll,
          border: Border.symmetric(
            horizontal: BorderSide(
              color: colorScheme.outlineVariant,
              width: AppSizes.hairline,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHourWheel(ColorScheme colorScheme) {
    return ListWheelScrollView.useDelegate(
      key: const ValueKey('time-wheel-hour'),
      controller: _hourController,
      itemExtent: _itemExtent,
      overAndUnderCenterOpacity: 0.35,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: (index) => setState(() => _hour = index),
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: _hourCount,
        builder: (context, index) =>
            _buildWheelItem(_twoDigits(index), index == _hour, colorScheme),
      ),
    );
  }

  Widget _buildMinuteWheel(ColorScheme colorScheme) {
    return ListWheelScrollView.useDelegate(
      key: const ValueKey('time-wheel-minute'),
      controller: _minuteController,
      itemExtent: _itemExtent,
      overAndUnderCenterOpacity: 0.35,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: (index) => setState(() => _minute = index),
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: _minuteCount,
        builder: (context, index) =>
            _buildWheelItem(_twoDigits(index), index == _minute, colorScheme),
      ),
    );
  }

  Widget _buildWheelItem(String text, bool selected, ColorScheme colorScheme) {
    return Center(
      child: Text(
        text,
        style: (selected ? AppText.sectionTitle : AppText.body).copyWith(
          color: selected ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 与项目其它位置一致：手写两位补零，不走 intl。
  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
