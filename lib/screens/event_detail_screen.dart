import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';

import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
class EventDetailScreen extends StatelessWidget {
  final String eventName;
  final int tabIndex;

  const EventDetailScreen(
      {super.key, required this.eventName, required this.tabIndex});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TimeProvider>(context);
    final colorScheme = Theme.of(context).colorScheme;

    // 普通详情仍按时间平铺；“已删除”详情额外携带父事件关系。
    final Map<String, List<EventHistoryItem>> history =
        provider.getEventHistory(eventName, tabIndex);
    final showDeletedRelations = provider.isDeletedEventName(eventName);

    return Scaffold(
      appBar: AppBar(
        title: Text(eventName),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("时间分布详情",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              if (history.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text("暂无记录",
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        )),
                  ),
                )
              else
                ...history.entries.map((entry) {
                  final groupedRelations = <String, List<EventHistoryItem>>{};
                  if (showDeletedRelations) {
                    for (final item in entry.value) {
                      final parentName = item.parentName ?? '父事件关系不明确';
                      groupedRelations
                          .putIfAbsent(parentName, () => [])
                          .add(item);
                    }
                  }
                  return SizedBox(
                    width: double.infinity,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 日期标题
                        Text(entry.key,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppSemanticColors.readableOn(
                                    AppSemanticColors.brand,
                                    AppSurfaces.of(context).card))),
                        const SizedBox(height: 8),
                        if (showDeletedRelations)
                          ...groupedRelations.entries.map(
                            (group) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.account_tree_outlined,
                                          size: 15,
                                          color: colorScheme.onSurface),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          group.key,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                            color: colorScheme.onSurface,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  ...group.value.map(
                                    (item) => _buildHistoryRow(
                                      item,
                                      colorScheme,
                                      indent: 24,
                                      label: item.isParentEvent
                                          ? '父事件本身'
                                          : item.label,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ...entry.value.map(
                            (item) => _buildHistoryRow(
                              item,
                              colorScheme,
                              indent: 8,
                              label: item.label,
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryRow(
    EventHistoryItem item,
    ColorScheme colorScheme, {
    required double indent,
    required String label,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 6.0, left: indent),
      child: Row(
        children: [
          Icon(Icons.access_time,
              size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(item.range,
              style: TextStyle(fontSize: 15, color: colorScheme.onSurface)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
