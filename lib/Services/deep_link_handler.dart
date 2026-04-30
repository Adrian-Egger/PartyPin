// lib/Services/deep_link_handler.dart
// Verarbeitet partypin:// Deep-Links — derzeit für Stripe-Onboarding-Returns.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'stripe_service.dart';

/// Globaler ScaffoldMessenger-Key, damit wir Snackbars von außerhalb
/// des Widget-Trees zeigen können (Deep-Link triggert ja keinen build).
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class DeepLinkHandler {
  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;
  static bool _started = false;

  /// In main() nach Stripe-Init aufrufen. Idempotent.
  static Future<void> start() async {
    if (_started) return;
    _started = true;

    // 1) Initial-Link (App war geschlossen, durch Link gestartet)
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handle(initial);
    } catch (e) {
      debugPrint('DeepLink getInitialLink failed: $e');
    }

    // 2) Live-Stream (App lief im Hintergrund)
    _sub = _appLinks.uriLinkStream.listen(
      _handle,
      onError: (e) => debugPrint('DeepLink stream error: $e'),
    );
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }

  static Future<void> _handle(Uri uri) async {
    debugPrint('DeepLink received: $uri');

    if (uri.scheme != 'partypin') return;

    switch (uri.host) {
      case 'stripe-return':
        await _onStripeReturn();
        break;
      case 'stripe-refresh':
        _showSnack(
          'Bitte tippe erneut auf „Onboarding fortsetzen".',
          color: Colors.orange,
        );
        break;
      default:
        // andere Hosts ignorieren
        break;
    }
  }

  static Future<void> _onStripeReturn() async {
    _showSnack('Stripe-Status wird geprüft…');
    try {
      final res = await StripeService.refreshHostStatus();
      final status = res['status']?.toString() ?? 'unknown';
      final chargesEnabled = res['chargesEnabled'] == true;

      _showSnack(
        chargesEnabled
            ? 'Stripe verbunden — du kannst jetzt Tickets verkaufen ✅'
            : status == 'pending_review'
                ? 'Stripe prüft deine Daten — das kann ein paar Minuten dauern.'
                : 'Onboarding noch nicht abgeschlossen.',
        color: chargesEnabled ? Colors.green : Colors.orange,
      );
    } catch (e) {
      _showSnack('Status-Update fehlgeschlagen: $e', color: Colors.red);
    }
  }

  static void _showSnack(String msg, {Color? color}) {
    final messenger = rootMessengerKey.currentState;
    if (messenger == null) return;
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }
}
