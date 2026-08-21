import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

class AppState extends ChangeNotifier {
  Session? _session;
  String? _role;
  bool _isLoadingRole = false;
  late final StreamSubscription<AuthState> _authSubscription;

  Session? get session => _session;
  String? get role => _role;
  bool get isLoadingRole => _isLoadingRole;

  AppState() {
    _session = supabase.auth.currentSession;
    if (_session != null) {
      _loadRole();
    }
    _authSubscription = supabase.auth.onAuthStateChange.listen((data) {
      _session = data.session;
      if (_session == null) {
        _role = null;
        notifyListeners();
      } else {
        _loadRole();
      }
    });
  }

  Future<void> _loadRole() async {
    _isLoadingRole = true;
    notifyListeners();
    try {
      final data = await supabase
          .from('profiles')
          .select('role')
          .eq('id', _session!.user.id)
          .single();
      _role = data['role'] as String;
    } catch (_) {
      _role = null;
    }
    _isLoadingRole = false;
    notifyListeners();
  }

  Future<void> signOut() => supabase.auth.signOut();

  @override
  void dispose() {
    _authSubscription.cancel();
    super.dispose();
  }
}
