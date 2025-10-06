import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

/// Ergebnis einer Geocoding-Anfrage
class GeocodedLocation {
  final double latitude;
  final double longitude;
  /// ISO-2 lowercase (z. B. "at")
  final String? countryCode;
  final String? displayName;

  GeocodedLocation({
    required this.latitude,
    required this.longitude,
    this.countryCode,
    this.displayName,
  });
}

class GeocodingService {
  static const _ua = 'PartyApp/1.0 (support@example.com)';

  /// Haupt-Entry: beste Location nahe einer Bias-Position (falls vorhanden).
  /// - Versucht zuerst mit Umlauten.
  /// - Fallback: ersetzt Umlaute (ä->ae, ö->oe, ü->ue, ß->ss).
  static Future<GeocodedLocation?> getBestLocationNear(
      String address, {
        String? countryCode,
        double? biasLat,
        double? biasLng,
      }) async {
    final lang = _languageForCountry(countryCode);
    final q = _normalize(address);

    // 1) Primärversuch (mit Umlauten)
    var list = await _searchRaw(q, countryCode: countryCode, limit: 8, language: lang);

    // 2) Fallback ohne Umlaute, wenn leer
    if (list.isEmpty) {
      final asciiQ = _deUmlaut(q);
      if (asciiQ != q) {
        list = await _searchRaw(asciiQ, countryCode: countryCode, limit: 8, language: lang);
      }
    }

    if (list.isEmpty) return null;

    // Nächstgelegenen Treffer anhand Bias wählen
    if (biasLat != null && biasLng != null) {
      list.sort((a, b) {
        final da = _distKm(biasLat, biasLng, a.latitude, a.longitude);
        final db = _distKm(biasLat, biasLng, b.latitude, b.longitude);
        return da.compareTo(db);
      });
    }

    return list.first;
  }

  /// Convenience: eine beste Location (ohne Bias).
  /// - Versucht zuerst mit Umlauten, dann Fallback ohne Umlaute.
  static Future<GeocodedLocation?> getLocationFromAddress(
      String address, {
        String? countryCode,
      }) async {
    final lang = _languageForCountry(countryCode);
    final q = _normalize(address);

    // 1) Primärversuch
    var list = await _searchRaw(q, countryCode: countryCode, limit: 1, language: lang);

    // 2) Fallback
    if (list.isEmpty) {
      final asciiQ = _deUmlaut(q);
      if (asciiQ != q) {
        list = await _searchRaw(asciiQ, countryCode: countryCode, limit: 1, language: lang);
      }
    }

    return list.isEmpty ? null : list.first;
  }

  // ---------------- intern ----------------

  /// Nominatim-Suche.
  /// - `countryCode` filtert hart auf Land (ISO2, lowercase)
  /// - `language` steuert accept-language (z. B. "de")
  static Future<List<GeocodedLocation>> _searchRaw(
      String query, {
        String? countryCode,
        int limit = 5,
        String language = 'de',
      }) async {
    final params = <String, String>{
      'format': 'jsonv2',          // jsonv2 ist robuster
      'limit': '$limit',
      'addressdetails': '1',
      'accept-language': language, // Ergebnis-Lokalisierung
      'q': query,                  // Uri.https encodiert korrekt (inkl. Umlaute)
    };
    final cc = (countryCode ?? '').trim().toLowerCase();
    if (cc.isNotEmpty) params['countrycodes'] = cc;

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final res = await http.get(uri, headers: {'User-Agent': _ua});

    if (res.statusCode != 200) return const [];

    final List data = jsonDecode(res.body) as List;
    return data.map((e) {
      final m = e as Map<String, dynamic>;
      final lat = double.tryParse(m['lat']?.toString() ?? '');
      final lon = double.tryParse(m['lon']?.toString() ?? '');
      if (lat == null || lon == null) return null;

      final addr = (m['address'] ?? {}) as Map<String, dynamic>;
      final hitCc = (addr['country_code']?.toString() ?? '').toLowerCase();

      return GeocodedLocation(
        latitude: lat,
        longitude: lon,
        countryCode: hitCc.isEmpty ? null : hitCc,
        displayName: m['display_name']?.toString(),
      );
    }).whereType<GeocodedLocation>().toList();
  }

  /// Haversine-Distanz in km
  static double _distKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _deg2rad(double d) => d * pi / 180.0;

  /// Whitespace normalisieren
  static String _normalize(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Minimaler DE/AT/CH-Fallback (ä→ae, ö→oe, ü→ue, ß→ss)
  static String _deUmlaut(String s) => s
      .replaceAll('Ä', 'Ae').replaceAll('ä', 'ae')
      .replaceAll('Ö', 'Oe').replaceAll('ö', 'oe')
      .replaceAll('Ü', 'Ue').replaceAll('ü', 'ue')
      .replaceAll('ẞ', 'SS').replaceAll('ß', 'ss');

  /// Einfache Sprachauswahl (gut genug für DACH/CZ/SK/HU/IT)
  static String _languageForCountry(String? cc) {
    switch ((cc ?? '').toLowerCase()) {
      case 'de':
      case 'at':
      case 'ch':
        return 'de';
      case 'it':
        return 'it';
      case 'cz':
        return 'cs';
      case 'sk':
        return 'sk';
      case 'hu':
        return 'hu';
      default:
        return 'de';
    }
  }
}
