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

  @override
  Widget build(BuildContext context) {
    final templates = provider.templates;

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
              const SizedBox(width: 6),
              Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: onCopyYesterdayTap,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: const Color(0xFF9CB86A).withValues(alpha: 0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.content_copy,
                            size: 12, color: Colors.grey[700]),
                        const SizedBox(width: 3),
                        Text(
                          '复制昨天',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[800],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
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
          if (templates.isEmpty)
            GestureDetector(
              onTap: onManageTap,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
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
            )
          else
            SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.vertical,
                itemCount: templates.length,
                separatorBuilder: (_, __) => const SizedBox(height: 3),
                itemBuilder: (context, index) {
                  final template = templates[index];
                  return _TemplateChip(
                    name: template.name,
                    onTap: () => onTemplateTap(template),
                  );
                },
              ),
            ),
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
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
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
