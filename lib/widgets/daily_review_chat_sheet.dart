import 'package:flutter/material.dart';

import '../models/daily_review_chat_message.dart';
import '../services/daily_review_chat_service.dart';
import '../services/daily_review_chat_store.dart';
import '../services/daily_review_summary.dart';
import '../services/siliconflow_ai_service.dart';

class DailyReviewChatSheet extends StatefulWidget {
  final DateTime date;
  final String? reviewBody;
  final String? initialQuestion;

  const DailyReviewChatSheet({
    super.key,
    required this.date,
    this.reviewBody,
    this.initialQuestion,
  });

  static Future<void> open(
    BuildContext context, {
    required DateTime date,
    String? reviewBody,
    String? initialQuestion,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => DailyReviewChatSheet(
        date: date,
        reviewBody: reviewBody,
        initialQuestion: initialQuestion,
      ),
    );
  }

  @override
  State<DailyReviewChatSheet> createState() => _DailyReviewChatSheetState();
}

class _DailyReviewChatSheetState extends State<DailyReviewChatSheet> {
  static const _contextSyncText = '时间记录已更新';

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<DailyReviewChatMessage> _messages = [];
  bool _loadingHistory = true;
  bool _sending = false;
  String? _dataHash;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final session = await DailyReviewChatStore.loadSession(widget.date);
    var messages = List<DailyReviewChatMessage>.from(session.messages);
    _dataHash = session.dataHash;

    if (messages.isEmpty) {
      final review = widget.reviewBody?.trim();
      if (review != null && review.isNotEmpty) {
        messages = [
          DailyReviewChatMessage(
            role: 'assistant',
            content: review,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            fromReview: true,
          ),
        ];
      }
    }

    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
      _loadingHistory = false;
    });

    await _syncContextIfNeeded();
    _scrollToBottom();

    final pending = widget.initialQuestion?.trim();
    if (pending != null && pending.isNotEmpty) {
      await _sendMessage(pending);
    }
  }

  Future<void> _syncContextIfNeeded() async {
    final currentHash =
        await DailyReviewSummaryBuilder.computeDayDataHash(widget.date);
    if (_dataHash == currentHash) return;

    final hasUserChat = _messages.any((m) => m.isUser);
    if (hasUserChat && (_messages.isEmpty || !_messages.last.contextSync)) {
      setState(() {
        _messages.add(DailyReviewChatMessage(
          role: 'assistant',
          content: _contextSyncText,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          contextSync: true,
        ));
      });
    }

    _dataHash = currentHash;
    await _persist();
  }

  Future<void> _persist() async {
    await DailyReviewChatStore.save(
      widget.date,
      List.of(_messages),
      dataHash: _dataHash,
    );
  }

  Future<void> _sendMessage([String? text]) async {
    final content = (text ?? _inputController.text).trim();
    if (content.isEmpty || _sending) return;

    if (!SiliconFlowAiService.hasApiKeyConfigured) {
      _showSnack('未配置 AI API Key');
      return;
    }

    await _syncContextIfNeeded();

    setState(() {
      _sending = true;
      _messages.add(DailyReviewChatMessage(
        role: 'user',
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    });
    if (text == null) {
      _inputController.clear();
    }
    await _persist();
    _scrollToBottom();

    final reply = await DailyReviewChatService.send(
      date: widget.date,
      userText: content,
      history: _messages.sublist(0, _messages.length - 1),
    );

    if (!mounted) return;

    if (!reply.isSuccess) {
      setState(() {
        _sending = false;
        _messages.removeLast();
      });
      await _persist();
      _showSnack(reply.errorMessage);
      return;
    }

    setState(() {
      _messages.add(DailyReviewChatMessage(
        role: 'assistant',
        content: reply.content!,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      _sending = false;
    });
    await _persist();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空对话'),
        content: const Text('将删除这一天的聊天记录，复盘正文不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await DailyReviewChatStore.clear(widget.date);
    final review = widget.reviewBody?.trim();
    final hash =
        await DailyReviewSummaryBuilder.computeDayDataHash(widget.date);
    setState(() {
      _messages.clear();
      _dataHash = hash;
      if (review != null && review.isNotEmpty) {
        _messages.add(DailyReviewChatMessage(
          role: 'assistant',
          content: review,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          fromReview: true,
        ));
      }
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.72;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: sheetHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.date.month}月${widget.date.day}日 对话',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_messages.any((m) => m.isUser))
                    TextButton(
                      onPressed: _sending ? null : _confirmClear,
                      child: const Text('清空'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loadingHistory
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? Center(
                          child: Text(
                            '暂无对话，在下方输入问题',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          itemCount: _messages.length + (_sending ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _messages.length) {
                              return _buildTypingBubble(colorScheme);
                            }
                            return _buildBubble(
                              _messages[index],
                              colorScheme,
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sending ? null : (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: '问问这一天…',
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : () => _sendMessage(),
                    icon: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(
    DailyReviewChatMessage message,
    ColorScheme colorScheme,
  ) {
    final isUser = message.isUser;
    final isNotice = message.contextSync;
    final bg = isUser
        ? colorScheme.primary
        : isNotice
            ? colorScheme.tertiaryContainer
            : colorScheme.surfaceContainerHigh;
    final fg = isUser
        ? colorScheme.onPrimary
        : isNotice
            ? colorScheme.onTertiaryContainer
            : colorScheme.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.fromReview)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '今日复盘（打开对话时的摘要，若之后有补记请以最新回答为准）',
                  style: TextStyle(
                    fontSize: 11,
                    color: fg.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (message.contextSync)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '记录已同步',
                  style: TextStyle(
                    fontSize: 11,
                    color: fg.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Text(
              message.content,
              style: TextStyle(color: fg, height: 1.5, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingBubble(ColorScheme colorScheme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
