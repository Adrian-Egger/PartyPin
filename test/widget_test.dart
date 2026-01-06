import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:party_pin/Screens/create_account_screen.dart';
import 'package:party_pin/main.dart';

void main() {
  testWidgets('App startet ohne Crash', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MyApp(
        startScreen: CreateAccountScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(CreateAccountScreen), findsOneWidget);
  });
}
