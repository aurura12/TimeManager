import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/diary_conflict.dart';
import '../models/diary_kind.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../utils/text_diff.dart';

/// 日记冲突处理页：逐块对比本地与远端，选择保留哪一边或手动合并。
///
/// 纯展示与选择：不访问网络、不读写存储，结果通过 [Navigator.pop] 返回
/// [DiaryConflictDecision]，由日记页负责保存与上传。
class DiaryConflictScreen extends StatefulWidget {
  const DiaryConflictScreen({
    super.key,
    required this.kind,
    required this.date,
    required this.localBody,
    required this.remoteBody,
    this.remoteSha,
  });

  final DiaryKind kind;
  final DateTime date;
  final String localBody;
  final String remoteBody;
  final String? remoteSha;

  @override
  State<DiaryConflictScreen> createState() => _DiaryConflictScreenState();
}

class _DiaryConflictScreenState extends State<DiaryConflictScreen> {
  late final List<TextDiffBlock> _blocks;
  late final List<int> _conflictBlockIndexes;
  late List<HunkChoice> _choices;
  TextEditingController? _mergeController;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _blocks = buildDiffBlocks(widget.localBody, widget.remoteBody);
    _conflictBlockIndexes = [
      for (var i = 0; i < _blocks.length; i++)
        if (_blocks[i].isConflict) i,
    ];
    _choices = defaultHunkChoices(_blocks);
  }

  @override
  void dispose() {
    _mergeController?.dispose();
    super.dispose();
  }

  String get _kindLabel => widget.kind == DiaryKind.g ? '乖乖' : '晶晶';

  String get _dateLabel => DateFormat('yyyy年M月d日').format(widget.date);

  String get _mergedBody => mergeDiffBlocks(_blocks, _choices);

  void _setChoice(int blockIndex, HunkChoice choice) {
    final index = _conflictBlockIndexes.indexOf(blockIndex);
    if (index < 0 || index >= _choices.length) return;
    setState(() => _choices[index] = choice);
  }

  void _startEditing() {
    final controller = TextEditingController(text: _mergedBody);
    setState(() {
      _mergeController?.dispose();
      _mergeController = controller;
      _editing = true;
    });
  }

  void _cancelEditing() {
    setState(() {
      _mergeController?.dispose();
      _mergeController = null;
      _editing = false;
    });
  }

  Future<void> _useRemote() async {
    final confirmed = await _confirm(
      title: '用远端覆盖本地',
      content: '将丢弃本机这篇的修改，改用远端当前版本。此操作不可撤销。',
      actionLabel: '用远端覆盖',
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop<DiaryConflictDecision>(
      const DiaryUseRemote(),
    );
  }

  Future<void> _useLocal() async {
    final confirmed = await _confirm(
      title: '用本地覆盖远端',
      content: '将用本机内容覆盖远端当前版本；如果其他设备还有更新，这次操作会覆盖它们。'
          '此操作不可撤销。',
      actionLabel: '用本地覆盖',
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop<DiaryConflictDecision>(
      const DiaryKeepLocal(),
    );
  }

  Future<void> _saveMerged() async {
    final body = _mergeController?.text ?? _mergedBody;
    if (body.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('合并结果为空，请补充内容后再保存')),
      );
      return;
    }
    Navigator.of(context).pop<DiaryConflictDecision>(
      DiaryUseMerged(body),
    );
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String actionLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_editing,
      child: Scaffold(
        backgroundColor: AppWallpaperTheme.of(context).enabled
            ? Colors.transparent
            : colorScheme.surface,
        appBar: AppBar(
          title: Text(_editing ? '合并编辑' : '处理冲突'),
          leading: _editing
              ? IconButton(
                  tooltip: '返回对比',
                  onPressed: _cancelEditing,
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
        ),
        body: _editing ? _buildMergeEditor() : _buildDiffView(context),
        bottomNavigationBar: _editing
            ? _buildEditingActions(context)
            : _buildDiffActions(context),
      ),
    );
  }

  Widget _buildDiffView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: AppSpacing.page,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppSizes.desktopContentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: AppSpacing.md),
              for (var i = 0; i < _blocks.length; i++)
                _buildBlock(context, i, _blocks[i]),
              if (_conflictBlockIndexes.isEmpty)
                Padding(
                  padding: AppSpacing.cardComfortable,
                  child: Text(
                    '本地与远端正文一致，无需处理。',
                    style: AppText.body.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    final sha = widget.remoteSha;
    final shortSha = sha == null || sha.isEmpty
        ? '未知'
        : sha.length > 7
            ? sha.substring(0, 7)
            : sha;
    return Container(
      padding: AppSpacing.cardComfortable,
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: AppRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$_kindLabel · $_dateLabel', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '共 ${_conflictBlockIndexes.length} 处差异。下面每一处都可以单独选择保留哪一边，'
            '也可以直接整体采用某一边。',
            style: AppText.body.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '远端版本：$shortSha',
            style: AppText.caption.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(BuildContext context, int blockIndex, TextDiffBlock block) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!block.isConflict) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Text(
          block.localLines.join('\n'),
          style: AppText.body.copyWith(color: colorScheme.onSurface),
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 840;
    final choiceIndex = _conflictBlockIndexes.indexOf(blockIndex);
    final choice =
        choiceIndex >= 0 ? _choices[choiceIndex] : HunkChoice.both;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: AppSpacing.card,
      decoration: BoxDecoration(
        color: AppSemanticColors.tint(
          AppSemanticColors.warning,
          AppSurfaces.of(context).card,
          0.06,
        ),
        borderRadius: AppRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildSide(
                    context,
                    label: '本地',
                    lines: block.localLines,
                    tint: AppSemanticColors.danger,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _buildSide(
                    context,
                    label: '远端',
                    lines: block.remoteLines,
                    tint: AppSemanticColors.success,
                  ),
                ),
              ],
            )
          else ...[
            _buildSide(
              context,
              label: '本地',
              lines: block.localLines,
              tint: AppSemanticColors.danger,
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildSide(
              context,
              label: '远端',
              lines: block.remoteLines,
              tint: AppSemanticColors.success,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: SegmentedButton<HunkChoice>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: HunkChoice.local, label: Text('用本地')),
                ButtonSegment(value: HunkChoice.remote, label: Text('用远端')),
                ButtonSegment(value: HunkChoice.both, label: Text('两边都留')),
              ],
              selected: {choice},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                _setChoice(blockIndex, selection.first);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSide(
    BuildContext context, {
    required String label,
    required List<String> lines,
    required Color tint,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final surfaces = AppSurfaces.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppText.caption.copyWith(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          width: double.infinity,
          padding: AppSpacing.chip,
          decoration: BoxDecoration(
            color: AppSemanticColors.tint(tint, surfaces.card, 0.10),
            borderRadius: AppRadius.controlAll,
          ),
          child: Text(
            lines.isEmpty ? '（无内容）' : lines.join('\n'),
            style: AppText.body.copyWith(color: colorScheme.onSurface),
          ),
        ),
      ],
    );
  }

  Widget _buildMergeEditor() {
    return Padding(
      padding: AppSpacing.page,
      child: TextField(
        controller: _mergeController,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          hintText: '在这里调整合并后的正文',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildDiffActions(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    return Container(
      color: surfaces.overlay,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: AppSpacing.cardComfortable,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton(
                onPressed: _useRemote,
                child: const Text('用远端覆盖本地'),
              ),
              OutlinedButton(
                onPressed: _useLocal,
                child: const Text('用本地覆盖远端'),
              ),
              FilledButton(
                onPressed: _startEditing,
                child: const Text('合并并上传'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditingActions(BuildContext context) {
    final surfaces = AppSurfaces.of(context);
    return Container(
      color: surfaces.overlay,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: AppSpacing.cardComfortable,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _cancelEditing,
                child: const Text('取消'),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: _saveMerged,
                child: const Text('保存合并结果'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
