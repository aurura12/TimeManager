import 'package:flutter/material.dart';

import '../models/voice_schedule_draft.dart';
import '../providers/time_provider.dart';
import '../services/speech_recognition_service.dart';
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
  late final SpeechRecognitionService _speechService;

  VoiceScheduleParseResult? _parseResult;
  VoiceScheduleConflictMode _conflictMode =
      VoiceScheduleConflictMode.fillEmptyOnly;
  String? _error;
  bool _isListening = false;
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    _speechService = SpeechRecognitionService();
  }

  @override
  void dispose() {
    _speechService.cancel();
    _textController.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speechService.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    setState(() {
      _error = null;
      _isListening = true;
    });

    final started = await _speechService.start(
      onText: (text, isFinal) {
        if (!mounted) return;
        _updateTranscript(text);
        if (isFinal) setState(() => _isListening = false);
      },
      onError: (message) {
        if (!mounted) return;
        setState(() {
          _isListening = false;
          _error = message;
        });
      },
      onStatus: (status) {
        if (!mounted) return;
        if (status == 'notListening' || status == 'done') {
          setState(() => _isListening = false);
        }
      },
    );

    if (mounted && !started) {
      setState(() {
        _isListening = false;
        _error = '无法启动语音识别，请检查安卓麦克风权限';
      });
    }
  }

  void _updateTranscript(String text) {
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _parseTranscript(text);
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
              '例如：明天下午三点到四点开会。没有匹配到的事项会作为临时事件。',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textController,
              onChanged: _onTextChanged,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '识别内容',
                hintText: '点击下方按钮开始说话，也可以直接修改文字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isApplying ? null : _toggleListening,
              icon: Icon(_isListening ? Icons.stop : Icons.mic),
              label: Text(_isListening ? '停止识别' : '开始识别'),
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
              onPressed:
                  draft == null || _isListening || _isApplying ? null : _apply,
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
