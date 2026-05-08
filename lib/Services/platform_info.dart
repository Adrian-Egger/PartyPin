// lib/Services/platform_info.dart
//
// Eine Wahrheitsquelle für die Plattform-Detection.
// Schreibwerte werden ins User-Doc als users/{uid}.platform abgelegt
// (Form: "Android", "iOS", "Web", "Other") — kein Mix aus Casing,
// damit der Admin-Detail-Screen ohne Fallback-Acrobatics anzeigen
// kann. Nutzt kIsWeb VOR Platform.is..., weil Platform.* unter Web
// throwen würde.

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class PlatformInfo {
  /// Liefert "Android" / "iOS" / "Web" / "Other".
  /// Niemals null, niemals leer.
  static String detectName() {
    if (kIsWeb) return 'Web';
    try {
      if (Platform.isAndroid) return 'Android';
      if (Platform.isIOS) return 'iOS';
    } catch (_) {
      // Falls Platform.* in einem Test- oder Web-Kontext läuft,
      // wo die Klasse nicht verfügbar ist — bewusst stillschweigend.
    }
    return 'Other';
  }

  /// Normalisiert einen schon gespeicherten Plattform-String.
  /// Akzeptiert legacy-Schreibweisen wie "android" / "ANDROID" / "ios"
  /// und mappt sie auf das kanonische Format.
  static String normalize(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString().trim().toLowerCase();
    if (s.isEmpty) return '';
    switch (s) {
      case 'android':
        return 'Android';
      case 'ios':
      case 'iphone os':
      case 'iphoneos':
        return 'iOS';
      case 'web':
      case 'browser':
        return 'Web';
      default:
        // Unbekanntes Format: original mit Capitalize-First zurückgeben,
        // damit Admin-Detail wenigstens nicht mit Müll umgeht.
        final orig = raw.toString().trim();
        if (orig.isEmpty) return '';
        return orig[0].toUpperCase() + orig.substring(1);
    }
  }
}
