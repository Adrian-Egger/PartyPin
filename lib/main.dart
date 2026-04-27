import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

import 'firebase_options.dart';
import 'Screens/home/home_shell.dart';
import 'Theme/app_theme.dart';
import 'Services/notification_service.dart';
import 'l10n/lang.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use SurfaceAndroidViewController so the GoogleMap native view does not
  // intercept the IME connection — without this, the map steals text input
  // focus on all screens when using IndexedStack, blocking ä/ö/ü input.
  final mapsImpl = GoogleMapsFlutterPlatform.instance;
  if (mapsImpl is GoogleMapsFlutterAndroid) {
    await mapsImpl.initializeWithRenderer(AndroidMapRenderer.latest);
  }

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // nötig für Callable Functions
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }

  await Lang.load();
  try {
    await NotificationService.init();
  } catch (_) {}

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
        home: const HomeShell(),
      ),
    );
  }
}
