import 'package:flutter/material.dart';
import '../models/schedule_template.dart';
import '../providers/time_provider.dart';

class TemplateBar extends StatelessWidget {
  final TimeProvider provider;
  final void Function(ScheduleTemplate template) onTemplateTap;
  final VoidCallback onManageTap;
  final VoidCallback onCopyYesterdayTap;

  const TemplateBar({
    super.key,
    required this.provider,
    required this.onTemplateTap,
    required this.onManageTap,
    required this.onCopyYesterdayTap,
  });

  static const double _chipHeight = 30;
  static const double _chipGap = 3;
  static const double _maxListHeight = 126;

  @override
  Widget build(BuildContext context) {
    final templates = provider.templates;
    final chipCount = templates.length + 1;
    final listHeight = (chipCount * _chipHeight + (chipCount - 1) * _chipGap)
        .clamp(_chipHeight, _maxListHeight)
        .toDouble();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 8, 2, 6),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        border: Border(bottom: BorderSide(color: Colors.grey[300]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '模板',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[800],
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: onManageTap,
                icon: Icon(Icons.settings, size: 22, color: Colors.grey[700]),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                tooltip: '管理模板',
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: templates.isEmpty ? _chipHeight : listHeight,
            child: templates.isEmpty
                ? _TemplateChip(
                    name: '昨天',
                    onTap: onCopyYesterdayTap,
                  )
                : ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: chipCount,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: _chipGap),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _TemplateChip(
                          name: '昨天',
                          onTap: onCopyYesterdayTap,
                        );
                      }
                      final template = templates[index - 1];
                      return _TemplateChip(
                        name: template.name,
                        onTap: () => onTemplateTap(template),
                      );
                    },
                  ),
          ),
          if (templates.isEmpty) ...[
            const SizedBox(height: _chipGap),
            GestureDetector(
              onTap: onManageTap,
              child: Container(
                height: _chipHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Text(
                  '添加模板',
                  style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TemplateChip extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const _TemplateChip({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: Material(
        color: const Color(0xFF9CB86A),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: TemplateBar._chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
