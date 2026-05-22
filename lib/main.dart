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
// FEATURE_DISABLED_TICKETING — Stripe-Init entfernt.
// see archived/ticketing/README.md
import 'l10n/lang.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  // 1. Flutter binding
  WidgetsFlutterBinding.ensureInitialized();

  // 2. NUR LOKALE Init im kritischen Start-Pfad — KEIN Netzwerk.
  //    Firebase.initializeApp ist lokal (liest google-services config),
  //    Lang.load liest SharedPreferences, der Maps-Renderer ist nativer
  //    Surface-Setup. Keine dieser Ops blockiert auf Netz → kein ANR.
  final mapsImpl = GoogleMapsFlutterPlatform.instance;
  final mapsFuture = (mapsImpl is GoogleMapsFlutterAndroid)
      ? mapsImpl.initializeWithRenderer(AndroidMapRenderer.latest)
      : Future<void>.value();

  await Future.wait<void>([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    Lang.load(),
    mapsFuture,
  ]);

  // 3. App Check aktivieren — DEFENSIV. activate() ist lokal (registriert
  //    nur den Provider); der Token-Fetch passiert lazy beim ersten
  //    Firebase-Request. Ein Fehler hier darf den Start NIEMALS crashen —
  //    sonst killt eine fehlgeschlagene Attestation die ganze App.
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
      appleProvider:
          kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
    );
    if (kDebugMode) {
      // ignore: avoid_print
      print('[appcheck] activated');
    }
  } catch (e) {
    // ignore: avoid_print
    if (kDebugMode) print('[appcheck] activate failed (non-fatal): $e');
  }

  // 4. Background-Handler: SYNCHRON registrieren, kein await, kein Netz.
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // 5. UI SOFORT starten — KEIN Netzwerk-await mehr davor.
  //    signInAnonymously + Services laufen hinter dem ersten Frame im
  //    _Bootstrap-Gate. Erster Frame in Millisekunden statt nach Sekunden.
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
        home: const _Bootstrap(),
      ),
    );
  }
}

/// Bootstrap-Gate: läuft NACH dem ersten Frame. Macht die Netzwerk-Arbeit
/// (anonyme Auth) die früher main() blockiert hat, ohne den Start-Frame zu
/// verzögern. Zeigt solange einen leichten Splash. Firestore-Reads im
/// HomeShell starten erst wenn dieser Gate fertig ist → kein
/// "PERMISSION_DENIED weil Auth noch nicht da".
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<void> _ready = _init();

  Future<void> _init() async {
    // Anonyme Auth jetzt — UI ist schon sichtbar, blockt keinen Frame.
    // Mit Timeout, damit ein hängendes Netz den Gate nicht ewig offen hält.
    if (FirebaseAuth.instance.currentUser == null) {
      try {
        await FirebaseAuth.instance
            .signInAnonymously()
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        // ignore: avoid_print
        if (kDebugMode) print('[auth] anon sign-in failed (non-fatal): $e');
        // Nicht crashen — die App startet trotzdem; Reads scheitern dann
        // graceful (per-Operation try/catch) statt die App zu killen.
      }
    }

    // Services NACH Auth, fire-and-forget. Kein Block auf OS-Permission-
    // Prompt (NotificationService) oder Deep-Link-Parsing.
    unawaited(NotificationService.init().catchError((_) {}));
    unawaited(DeepLinkHandler.start().catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: AppColors.bgTop,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          );
        }
        return const HomeShell();
      },
    );
  }
}
