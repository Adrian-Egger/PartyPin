// lib/Services/geocoding_services.dart
import 'dart:math';
import 'package:geocoding/geocoding.dart' as geo;

/// Ergebnis einer Geocoding-Anfrage
class GeocodedLocation {
  final double latitude;
  final double longitude;

  /// ISO-2 lowercase (z. B. "at") – hier meist null, da das Plugin das nicht liefert
  final String? countryCode;
  final String? displayName;

  GeocodedLocation({
    required this.latitude,
    required this.longitude,
    this.countryCode,
    this.displayName,
  });

  @override
  String toString() =>
      'GeocodedLocation(lat=$latitude, lon=$longitude, countryCode=$countryCode, displayName=$displayName)';
}

class GeocodingService {
  /// Beste Location nahe einer Bias-Position (falls vorhanden).
  /// Nutzt das Flutter-Plugin `geocoding` – KEIN Google-API-Key nötig.
  static Future<GeocodedLocation?> getBestLocationNear(
      String address, {
        String? countryCode, // wird hier ignoriert, ist aber für API kompatibel
        double? biasLat,
        double? biasLng,
      }) async {
    final q = _normalize(address);
    final List<geo.Location> all = [];

    try {
      // 1. Direkt mit Umlauten probieren
      final locs = await geo.locationFromAddress(q);
      all.addAll(locs);
    } catch (_) {}

    if (all.isEmpty) {
      // 2. Fallback: ohne Umlaute
      final asciiQ = _deUmlaut(q);
      if (asciiQ != q) {
        try {
          final locs = await geo.locationFromAddress(asciiQ);
          all.addAll(locs);
        } catch (_) {}
      }
    }

    if (all.isEmpty) return null;

    if (biasLat != null && biasLng != null) {
      all.sort((a, b) {
        final da = _distKm(biasLat, biasLng, a.latitude, a.longitude);
        final db = _distKm(biasLat, biasLng, b.latitude, b.longitude);
        return da.compareTo(db);
      });
    }

    final best = all.first;
    return GeocodedLocation(
      latitude: best.latitude,
      longitude: best.longitude,
      countryCode: null,
      displayName: q,
    );
  }

  /// Einfachste Variante: erste gefundene Location zurückgeben.
  static Future<GeocodedLocation?> getLocationFromAddress(
      String address, {
        String? countryCode, // wird ignoriert, API-kompatibel gelassen
      }) async {
    final q = _normalize(address);

    try {
      final locs = await geo.locationFromAddress(q);
      if (locs.isNotEmpty) {
        final l = locs.first;
        return GeocodedLocation(
          latitude: l.latitude,
          longitude: l.longitude,
          countryCode: null,
          displayName: q,
        );
      }
    } catch (_) {}

    // Fallback: ohne Umlaute versuchen
    final asciiQ = _deUmlaut(q);
    if (asciiQ != q) {
      try {
        final locs = await geo.locationFromAddress(asciiQ);
        if (locs.isNotEmpty) {
          final l = locs.first;
          return GeocodedLocation(
            latitude: l.latitude,
            longitude: l.longitude,
            countryCode: null,
            displayName: asciiQ,
          );
        }
      } catch (_) {}
    }

    return null;
  }

  // ---------- intern ----------

  /// Haversine-Distanz in km
  static double _distKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _deg2rad(double d) => d * pi / 180.0;

  static String _normalize(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _deUmlaut(String s) => s
      .replaceAll('Ä', 'Ae')
      .replaceAll('ä', 'ae')
      .replaceAll('Ö', 'Oe')
      .replaceAll('ö', 'oe')
      .replaceAll('Ü', 'Ue')
      .replaceAll('ü', 'ue')
      .replaceAll('ẞ', 'SS')
      .replaceAll('ß', 'ss');
}
