import 'package:flutter/material.dart';
import '../services/daily_review_summary.dart';

class DailyReviewScreen extends StatefulWidget {
  final DateTime date;

  const DailyReviewScreen({
    super.key,
    required this.date,
  });

  static Future<void> open(
    BuildContext context, {
    DateTime? date,
  }) {
    final target = date ?? DateTime.now();
    final normalized = DateTime(target.year, target.month, target.day);
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DailyReviewScreen(date: normalized),
      ),
    );
  }

  @override
  State<DailyReviewScreen> createState() => _DailyReviewScreenState();
}

class _DailyReviewScreenState extends State<DailyReviewScreen> {
  DailyReviewAiResult? _result;
  bool _loading = true;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.date;
    _loadReview(forceRefresh: false);
  }

  Future<void> _loadReview({required bool forceRefresh}) async {
    setState(() => _loading = true);

    if (!forceRefresh) {
      final cached = await DailyReviewSummaryBuilder.loadCachedAi(_selectedDate);
      if (cached != null && mounted) {
        setState(() {
          _result = cached;
          _loading = false;
        });
        return;
      }
    }

    final result = await DailyReviewSummaryBuilder.fetchAiForDate(
      _selectedDate,
      forceRefresh: forceRefresh,
    );

    if (mounted) {
      setState(() {
        _result = result;
        _loading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
      locale: const Locale('zh', 'CN'),
    );
    if (picked == null) return;

    final normalized = DateTime(picked.year, picked.month, picked.day);
    if (normalized == _selectedDate) return;
    setState(() {
      _selectedDate = normalized;
      _result = null;
    });
    await _loadReview(forceRefresh: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(
          '${_selectedDate.month}月${_selectedDate.day}日 · 今日复盘',
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            tooltip: '选择日期',
            onPressed: _loading ? null : _pickDate,
            icon: const Icon(Icons.calendar_month_outlined),
          ),
          IconButton(
            tooltip: '重新生成',
            onPressed: _loading ? null : () => _loadReview(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _result == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF9CB86A)),
            SizedBox(height: 16),
            Text('AI 正在生成今日复盘…', style: TextStyle(color: Colors.black54)),
          ],
        ),
      );
    }

    final result = _result;
    if (result == null) {
      return _buildError('加载失败', '请稍后重试');
    }

    if (!result.isSuccess) {
      return _buildError('无法展示复盘', result.errorMessage);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF9CB86A).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'AI 生成',
                      style: TextStyle(
                        color: Color(0xFF6B8E3A),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (result.fromCache) ...[
                    const SizedBox(width: 8),
                    Text(
                      '来自缓存',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              Text(
                result.body!,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.75,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF9CB86A),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildError(String title, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], height: 1.5),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loading ? null : () => _loadReview(forceRefresh: true),
              icon: const Icon(Icons.refresh),
              label: const Text('重新生成'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF9CB86A),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
