import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/target.dart';
import 'add_target_screen.dart';
import '../widgets/target_stats_section.dart';

class TargetDetailScreen extends StatelessWidget {
  final Target target;

  const TargetDetailScreen({super.key, required this.target});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        title: Text(target.name, style: TextStyle(color: isDark ? colorScheme.onSurface : Colors.white)),
        centerTitle: true,
        backgroundColor: isDark ? colorScheme.surface : const Color(0xFF96B462),
        foregroundColor: isDark ? colorScheme.onSurface : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.white),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddTargetScreen(target: target),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("确认删除"),
                  content: Text('确定要删除目标"${target.name}"吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("取消"),
                    ),
                    TextButton(
                      onPressed: () {
                        Provider.of<TimeProvider>(context, listen: false)
                            .deleteTarget(target);
                        Navigator.pop(context);
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text("删除"),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: TargetStatsSection(
              target: target,
              provider: timeProvider,
            ),
          );
        },
      ),
    );
  }
}
