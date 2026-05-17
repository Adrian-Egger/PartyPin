// lib/Social/host_level.dart
//
// Host Reputation & Creator System — Level-Enum + Display-Metadaten.
// Single source of truth für Farben, Icons, Labels.
// Backend-Schwellen liegen parallel in functions/hostStats/recompute.js.

import 'package:flutter/material.dart';

enum HostLevel {
  rookie,
  local,
  rising,
  nightlife,
  elite,
}

extension HostLevelX on HostLevel {
  /// Backend-String (`rookie`, `local`, ...).
  String get id => name;

  /// Numerischer Rank — für ≤/≥ Vergleiche.
  int get rank {
    switch (this) {
      case HostLevel.rookie:    return 0;
      case HostLevel.local:     return 1;
      case HostLevel.rising:    return 2;
      case HostLevel.nightlife: return 3;
      case HostLevel.elite:     return 4;
    }
  }

  /// Anzeigename. „New Host" wirkt einladend; Rookie ist intern.
  String get label {
    switch (this) {
      case HostLevel.rookie:    return 'New Host';
      case HostLevel.local:     return 'Local Host';
      case HostLevel.rising:    return 'Rising Host';
      case HostLevel.nightlife: return 'Nightlife Host';
      case HostLevel.elite:     return 'Elite Host';
    }
  }

  /// Kurzform für enge UI (Map-Marker, Cards).
  String get shortLabel {
    switch (this) {
      case HostLevel.rookie:    return 'New';
      case HostLevel.local:     return 'Local';
      case HostLevel.rising:    return 'Rising';
      case HostLevel.nightlife: return 'Nightlife';
      case HostLevel.elite:     return 'Elite';
    }
  }

  /// Tagline für Profil-Banner.
  String get tagline {
    switch (this) {
      case HostLevel.rookie:    return 'Frisch dabei.';
      case HostLevel.local:     return 'Bekannt in der Szene.';
      case HostLevel.rising:    return 'Geht steil. 🚀';
      case HostLevel.nightlife: return 'Hosting Pro.';
      case HostLevel.elite:     return 'Legende.';
    }
  }

  /// Primärfarbe für Badge / Pill / Glow. Bewusst kein corporate Grau —
  /// jeder Level hat einen unverwechselbaren Akzent.
  Color get color {
    switch (this) {
      case HostLevel.rookie:    return const Color(0xFF8A8F99); // graue Neutral
      case HostLevel.local:     return const Color(0xFF22C55E); // green
      case HostLevel.rising:    return const Color(0xFF38BDF8); // sky
      case HostLevel.nightlife: return const Color(0xFFA855F7); // purple
      case HostLevel.elite:     return const Color(0xFFFBBF24); // gold
    }
  }

  /// Sekundärfarbe für Gradient (Badge-Hintergrund, Profile-Banner).
  Color get colorAccent {
    switch (this) {
      case HostLevel.rookie:    return const Color(0xFFB0B5BD);
      case HostLevel.local:     return const Color(0xFF15803D);
      case HostLevel.rising:    return const Color(0xFF7C3AED);
      case HostLevel.nightlife: return const Color(0xFFEC4899);
      case HostLevel.elite:     return const Color(0xFFFB923C);
    }
  }

  /// Icon. Eskaliert von neutralem Stern bis Krone.
  IconData get icon {
    switch (this) {
      case HostLevel.rookie:    return Icons.star_outline_rounded;
      case HostLevel.local:     return Icons.local_fire_department_rounded;
      case HostLevel.rising:    return Icons.trending_up_rounded;
      case HostLevel.nightlife: return Icons.nightlife_rounded;
      case HostLevel.elite:     return Icons.workspace_premium_rounded;
    }
  }

  /// Emoji-Variante für Push-Notifications / Push-Texte.
  String get emoji {
    switch (this) {
      case HostLevel.rookie:    return '⭐';
      case HostLevel.local:     return '🔥';
      case HostLevel.rising:    return '🚀';
      case HostLevel.nightlife: return '🌃';
      case HostLevel.elite:     return '👑';
    }
  }

  /// Nächster Level — Elite kennt keinen.
  HostLevel? get next {
    switch (this) {
      case HostLevel.rookie:    return HostLevel.local;
      case HostLevel.local:     return HostLevel.rising;
      case HostLevel.rising:    return HostLevel.nightlife;
      case HostLevel.nightlife: return HostLevel.elite;
      case HostLevel.elite:     return null;
    }
  }
}

/// Backend-Threshold-Tabelle. Muss in Sync bleiben mit
/// functions/hostStats/recompute.js → LEVELS.
///
/// Kalibrierung für Linz / lokale Jugend-Nightlife-App (Early-Stage):
///   - Local schon ab 1 erfolgreichem Event (≥3 Gäste) + 30 Score.
///     Sichtbarer Erfolg nach erster richtiger Party.
///   - Rising bei 5 Events / 150 Score / 50% positive — engagierter
///     monatlicher Host.
///   - Nightlife bei 12 Events / 500 Score / 60% positive — fester Teil
///     der Szene.
///   - Elite bei 30 Events / 1500 Score / 70% positive — top der Stadt.
///
/// Quality-Gate: ratingPositiveRate ab Rising verhindert Score-grinding
/// durch reines Volume.
class HostLevelThreshold {
  const HostLevelThreshold({
    required this.level,
    required this.minEvents,
    required this.minScore,
    required this.minPositiveRate,
  });

  final HostLevel level;
  final int minEvents;
  final int minScore;
  final double minPositiveRate;
}

const List<HostLevelThreshold> kHostLevelThresholds = [
  HostLevelThreshold(level: HostLevel.rookie,    minEvents: 0,  minScore: 0,    minPositiveRate: 0.0),
  HostLevelThreshold(level: HostLevel.local,     minEvents: 1,  minScore: 30,   minPositiveRate: 0.0),
  HostLevelThreshold(level: HostLevel.rising,    minEvents: 5,  minScore: 150,  minPositiveRate: 0.5),
  HostLevelThreshold(level: HostLevel.nightlife, minEvents: 12, minScore: 500,  minPositiveRate: 0.6),
  HostLevelThreshold(level: HostLevel.elite,     minEvents: 30, minScore: 1500, minPositiveRate: 0.7),
];

HostLevelThreshold thresholdOf(HostLevel level) =>
    kHostLevelThresholds.firstWhere((t) => t.level == level);

/// Parst einen Backend-String. Unbekannt → rookie (sicherer Default).
HostLevel parseHostLevel(Object? raw) {
  final s = (raw ?? '').toString().trim().toLowerCase();
  for (final l in HostLevel.values) {
    if (l.id == s) return l;
  }
  return HostLevel.rookie;
}
