import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'app_theme.dart';
import 'role_gate.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const InfraGoApp(),
    ),
  );
}

class InfraGoApp extends StatelessWidget {
  const InfraGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'InfraGo',
      theme: AppTheme.light,
      home: const RoleGate(),
    );
  }
}
