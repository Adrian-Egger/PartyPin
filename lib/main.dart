// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:party_pin/Screens/nutzungsbedinungen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'Screens/party_map_screen.dart';
import 'Screens/create_account_screen.dart';
import 'Screens/selection_screen.dart';
import 'Screens/nutzungsbedinungen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final prefs = await SharedPreferences.getInstance();

  // Login-Status
  final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

  // Rechtliche Zustimmung
  final termsAccepted = prefs.getBool('termsAccepted') ?? false;

  // Standortdaten
  final savedCity = prefs.getString('city');
  final savedCountry = prefs.getString('country');
  final savedLat = prefs.getDouble('selectedLat');
  final savedLng = prefs.getDouble('selectedLng');

  final bool hasLocationData =
      savedCity != null &&
          savedCountry != null &&
          savedLat != null &&
          savedLng != null;

  // Start-Screen bestimmen
  Widget startScreen;

  if (!isLoggedIn) {
    // Noch kein Account / nicht eingeloggt
    startScreen = const CreateAccountScreen();
  } else if (!termsAccepted) {
    // Eingeloggt, aber AGB/Datenschutz noch nicht bestätigt
    startScreen = const TermsScreen();
  } else if (!hasLocationData) {
    // Eingeloggt + AGB akzeptiert, aber noch keine Stadt/Land gewählt
    startScreen = const SelectionScreen();
  } else {
    // Alles erfüllt → direkt zur Karte
    startScreen = const PartyMapScreen();
  }

  runApp(MyApp(startScreen: startScreen));
}

class MyApp extends StatelessWidget {
  final Widget startScreen;

  const MyApp({super.key, required this.startScreen});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Party Finder',
      home: startScreen,
    );
  }
}
