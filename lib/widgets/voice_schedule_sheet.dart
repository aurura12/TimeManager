import 'package:flutter/material.dart';

import '../models/voice_schedule_draft.dart';
import '../providers/time_provider.dart';
import '../services/voice_schedule_parser.dart';
import '../services/voice_schedule_slot_planner.dart';

class VoiceScheduleSheet extends StatefulWidget {
  final TimeProvider provider;
  final DateTime baseDate;

  const VoiceScheduleSheet({
    super.key,
    required this.provider,
    required this.baseDate,
  });

  static Future<void> show(
    BuildContext context, {
    required TimeProvider provider,
    required DateTime baseDate,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => VoiceScheduleSheet(
        provider: provider,
        baseDate: baseDate,
      ),
    );
  }

  @override
  State<VoiceScheduleSheet> createState() => _VoiceScheduleSheetState();
}

class _VoiceScheduleSheetState extends State<VoiceScheduleSheet> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();

  VoiceScheduleParseResult? _parseResult;
  VoiceScheduleConflictMode _conflictMode =
      VoiceScheduleConflictMode.fillEmptyOnly;
  String? _error;
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String text) {
    _parseTranscript(text);
  }

  void _parseTranscript(String text) {
    final result = VoiceScheduleParser.parse(
      transcript: text,
      baseDate: widget.baseDate,
      categories: widget.provider.categories,
    );
    if (!mounted) return;
    setState(() {
      _parseResult = result;
      _error = null;
    });
  }

  Future<void> _apply() async {
    final draft = _parseResult?.draft;
    if (draft == null || _isApplying) return;

    setState(() => _isApplying = true);
    final result = widget.provider.applyVoiceSchedule(
      draft,
      mode: _conflictMode,
    );
    if (!mounted) return;

    if (result.appliedSlotCount == 0) {
      setState(() {
        _isApplying = false;
        _error =
            result.conflictCount > 0 ? '选定时段已有日程，请选择覆盖冲突或修改时间' : '没有可添加的时间槽位';
      });
      return;
    }
    Navigator.pop(context);
  }

  String _formatTime(int index) {
    final hour = index ~/ 6;
    final minute = (index % 6) * 10;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final draft = _parseResult?.draft;
    final plan = draft == null
        ? null
        : VoiceScheduleSlotPlanner.plan(
            slots: widget.provider.slotsForDate(draft.date),
            draft: draft,
            mode: VoiceScheduleConflictMode.fillEmptyOnly,
          );

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.mic_none),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '语音添加日程',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '请点击系统键盘上的麦克风输入语音，识别结果会自动填入这里。没有匹配到的事项会作为临时事件。',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              focusNode: _textFocusNode,
              autofocus: true,
              onChanged: _onTextChanged,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '识别内容',
                hintText: '也可以直接输入，例如：明天下午三点到四点开会',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_parseResult != null) ...[
              const SizedBox(height: 12),
              _buildPreview(draft, plan),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: draft == null || _isApplying ? null : _apply,
              child: Text(_isApplying ? '添加中...' : '确认添加'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(VoiceScheduleDraft? draft, VoiceScheduleSlotPlan? plan) {
    if (draft == null) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_parseResult?.error ?? '无法解析日程'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('添加预览', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('日期：${draft.date.month}月${draft.date.day}日'),
            Text(
                '时间：${_formatTime(draft.startIndex)} - ${_formatTime(draft.endIndexExclusive)}'),
            Text('事件：${draft.label}'),
            Text(draft.isTemporary ? '类型：临时事件' : '类型：已有事件'),
            if (plan != null && plan.conflictCount > 0) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('已有 ${plan.conflictCount} 个时间槽位被占用'),
                subtitle: const Text('开启后将覆盖这些已有日程'),
                value:
                    _conflictMode == VoiceScheduleConflictMode.replaceExisting,
                onChanged: (value) {
                  setState(() {
                    _conflictMode = value
                        ? VoiceScheduleConflictMode.replaceExisting
                        : VoiceScheduleConflictMode.fillEmptyOnly;
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
