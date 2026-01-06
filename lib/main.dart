import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'firebase_options.dart';
import 'Screens/home_shell.dart';
import 'Screens/create_account_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // nötig für Callable Functions
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }

  runApp(
    const MyApp(
      startScreen: HomeShell(),
    ),
  );
}

class MyApp extends StatelessWidget {
  final Widget startScreen;

  const MyApp({
    super.key,
    required this.startScreen,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Party Finder',
      home: startScreen,
    );
  }
}
