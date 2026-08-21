import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'app_theme.dart';
import 'role_gate.dart';
import 'supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.anonKey,
  );
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
