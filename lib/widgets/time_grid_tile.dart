import 'package:flutter/material.dart';
import '../models/time_slot.dart';

class TimeGridTile extends StatelessWidget {
  final TimeSlot slot;
  final VoidCallback onTap;

  const TimeGridTile({super.key, required this.slot, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool active = slot.recorded;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: active ? Colors.blueAccent.withOpacity(0.9) : Colors.grey[200],
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            if (active) BoxShadow(color: Colors.black12, blurRadius: 2)
          ],
        ),
        child: Center(
          child: Text("${slot.minute10}",
              style: TextStyle(
                  fontSize: 10,
                  color: active ? Colors.white : Colors.black54,
                  fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}
