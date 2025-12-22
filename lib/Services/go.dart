// lib/Services/go.dart
import 'package:flutter/material.dart';
import '../Screens/home_shell.dart';

class Go {
  /// Öffnet IMMER die HomeShell mit BottomNav
  /// [tab] = Index der BottomNavigationBar
  ///
  /// 0 = Feedback
  /// 1 = Freunde
  /// 2 = Map
  /// 3 = Neu
  static void home(BuildContext context, {int tab = 0}) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => HomeShell(initialIndex: tab),
      ),
          (route) => false,
    );
  }
}
