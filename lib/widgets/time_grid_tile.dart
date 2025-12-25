import 'package:flutter/material.dart';
import '../models/time_slot.dart';

class TimeGridTile extends StatelessWidget {
  final TimeSlot slot;
  final VoidCallback onTap;

  const TimeGridTile({super.key, required this.slot, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: slot.priority.color.withOpacity(0.9),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [if(slot.priority != Priority.none) BoxShadow(color: Colors.black12, blurRadius: 2)],
        ),
        child: Center(
          child: Text("${slot.minute10}", style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}