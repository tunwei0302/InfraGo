import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'booking_form_screen.dart';

void main() {
  runApp(const BookingFormPreviewApp());
}

class BookingFormPreviewApp extends StatelessWidget {
  const BookingFormPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const BookingFormScreen(),
    );
  }
}
