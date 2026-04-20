import 'package:flutter/material.dart';
import '../Screens/home/home_shell.dart';
import '../Theme/app_theme.dart';

class Go {
  /// Öffnet HomeShell mit BottomNav, smooth Fade+Slide Transition
  static void home(BuildContext context, {int tab = 0}) {
    Navigator.of(context).pushAndRemoveUntil(
      _smoothRoute(HomeShell(initialIndex: tab)),
      (route) => false,
    );
  }

  /// Smooth push (Fade + mini Slide up)
  static Future<T?> push<T>(BuildContext context, Widget screen) {
    return Navigator.of(context).push<T>(_smoothRoute(screen));
  }

  /// Smooth pushReplacement
  static Future<T?> replace<T>(BuildContext context, Widget screen) {
    return Navigator.of(context).pushReplacement<T, dynamic>(_smoothRoute(screen));
  }

  static PageRouteBuilder<T> _smoothRoute<T>(Widget screen) {
    return PageRouteBuilder<T>(
      transitionDuration: AppDurations.normal,
      reverseTransitionDuration: AppDurations.fast,
      pageBuilder: (_, __, ___) => screen,
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: AppCurves.enter),
          child: child,
        );
      },
    );
  }
}
