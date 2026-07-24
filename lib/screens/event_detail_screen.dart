import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';

class EventDetailScreen extends StatelessWidget {
  final String eventName;
  final int tabIndex;

  const EventDetailScreen(
      {super.key, required this.eventName, required this.tabIndex});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TimeProvider>(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    // 获取筛选后的历史数据：Map<日期, List<{range, label}>>
    // 例如：{"2月15日": [(range: "08:00 - 09:00", label: "编程"), (range: "14:20 - 15:00", label: "开会")]}
    final Map<String, List<({String range, String label})>> history =
        provider.getEventHistory(eventName, tabIndex);

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(eventName),
        elevation: 0,
        backgroundColor:
            isDark ? colorScheme.surfaceContainerHighest : Colors.white,
        foregroundColor: isDark ? colorScheme.onSurface : Colors.black,
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
                          color: isDark
                              ? colorScheme.onSurfaceVariant
                              : Colors.grey,
                        )),
                  ),
                )
              else
                ...history.entries.map((entry) {
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
                                color: isDark
                                    ? const Color(0xFFB5D390)
                                    : const Color(0xFF9CB86A))),
                        const SizedBox(height: 8),
                        // 该日期下的所有时间段
                        ...entry.value.map((item) => Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 6.0, left: 8.0),
                              child: Row(
                                children: [
                                  Icon(Icons.access_time,
                                      size: 14,
                                      color: isDark
                                          ? colorScheme.onSurfaceVariant
                                          : Colors.grey),
                                  const SizedBox(width: 8),
                                  Text(item.range,
                                      style: TextStyle(
                                          fontSize: 15,
                                          color: isDark
                                              ? colorScheme.onSurface
                                              : Colors.black87)),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(item.label,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: isDark
                                                ? colorScheme.onSurfaceVariant
                                                : Colors.grey)),
                                  ),
                                ],
                              ),
                            )),
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
}
