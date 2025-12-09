import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:party_pin/Screens/create_account_screen.dart';
import 'package:party_pin/main.dart';

void main() {
  testWidgets('App startet ohne Crash', (WidgetTester tester) async {
    // startScreen ist required -> MUSS gesetzt werden
    await tester.pumpWidget(
      MyApp(startScreen: const CreateAccountScreen()),
    );


    // einmal rendern lassen
    await tester.pumpAndSettle();

    // Smoke-Test: App ist da, kein Crash
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
