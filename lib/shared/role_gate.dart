import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:infra_go/shared/app_state.dart';
import 'package:infra_go/shared/commuter_home_screen.dart';
import 'package:infra_go/heng/driver_home_screen.dart';
import 'package:infra_go/shared/login_screen.dart';

class RoleGate extends StatelessWidget {
  const RoleGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.session == null) {
          return const LoginScreen();
        }
        if (appState.isLoadingRole) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (appState.roleLoadFailed) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not load your profile.'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => appState.retryLoadRole(),
                    child: const Text('Retry'),
                  ),
                  TextButton(
                    onPressed: () => appState.signOut(),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          );
        }
        if (appState.role == 'driver') {
          return const DriverHomeScreen();
        }
        return const CommuterHomeScreen();
      },
    );
  }
}
