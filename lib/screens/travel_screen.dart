import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/travel_record.dart';
import '../services/diary_local_store.dart';
import '../services/travel_github_service.dart';
import '../services/travel_local_store.dart';

enum _TravelViewMode { table, calendar }

class TravelScreen extends StatefulWidget {
  const TravelScreen({super.key});

  @override
  State<TravelScreen> createState() => _TravelScreenState();
}

class _TravelScreenState extends State<TravelScreen> {
  DateTime _selectedDate = DateTime.now();
  DateTime _calendarMonth = DateTime.now();
  _TravelViewMode _viewMode = _TravelViewMode.table;
  TravelRecordsDocument _document = const TravelRecordsDocument(records: []);
  String? _token;
  bool _loading = true;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _selectedDate = _normalizedDate(DateTime.now());
    _calendarMonth = DateTime(_selectedDate.year, _selectedDate.month);
    _loadInitial();
  }

  DateTime _normalizedDate(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

  Future<void> _loadInitial() async {
    _token = await DiaryLocalStore.loadToken();
    final local = await TravelLocalStore.loadDraft();
    if (local != null && local.trim().isNotEmpty) {
      try {
        _document = TravelRecordsDocument.fromMarkdown(local);
      } catch (_) {
        _document = const TravelRecordsDocument(records: []);
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  String _selectedDateText() => DateFormat('yyyy-MM-dd').format(_selectedDate);

  TravelRecord? _recordForDate(DateTime date) {
    final key = DateFormat('yyyy-MM-dd').format(date);
    for (final record in _document.records) {
      if (record.dateKey == key) return record;
    }
    return null;
  }

  Set<String> get _recordDateKeys =>
      _document.records.map((e) => e.dateKey).toSet();

  Future<void> _saveDraft() async {
    await TravelLocalStore.saveDraft(_document.toMarkdown());
  }

  Future<DateTime?> _pickDate({
    required DateTime initialDate,
    DatePickerMode initialMode = DatePickerMode.day,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDatePickerMode: initialMode,
    );
    if (picked == null) return null;
    return _normalizedDate(picked);
  }

  Future<void> _saveRecord({
    required DateTime date,
    required String location,
    required String event,
  }) async {
    if (location.trim().isEmpty) {
      _showMessage('地点不能为空');
      return;
    }
    final normalizedDate = _normalizedDate(date);
    final record = TravelRecord(
      date: normalizedDate,
      location: location.trim(),
      event: event.trim(),
    );
    setState(() {
      _document = _document.upsert(record);
      _selectedDate = normalizedDate;
      _calendarMonth = DateTime(normalizedDate.year, normalizedDate.month);
    });
    await _saveDraft();
  }

  Future<void> _showAddRecordDialog() async {
    var tempDate = _normalizedDate(DateTime.now());
    final locationController = TextEditingController();
    final eventController = TextEditingController();

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('新增出行记录'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await _pickDate(initialDate: tempDate);
                        if (picked == null) return;
                        setDialogState(() => tempDate = picked);
                      },
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(DateFormat('yyyy-MM-dd').format(tempDate)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                        labelText: '地点',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: eventController,
                      decoration: const InputDecoration(
                        labelText: '事件',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave == true) {
      await _saveRecord(
        date: tempDate,
        location: locationController.text,
        event: eventController.text,
      );
      _showMessage('已保存到本地');
    }
    locationController.dispose();
    eventController.dispose();
  }

  Future<void> _showEditRecordDialog(DateTime date) async {
    final normalizedDate = _normalizedDate(date);
    final existing = _recordForDate(normalizedDate);
    var tempDate = normalizedDate;
    final locationController =
        TextEditingController(text: existing?.location ?? '');
    final eventController = TextEditingController(text: existing?.event ?? '');

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('编辑出行记录'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await _pickDate(initialDate: tempDate);
                        if (picked == null) return;
                        setDialogState(() => tempDate = picked);
                      },
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(DateFormat('yyyy-MM-dd').format(tempDate)),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                        labelText: '地点',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: eventController,
                      decoration: const InputDecoration(
                        labelText: '事件',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('保存并同步'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave == true) {
      await _saveRecord(
        date: tempDate,
        location: locationController.text,
        event: eventController.text,
      );
      await _pushToGitHub();
    }
    locationController.dispose();
    eventController.dispose();
  }

  Future<bool> _ensureToken() async {
    final token = (_token ?? '').trim();
    if (token.isNotEmpty) return true;
    _showMessage('未配置 GitHub Token，请先配置日记模块 token');
    return false;
  }

  Future<void> _pullFromGitHub() async {
    final ok = await _ensureToken();
    if (!ok) return;
    setState(() => _processing = true);
    final result = await TravelGitHubService.pullFile(
      token: _token!,
      path: TravelRecordsDocument.filePath,
    );
    if (!mounted) return;
    if (result.success) {
      try {
        final doc = TravelRecordsDocument.fromMarkdown(result.content!);
        _document = doc;
        await _saveDraft();
        _showMessage('拉取成功（已覆盖本地）');
      } catch (e) {
        _showMessage('解析远端记录失败: $e');
      }
      setState(() => _processing = false);
      return;
    }
    setState(() => _processing = false);
    if (result.notFound) {
      _showMessage('远端暂无出行记录文件');
      return;
    }
    _showMessage(result.error ?? '拉取失败');
  }

  Future<void> _pushToGitHub() async {
    final ok = await _ensureToken();
    if (!ok) return;
    await _saveDraft();
    setState(() => _processing = true);
    final content = _document.toMarkdown();
    final result = await TravelGitHubService.pushFile(
      token: _token!,
      path: TravelRecordsDocument.filePath,
      content: content,
      commitMessage: 'travel: update ${TravelRecordsDocument.filePath}',
    );
    if (!mounted) return;
    setState(() => _processing = false);
    if (result.success) {
      await _saveDraft();
      _showMessage(result.created ? '同步成功（已新建远端文件）' : '同步成功');
      return;
    }
    _showMessage(result.error ?? '同步失败');
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _buildViewSwitch() {
    return Row(
      children: [
        ChoiceChip(
          label: const Text('表格'),
          selected: _viewMode == _TravelViewMode.table,
          onSelected: (_) => setState(() => _viewMode = _TravelViewMode.table),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('日历'),
          selected: _viewMode == _TravelViewMode.calendar,
          onSelected: (_) =>
              setState(() => _viewMode = _TravelViewMode.calendar),
        ),
      ],
    );
  }

  Widget _buildTableView() {
    final rows = _document.records;
    if (rows.isEmpty) {
      return const Center(child: Text('暂无出行记录，先新增一条吧'));
    }
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 90,
                child: Text(
                  '日期',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '地点',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text(
                  '事件',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final record = rows[index];
              final selected = record.dateKey == _selectedDateText();
              return Container(
                decoration: BoxDecoration(
                  color: selected ? Colors.amber.withOpacity(0.15) : null,
                  border: Border(
                    bottom: BorderSide(color: Colors.grey[200]!, width: 0.5),
                  ),
                ),
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedDate = record.date;
                      _calendarMonth =
                          DateTime(record.date.year, record.date.month);
                    });
                  },
                  onDoubleTap: () => _showEditRecordDialog(record.date),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            record.dateKey,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            record.location,
                            style: const TextStyle(fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: Text(
                            record.event,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _changeCalendarMonth(int delta) {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + delta,
      );
    });
  }

  Future<void> _pickCalendarMonth() async {
    final picked = await _showMonthPickerDialog(
      initialMonth: DateTime(_calendarMonth.year, _calendarMonth.month, 1),
    );
    if (picked == null) return;
    setState(() {
      _calendarMonth = DateTime(picked.year, picked.month);
      final maxDay = DateTime(picked.year, picked.month + 1, 0).day;
      final nextDay = _selectedDate.day > maxDay ? maxDay : _selectedDate.day;
      _selectedDate = DateTime(picked.year, picked.month, nextDay);
    });
  }

  Future<DateTime?> _showMonthPickerDialog({
    required DateTime initialMonth,
  }) async {
    var selectedYear = initialMonth.year;
    var selectedMonth = initialMonth.month;
    final years = List<int>.generate(81, (i) => 2020 + i);

    return showDialog<DateTime>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('选择年月'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButton<int>(
                    value: selectedYear,
                    isExpanded: true,
                    items: years
                        .map(
                          (year) => DropdownMenuItem<int>(
                            value: year,
                            child: Text('$year 年'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => selectedYear = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(12, (index) {
                      final month = index + 1;
                      return ChoiceChip(
                        label: Text('$month月'),
                        selected: month == selectedMonth,
                        onSelected: (_) {
                          setDialogState(() => selectedMonth = month);
                        },
                      );
                    }),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(
                      context,
                    ).pop(DateTime(selectedYear, selectedMonth, 1));
                  },
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildCalendarView() {
    final selectedRecord = _recordForDate(_selectedDate);
    final hasRecord = selectedRecord != null;
    final year = _calendarMonth.year;
    final month = _calendarMonth.month;
    final firstDayOfMonth = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final startWeekday = firstDayOfMonth.weekday;
    final today = DateTime.now();
    final todayKey = DateFormat('yyyy-MM-dd').format(today);

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              onPressed: () => _changeCalendarMonth(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            InkWell(
              onTap: _pickCalendarMonth,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Text(
                      '$year年$month月',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.unfold_more, size: 16),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: () => _changeCalendarMonth(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: ['一', '二', '三', '四', '五', '六', '日']
              .map(
                (d) => Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.0,
          children: List.generate(42, (index) {
            final dayOffset = index - (startWeekday - 1);
            if (dayOffset < 0 || dayOffset >= daysInMonth) {
              return const SizedBox.shrink();
            }
            final day = dayOffset + 1;
            final date = DateTime(year, month, day);
            final dateKey = DateFormat('yyyy-MM-dd').format(date);
            final isSelected = dateKey == _selectedDateText();
            final isToday = dateKey == todayKey;
            final hasEvent = _recordDateKeys.contains(dateKey);

            return GestureDetector(
              onTap: () {
                setState(() {
                  _selectedDate = date;
                });
              },
              onDoubleTap: () => _showEditRecordDialog(date),
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.amber[100] : null,
                  border: isToday
                      ? Border.all(color: Colors.blue, width: 1.5)
                      : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$day',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.amber[900] : null,
                      ),
                    ),
                    if (hasEvent)
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        width: 5,
                        height: 5,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text(
          hasRecord ? '该日期已有记录，可直接修改' : '该日期暂无记录，可新增',
          style: TextStyle(
            color: hasRecord ? Colors.green[700] : Colors.black54,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(10),
          ),
          child: hasRecord
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '日期：${DateFormat('yyyy-MM-dd').format(_selectedDate)}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text('地点：${selectedRecord.location}'),
                    const SizedBox(height: 4),
                    Text('事件：${selectedRecord.event.isEmpty ? '（空）' : selectedRecord.event}'),
                  ],
                )
              : Text(
                  '日期：${DateFormat('yyyy-MM-dd').format(_selectedDate)}\n当天暂无记录',
                  style: TextStyle(color: Colors.grey[700]),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('出行'),
        actions: [
          IconButton(
            tooltip: '拉取出行记录',
            onPressed: _processing ? null : _pullFromGitHub,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: '同步出行记录',
            onPressed: _processing ? null : _pushToGitHub,
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: '新增记录',
            onPressed: _processing ? null : _showAddRecordDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildViewSwitch(),
            const SizedBox(height: 12),
            Expanded(
              child: _viewMode == _TravelViewMode.table
                  ? _buildTableView()
                  : _buildCalendarView(),
            ),
          ],
        ),
      ),
    );
  }
}
