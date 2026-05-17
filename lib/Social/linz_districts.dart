// lib/Social/linz_districts.dart
//
// City Mood Layer — grobe District-Lookup-Table für Linz.
//
// Bewusst hardcoded (kein Backend-Lookup, kein OSM-Reverse-Geocoding):
//   - keine zusätzlichen Reads
//   - keine Netzwerk-Latency
//   - keine externe Dependency
//
// Trade-off: Außerhalb von Linz greift `districtFor()` ins Leere und
// liefert null — Mood-Strip zeigt dann keine District-Pille, sondern
// nur die Aktivitäts-Aussagen. Akzeptabel weil PartyPin Linz-First ist.
//
// Bei Bedarf später ergänzbar:
//   - mehr Linz-Bereiche
//   - Wien-Bezirke
//   - generischer Cluster-Algorithmus für unbekannte Städte
//
// Distanzberechnung via Haversine. ~6 Lookups pro Party = vernachlässigbar.

import 'dart:math';

class CityDistrict {
  const CityDistrict({
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
  });

  final String name;
  final double lat;
  final double lng;

  /// Grober Wirkungs-Radius. Über-/Unterlappung mit Nachbar-Districts
  /// ist akzeptabel — wir nehmen das nächstgelegene.
  final double radiusMeters;
}

/// Grobe Linz-Districts. Koordinaten ungefähr — können verfeinert
/// werden. Wirkt sich nur auf die Mood-Pille aus ("Altstadt aktiv"),
/// nicht auf Marker oder Funktionalität.
const List<CityDistrict> kLinzDistricts = [
  CityDistrict(
    name: 'Altstadt',
    lat: 48.3066,
    lng: 14.2858,
    radiusMeters: 700,
  ),
  CityDistrict(
    name: 'Innenstadt',
    lat: 48.3000,
    lng: 14.2870,
    radiusMeters: 900,
  ),
  CityDistrict(
    name: 'Urfahr',
    lat: 48.3175,
    lng: 14.2845,
    radiusMeters: 1500,
  ),
  CityDistrict(
    name: 'Neue Welt',
    lat: 48.2870,
    lng: 14.3010,
    radiusMeters: 1200,
  ),
  CityDistrict(
    name: 'Stadthafen',
    lat: 48.2945,
    lng: 14.3160,
    radiusMeters: 1400,
  ),
  CityDistrict(
    name: 'Froschberg',
    lat: 48.2920,
    lng: 14.2700,
    radiusMeters: 1100,
  ),
];

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLng = (lng2 - lng1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// Liefert den nächstgelegenen District innerhalb seines Radius —
/// oder null wenn keine Übereinstimmung (z.B. Party außerhalb Linz
/// oder zwischen den Districts).
String? districtFor({
  required double lat,
  required double lng,
  List<CityDistrict> table = kLinzDistricts,
}) {
  String? best;
  double bestDist = double.infinity;
  for (final d in table) {
    final dist = _haversineMeters(lat, lng, d.lat, d.lng);
    if (dist <= d.radiusMeters && dist < bestDist) {
      best = d.name;
      bestDist = dist;
    }
  }
  return best;
}
