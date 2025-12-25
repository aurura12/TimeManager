import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/time_provider.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => TimeProvider(),
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
}