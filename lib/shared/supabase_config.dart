import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const String url = 'https://zksdzafmugorcbxtfjnl.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inprc2R6YWZtdWdvcmNieHRmam5sIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcxMDgyMDYsImV4cCI6MjEwMjY4NDIwNn0.jIYfUKIcsIJIm9MUErPPIwBbmIqZzYksfp70mKc_3G4';
}

final supabase = Supabase.instance.client;
