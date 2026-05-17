// lib/Services/deep_link_handler.dart
//
// Zentraler Handler für `partypin://`-Deep-Links.
//
// FEATURE_DISABLED_TICKETING — der frühere Stripe-Onboarding-Return-
// Branch (Hosts `stripe-return` / `stripe-refresh`) ist mit dem
// Ticketing-Removal entfernt worden. Siehe archived/ticketing/README.md.
//
// Die Datei bleibt bestehen, weil PartyPin in Zukunft weitere Deep-Links
// braucht — z. B. Party-Share, Invite-Links, Discovery-Links, QR-Join.
// Neue Hosts werden in `_handle()` als weitere case-Zweige ergänzt.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Globaler ScaffoldMessenger-Key, damit wir Snackbars von außerhalb
/// des Widget-Trees zeigen können (Deep-Link triggert ja keinen build).
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class DeepLinkHandler {
  static final AppLinks _appLinks = AppLinks();
  static StreamSubscription<Uri>? _sub;
  static bool _started = false;

  /// In main() nach App-Setup aufrufen. Idempotent.
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

    // Aktuell keine Hosts implementiert. Künftig hier z. B.:
    //   case 'party':         → öffne PartyDetail für uri.pathSegments
    //   case 'invite':        → Friend-Request-Flow
    //   case 'discovery':     → Map-Region-Deep-Link
    //   case 'join':          → QR-Join für Closed-Party
    switch (uri.host) {
      default:
        // Unbekannten Host nicht crashen, nur loggen.
        debugPrint('DeepLink: unbekannter Host "${uri.host}" — ignoriert.');
        break;
    }
  }
}
