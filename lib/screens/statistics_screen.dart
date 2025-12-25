import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/time_provider.dart';
import '../models/time_slot.dart';

class StatisticsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('每日统计'),
      ),
      body: Consumer<TimeProvider>(
        builder: (context, timeProvider, child) {
          final highPrioritySlots = timeProvider.slots
              .where((slot) => slot.priority == Priority.high)
              .toList();
          final mediumPrioritySlots = timeProvider.slots
              .where((slot) => slot.priority == Priority.medium)
              .toList();
          final lowPrioritySlots = timeProvider.slots
              .where((slot) => slot.priority == Priority.low)
              .toList();

          return ListView(
            padding: EdgeInsets.all(8.0),
            children: [
              _buildPrioritySection('高优先级', highPrioritySlots, context),
              _buildPrioritySection('中优先级', mediumPrioritySlots, context),
              _buildPrioritySection('低优先级', lowPrioritySlots, context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPrioritySection(
      String title, List<TimeSlot> slots, BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(vertical: 8.0),
      child: ExpansionTile(
        title: Text(
          '$title (${slots.length} 项)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        children: slots.map((slot) {
          final startHour = slot.hour;
          final startMinute = slot.minute10 * 10;
          final start =
              '${startHour}:${startMinute.toString().padLeft(2, '0')}';
          // 每个 TimeSlot 表示 10 分钟片段
          DateTime endTime = DateTime(2000, 1, 1, startHour, startMinute)
              .add(Duration(minutes: 10));
          final end =
              '${endTime.hour}:${endTime.minute.toString().padLeft(2, '0')}';
          return ListTile(
            title: Text('$start - $end'),
            subtitle: Text('优先级: ${slot.priority.label}'),
          );
        }).toList(),
      ),
    );
  }
}
