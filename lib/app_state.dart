import 'package:flutter/material.dart';

class AppState extends ChangeNotifier {
  bool _isDriverMode = false;

  bool get isDriverMode => _isDriverMode;

  void toggleRole() {
    _isDriverMode = !_isDriverMode;
    notifyListeners();
  }
}
