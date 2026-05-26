import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/time_provider.dart';
import 'package:time_manager/screens/main_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (context) => TimeProvider(),
      child: const MaterialApp(home: MainScreen()),
    ),
  );
}