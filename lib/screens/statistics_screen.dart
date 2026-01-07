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
          final recordedSlots =
              timeProvider.slots.where((s) => s.recorded).toList();

          return ListView(
            padding: EdgeInsets.all(8.0),
            children: [
              Card(
                margin: EdgeInsets.symmetric(vertical: 8.0),
                child: ListTile(
                  title: Text('已记录片段'),
                  subtitle: Text(
                      '共 ${recordedSlots.length} 项，${recordedSlots.length * 10} 分钟'),
                ),
              ),
              ...recordedSlots.map((slot) {
                final startHour = slot.hour;
                final startMinute = slot.minute10 * 10;
                final start =
                    '${startHour}:${startMinute.toString().padLeft(2, '0')}';
                DateTime endTime = DateTime(2000, 1, 1, startHour, startMinute)
                    .add(Duration(minutes: 10));
                final end =
                    '${endTime.hour}:${endTime.minute.toString().padLeft(2, '0')}';
                return ListTile(
                  title: Text('$start - $end'),
                );
              }).toList(),
            ],
          );
        },
      ),
    );
  }
}
