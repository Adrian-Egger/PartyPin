import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

import 'firebase_options.dart';
import 'Screens/home/home_shell.dart';
import 'Theme/app_theme.dart';
import 'Services/deep_link_handler.dart';
import 'Services/notification_service.dart';
import 'Services/stripe_service.dart';
import 'l10n/lang.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  // 1. Flutter binding
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Phase 1: alles, was KEIN Firebase-Service braucht, parallel.
  //    - Firebase.initializeApp        (schwerste Init-Operation)
  //    - Lang.load                     (SharedPreferences read)
  //    - Maps-Renderer (Android)       (Native Surface-Setup)
  //    Statt sequenziell laufen sie gleichzeitig — typisch 200-500ms
  //    Cold-Start-Ersparnis.
  final mapsImpl = GoogleMapsFlutterPlatform.instance;
  final mapsFuture = (mapsImpl is GoogleMapsFlutterAndroid)
      // Surface-Renderer, damit GoogleMap nicht den IME-Fokus stiehlt.
      ? mapsImpl.initializeWithRenderer(AndroidMapRenderer.latest)
      : Future<void>.value();

  await Future.wait<void>([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    Lang.load(),
    mapsFuture,
  ]);

  // 3. App Check — KRITISCHER SYNC-POINT.
  //    Muss unmittelbar nach Firebase.initializeApp() laufen, bevor
  //    irgendein Firebase-Service einen App-Check-Token anfordert.
  //    Release: Play Integrity / Device Check. Debug: Debug-Provider
  //    (Token muss in der Firebase Console hinterlegt sein).
  await FirebaseAppCheck.instance.activate(
    androidProvider: kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
    appleProvider: kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
  );
  if (kDebugMode) {
    // ignore: avoid_print
    print("DEBUG APPCHECK ACTIVE");
  }

  // 4. Phase 2: Stripe + (optional) anonyme Auth parallel.
  //    Stripe haengt nicht von Auth ab und umgekehrt.
  //    signInAnonymously nur, wenn noch kein User da ist — vermeidet
  //    einen unnoetigen Netzwerk-Roundtrip beim Warmstart.
  await Future.wait<void>([
    StripeService.init(),
    if (FirebaseAuth.instance.currentUser == null)
      FirebaseAuth.instance.signInAnonymously().then((_) {}),
  ]);

  // Background-Handler: SYNCHRONOUS Registrierung, kein await.
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // 5. Fire-and-forget — NICHT im kritischen Start-Pfad warten.
  //    NotificationService.init() oeffnet beim Erstinstall den OS-
  //    Permission-Prompt, das wuerde sonst den Splashscreen blockieren
  //    bis der User antwortet (Sekunden!). DeepLinkHandler verarbeitet
  //    den Initial-Link auch noch nach UI-Mount korrekt.
  unawaited(NotificationService.init().catchError((_) {}));
  unawaited(DeepLinkHandler.start().catchError((_) {}));

  // 6. UI starten — App ist sichtbar.
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (_, lang, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'PartyPin',
        theme: AppTheme.dark,
        scaffoldMessengerKey: rootMessengerKey,
        home: const HomeShell(),
      ),
    );
  }
}
