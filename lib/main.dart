import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  WidgetsFlutterBinding.ensureInitialized();

  // Phase 1: alles, was unabhängig voneinander laufen kann, parallel starten.
  // Reihenfolge der Sequenzialitäten:
  //   • Firebase muss vor signInAnonymously fertig sein.
  //   • Lang.load / StripeService.init / Maps-Renderer sind unabhängig.
  //   • DeepLinkHandler nutzt Auth — kommt nach Phase 2.
  final mapsImpl = GoogleMapsFlutterPlatform.instance;

  final mapsFuture = (mapsImpl is GoogleMapsFlutterAndroid)
      // Use SurfaceAndroidViewController so the GoogleMap native view does
      // not intercept the IME connection — without this, the map steals text
      // input focus on all screens when using IndexedStack.
      ? mapsImpl.initializeWithRenderer(AndroidMapRenderer.latest)
      : Future<void>.value();

  final firebaseFuture = Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Diese drei brauchen Firebase NICHT → sofort parallel starten.
  final langFuture = Lang.load();
  final stripeFuture = StripeService.init();

  await Future.wait([mapsFuture, firebaseFuture, langFuture, stripeFuture]);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Phase 2: Auth + Notifications + DeepLinks parallel — alle drei brauchen
  // ein initialisiertes Firebase, sind aber untereinander unabhängig.
  await Future.wait<void>([
    if (FirebaseAuth.instance.currentUser == null)
      FirebaseAuth.instance.signInAnonymously().then((_) {}),
    NotificationService.init().catchError((_) {}),
    DeepLinkHandler.start(),
  ]);

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
