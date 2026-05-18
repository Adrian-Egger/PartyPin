// lib/Services/geocoding_services.dart
//
// Reines HTTP-Geocoding ueber die Google Geocoding API. Das frueher genutzte
// Flutter-Plugin `geocoding` wurde entfernt, weil `geocoding_ios-3.1.0` beim
// iOS-Archive in xcode_backend.dart -> Context.embedFlutterFrameworks crasht.
//
// Funktioniert plattformuebergreifend (iOS/Android/Web) ohne native
// Abhaengigkeiten.

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Forward-Geocoding-Resultat (Adresse -> Koordinaten).
class GeocodedLocation {
  final double latitude;
  final double longitude;

  /// ISO-2 lowercase (z. B. "at"), aus address_components extrahiert.
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

/// Reverse-Geocoding-Resultat (Koordinaten -> Adresskomponenten).
/// Feldnamen sind absichtlich kompatibel zum frueheren `geocoding.Placemark`,
/// damit aufrufende Screens unveraendert bleiben.
class GeocodedPlacemark {
  final String? street;             // route
  final String? subThoroughfare;    // street_number
  final String? locality;           // locality / postal_town
  final String? subAdministrativeArea; // administrative_area_level_2
  final String? postalCode;         // postal_code
  final String? country;            // country (long_name)
  final String? isoCountryCode;     // country (short_name, lowercase)

  GeocodedPlacemark({
    this.street,
    this.subThoroughfare,
    this.locality,
    this.subAdministrativeArea,
    this.postalCode,
    this.country,
    this.isoCountryCode,
  });
}

class GeocodingService {
  // Google Maps API Key. Wird auch von der Android-App in AndroidManifest.xml
  // verwendet. Fuer iOS HTTP-Requests muss der Key in der Google Cloud Console
  // fuer die Geocoding API freigeschaltet sein (und ggf. mit Bundle-ID /
  // SHA-1 Restriction belegt werden).
  static const String _apiKey = 'AIzaSyD87LYkHyCjLJbh5dH3Mc6yeiXF9zH_ly8';
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/geocode/json';

  // ---------------------------------------------------------------------------
  // Forward Geocoding
  // ---------------------------------------------------------------------------

  /// Erste plausible Location fuer eine Adresse, mit Umlaut-Fallback.
  static Future<GeocodedLocation?> getLocationFromAddress(
    String address, {
    String? countryCode,
  }) async {
    final q = _normalize(address);

    var results = await _fetchResults(q, countryCode: countryCode);
    if (results.isEmpty) {
      final asciiQ = _deUmlaut(q);
      if (asciiQ != q) {
        results = await _fetchResults(asciiQ, countryCode: countryCode);
      }
    }
    if (results.isEmpty) return null;
    return _toLocation(results.first, q);
  }

  /// Beste Location nahe einer Bias-Position. Identische API zur alten
  /// Service-Klasse, damit Aufrufer nicht angefasst werden muessen.
  static Future<GeocodedLocation?> getBestLocationNear(
    String address, {
    String? countryCode,
    double? biasLat,
    double? biasLng,
  }) async {
    final q = _normalize(address);

    var results = await _fetchResults(q, countryCode: countryCode);
    if (results.isEmpty) {
      final asciiQ = _deUmlaut(q);
      if (asciiQ != q) {
        results = await _fetchResults(asciiQ, countryCode: countryCode);
      }
    }
    if (results.isEmpty) return null;

    if (biasLat != null && biasLng != null) {
      results.sort((a, b) {
        final la = _lat(a);
        final lo = _lng(a);
        final lb = _lat(b);
        final lob = _lng(b);
        final da = _distKm(biasLat, biasLng, la, lo);
        final db = _distKm(biasLat, biasLng, lb, lob);
        return da.compareTo(db);
      });
    }

    return _toLocation(results.first, q);
  }

  // ---------------------------------------------------------------------------
  // Reverse Geocoding (ersetzt geocoding.placemarkFromCoordinates)
  // ---------------------------------------------------------------------------

  static Future<List<GeocodedPlacemark>> placemarkFromCoordinates(
    double latitude,
    double longitude,
  ) async {
    try {
      final url = Uri.parse(
        '$_baseUrl?latlng=$latitude,$longitude&key=$_apiKey',
      );
      final response = await http.get(url);
      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return const [];

      final results = (data['results'] as List?) ?? const [];
      return results
          .map<GeocodedPlacemark>(
              (r) => _toPlacemark(r as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP / Parsing
  // ---------------------------------------------------------------------------

  static Future<List<Map<String, dynamic>>> _fetchResults(
    String address, {
    String? countryCode,
  }) async {
    try {
      var urlStr =
          '$_baseUrl?address=${Uri.encodeComponent(address)}&key=$_apiKey';
      if (countryCode != null && countryCode.trim().isNotEmpty) {
        urlStr +=
            '&components=country:${Uri.encodeComponent(countryCode.trim())}';
      }

      final response = await http.get(Uri.parse(urlStr));
      if (response.statusCode != 200) return const [];

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return const [];

      final raw = (data['results'] as List?) ?? const [];
      return raw.cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }

  static GeocodedLocation _toLocation(
      Map<String, dynamic> result, String displayName) {
    return GeocodedLocation(
      latitude: _lat(result),
      longitude: _lng(result),
      countryCode: _extractCountryCode(result),
      displayName: displayName,
    );
  }

  static double _lat(Map<String, dynamic> r) =>
      ((r['geometry'] as Map)['location']['lat'] as num).toDouble();

  static double _lng(Map<String, dynamic> r) =>
      ((r['geometry'] as Map)['location']['lng'] as num).toDouble();

  static String? _extractCountryCode(Map<String, dynamic> result) {
    final comps = (result['address_components'] as List?) ?? const [];
    for (final c in comps) {
      final types = ((c as Map)['types'] as List?) ?? const [];
      if (types.contains('country')) {
        final short = c['short_name'] as String?;
        return short?.toLowerCase();
      }
    }
    return null;
  }

  static GeocodedPlacemark _toPlacemark(Map<String, dynamic> result) {
    String? street;
    String? streetNumber;
    String? locality;
    String? subAdministrativeArea;
    String? postalCode;
    String? country;
    String? isoCountry;

    final comps = (result['address_components'] as List?) ?? const [];
    for (final c in comps) {
      final m = c as Map;
      final types = ((m['types'] as List?) ?? const []).cast<String>();
      final longName = m['long_name'] as String?;
      final shortName = m['short_name'] as String?;

      if (types.contains('route')) {
        street = longName;
      } else if (types.contains('street_number')) {
        streetNumber = longName;
      } else if (types.contains('locality')) {
        locality = longName;
      } else if (types.contains('postal_town') && locality == null) {
        locality = longName;
      } else if (types.contains('administrative_area_level_2')) {
        subAdministrativeArea = longName;
      } else if (types.contains('postal_code')) {
        postalCode = longName;
      } else if (types.contains('country')) {
        country = longName;
        isoCountry = shortName?.toLowerCase();
      }
    }

    return GeocodedPlacemark(
      street: street,
      subThoroughfare: streetNumber,
      locality: locality,
      subAdministrativeArea: subAdministrativeArea,
      postalCode: postalCode,
      country: country,
      isoCountryCode: isoCountry,
    );
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  static double _distKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_deg2rad(lat1)) *
            cos(_deg2rad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
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
