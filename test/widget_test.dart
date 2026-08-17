import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:infra_go/app_state.dart';
import 'package:infra_go/main.dart';

void main() {
  Widget buildApp() {
    return ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const InfraGoApp(),
    );
  }

  testWidgets('App launches into Commuter home', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());

    expect(find.text('InfraGo · Commuter'), findsOneWidget);
  });

  testWidgets('Role switch toggles between Commuter and Driver home',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('InfraGo · Driver'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();
    expect(find.text('InfraGo · Commuter'), findsOneWidget);
  });

  testWidgets('Booking form validates before popping back',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('Book a Ride'));
    await tester.pumpAndSettle();
    expect(find.text('Ride Booking & Forms'), findsOneWidget);

    await tester.tap(find.text('Confirm Booking'));
    await tester.pumpAndSettle();
    expect(find.text('Please enter a pickup location'), findsOneWidget);
    expect(find.text('Ride Booking & Forms'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Pickup location'), 'KLCC');
    await tester.enterText(find.widgetWithText(TextFormField, 'Destination'), 'KL Sentral');
    await tester.tap(find.text('Confirm Booking'));
    await tester.pumpAndSettle();
    expect(find.text('InfraGo · Commuter'), findsOneWidget);
  });

  testWidgets('Driver bottom nav switches between Hub and Available Orders',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.byIcon(Icons.swap_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Online'), findsOneWidget);

    await tester.tap(find.text('Orders'));
    await tester.pumpAndSettle();
    expect(find.text('No orders yet'), findsOneWidget);

    await tester.tap(find.text('Hub'));
    await tester.pumpAndSettle();
    expect(find.text('InfraGo · Driver'), findsOneWidget);
  });

  testWidgets('Commuter bottom nav switches between Map, Chat, Analytics, Profile',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Chat with Driver'), findsOneWidget);

    await tester.tap(find.text('Analytics'));
    await tester.pumpAndSettle();
    expect(find.text('Analytics Dashboard'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('User Profile'), findsOneWidget);

    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    expect(find.text('InfraGo · Commuter'), findsOneWidget);
  });
}
