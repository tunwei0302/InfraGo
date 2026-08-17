import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'commuter_home_screen.dart';
import 'driver_home_screen.dart';

class RoleGate extends StatelessWidget {
  const RoleGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        return appState.isDriverMode
            ? const DriverHomeScreen()
            : const CommuterHomeScreen();
      },
    );
  }
}
