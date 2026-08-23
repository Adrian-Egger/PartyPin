// lib/Screens/party_map_screen.dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../home/menu_screen.dart';
import '../profile/profil_settings_screen.dart';
import '../profile/user_profile_screen.dart';
import '../../Services/geocoding_services.dart';
import '../../Social/city_mood.dart';
import '../../Social/city_mood_strip.dart';
import '../../Social/friends_model.dart';
import '../../Social/map_social_layer.dart';
import '../../Social/trending_hosts_strip.dart';
import '../bar/bar_bottom_sheet.dart';
import '../festl/festl_bottom_sheet.dart';
import '../../Theme/app_theme.dart';
import '../../Services/timestamp_ext.dart';
import 'party_bottom_sheet.dart';

/// TIME_RANGE_FILTER: Zeitraum-Auswahl für Karte und Marker.
///
/// `windowFor()` liefert das Fenster [von, bis]; ein Event zählt als
/// sichtbar, wenn es das Fenster überlappt (Start vor `bis`, Ende nach
/// `von`) — nicht nur, wenn es exakt darin startet. Sonst würde ein
/// mehrtägiges Festl, das gestern begonnen hat, bei "Heute" fehlen.
enum TimeRangeFilter {
  today('range_today', 'Heute'),
  thisWeekend('range_weekend', 'Dieses Wochenende'),
  next14Days('range_14d', 'Nächste 14 Tage'),
  next2Months('range_2m', 'Nächste 2 Monate'),
  all('range_all', 'Alle');

  const TimeRangeFilter(this.prefValue, this.label);

  /// Stabiler Wert für SharedPreferences — NICHT `name` verwenden,
  /// sonst bricht die Persistenz beim Umbenennen einer Konstante.
  final String prefValue;
  final String label;

  static TimeRangeFilter fromPref(String? v) {
    for (final r in TimeRangeFilter.values) {
      if (r.prefValue == v) return r;
    }
    return TimeRangeFilter.next14Days;
  }

  /// Zeitfenster ab [now]. `end == null` bedeutet "keine Obergrenze".
  ({DateTime start, DateTime? end}) windowFor(DateTime now) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    switch (this) {
      case TimeRangeFilter.today:
        return (start: startOfToday, end: startOfToday.add(const Duration(days: 1)));
      case TimeRangeFilter.thisWeekend:
        // Samstag 00:00 bis Montag 00:00. Ist heute schon Sa/So, gilt
        // das laufende Wochenende, sonst das nächste.
        final daysUntilSat = (DateTime.saturday - now.weekday + 7) % 7;
        final satStart = now.weekday == DateTime.sunday
            ? startOfToday.subtract(const Duration(days: 1))
            : startOfToday.add(Duration(days: daysUntilSat));
        return (start: satStart, end: satStart.add(const Duration(days: 2)));
      case TimeRangeFilter.next14Days:
        return (start: startOfToday, end: startOfToday.add(const Duration(days: 14)));
      case TimeRangeFilter.next2Months:
        return (start: startOfToday, end: startOfToday.add(const Duration(days: 60)));
      case TimeRangeFilter.all:
        return (start: startOfToday, end: null);
    }
  }
}

class PartyMapScreen extends StatefulWidget {
  final String? initialOpenPartyId;

  // ✅ Gleiches Prinzip wie initialOpenPartyId, aber für Festln (z. B. aus
  // all_events_list_screen.dart).

  const PartyMapScreen({
    super.key,
    this.initialOpenPartyId,
  });

  @override
  State<PartyMapScreen> createState() => _PartyMapScreenState();
}

class _PartyMapScreenState extends State<PartyMapScreen>
    with SingleTickerProviderStateMixin {
  // Farbschema
  static const _panel = AppColors.panel;
  static const _accent = AppColors.accent;

  // ✅ öffentliche POIs ausblenden
  static const String _mapStyleHidePublicPois = r'''
  [
    { "featureType": "poi", "stylers": [ { "visibility": "off" } ] },
    { "featureType": "poi.park", "stylers": [ { "visibility": "off" } ] },
    { "featureType": "transit", "stylers": [ { "visibility": "off" } ] },
    { "featureType": "road", "elementType": "labels.icon", "stylers": [ { "visibility": "off" } ] }
  ]
  ''';

  // ✅ Marker-Größen
  static const int _lockBaseDiameter = 92;
  static const int _friendsBaseDiameter = 92;
  static const int _hitBaseDiameter = 180;
  static const int _barBaseDiameter = 92;

  // 🎡 Festl-Marker (etwas größer → Highlight, bewusst distinct von Party/Bar)
  static const int _festlBaseDiameter = 104;
  static const Color _festlColor = Color(0xFF8E24AA);
  // Festln bleiben nach Ende noch etwas sichtbar, dann fallen sie raus.
  static const int _festlHoursAfterEnd = 12;

  // ✅ Event-Zeitraum (Bars)
  static const int _barEventDaysBefore = 7;
  static const int _barEventHoursAfter = 24;

  GoogleMapController? mapController;
  CameraPosition? _startPos;

  final Set<Marker> _markers = {};

  // PERF (Fix #2): O(1)-Index über markerId, parallel zum Set. `_markers` und
  // `_markerById` werden AUSSCHLIESSLICH über _putMarker/_clearMarkers mutiert
  // → sie können nie inkonsistent werden. Ersetzt die früheren O(N)-Scans
  // (`_markers.where` / `removeWhere`), die im Status-Enrichment zu O(N²)
  // wurden. Die einzige Stelle mit direkter Set-Mutation ist
  // _rebuildMarkersWithNewIcons, wo BEIDE atomar aus derselben Quelle
  // (newMarkers) neu befüllt werden.
  final Map<String, Marker> _markerById = {};

  /// Fügt einen Marker ein oder ersetzt den mit gleicher id — O(1).
  /// `_markerById[id]` hält stets exakt dieselbe Objekt-Referenz wie im Set,
  /// daher ist `_markers.remove(old)` ein O(1)-Hash-Lookup.
  void _putMarker(Marker m) {
    final id = m.markerId.value;
    final old = _markerById[id];
    if (old != null) _markers.remove(old);
    _markers.add(m);
    _markerById[id] = m;
  }

  /// Marker per id nachschlagen — O(1). null wenn nicht vorhanden.
  Marker? _getMarker(String id) => _markerById[id];

  /// Leert Set und Index gemeinsam.
  void _clearMarkers() {
    _markers.clear();
    _markerById.clear();
  }
  final Set<Circle> _circles = {};
  final Map<String, Map<String, dynamic>> _partyCache = {};

  // Bar-Marker-Icons cachen
  final Map<String, BitmapDescriptor> _barIconCache = {};
  final Map<String, BitmapDescriptor> _barIconEventRingCache = {};

  // 🎡 Festl-Marker-Icon (einmal gerendert, zoom-invariant wie Bars)
  BitmapDescriptor? _festlIcon;

  String _currentCity = "";
  double _currentLat = 48.2082;
  double _currentLng = 16.3738;

  String? _currentUsername;
  String? _currentFullName;
  String? profileImageUrl;

  bool _isBarAccount = false;

  BitmapDescriptor? _lockIconGrey;
  BitmapDescriptor? _lockIconGreen;
  BitmapDescriptor? _lockIconBlue;
  BitmapDescriptor? _lockIconRed;
  BitmapDescriptor? _hitboxIcon;

  // Friends-only Icon (eigener Marker)
  BitmapDescriptor? _friendsOnlyIcon;

  // Friends-only Status Icons
  BitmapDescriptor? _friendsIconBlue;
  BitmapDescriptor? _friendsIconGreen;
  BitmapDescriptor? _friendsIconOrange;
  BitmapDescriptor? _friendsIconPurple;

  // 🎉 Party-Icons
  BitmapDescriptor? _partyIconBlue;
  BitmapDescriptor? _partyIconGreen;
  BitmapDescriptor? _partyIconOrange;
  BitmapDescriptor? _partyIconRed;

  // 👥 Social-Overlay-Icons — Live Social Map Layer.
  // Werden EINMAL gerendert (kein per-Party Bitmap), als kleine
  // Sekundär-Marker mit anchor-offset oben rechts am Haupt-Marker.
  // Zoom-invariant: keine Re-Rendering im _updateCustomMarkerSizesForZoom-Pfad.
  BitmapDescriptor? _friendDotIcon;       // 1 Freund going
  BitmapDescriptor? _friendDotDoubleIcon; // ≥2 Freunde going (Phase 3)

  final Map<String, bool> _verifiedCache = {};
  bool _ratingPromptShown = false;
  bool _isReloading = false;

  // ----- Filter-State -----
  bool _showParties = true;
  bool _showBars = true;
  bool _showFestln = true;
  int? _minAgeFilter;
  double? _maxEntryFilter;
  bool _onlyFree = false;
  double? _radiusKm = 25.0;

  // Party-Typ Filter
  bool _onlyClosedParties = false;
  bool _onlyOpenParties = false;

  // TIME_RANGE_FILTER: Die Festlliste importiert Termine bis mehrere
  // Monate voraus (ganzjährige PDF-Quelle). Ohne Zeitraum-Filter liegen
  // Termine vom November mit auf der Karte, wenn man eigentlich nur
  // wissen will, was demnächst los ist. Default bewusst nicht "alle".
  TimeRangeFilter _timeRange = TimeRangeFilter.next14Days;

  // Suche
  final TextEditingController _searchCtrl = TextEditingController();

  // FriendsModel + Cache meiner Freunde
  final FriendsModel _friendsModel = FriendsModel();
  Set<String> _myFriendsSet = {};

  // Zoom-State
  CameraPosition? _lastCameraPosition;
  bool _isUpdatingZoomIcons = false;

  // PERF: Zoom-Icons werden pro perzeptuellem Größen-"Bucket" EINMAL erzeugt
  // und gecacht. Verhindert, dass bei jedem kleinen Zoom-Schritt 13 Bitmaps
  // neu PNG-encodiert werden (teuerste Einzeloperation beim Zoomen). Buckets
  // in ~0.08-Skalenschritten (~6 diskrete Größen über den ganzen Zoombereich).
  double _iconScaleBucket = -1;
  final Map<double, Map<String, BitmapDescriptor>> _zoomIconCache = {};

  // Status-Cache für geschlossene Partys
  final Map<String, String?> _closedPartyStatus = {};

  // Status-Cache für offene Partys
  final Map<String, String?> _openPartyStatus = {};
  final Map<String, bool> _openPartyIsHost = {};

  // RENDER-FIRST: Partys die noch einen RSVP/Request-Status-Read brauchen.
  // Werden NICHT seriell im Lade-Loop aufgelöst (das waren 40-80
  // sequentielle Firestore-Round-Trips = 6-12s Main-Thread-Freeze/ANR auf
  // echten Geräten), sondern in _enrichPartyStatuses() PARALLEL nachgeladen
  // nachdem die Marker schon sichtbar sind.
  final List<({String id, bool isClosed})> _pendingStatus = [];

  // City Mood — Phase 4. Wird in _refreshMap berechnet aus dem
  // bereits geladenen _partyCache (keine extra Reads).
  CityMood _cityMood = CityMood.empty;

  // SECURITY_HARDENING / Audit-Fix H3: Re-Entry-Guard für _refreshMap.
  // Vorher konnte ein schneller Filter-Toggle zwei parallele Refreshes
  // starten — beide riefen _markers.clear() und await load() mit dem
  // Risiko dass Marker aus Lauf A nach clear() von Lauf B wieder
  // eingefügt werden → Duplikate ODER stale `_partyCache[id]!` →
  // Null-Bang-Crash. Coalescing: zweiter Aufruf wartet auf den
  // laufenden Future statt parallel zu starten.
  Future<void>? _refreshFuture;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    // CRASH-FIX: GoogleMapController hält eine native Texture + Surface.
    // Ohne dispose() bleibt sie nach dem Verlassen des Screens im Speicher
    // → auf 2-3GB-Geräten OOM/nativer Crash nach mehrfachem Öffnen.
    mapController?.dispose();
    mapController = null;
    super.dispose();
  }

  Future<void> _init() async {
    await _loadSavedLocation();
    await _loadCurrentUser();
    await _loadFilterPrefs();
    await _prepareIcons();
    await _refreshMap();

    // initialOpenPartyId öffnen
    if (widget.initialOpenPartyId != null &&
        widget.initialOpenPartyId!.trim().isNotEmpty) {
      final pid = widget.initialOpenPartyId!.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;

        Map<String, dynamic>? data = _partyCache[pid];
        if (data == null) {
          try {
            final snap = await FirebaseFirestore.instance
                .collection('Party')
                .doc(pid)
                .get();
            if (snap.exists) {
              data = snap.data();
              if (data != null) _partyCache[pid] = data!;
            }
          } catch (_) {}
        }
        if (!mounted || data == null) return;
        _openPartySheet(data!, pid);
      });
    }

    await _maybePromptForRating();
  }

  // ✅ Closed-Partys: Marker weiter weg, aber im Kreis (Kreis bleibt am echten Ort)
  LatLng _offsetWithinRadiusMeters({
    required LatLng center,
    required double minMeters,
    required double maxMeters,
    required Random rng,
  }) {
    final dist = minMeters + rng.nextDouble() * (maxMeters - minMeters);
    final ang = rng.nextDouble() * 2 * pi;

    final dLat = (dist * cos(ang)) / 111320.0;
    final dLng =
        (dist * sin(ang)) / (111320.0 * cos(center.latitude * pi / 180.0));

    return LatLng(center.latitude + dLat, center.longitude + dLng);
  }

  Future<void> _loadSavedLocation() async {
    final prefs = await SharedPreferences.getInstance();
    _currentCity = prefs.getString('city') ?? "Wien";
    _currentLat = prefs.getDouble('selectedLat') ?? 48.2082;
    _currentLng = prefs.getDouble('selectedLng') ?? 16.3738;

    if (!mounted) return;
    setState(() {
      _startPos = CameraPosition(
        target: LatLng(_currentLat, _currentLng),
        zoom: 12,
      );
    });
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();

    final uname =
    (prefs.getString('currentUsername') ??
        prefs.getString('username') ??
        '')
        .trim();

    final vorname = (prefs.getString('vorname') ?? '').trim();
    final nachname = (prefs.getString('nachname') ?? '').trim();
    final fullName = ('$vorname $nachname').trim();

    final isBar = prefs.getBool('isBarAccount') ?? false;

    // ✅ Profilbild laden
    String profileImg =
    (prefs.getString('profileImageUrl') ?? '').trim();

    // Eigenes Profil-Doc == authentifizierte UID (== Firestore-Doc-ID).
    // NIE doc(username) — der Username ist nur ein Feld, nicht die Doc-ID.
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isNotEmpty) {
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();

        final firestoreImg =
        (userDoc.data()?['profileImageUrl'] ?? '')
            .toString()
            .trim();

        if (firestoreImg.isNotEmpty) {
          profileImg = firestoreImg;

          // optional lokal cachen
          await prefs.setString(
            'profileImageUrl',
            firestoreImg,
          );
        }
      } catch (_) {}
    }
    if (!mounted) return;

    setState(() {
      _currentUsername = uname.isEmpty ? null : uname;
      _currentFullName = fullName.isEmpty ? null : fullName;
      _isBarAccount = isBar;

      // ✅ setzen
      profileImageUrl =
      profileImg.isEmpty ? null : profileImg;
    });

    if (_isBarAccount) {
      _myFriendsSet = {};
      return;
    }

    if (_currentUsername != null &&
        _currentUsername!.isNotEmpty) {
      try {
        final list =
        await _friendsModel.myFriends(_currentUsername!);

        _myFriendsSet = list.toSet();
      } catch (_) {
        _myFriendsSet = {};
      }
    }
  }


  // =========================
  // ✅ FILTER-PERSISTENZ (SharedPreferences)
  // =========================
  // Standard beim ersten Öffnen: ALLES sichtbar (Partys, Bars, Festln),
  // nichts gefiltert. Erst danach gespeicherte Werte anwenden. Fehlende
  // Keys → Default = sichtbar/kein Limit.
  static const String _kPrefShowParties = 'filter_showParties_v1';
  static const String _kPrefShowBars = 'filter_showBars_v1';
  static const String _kPrefShowFestln = 'filter_showFestln_v1';
  static const String _kPrefOnlyFree = 'filter_onlyFree_v1';
  static const String _kPrefOnlyOpen = 'filter_onlyOpen_v1';
  static const String _kPrefOnlyClosed = 'filter_onlyClosed_v1';
  static const String _kPrefMinAge = 'filter_minAge_v1';
  static const String _kPrefMaxEntry = 'filter_maxEntry_v1';
  static const String _kPrefRadius = 'filter_radiusKm_v1';
  static const String _kPrefTimeRange = 'filter_timeRange_v1';

  Future<void> _loadFilterPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _showParties = prefs.getBool(_kPrefShowParties) ?? true;
    _showBars = prefs.getBool(_kPrefShowBars) ?? true;
    _showFestln = prefs.getBool(_kPrefShowFestln) ?? true;
    _onlyFree = prefs.getBool(_kPrefOnlyFree) ?? false;
    _onlyOpenParties = prefs.getBool(_kPrefOnlyOpen) ?? false;
    _onlyClosedParties = prefs.getBool(_kPrefOnlyClosed) ?? false;
    // -1 als Sentinel für "nicht gesetzt" (kein Limit).
    final minAge = prefs.getInt(_kPrefMinAge);
    _minAgeFilter = (minAge == null || minAge < 0) ? null : minAge;
    if (prefs.containsKey(_kPrefMaxEntry)) {
      _maxEntryFilter = prefs.getDouble(_kPrefMaxEntry);
    }
    if (prefs.containsKey(_kPrefRadius)) {
      final r = prefs.getDouble(_kPrefRadius);
      _radiusKm = (r != null && r < 0) ? null : r;
    }
    // Konsistenz: bei ausgeblendeten Partys keine Party-Sub-Filter aktiv.
    if (!_showParties) {
      _onlyOpenParties = false;
      _onlyClosedParties = false;
      _onlyFree = false;
      _minAgeFilter = null;
      _maxEntryFilter = null;
    }
    if (_onlyOpenParties && _onlyClosedParties) _onlyClosedParties = false;
    _timeRange = TimeRangeFilter.fromPref(prefs.getString(_kPrefTimeRange));
  }

  Future<void> _saveFilterPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefShowParties, _showParties);
    await prefs.setBool(_kPrefShowBars, _showBars);
    await prefs.setBool(_kPrefShowFestln, _showFestln);
    await prefs.setBool(_kPrefOnlyFree, _onlyFree);
    await prefs.setBool(_kPrefOnlyOpen, _onlyOpenParties);
    await prefs.setBool(_kPrefOnlyClosed, _onlyClosedParties);
    await prefs.setInt(_kPrefMinAge, _minAgeFilter ?? -1);
    if (_maxEntryFilter != null) {
      await prefs.setDouble(_kPrefMaxEntry, _maxEntryFilter!);
    } else {
      await prefs.remove(_kPrefMaxEntry);
    }
    // -1 als Sentinel für "kein Radius-Limit".
    await prefs.setDouble(_kPrefRadius, _radiusKm ?? -1);
    await prefs.setString(_kPrefTimeRange, _timeRange.prefValue);
  }

  // =========================
  // ✅ STATUS NORMALISIERUNG (FIX fürs Rot nach Refresh)
  // =========================
  String? _normOpenStatus(String? raw) {
    if (raw == null) return null;
    final s = raw.toString().trim().toLowerCase();

    // "komme"/"coming"/etc -> going
    if (s == 'going' ||
        s == 'come' ||
        s == 'komme' ||
        s == 'coming' ||
        s == 'yes') {
      return 'going';
    }

    // "angefragt"/request/pending -> pending (orange)
    if (s == 'pending' ||
        s == 'requested' ||
        s == 'request' ||
        s == 'anfrage') {
      return 'pending';
    }

    if (s == 'maybe') return 'maybe';
    return null;
  }

  Future<String?> _myOpenRsvpStatus(String partyId) async {
    if (_currentUsername == null) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('Party')
          .doc(partyId)
          .collection('rsvps')
          .doc(_currentUsername!)
          .get();
      final raw = snap.data()?['status'] as String?;
      return _normOpenStatus(raw);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _myOpenRequestStatus(String partyId) async {
    if (_currentUsername == null) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('Party')
          .doc(partyId)
          .collection('requests')
          .doc(_currentUsername!)
          .get();
      final raw = snap.data()?['status'] as String?;
      return _normOpenStatus(raw);
    } catch (_) {
      return null;
    }
  }

  // =========================

  Future<void> _prepareIcons() async {
    _lockIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFF1976D2),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconGrey = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFF424242),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFF2E7D32),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconRed = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFFD32F2F),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _hitboxIcon = BitmapDescriptor.fromBytes(
      await _drawTransparentCircle(diameter: _hitBaseDiameter),
    );

    _friendsOnlyIcon = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _friendsBaseDiameter,
      circleColor: const Color(0xFF6A1B9A),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));

    _friendsIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _friendsBaseDiameter,
      circleColor: const Color(0xFF1976D2),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _friendsBaseDiameter,
      circleColor: const Color(0xFF2E7D32),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconOrange = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: _friendsBaseDiameter,
      circleColor: const Color(0xFFF57C00),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconPurple = _friendsOnlyIcon;

    _partyIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFF1976D2),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFF2E7D32),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconOrange = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFFF57C00),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconRed = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: _lockBaseDiameter,
      circleColor: const Color(0xFFD32F2F),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));

    // Friend-Dot — kleiner grüner Kreis mit weißem Border. Zoom-stabil
    // weil als Sekundär-Marker mit fixer Anchor-Offset montiert wird.
    _friendDotIcon = BitmapDescriptor.fromBytes(
      await _drawSolidDot(
        diameter: 36,
        fillColor: AppColors.success,
        borderColor: Colors.white,
        borderWidth: 4,
      ),
    );

    // Doppel-Dot für ≥2 Freunde going. Zwei überlappende grüne Punkte
    // — sichtbar "mehr als ein Freund" ohne Zahlenbadge (anti-cringe).
    _friendDotDoubleIcon = BitmapDescriptor.fromBytes(
      await _drawDoubleDot(
        canvasWidth: 52,
        canvasHeight: 36,
        dotDiameter: 32,
        offsetX: 16,
        fillColor: AppColors.success,
        borderColor: Colors.white,
        borderWidth: 4,
      ),
    );

    if (mounted) setState(() {});
  }

  /// Zwei überlappende Solid-Dots für „2+ Freunde". Bewusst breiter
  /// als das Single-Icon (52×36 statt 36×36), damit beide Dots Platz
  /// haben. Anchor-Offset im Marker kompensiert die Breite.
  Future<Uint8List> _drawDoubleDot({
    required int canvasWidth,
    required int canvasHeight,
    required int dotDiameter,
    required int offsetX,
    required Color fillColor,
    required Color borderColor,
    required double borderWidth,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final r = dotDiameter / 2.0;
    final cy = canvasHeight / 2.0;

    void drawDot(double cx) {
      // Drop-shadow
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = Colors.black.withOpacity(0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      canvas.drawCircle(Offset(cx, cy), r - borderWidth / 2,
          Paint()..color = borderColor);
      canvas.drawCircle(Offset(cx, cy), r - borderWidth,
          Paint()..color = fillColor);
    }

    // Hinterer Dot zuerst (rechts), vorderer Dot überlappend (links).
    drawDot(offsetX + r);
    drawDot(r);

    final picture = recorder.endRecording();
    final img = await picture.toImage(canvasWidth, canvasHeight);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  /// Volle Kreisscheibe mit Outline — für Social-Dot-Marker.
  /// Bewusst klein (≤40px) und pre-rendered, kein per-Party-Bitmap.
  Future<Uint8List> _drawSolidDot({
    required int diameter,
    required Color fillColor,
    required Color borderColor,
    required double borderWidth,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);
    final r = diameter / 2.0;

    // Subtle drop-shadow für besseren Kontrast auf hellen Map-Stellen.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.black.withOpacity(0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(center, r - borderWidth / 2, Paint()..color = borderColor);
    canvas.drawCircle(center, r - borderWidth, Paint()..color = fillColor);

    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _drawCircleWithIcon({
    required int diameter,
    required Color circleColor,
    required IconData icon,
    required Color iconColor,
    required double iconScale,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);

    canvas.drawCircle(center, diameter / 2, Paint()..color = circleColor);

    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: diameter * iconScale,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: iconColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _drawCircleWithEmoji({
    required int diameter,
    required Color circleColor,
    required String emoji,
    required Color emojiColor,
    required double emojiScale,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);

    canvas.drawCircle(center, diameter / 2, Paint()..color = circleColor);

    final tp = TextPainter(
      text: TextSpan(
        text: emoji,
        style: TextStyle(
          fontSize: diameter * emojiScale,
          color: emojiColor,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<Uint8List> _drawTransparentCircle({required int diameter}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(
      center,
      diameter / 2,
      Paint()..color = const Color(0x00000000),
    );
    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  Future<BitmapDescriptor> _createBarMarkerIcon(String? imageUrl) async {
    // Standardmäßig roter Ring (PartyPin-Akzent).
    return _createBarMarkerIconWithRing(
      imageUrl: imageUrl,
      ringWidth: 5,
      solidRingColor: AppColors.accent,
    );
  }

  Future<BitmapDescriptor> _createBarMarkerIconWithGreenRing(
      String? imageUrl) async {
    // Bei aktivem Event: grüner Ring.
    return _createBarMarkerIconWithRing(
      imageUrl: imageUrl,
      ringWidth: 6,
      solidRingColor: AppColors.success,
    );
  }

  Future<BitmapDescriptor> _createBarMarkerIconWithRing({
    required String? imageUrl,
    required double ringWidth,
    Color solidRingColor = Colors.white,
  }) async {
    final int diameter = _barBaseDiameter;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = diameter / 2.0;
    final imageRadius = outerRadius - ringWidth;

    // Draw background circle
    canvas.drawCircle(center, outerRadius, Paint()..color = _panel);

    // Draw image or fallback fill
    if (imageUrl != null && imageUrl.trim().isNotEmpty) {
      try {
        final uri = Uri.parse(imageUrl);
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final codec = await ui.instantiateImageCodec(
            resp.bodyBytes,
            targetWidth: diameter,
            targetHeight: diameter,
          );
          final image = (await codec.getNextFrame()).image;
          final dstRect = Rect.fromCircle(center: center, radius: imageRadius);
          canvas.save();
          canvas.clipPath(Path()..addOval(dstRect));
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
            dstRect,
            Paint(),
          );
          canvas.restore();
        }
      } catch (_) {}
    } else {
      canvas.drawCircle(center, imageRadius, Paint()..color = AppColors.accentBorder);
    }

    // Draw ring — solid color (rot normal, grün bei Event).
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..isAntiAlias = true
      ..color = solidRingColor;

    canvas.drawCircle(center, imageRadius, ringPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(pngBytes!.buffer.asUint8List());
  }

  bool _barHasVisibleEvent(Map<String, dynamic> bar, DateTime now) {
    if (bar['eventActive'] != true) return false;

    DateTime? dt;
    final raw = bar['eventDate'];
    if (raw is Timestamp) {
      dt = raw.toLocalDateTime();
    } else if (raw is String) {
      dt = DateTime.tryParse(raw)?.toLocal();
    }
    if (dt == null) return false;

    final start = dt.subtract(const Duration(hours: 1));
    final visibleFrom = start.subtract(const Duration(days: _barEventDaysBefore));
    final visibleUntil = start.add(const Duration(hours: _barEventHoursAfter));

    return now.isAfter(visibleFrom) && now.isBefore(visibleUntil);
  }

  String _monthName(int month) {
    const months = [
      "",
      "Januar",
      "Februar",
      "März",
      "April",
      "Mai",
      "Juni",
      "Juli",
      "August",
      "September",
      "Oktober",
      "November",
      "Dezember"
    ];
    return months[month];
  }

  bool _isClosedDoc(Map<String, dynamic> d) {
    final t = (d['type'] ?? '').toString().trim().toLowerCase();
    final b = d['isClosed'] == true;
    return t == 'closed' || b == true;
  }

  LatLng? _parseLatLng(Map<String, dynamic> d) {
    try {
      if (d['lat'] != null && d['lng'] != null) {
        double toD(v) {
          if (v is num) return v.toDouble();
          if (v is String) return double.parse(v);
          return double.nan;
        }

        final lat = toD(d['lat']);
        final lng = toD(d['lng']);
        if (lat.isFinite && lng.isFinite) return LatLng(lat, lng);
      }
      final gp = d['location'] ?? d['geo'] ?? d['coords'];
      if (gp != null && gp is GeoPoint) {
        return LatLng(gp.latitude, gp.longitude);
      }
    } catch (_) {}
    return null;
  }

  double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const R = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) *
            sin(dLng / 2) * sin(dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  /// TIME_RANGE_FILTER: true, wenn das Event das gewählte Zeitfenster
  /// überlappt. Events ohne verwertbares Datum bleiben sichtbar — lieber
  /// eines zu viel zeigen als eines zu verstecken, dessen Zeit wir nur
  /// nicht lesen konnten.
  bool _inTimeRange(Map<String, dynamic> d, DateTime now) {
    if (_timeRange == TimeRangeFilter.all) return true;

    final w = _timeRange.windowFor(now);
    final start = _partyStart(d);
    if (start == null) return true;

    final rawEnd = d['endTime'];
    final end = rawEnd is Timestamp ? rawEnd.toLocalDateTime() : start;

    if (w.end != null && !start.isBefore(w.end!)) return false;
    return !end.isBefore(w.start);
  }

  DateTime? _partyStart(Map<String, dynamic> d) {
    // 1) startTime bevorzugt (matcht functions/index.js parsePartyStart)
    final st = d['startTime'];
    if (st is Timestamp) return st.toLocalDateTime();
    if (st is String) {
      final parsed = DateTime.tryParse(st);
      if (parsed != null) return parsed.toLocal();
    }

    // 2) Fallback: date + time
    DateTime? base;
    final v = d['date'];
    if (v is Timestamp) {
      base = v.toLocalDateTime();
    } else if (v is String) {
      base = DateTime.tryParse(v);
    }
    if (base == null) return null;

    final timeStr = (d['time'] ?? '').toString().trim();
    int hh = 0, mm = 0;
    if (timeStr.contains(':')) {
      final parts = timeStr.split(':');
      if (parts.isNotEmpty) hh = int.tryParse(parts[0]) ?? 0;
      if (parts.length > 1) mm = int.tryParse(parts[1]) ?? 0;
    }
    return DateTime(base.year, base.month, base.day, hh, mm);
  }

  bool _isExpiredWithGrace(Map<String, dynamic> d) {
    final start = _partyStart(d);
    if (start == null) return false;
    final cutoff = start.add(const Duration(hours: 24));
    return DateTime.now().isAfter(cutoff);
  }

  bool _isActive(Map<String, dynamic> d) => !_isExpiredWithGrace(d);

  bool _isInRatingWindow(Map<String, dynamic> d) {
    final start = _partyStart(d);
    if (start == null) return false;
    final now = DateTime.now();
    final end = start.add(const Duration(hours: 24));
    return now.isAfter(start) && now.isBefore(end);
  }

  bool _isHostForPartyData(Map<String, dynamic> data) {
    final hostName = (data['hostName'] ?? '').toString().trim();
    final hostUid = ((data['hostUid'] ?? data['hostId']) ?? '')
        .toString()
        .trim();
    final cu = _currentUsername?.trim();
    final cf = _currentFullName?.trim();

    final byUid = cu != null && cu.isNotEmpty && hostUid.isNotEmpty && hostUid == cu;
    final byName = cf != null && cf.isNotEmpty && hostName.isNotEmpty && hostName == cf;

    return byUid || byName;
  }

  Future<bool> _isUserVerified(String usernameDocId) async {
    if (_verifiedCache.containsKey(usernameDocId)) {
      return _verifiedCache[usernameDocId]!;
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(usernameDocId)
          .get();
      final verified = (snap.data()?['verified'] == true);
      _verifiedCache[usernameDocId] = verified;
      return verified;
    } catch (_) {
      _verifiedCache[usernameDocId] = false;
      return false;
    }
  }

  // =========================
  // ✅ MARKER ICONS (Open + Friends)
  // =========================

  BitmapDescriptor _iconForOpenPartyMarker(String partyId) {
    final isHost = _openPartyIsHost[partyId] == true;
    final status = _openPartyStatus[partyId];

    if (isHost) return _partyIconBlue ?? BitmapDescriptor.defaultMarker;
    if (status == 'going') return _partyIconGreen ?? BitmapDescriptor.defaultMarker;
    if (status == 'maybe' || status == 'pending') {
      return _partyIconOrange ?? BitmapDescriptor.defaultMarker;
    }
    return _partyIconRed ?? BitmapDescriptor.defaultMarker;
  }

  BitmapDescriptor _iconForFriendsPartyMarker(String partyId) {
    final data = _partyCache[partyId];
    if (data == null) {
      return _friendsOnlyIcon ?? BitmapDescriptor.defaultMarker;
    }

    final isHost = _isHostForPartyData(data);
    final status = _openPartyStatus[partyId];

    if (isHost) return _friendsIconBlue ?? (_friendsOnlyIcon ?? BitmapDescriptor.defaultMarker);
    if (status == 'going') return _friendsIconGreen ?? (_friendsOnlyIcon ?? BitmapDescriptor.defaultMarker);
    if (status == 'maybe' || status == 'pending') {
      return _friendsIconOrange ?? (_friendsOnlyIcon ?? BitmapDescriptor.defaultMarker);
    }
    return _friendsIconPurple ?? (_friendsOnlyIcon ?? BitmapDescriptor.defaultMarker);
  }

  void _setOpenMarkerColor(String partyId, {required String? status, required bool isHost}) {
    // Invariant: dieser Pfad rebuildet NUR den Haupt-Marker (mid =
    // partyId). Social-Overlays (`social_dot_*` Marker, `social_*`
    // Circle) bleiben unberührt — sie hängen an friend-overlap, nicht
    // am User-eigenen RSVP-Status. Wenn du hier Marker-Cleanup machst,
    // achte darauf, social_* nicht aus Versehen zu killen.
    final mid = partyId;
    final old = _getMarker(mid);
    if (old == null) return;

    _openPartyStatus[partyId] = _normOpenStatus(status);
    _openPartyIsHost[partyId] = isHost;

    final data = _partyCache[partyId];
    final isFriendsOnly = data != null &&
        (data['visibility'] ?? 'public').toString() == 'friends' &&
        !_isClosedDoc(data);

    final icon = isFriendsOnly
        ? _iconForFriendsPartyMarker(partyId)
        : _iconForOpenPartyMarker(partyId);

    setState(() {
      _putMarker(Marker(
        markerId: MarkerId(mid),
        position: old.position,
        icon: icon,
        onTap: () => _openPartySheet(_partyCache[partyId]!, partyId),
        anchor: old.anchor,
        zIndex: old.zIndex,
        consumeTapEvents: old.consumeTapEvents,
        infoWindow: old.infoWindow,
      ));
    });
  }

  // =========================
  // ✅ LOAD / REFRESH
  // =========================

  Future<void> _refreshMap() {
    // Coalescing: wenn schon ein Refresh läuft, gib den existierenden
    // Future zurück. Caller die `await` machen, hängen am gleichen Run —
    // die Inner-Mutations (_markers.clear etc.) passieren nur einmal.
    final existing = _refreshFuture;
    if (existing != null) return existing;
    final f = _refreshMapImpl().whenComplete(() {
      // Erst nach Abschluss freigeben, sonst startet ein gleichzeitiger
      // zweiter Caller einen neuen Lauf in der setState-Lücke.
      _refreshFuture = null;
    });
    _refreshFuture = f;
    return f;
  }

  Future<void> _refreshMapImpl() async {
    _partyCache.clear();
    _clearMarkers();
    _circles.clear();
    _closedPartyStatus.clear();
    _openPartyStatus.clear();
    _openPartyIsHost.clear();
    _pendingStatus.clear();

    // PHASE 1: Marker synchron mit Platzhalter-Icons bauen (kein Status-
    // await im Loop). Nur 2 Reads gesamt (Partys + Bars) statt 40-80.
    await _loadPartiesFromFirebase();
    await _loadBarsFromFirebase();
    await _loadFestlnFromFirebase();

    // Phase 4: City-Mood aus den bereits geladenen Party-Docs ableiten.
    // Pure function, O(n) — keine zusätzlichen Reads.
    _cityMood = computeCityMood(
      parties: _partyCache.values,
      myFriends: _myFriendsSet,
    );

    // Karte ist JETZT sichtbar (Platzhalter-Icons grau/rot/lila).
    if (mounted) setState(() {});

    // PHASE 2: echte RSVP/Request-Status PARALLEL nachladen und Icons
    // updaten. Kein await hier — die Map blockiert nicht auf diese Reads.
    unawaited(_enrichPartyStatuses());
  }

  /// PHASE 2 des render-first Ladens. Löst alle ausstehenden Status-Reads
  /// PARALLEL (Future.wait) auf statt seriell im Lade-Loop, und updatet die
  /// betroffenen Marker-Icons in EINEM setState. Verwandelt 40-80
  /// sequentielle Round-Trips (~6-12s Freeze) in einen parallelen Batch
  /// (~200ms, kein Main-Thread-Block). Jeder Read fängt seine Fehler selbst
  /// ab → ein PERMISSION_DENIED killt nicht den ganzen Batch.
  Future<void> _enrichPartyStatuses() async {
    if (_pendingStatus.isEmpty) return;
    final me = _currentUsername;
    if (me == null) return;

    final pending = List<({String id, bool isClosed})>.from(_pendingStatus);
    _pendingStatus.clear();

    final results = await Future.wait(pending.map((p) async {
      try {
        final status = p.isClosed
            ? await _myRequestStatus(p.id, me)
            : (await _myOpenRsvpStatus(p.id) ?? await _myOpenRequestStatus(p.id));
        return (id: p.id, isClosed: p.isClosed, status: status);
      } catch (_) {
        return (id: p.id, isClosed: p.isClosed, status: null as String?);
      }
    }));

    if (!mounted) return;

    setState(() {
      for (final r in results) {
        if (r.isClosed) {
          _closedPartyStatus[r.id] = r.status;
          _applyClosedMarkerIcon(r.id, r.status);
        } else {
          _openPartyStatus[r.id] = _normOpenStatus(r.status);
          _applyOpenMarkerIcon(r.id);
        }
      }
    });
  }

  /// Tauscht das Icon eines geschlossenen Party-Markers IN-PLACE aus
  /// (kein eigenes setState — wird im Batch-setState von
  /// _enrichPartyStatuses aufgerufen). Social-Overlays bleiben unberührt.
  void _applyClosedMarkerIcon(String partyId, String? status) {
    final mid = 'lock_$partyId';
    final old = _getMarker(mid);
    if (old == null) return;
    final data = _partyCache[partyId];
    final isHost = data != null && _isHostForPartyData(data);

    final BitmapDescriptor icon;
    if (isHost) {
      icon = _lockIconBlue ?? BitmapDescriptor.defaultMarker;
    } else if (status == 'approved') {
      icon = _lockIconGreen ?? BitmapDescriptor.defaultMarker;
    } else if (status == 'declined') {
      icon = _lockIconRed ?? BitmapDescriptor.defaultMarker;
    } else {
      icon = _lockIconGrey ?? BitmapDescriptor.defaultMarker;
    }

    _putMarker(Marker(
      markerId: MarkerId(mid),
      position: old.position,
      icon: icon,
      zIndex: old.zIndex,
      onTap: () => _openPartySheet(_partyCache[partyId] ?? const {}, partyId),
    ));
  }

  /// Tauscht das Icon eines offenen/friends Party-Markers IN-PLACE aus
  /// (kein eigenes setState). Liest _openPartyStatus/_openPartyIsHost die
  /// vorher gesetzt wurden.
  void _applyOpenMarkerIcon(String partyId) {
    final old = _getMarker(partyId);
    if (old == null) return;
    final data = _partyCache[partyId];
    final isFriendsOnly = data != null &&
        (data['visibility'] ?? 'public').toString() == 'friends' &&
        !_isClosedDoc(data);

    final icon = isFriendsOnly
        ? _iconForFriendsPartyMarker(partyId)
        : _iconForOpenPartyMarker(partyId);

    _putMarker(Marker(
      markerId: MarkerId(partyId),
      position: old.position,
      icon: icon,
      onTap: () => _openPartySheet(_partyCache[partyId] ?? const {}, partyId),
      anchor: old.anchor,
      zIndex: old.zIndex,
      consumeTapEvents: old.consumeTapEvents,
      infoWindow: old.infoWindow,
    ));
  }

  Future<void> _loadPartiesFromFirebase() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('Party')
        .limit(300)
        .get();
    for (final doc in snapshot.docs) {
      try {
        final data = doc.data();
        _partyCache[doc.id] = data;

        if (!_showParties) continue;

        // TIME_RANGE_FILTER: gleicher Zeitraum wie für Festln, damit die
        // Karte als Ganzes zum gewählten Zeitfenster passt.
        if (!_inTimeRange(data, DateTime.now())) continue;

        // 🔒 Host-Erkennung (NUR EINMAL!)
        final bool isHostForThisParty = _isHostForPartyData(data);

        // 🚨 Moderationsstatus (Apple 1.2-konform)
        final String moderationStatus =
        (data['moderationStatus'] ?? 'active').toString();

        if (moderationStatus == 'blocked' && !isHostForThisParty) {
          continue;
        }

        // =============================
        // 🎂 Altersfilter
        // =============================
        if (_minAgeFilter != null) {
          int partyAge = 0;
          if (data['minAge'] is int) {
            partyAge = data['minAge'] as int;
          } else {
            final ageStr = (data['minAge'] ??
                data['age'] ??
                data['eventAge'] ??
                '')
                .toString()
                .toLowerCase()
                .trim();
            final digits = RegExp(r'\d+').stringMatch(ageStr);
            if (digits != null) {
              partyAge = int.tryParse(digits) ?? 0;
            }
          }
          if (partyAge > 0 && partyAge > _minAgeFilter!) continue;
        }

        // =============================
        // 💰 Eintritt
        // =============================
        final rawEntry = data['entryFee'] ?? data['price'];
        double? entryFee;

        if (rawEntry is num) {
          entryFee = rawEntry.toDouble();
        } else if (rawEntry != null) {
          entryFee = double.tryParse(
            rawEntry.toString().replaceAll(',', '.'),
          );
        }

        if (_onlyFree && (entryFee ?? 0) > 0) continue;
        if (_maxEntryFilter != null &&
            entryFee != null &&
            entryFee > _maxEntryFilter!) continue;

        // =============================
        // ⏰ abgelaufen
        // =============================
        if (_isExpiredWithGrace(data)) continue;

        // =============================
        // 📍 Position
        // =============================
        final pos = _parseLatLng(data);
        if (pos == null) continue;

        // =============================
        // 📍 Radius-Filter
        // =============================
        if (_radiusKm != null) {
          final distKm = _haversineKm(_currentLat, _currentLng, pos.latitude, pos.longitude);
          if (distKm > _radiusKm!) continue;
        }

        // =============================
        // 🌍 friends-only Sichtbarkeit
        // =============================
        final visibility = (data['visibility'] ?? 'public').toString();
        final excluded =
            (data['excludedFriends'] as List?)?.cast<String>() ?? const [];
        final isFriendOnly = visibility == 'friends';

        final hostUsername =
        ((data['hostId'] ?? data['hostUid']) ?? '').toString().trim();

        if (isFriendOnly && !isHostForThisParty) {
          final me = _currentUsername?.trim();
          final isFriend =
              me != null && me.isNotEmpty && _myFriendsSet.contains(hostUsername);
          final isExcluded = me != null && excluded.contains(me);

          if (!isFriend || isExcluded) continue;
        }

        // =============================
        // 🔓 / 🔒 open / closed Filter
        // =============================
        final isClosed = _isClosedDoc(data);
        if (_onlyClosedParties && !isClosed) continue;
        if (_onlyOpenParties && isClosed) continue;

        // Social-Flags aus Aggregat-Feldern + Friend-Set ableiten.
        // Closed-Partys werden auf der echten LatLng (pos) bewertet,
        // aber visuell am verschobenen Pin angezeigt — Aura geht am
        // Pin auf, nicht am echten Ort (damit Privacy gewahrt bleibt).
        //
        // Phase 3: startTime mit reingeben → momentum + startingSoon.
        final social = computeMapSocialFlags(
          partyData: data,
          myFriends: _myFriendsSet,
          startTime: _partyStart(data),
        );

        // =================================================
        // 🔒 CLOSED PARTY
        // =================================================
        if (isClosed) {
          final rng = Random(doc.id.hashCode);
          final fakeCenter = _offsetWithinRadiusMeters(
            center: pos,
            minMeters: 400,
            maxMeters: 650,
            rng: rng,
          );

          // RENDER-FIRST: KEIN await hier. Status (grün/rot) wird in
          // Phase 2 parallel nachgeladen. Platzhalter: Host=blau, sonst grau.
          final bool needsStatus = !_isBarAccount &&
              _currentUsername != null &&
              !isHostForThisParty;

          final BitmapDescriptor icon = isHostForThisParty
              ? (_lockIconBlue ?? BitmapDescriptor.defaultMarker)
              : (_lockIconGrey ?? BitmapDescriptor.defaultMarker);

          _putMarker(Marker(
            markerId: MarkerId('lock_${doc.id}'),
            position: fakeCenter,
            icon: icon,
            zIndex: _socialZIndexFor(social, base: 0),
            onTap: () => _openPartySheet(data, doc.id),
          ));

          _applySocialOverlay(
            partyId: doc.id,
            markerId: 'lock_${doc.id}',
            position: fakeCenter,
            flags: social,
            onTap: () => _openPartySheet(data, doc.id),
          );

          if (needsStatus) {
            _pendingStatus.add((id: doc.id, isClosed: true));
          }
        }
        // =================================================
        // 🎉 OPEN PARTY
        // =================================================
        else {
          _openPartyIsHost[doc.id] = isHostForThisParty;

          // RENDER-FIRST: KEIN await. Status noch unbekannt → die
          // Icon-Funktionen liefern Platzhalter (rot/lila). Echter Status
          // kommt in Phase 2 (_enrichPartyStatuses) parallel nach.
          final bool needsStatus = !_isBarAccount &&
              _currentUsername != null &&
              !isHostForThisParty;

          final icon = isFriendOnly
              ? _iconForFriendsPartyMarker(doc.id)
              : _iconForOpenPartyMarker(doc.id);

          _putMarker(Marker(
            markerId: MarkerId(doc.id),
            position: pos,
            icon: icon,
            zIndex: _socialZIndexFor(social, base: 0),
            onTap: () => _openPartySheet(data, doc.id),
          ));

          _applySocialOverlay(
            partyId: doc.id,
            markerId: doc.id,
            position: pos,
            flags: social,
            onTap: () => _openPartySheet(data, doc.id),
          );

          if (needsStatus) {
            _pendingStatus.add((id: doc.id, isClosed: false));
          }
        }
      } catch (_) {
        continue;
      }
    }
  }

  // =========================
  // 👥 LIVE SOCIAL MAP LAYER
  // =========================

  /// Mappt Social-Signals auf einen Marker-zIndex. Hot-Parties +
  /// Friends-Parties liegen visuell über plain Markern bei Cluster.
  /// Bewusst klein gehalten — kein Ranking-Spiel.
  ///
  /// Phase-3: Surging bringt Momentum-Parties zusätzlich nach vorn.
  double _socialZIndexFor(MapSocialFlags flags, {double base = 0}) {
    double z = base;
    if (flags.hasFriend) z += 4;
    else if (flags.isHot) z += 2;
    if (flags.momentum == PartyMomentum.surging) z += 1;
    return z;
  }

  /// Fügt Social-Overlays für eine Party hinzu — Aura (Circle) +
  /// optional Friend-Dot-Marker oben rechts vom Haupt-Marker.
  ///
  /// Performance-Garantien:
  ///   - 1 zusätzlicher Circle nur wenn `hasAnySignal`
  ///   - 1 zusätzlicher Marker nur wenn `hasFriend`
  ///   - Reused werden die PRE-RENDERED `_friendDotIcon` /
  ///     `_friendDotDoubleIcon` — KEIN per-Party Bitmap-Rendering
  ///   - Tap auf Dot-Marker fällt durch zum Haupt-Marker
  ///     (consumeTapEvents: false)
  ///
  /// Phase-3-Skalierung:
  ///   - rising  → Radius +4m, Stroke +0.10 opacity
  ///   - surging → Radius +8m, Stroke +0.20 opacity
  void _applySocialOverlay({
    required String partyId,
    required String markerId,
    required LatLng position,
    required MapSocialFlags flags,
    required VoidCallback onTap,
  }) {
    if (!flags.hasAnySignal) return;

    // Aura: Radius in Metern → bei Far-Zoom unsichtbar (Map ist clean),
    // bei Close-Up sichtbares Glühen. Genau das gewünschte Verhalten:
    // weit weg = aufgeräumt, nah dran = lebendig.
    //
    // Friends-Aura (grün) gewinnt über Hot-Aura (accent).
    final auraColor = flags.hasFriend ? AppColors.success : AppColors.accent;
    double auraRadius = 22;
    double auraFillOpacity = flags.hasFriend ? 0.10 : 0.07;
    double auraStrokeOpacity = flags.hasFriend ? 0.45 : 0.30;

    // Momentum-Skalierung. Subtle stärker, kein neuer Farbcode.
    switch (flags.momentum) {
      case PartyMomentum.rising:
        auraRadius += 4;
        auraFillOpacity += 0.04;
        auraStrokeOpacity += 0.10;
        break;
      case PartyMomentum.surging:
        auraRadius += 8;
        auraFillOpacity += 0.08;
        auraStrokeOpacity += 0.20;
        break;
      case PartyMomentum.none:
        break;
    }

    _circles.add(Circle(
      circleId: CircleId('social_$partyId'),
      center: position,
      radius: auraRadius,
      fillColor: auraColor.withOpacity(auraFillOpacity),
      strokeColor: auraColor.withOpacity(auraStrokeOpacity),
      strokeWidth: flags.momentum == PartyMomentum.surging ? 2 : 1,
      zIndex: 0,
    ));

    // Friend-Dot: nur wenn ≥1 Freund going. Bei nur "hot" ohne
    // Freunde kommt KEIN Dot — Aura allein signalisiert Crowd.
    //
    // 2+ Freunde → Doppel-Dot. Anchor angepasst weil Bitmap breiter ist.
    if (flags.hasFriend) {
      final useDouble = flags.hasManyFriends && _friendDotDoubleIcon != null;
      final icon = useDouble ? _friendDotDoubleIcon! : _friendDotIcon;
      if (icon == null) return;

      _putMarker(Marker(
        markerId: MarkerId('social_dot_$markerId'),
        position: position,
        icon: icon,
        // Anchor verschiebt den Dot oben rechts vom Haupt-Marker.
        // Doppel-Dot ist breiter (52px vs 36px) → x-Anchor leicht
        // anders gewählt damit der vordere Dot etwa an derselben
        // optischen Position sitzt wie der Single-Dot.
        anchor: useDouble
            ? const Offset(-0.25, 1.6)
            : const Offset(-0.4, 1.6),
        zIndex: _socialZIndexFor(flags, base: 0) + 0.5,
        consumeTapEvents: false,
        onTap: onTap,
      ));
    }
  }

  Future<void> _loadBarsFromFirebase() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('bars')
          .where('status', isEqualTo: 'approved')
          .get();

      final now = DateTime.now();

      // ── Phase 1: alle relevanten Bars sammeln (kein await im Loop) ─────────
      final pending = <_BarMarkerJob>[];
      final neededIconKeys = <String>{};

      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (!_showBars) continue;

        // Event abgelaufen → zurücksetzen (fire-and-forget, kein await)
        if (data['eventActive'] == true && data['eventDate'] is Timestamp) {
          final dt = (data['eventDate'] as Timestamp).toLocalDateTime();
          final start = dt.subtract(const Duration(hours: 1));
          if (now.isAfter(
              start.add(const Duration(hours: _barEventHoursAfter)))) {
            FirebaseFirestore.instance.collection('bars').doc(doc.id).set(
              {
                'eventActive': false,
                'eventTitle': FieldValue.delete(),
                'eventDescription': FieldValue.delete(),
                'eventDate': FieldValue.delete(),
                'eventTime': FieldValue.delete(),
                'eventUpdatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
          }
        }

        final pos = _parseLatLng(data);
        if (pos == null) continue;

        if (_radiusKm != null) {
          final distKm = _haversineKm(
              _currentLat, _currentLng, pos.latitude, pos.longitude);
          if (distKm > _radiusKm!) continue;
        }

        final barName = (data['barName'] ?? 'Bar').toString();
        final imageUrl =
            (data['profileImageUrl'] ?? '').toString().trim();
        final baseKey = imageUrl.isEmpty ? '__default' : imageUrl;
        final hasEvent = _barHasVisibleEvent(data, now);
        final iconKey =
            hasEvent ? 'event|$baseKey' : 'normal|$baseKey';

        final isCached = hasEvent
            ? _barIconEventRingCache.containsKey(iconKey)
            : _barIconCache.containsKey(iconKey);

        if (!isCached) neededIconKeys.add(iconKey);

        pending.add(_BarMarkerJob(
          docId: doc.id,
          data: data,
          pos: pos,
          name: barName,
          imageUrl: imageUrl,
          hasEvent: hasEvent,
          iconKey: iconKey,
        ));
      }

      // ── Phase 2: alle fehlenden Icons PARALLEL bauen ───────────────────────
      // Vorher: sequenziell N × ~200 ms. Jetzt: alle Downloads gleichzeitig.
      if (neededIconKeys.isNotEmpty) {
        final keysToBuild = neededIconKeys.toList();
        final futures = keysToBuild.map((key) {
          final isEvent = key.startsWith('event|');
          final url = key.substring(key.indexOf('|') + 1);
          final urlOrNull = url == '__default' ? null : url;
          return isEvent
              ? _createBarMarkerIconWithGreenRing(urlOrNull)
              : _createBarMarkerIcon(urlOrNull);
        }).toList();
        final results = await Future.wait(futures, eagerError: false);
        for (var i = 0; i < keysToBuild.length; i++) {
          final key = keysToBuild[i];
          final icon = results[i];
          if (key.startsWith('event|')) {
            _barIconEventRingCache[key] = icon;
          } else {
            _barIconCache[key] = icon;
          }
        }
      }

      // ── Phase 3: Marker aus Cache zusammenstellen ──────────────────────────
      for (final job in pending) {
        final icon = job.hasEvent
            ? _barIconEventRingCache[job.iconKey]
            : _barIconCache[job.iconKey];
        if (icon == null) continue; // build fehlgeschlagen → still überspringen
        _putMarker(
          Marker(
            markerId: MarkerId('bar_${job.docId}'),
            position: job.pos,
            icon: icon,
            infoWindow: InfoWindow(title: job.name),
            onTap: () => _openBarSheet(job.data, job.docId),
          ),
        );
      }
    } catch (_) {}
  }

  // =========================
  // 🎡 FESTLN (admin-kuratierte Events mit eigenem Symbol)
  // =========================

  /// Festl gilt als abgelaufen, wenn endTime (fallback startTime) plus
  /// Nachlauf-Fenster vorbei ist.
  bool _festlExpired(Map<String, dynamic> data, DateTime now) {
    final raw = data['endTime'] ?? data['startTime'];
    if (raw is! Timestamp) return false;
    final ref = raw.toLocalDateTime();
    return now.isAfter(ref.add(const Duration(hours: _festlHoursAfterEnd)));
  }

  Future<void> _loadFestlnFromFirebase() async {
    if (!_showFestln) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('festln')
          .where('status', isEqualTo: 'approved')
          .get();

      final now = DateTime.now();

      // Festl-Emoji-Marker einmal rendern (zoom-invariant, wie Bar-Marker).
      _festlIcon ??= BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
        diameter: _festlBaseDiameter,
        circleColor: _festlColor,
        emoji: "🎡",
        emojiColor: Colors.white,
        emojiScale: .58,
      ));

      for (final doc in snapshot.docs) {
        final data = doc.data();

        if (_festlExpired(data, now)) continue;

        // TIME_RANGE_FILTER: hier am wichtigsten — die Festlliste bringt
        // Termine bis mehrere Monate voraus mit.
        if (!_inTimeRange(data, now)) continue;

        final pos = _parseLatLng(data);
        if (pos == null) continue;

        if (_radiusKm != null) {
          final distKm = _haversineKm(
              _currentLat, _currentLng, pos.latitude, pos.longitude);
          if (distKm > _radiusKm!) continue;
        }

        _putMarker(Marker(
          markerId: MarkerId('festl_${doc.id}'),
          position: pos,
          icon: _festlIcon!,
          infoWindow:
              InfoWindow(title: (data['festlName'] ?? 'Festl').toString()),
          onTap: () => _openFestlSheet(data, doc.id),
        ));
      }
    } catch (_) {}
  }

  void _openFestlSheet(Map<String, dynamic> data, String festlId) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FestlBottomSheet(
        festlId: festlId,
        festlData: data,
        currentUsername: _currentUsername,
        currentAvatarUrl: profileImageUrl,
        friendUsernames: _myFriendsSet,
      ),
    );
  }

  // =========================
  // ✅ CLOSED REQUEST STATUS
  // =========================
  Future<String?> _myRequestStatus(String partyId, String username) async {
    try {
      final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);

      // 1) approvedUsers array
      try {
        final partyDoc = await partyRef.get();
        final arr = (partyDoc.data()?['approvedUsers'] as List?)?.cast<String>() ??
            const <String>[];
        if (arr.contains(username)) return 'approved';
      } catch (_) {}

      // 2) requests/{username}
      try {
        final reqSnap = await partyRef.collection('requests').doc(username).get();
        final m = reqSnap.data();
        if (m == null) return null;
        final s = (m['status'] as String?)?.toString();
        if (s == 'approved' || s == 'declined' || s == 'pending') return s;
      } catch (_) {}

      return null;
    } catch (_) {
      return null;
    }
  }

  // =========================
  // ✅ RATING / REPORT / STREAMS
  // =========================
  Future<void> _setRating(String partyId, String username, String value) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final partySnap = await partyRef.get();
    final partyData = partySnap.data() ?? {};

    if (!_isInRatingWindow(partyData)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bewertung nur innerhalb von 24h ab Start möglich.")),
      );
      return;
    }

    // Eigenes User-Doc == authentifizierte UID (== Firestore-Doc-ID). NIE
    // doc(username): der Zähler-Write unten aktualisiert das User-DOKUMENT,
    // und die Rules erlauben das nur für auth.uid == docId — mit dem
    // Username-Key schlägt die Transaktion mit PERMISSION_DENIED fehl.
    final myDocId = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myDocId.isEmpty) return;
    final userRef = FirebaseFirestore.instance.collection('users').doc(myDocId);

    final userRatingRef = userRef.collection('partyRatings').doc(partyId);
    final partyRatingRef = partyRef.collection('ratings').doc(username);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final prevUserRating = await tx.get(userRatingRef);
        final prevVal = prevUserRating.data()?['value'] as String?;

        int deltaGood = 0, deltaBad = 0;
        if (value == 'good') deltaGood++;
        if (value == 'bad') deltaBad++;
        if (prevVal == 'good') deltaGood--;
        if (prevVal == 'bad') deltaBad--;

        tx.set(
          userRatingRef,
          {
            'partyId': partyId,
            'value': value,
            'ts': FieldValue.serverTimestamp(),
            'partyName': (partyData['name'] ?? '').toString(),
            'hostId': ((partyData['hostUid'] ?? partyData['hostId']) ?? '').toString(),
            'hostName': (partyData['hostName'] ?? '').toString(),
            'date': partyData['date'],
            'time': (partyData['time'] ?? '').toString(),
          },
          SetOptions(merge: true),
        );

        tx.set(
          partyRatingRef,
          {'username': username, 'value': value, 'ts': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );

        if (deltaGood != 0 || deltaBad != 0) {
          final userSnap = await tx.get(userRef);
          final currentGood = (userSnap.data()?['partyRatingsGood'] ?? 0) as int;
          final currentBad = (userSnap.data()?['partyRatingsBad'] ?? 0) as int;

          final newGood = currentGood + deltaGood;
          final newBad = currentBad + deltaBad;
          final total = newGood + newBad;
          final pct = total > 0 ? ((newGood / total) * 100).round() : 0;

          tx.set(
            userRef,
            {
              'partyRatingsGood': newGood,
              'partyRatingsBad': newBad,
              'partyRatingsPct': pct,
              'partyRatingsUpdatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value == 'good' ? "Bewertung gespeichert 👍" : "Bewertung gespeichert 👎")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Bewerten: $e")),
      );
    }
  }

  // ✅ REPORT: Dialog + Firestore
  Future<void> _sendReportDialog(String partyId) async {
    if (!mounted) return;

    final reasons = <String>[
      'Fake / Irreführend',
      'Gewalt / Gefahr',
      'Belästigung / Hass',
      'Spam / Werbung',
      'Sonstiges',
    ];

    String selected = reasons.first;
    final noteCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.report_gmailerrorred_rounded, color: AppColors.accent),
              SizedBox(width: 10),
              Text(
                'Party melden',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          content: StatefulBuilder(
            builder: (ctx, setSB) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Grund auswählen:',
                    style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: selected,
                    dropdownColor: AppColors.panel,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: AppColors.panel,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.accent),
                      ),
                    ),
                    items: reasons
                        .map((r) => DropdownMenuItem(
                      value: r,
                      child: Text(r, style: const TextStyle(color: Colors.white)),
                    ))
                        .toList(),
                    onChanged: (v) => setSB(() => selected = v ?? reasons.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Optional: kurze Info dazu…',
                      hintStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: AppColors.panel,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.accent),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen', style: TextStyle(color: AppColors.muted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Melden'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      noteCtrl.dispose();
      return;
    }

    final note = noteCtrl.text.trim();
    noteCtrl.dispose();

    await _createReportInFirestore(
      partyId: partyId,
      reason: selected,
      note: note,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Meldung wurde gesendet. Danke.'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _createReportInFirestore({
    required String partyId,
    required String reason,
    required String note,
  }) async {
    try {
      final reporter = (_currentUsername ?? '').trim();

      final data = _partyCache[partyId];
      final partyName = (data?['name'] ?? '').toString();
      final hostId = ((data?['hostUid'] ?? data?['hostId']) ?? '').toString();
      final hostName = (data?['hostName'] ?? '').toString();

      await FirebaseFirestore.instance.collection('Meldungen').add({
        'type': 'party',
        'partyId': partyId,
        'partyName': partyName,
        'hostId': hostId,
        'hostName': hostName,
        'reason': reason,
        'note': note,
        'reportedBy': reporter,
        'reportedAt': FieldValue.serverTimestamp(),
        'status': 'open',
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler beim Melden: $e')),
      );
    }
  }

  Future<bool> _userHasRated(String partyId, String username) async {
    // Eigenes User-Doc == authentifizierte UID (== Firestore-Doc-ID).
    // Muss denselben Key wie _setRating verwenden, sonst schlägt der
    // "schon bewertet?"-Check fehl.
    final myDocId = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (myDocId.isEmpty) return false;
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(myDocId)
        .collection('partyRatings')
        .doc(partyId)
        .get();
    return snap.exists;
  }

  Future<void> _maybePromptForRating() async {
    if (_ratingPromptShown || _currentUsername == null) return;

    for (final entry in _partyCache.entries) {
      final pid = entry.key;
      final data = entry.value;

      if (!_isInRatingWindow(data)) continue;

      final myRsvp = await FirebaseFirestore.instance
          .collection('Party')
          .doc(pid)
          .collection('rsvps')
          .doc(_currentUsername!)
          .get();

      final statusRaw = myRsvp.data()?['status'] as String?;
      final status = _normOpenStatus(statusRaw);

      if (status != 'going' && status != 'maybe') continue;

      final rated = await _userHasRated(pid, _currentUsername!);
      if (rated) continue;

      _ratingPromptShown = true;
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Wie war „${data['name'] ?? 'die Party'}“? Jetzt bewerten."),
          action: SnackBarAction(
            label: "ÖFFNEN",
            onPressed: () => _openPartySheet(data, pid),
          ),
        ),
      );
      break;
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _rsvpStream(String partyId) {
    if (_currentUsername == null) return null;
    return FirebaseFirestore.instance
        .collection('Party')
        .doc(partyId)
        .collection('rsvps')
        .doc(_currentUsername!)
        .snapshots();
  }

  Future<String?> _getSelectedCountryCode() async {
    final prefs = await SharedPreferences.getInstance();
    String? raw = prefs.getString('countryCode') ??
        prefs.getString('selectedCountryCode') ??
        prefs.getString('countryISO2') ??
        prefs.getString('country') ??
        prefs.getString('country_name');

    if (raw == null || raw.trim().isEmpty) return null;
    final v = raw.trim().toLowerCase();
    if (RegExp(r'^[a-z]{2}$').hasMatch(v)) return v;

    const map = {
      'österreich': 'at',
      'austria': 'at',
      'deutschland': 'de',
      'germany': 'de',
      'schweiz': 'ch',
      'switzerland': 'ch',
      'italien': 'it',
      'italy': 'it',
      'tschechien': 'cz',
      'czechia': 'cz',
      'czech republic': 'cz',
      'slowakei': 'sk',
      'slovakia': 'sk',
      'ungarn': 'hu',
      'hungary': 'hu',
    };
    return map[v];
  }

  void _openPartySheet(Map<String, dynamic> data, String partyId) async {
    final isClosed = _isClosedDoc(data);
    final isHost = _isHostForPartyData(data);

    DateTime? date;
    if (data['date'] is Timestamp) {
      date = (data['date'] as Timestamp).toLocalDateTime();
    }
    final formattedDate =
    date != null ? "${date.day}. ${_monthName(date.month)} ${date.year}" : "";

    bool baseCanSeeFull = !isClosed;
    if (isClosed) {
      baseCanSeeFull = isHost;
      if (!isHost && _currentUsername != null) {
        final st = await _myRequestStatus(partyId, _currentUsername!);
        baseCanSeeFull = st == 'approved';
      }
    }

    final inRatingWindow = _isInRatingWindow(data);

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => PartyBottomSheet(
        partyId: partyId,
        data: data,
        isClosed: isClosed,
        isHost: isHost,
        baseCanSeeFull: baseCanSeeFull,
        formattedDate: formattedDate,
        currentUsername: _currentUsername,
        inRatingWindow: inRatingWindow,
        isActive: _isActive(data),
        onSetRsvp: (status) => _setRsvpStatus(partyId, _currentUsername!, status),
        onClearRsvp: () => _clearRsvp(partyId, _currentUsername!),
        onSendJoinRequest: () => _sendJoinRequest(partyId, _currentUsername!),
        onUpdateRequestStatus: (u, s) => _updateRequestStatus(partyId, u, s),
        onSetRating: (val) => _setRating(partyId, _currentUsername!, val),
        onReport: () => _sendReportDialog(partyId), // ✅ EINGEBAUT
        rsvpStream: () => _rsvpStream(partyId),
        comingStream: () => FirebaseFirestore.instance
            .collection('Party')
            .doc(partyId)
            .collection('coming')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        maybeStream: () => FirebaseFirestore.instance
            .collection('Party')
            .doc(partyId)
            .collection('maybe')
            .orderBy('timestamp', descending: true)
            .snapshots(),
        ratingsStream: () => FirebaseFirestore.instance
            .collection('Party')
            .doc(partyId)
            .collection('ratings')
            .snapshots(),
        isUserVerified: _isUserVerified,
        recolorOpenMarker: (status) {
          final isHostForThis = _isHostForPartyData(data);
          _setOpenMarkerColor(partyId, status: status, isHost: isHostForThis);
        },
        setClosedLockIcon: (status) =>
            _setLockIconForPartyStatus(partyId, status: status),
        onEditedParty: () async {
          await _refreshMap();
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  void _openBarSheet(Map<String, dynamic> data, String barId) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BarBottomSheet(barId: barId, barData: data),
    );
  }

  Future<void> _setRsvpStatus(String partyId, String username, String status) async {
    status = _normOpenStatus(status) ?? status;

    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final rsvpRef = partyRef.collection('rsvps').doc(username);
    final comingRef = partyRef.collection('coming').doc(username);
    final maybeRef = partyRef.collection('maybe').doc(username);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
        rsvpRef,
        {'username': username, 'status': status, 'timestamp': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
      if (status == 'going') {
        tx.set(comingRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.delete(maybeRef);
      } else if (status == 'maybe') {
        tx.set(maybeRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.delete(comingRef);
      }
    });

    final data = _partyCache[partyId];
    final isHost = data != null && _isHostForPartyData(data);

    _openPartyStatus[partyId] = _normOpenStatus(status);
    _openPartyIsHost[partyId] = isHost;
    _setOpenMarkerColor(partyId, status: status, isHost: isHost);

    // Push-Benachrichtigung an den Host
    try {
      final partyName = (data?['name'] ?? 'Party').toString();
      final hostUsername =
          ((data?['hostId'] ?? data?['hostUid']) ?? '').toString().trim();
      if (hostUsername.isNotEmpty && hostUsername != username) {
        final normStatus = _normOpenStatus(status);
        await FirebaseFunctions.instanceFor(region: 'europe-west1')
            .httpsCallable('sendPushNotification')
            .call({
          'toUsername': hostUsername,
          'title': normStatus == 'going' ? '🎉 Neuer Gast' : '🤔 Vielleicht',
          'body': normStatus == 'going'
              ? '$username kommt zu deiner Party "$partyName"!'
              : '$username kommt vielleicht zu deiner Party "$partyName".',
          'data': {'partyId': partyId, 'type': 'rsvp_${normStatus ?? status}'},
        });
      }
    } catch (_) {} // best-effort
  }

  Future<void> _clearRsvp(String partyId, String username) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.delete(partyRef.collection('rsvps').doc(username));
      tx.delete(partyRef.collection('coming').doc(username));
      tx.delete(partyRef.collection('maybe').doc(username));
    });

    final data = _partyCache[partyId];
    final isHost = data != null && _isHostForPartyData(data);

    _openPartyStatus[partyId] = null;
    _openPartyIsHost[partyId] = isHost;
    _setOpenMarkerColor(partyId, status: null, isHost: isHost);
  }

  Future<void> _sendJoinRequest(String partyId, String username) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final reqRef = partyRef.collection('requests').doc(username);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
        reqRef,
        {'username': username, 'status': 'pending', 'timestamp': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    });

    // ✅ sofort orange setzen
    final data = _partyCache[partyId];
    final isHost = data != null && _isHostForPartyData(data);
    _openPartyStatus[partyId] = 'pending';
    _openPartyIsHost[partyId] = isHost;
    _setOpenMarkerColor(partyId, status: 'pending', isHost: isHost);

    // Push-Benachrichtigung an den Host
    try {
      final partyName = (data?['name'] ?? 'Party').toString();
      final hostUsername =
          ((data?['hostId'] ?? data?['hostUid']) ?? '').toString().trim();
      if (hostUsername.isNotEmpty && hostUsername != username) {
        await FirebaseFunctions.instanceFor(region: 'europe-west1')
            .httpsCallable('sendPushNotification')
            .call({
          'toUsername': hostUsername,
          'title': '🔔 Neue Beitrittsanfrage',
          'body': '$username möchte deiner Party "$partyName" beitreten.',
          'data': {'partyId': partyId, 'type': 'join_request'},
        });
      }
    } catch (_) {} // best-effort
  }

  Future<void> _updateRequestStatus(String partyId, String username, String status) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final reqRef = partyRef.collection('requests').doc(username);
    final apprRef = partyRef.collection('approved').doc(username);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
        reqRef,
        {'username': username, 'status': status, 'handledAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
      if (status == 'approved') {
        tx.set(apprRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.set(
          partyRef,
          {'approvedUsers': FieldValue.arrayUnion([username])},
          SetOptions(merge: true),
        );
      } else {
        tx.delete(apprRef);
        tx.set(
          partyRef,
          {'approvedUsers': FieldValue.arrayRemove([username])},
          SetOptions(merge: true),
        );
      }
    });

    // Push-Benachrichtigung an den anfragenden User
    try {
      final partyName = (_partyCache[partyId]?['name'] ?? 'Party').toString();
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('sendPushNotification')
          .call({
        'toUsername': username,
        'title': status == 'approved' ? '✅ Zugang genehmigt' : '❌ Anfrage abgelehnt',
        'body': status == 'approved'
            ? 'Du wurdest für "$partyName" zugelassen!'
            : 'Deine Anfrage für "$partyName" wurde abgelehnt.',
        'data': {'partyId': partyId, 'type': 'request_$status'},
      });
    } catch (_) {} // best-effort

    if (_currentUsername == username) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setLockIconForPartyStatus(partyId, status: status);
      });
    }
  }

  void _setLockIconForPartyStatus(String partyId, {required String? status}) {
    _closedPartyStatus[partyId] = status;

    final lockId = 'lock_$partyId';
    final hitId = 'hit_$partyId';

    final old = _getMarker(lockId);
    if (old == null) return;

    BitmapDescriptor icon;
    if (status == 'approved') {
      icon = _lockIconGreen ?? BitmapDescriptor.defaultMarker;
    } else if (status == 'declined') {
      icon = _lockIconRed ?? BitmapDescriptor.defaultMarker;
    } else {
      icon = _lockIconGrey ?? BitmapDescriptor.defaultMarker;
    }

    setState(() {
      _putMarker(Marker(
        markerId: MarkerId(lockId),
        position: old.position,
        icon: icon,
        anchor: const Offset(0.5, 0.5),
        zIndex: 10,
        consumeTapEvents: true,
        onTap: () => _openPartySheet(_partyCache[partyId]!, partyId),
      ));

      // hitbox sicherstellen (O(1)-Index statt O(N)-every)
      if (!_markerById.containsKey(hitId)) {
        _putMarker(Marker(
          markerId: MarkerId(hitId),
          position: old.position,
          icon: _hitboxIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          anchor: const Offset(0.5, 0.5),
          zIndex: 9,
          consumeTapEvents: true,
          onTap: () => _openPartySheet(_partyCache[partyId]!, partyId),
        ));
      }
    });
  }

  // =========================
  // ✅ ZOOM ICON UPDATE
  // =========================
  double _zoomToScale(double zoom) {
    final z = zoom.clamp(4.0, 18.0);
    final t = (z - 4.0) / (18.0 - 4.0);
    return 0.6 + 0.4 * t;
  }

  /// Perzeptueller Größen-Bucket für einen Zoom-Wert (~0.08-Skalenschritte).
  double _bucketForZoom(double zoom) => (_zoomToScale(zoom) / 0.08).round() * 0.08;

  Future<void> _onCameraIdle() async {
    final pos = _lastCameraPosition;
    if (pos == null) return;

    // Nur neu rendern, wenn sich die SICHTBARE Markergröße ändert. Früher
    // feuerte das bei jedem 0.5-Zoom-Schritt (Größenänderung ~1.4% =
    // unsichtbar) und löste trotzdem 13 PNG-Encodes + Marker-Rebuild aus.
    final bucket = _bucketForZoom(pos.zoom);
    if (bucket == _iconScaleBucket) return;
    if (_isUpdatingZoomIcons) return;

    _isUpdatingZoomIcons = true;
    _iconScaleBucket = bucket;
    try {
      await _updateCustomMarkerSizesForZoom(bucket);
    } finally {
      _isUpdatingZoomIcons = false;
    }
  }

  Future<void> _updateCustomMarkerSizesForZoom(double bucket) async {
    // Cache-Hit: Icons für diese Größe schon erzeugt → nur zuweisen, KEIN
    // erneutes PNG-Encoding (der teuerste Teil). Nur Marker-Rebuild.
    final cached = _zoomIconCache[bucket];
    if (cached != null) {
      _assignZoomIcons(cached);
      _rebuildMarkersWithNewIcons();
      return;
    }

    final scale = bucket.clamp(0.55, 1.0);
    final lockDiameter = (_lockBaseDiameter * scale).round();
    final friendsDiameter = (_friendsBaseDiameter * scale).round();
    final hitDiameter = (_hitBaseDiameter * scale).round();

    Future<BitmapDescriptor> icon(Color c, IconData i, int d) async =>
        BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
          diameter: d,
          circleColor: c,
          icon: i,
          iconColor: Colors.white,
          iconScale: .60,
        ));
    Future<BitmapDescriptor> party(Color c) async =>
        BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
          diameter: lockDiameter,
          circleColor: c,
          emoji: "🎉",
          emojiColor: Colors.white,
          emojiScale: .62,
        ));

    const lock = Icons.lock_rounded;
    const people = Icons.people_alt_rounded;

    final icons = <String, BitmapDescriptor>{
      'lockBlue': await icon(const Color(0xFF1976D2), lock, lockDiameter),
      'lockGrey': await icon(const Color(0xFF424242), lock, lockDiameter),
      'lockGreen': await icon(const Color(0xFF2E7D32), lock, lockDiameter),
      'lockRed': await icon(const Color(0xFFD32F2F), lock, lockDiameter),
      'hitbox': BitmapDescriptor.fromBytes(
          await _drawTransparentCircle(diameter: hitDiameter)),
      'friendsOnly': await icon(const Color(0xFF6A1B9A), people, friendsDiameter),
      'friendsBlue': await icon(const Color(0xFF1976D2), people, friendsDiameter),
      'friendsGreen': await icon(const Color(0xFF2E7D32), people, friendsDiameter),
      'friendsOrange':
          await icon(const Color(0xFFF57C00), people, friendsDiameter),
      'partyBlue': await party(const Color(0xFF1976D2)),
      'partyGreen': await party(const Color(0xFF2E7D32)),
      'partyOrange': await party(const Color(0xFFF57C00)),
      'partyRed': await party(const Color(0xFFD32F2F)),
    };

    _zoomIconCache[bucket] = icons;
    _assignZoomIcons(icons);
    _rebuildMarkersWithNewIcons();
  }

  /// Weist die gecachten Zoom-Icons den Feldern zu (kein Encoding).
  void _assignZoomIcons(Map<String, BitmapDescriptor> m) {
    _lockIconBlue = m['lockBlue'];
    _lockIconGrey = m['lockGrey'];
    _lockIconGreen = m['lockGreen'];
    _lockIconRed = m['lockRed'];
    _hitboxIcon = m['hitbox'];
    _friendsOnlyIcon = m['friendsOnly'];
    _friendsIconBlue = m['friendsBlue'];
    _friendsIconGreen = m['friendsGreen'];
    _friendsIconOrange = m['friendsOrange'];
    _friendsIconPurple = m['friendsOnly'];
    _partyIconBlue = m['partyBlue'];
    _partyIconGreen = m['partyGreen'];
    _partyIconOrange = m['partyOrange'];
    _partyIconRed = m['partyRed'];
  }

  void _rebuildMarkersWithNewIcons() {
    final newMarkers = <Marker>{};

    for (final m in _markers) {
      final id = m.markerId.value;

      if (id.startsWith('lock_')) {
        newMarkers.add(Marker(
          markerId: m.markerId,
          position: m.position,
          icon: _iconForLockMarker(id),
          anchor: m.anchor,
          zIndex: m.zIndex,
          consumeTapEvents: m.consumeTapEvents,
          onTap: m.onTap,
          infoWindow: m.infoWindow,
        ));
      } else if (id.startsWith('hit_')) {
        newMarkers.add(Marker(
          markerId: m.markerId,
          position: m.position,
          icon: _hitboxIcon ?? m.icon,
          anchor: m.anchor,
          zIndex: m.zIndex,
          consumeTapEvents: m.consumeTapEvents,
          onTap: m.onTap,
          infoWindow: m.infoWindow,
        ));
      } else if (_isFriendsOnlyMarker(id)) {
        newMarkers.add(Marker(
          markerId: m.markerId,
          position: m.position,
          icon: _iconForFriendsPartyMarker(id),
          onTap: m.onTap,
          infoWindow: m.infoWindow,
          anchor: m.anchor,
          zIndex: m.zIndex,
          consumeTapEvents: m.consumeTapEvents,
        ));
      } else if (_partyCache.containsKey(id) &&
          !_isClosedDoc(_partyCache[id]!) &&
          !_isFriendsOnlyMarker(id)) {
        newMarkers.add(Marker(
          markerId: m.markerId,
          position: m.position,
          icon: _iconForOpenPartyMarker(id),
          onTap: m.onTap,
          infoWindow: m.infoWindow,
          anchor: m.anchor,
          zIndex: m.zIndex,
          consumeTapEvents: m.consumeTapEvents,
        ));
      } else {
        newMarkers.add(m);
      }
    }

    setState(() {
      // Beide Strukturen atomar aus derselben Quelle (newMarkers) neu
      // befüllen → garantierte Konsistenz. newMarkers hat eindeutige ids.
      _markers
        ..clear()
        ..addAll(newMarkers);
      _markerById
        ..clear()
        ..addEntries(newMarkers.map((m) => MapEntry(m.markerId.value, m)));
    });
  }

  bool _isFriendsOnlyMarker(String markerId) {
    final data = _partyCache[markerId];
    if (data == null) return false;
    final visibility = (data['visibility'] ?? 'public').toString();
    return visibility == 'friends' && !_isClosedDoc(data);
  }

  BitmapDescriptor _iconForLockMarker(String lockMarkerId) {
    final partyId = lockMarkerId.replaceFirst('lock_', '');
    final data = _partyCache[partyId];
    if (data == null) return _lockIconGrey ?? BitmapDescriptor.defaultMarker;

    final isHost = _isHostForPartyData(data);
    if (isHost) return _lockIconBlue ?? BitmapDescriptor.defaultMarker;

    if (_isBarAccount) return _lockIconGrey ?? BitmapDescriptor.defaultMarker;

    final status = _closedPartyStatus[partyId];
    if (status == 'approved') return _lockIconGreen ?? BitmapDescriptor.defaultMarker;
    if (status == 'declined') return _lockIconRed ?? BitmapDescriptor.defaultMarker;
    return _lockIconGrey ?? BitmapDescriptor.defaultMarker;
  }

  // =========================
  // ✅ FILTER SHEET
  // =========================
  Future<void> _openFilterSheet() async {
    bool showParties = _showParties;
    bool showBars = _showBars;
    bool showFestln = _showFestln;
    bool onlyFree = _onlyFree;
    int? minAge = _minAgeFilter;
    double? maxEntry = _maxEntryFilter;
    bool onlyOpen = _onlyOpenParties;
    bool onlyClosed = _onlyClosedParties;
    TimeRangeFilter timeRange = _timeRange;
    double? radius = _radiusKm;

    // Lokale Slider-Werte (falls gerade "Kein Limit" aktiv, trotzdem einen sinnvollen Wert merken)
    double sliderAge    = (minAge   ?? 18).toDouble();
    double sliderEntry  = (maxEntry ?? 20.0);
    double sliderRadius = (radius   ?? 25.0);

    final result = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSB) {
          void turnOff() {
            if (!showParties) {
              onlyOpen = false; onlyClosed = false;
              onlyFree = false; minAge = null; maxEntry = null;
            }
          }

          void applyAndClose() {
            bool fo = onlyOpen, fc = onlyClosed, ff = onlyFree;
            int? fa = minAge;
            double? fe = maxEntry;
            if (!showParties) { fo = false; fc = false; ff = false; fa = null; fe = null; }
            if (fo && fc) fc = false;
            Navigator.of(ctx).pop(<String, dynamic>{
              'showParties': showParties, 'showBars': showBars,
              'showFestln': showFestln,
              'onlyFree': ff, 'minAge': fa, 'maxEntry': fe,
              'onlyOpen': fo, 'onlyClosed': fc,
              'radiusKm': radius, 'timeRange': timeRange.prefValue,
              'reset': false,
            });
          }

          // ── Slider-Box ────────────────────────────────────────────────
          // hasLimit=true  → Slider aktiv, Wert anzeigen
          // hasLimit=false → "Kein Limit" aktiv, Slider versteckt
          Widget sliderBox({
            required String label,
            required bool hasLimit,
            required double sliderVal,
            required double min,
            required double max,
            required int divisions,
            required bool enabled,
            required String Function(double) valueFmt,
            required void Function(double) onSlide,
            required void Function() onActivate,   // Kein Limit → Limit
            required void Function() onDeactivate, // Limit → Kein Limit
          }) {
            final active = hasLimit;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color: const Color(0xFF181818),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active && enabled ? _accent.withOpacity(0.45) : Colors.white12,
                  width: active && enabled ? 1.5 : 1,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: enabled
                        ? () => setSB(() => active ? onDeactivate() : onActivate())
                        : null,
                    child: Row(children: [
                      Text(label, style: TextStyle(
                        color: enabled ? Colors.white54 : Colors.white24,
                        fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: .8,
                      )),
                      const Spacer(),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: active && enabled
                              ? _accent.withOpacity(0.15)
                              : Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: active && enabled ? _accent : Colors.white24,
                            width: active && enabled ? 1.5 : 1,
                          ),
                        ),
                        child: Text(
                          active ? valueFmt(sliderVal) : "Kein Limit",
                          style: TextStyle(
                            color: active && enabled ? _accent : Colors.white38,
                            fontSize: 12, fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ]),
                  ),
                  if (active) ...[
                    const SizedBox(height: 2),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        activeTrackColor: _accent,
                        thumbColor: _accent,
                        inactiveTrackColor: Colors.white12,
                        overlayColor: _accent.withOpacity(0.15),
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                      ),
                      child: Slider(
                        value: sliderVal.clamp(min, max),
                        min: min,
                        max: max,
                        divisions: divisions,
                        // Kein TweenAnimationBuilder → Finger geht direkt mit
                        onChanged: enabled ? (v) => setSB(() => onSlide(v)) : null,
                      ),
                    ),
                  ],
                ],
              ),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                child: Row(children: const [
                  Icon(Icons.filter_list_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text("Filter", style: TextStyle(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800,
                  )),
                ]),
              ),
              // ── Scrollbarer Inhalt ───────────────────────────────────
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── TIME_RANGE_FILTER ──────────────────────────
                      // Bewusst Chips statt eines weiteren Sliders: die
                      // Sheet hat schon drei Slider-Boxen, und die
                      // Zeiträume sind diskrete Wahlmöglichkeiten.
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          "ZEITRAUM",
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .6,
                          ),
                        ),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in TimeRangeFilter.values)
                            ChoiceChip(
                              label: Text(r.label),
                              selected: timeRange == r,
                              onSelected: (_) => setSB(() => timeRange = r),
                              showCheckmark: false,
                              labelStyle: TextStyle(
                                color: timeRange == r
                                    ? Colors.white
                                    : AppColors.muted,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                              backgroundColor: AppColors.panel,
                              selectedColor: AppColors.accent,
                              side: BorderSide(
                                color: timeRange == r
                                    ? AppColors.accent
                                    : AppColors.accentBorder,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),

                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Divider(color: Colors.white12, height: 1),
                      ),

                      _filterToggle("Partys anzeigen", showParties,
                          (v) => setSB(() { showParties = v; turnOff(); })),
                      const SizedBox(height: 4),
                      _filterToggle("Nur offene Partys", onlyOpen,
                          showParties ? (v) => setSB(() { onlyOpen = v; if (v) onlyClosed = false; }) : null),
                      const SizedBox(height: 4),
                      _filterToggle("Nur geschlossene Partys", onlyClosed,
                          showParties ? (v) => setSB(() { onlyClosed = v; if (v) onlyOpen = false; }) : null),
                      const SizedBox(height: 4),
                      _filterToggle("Bars anzeigen", showBars,
                          (v) => setSB(() => showBars = v)),
                      const SizedBox(height: 4),
                      _filterToggle("Festln anzeigen", showFestln,
                          (v) => setSB(() => showFestln = v)),
                      const SizedBox(height: 4),
                      _filterToggle("Nur gratis Partys", onlyFree,
                          showParties ? (v) => setSB(() {
                            onlyFree = v;
                            if (v) { maxEntry = 0.0; sliderEntry = 0.0; }
                            else if (maxEntry == 0.0) { maxEntry = null; }
                          }) : null),

                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 18),
                        child: Divider(color: Colors.white12, height: 1),
                      ),

                      // Mindestalter
                      sliderBox(
                        label: "MINDESTALTER",
                        hasLimit: minAge != null,
                        sliderVal: sliderAge,
                        min: 14, max: 30, divisions: 16,
                        enabled: showParties,
                        valueFmt: (v) => "${v.toInt()}+",
                        onSlide: (v) { sliderAge = v; minAge = v.toInt(); },
                        onActivate: () { minAge = sliderAge.toInt(); },
                        onDeactivate: () { minAge = null; },
                      ),
                      const SizedBox(height: 12),

                      // Max. Eintritt
                      sliderBox(
                        label: "MAX. EINTRITT",
                        hasLimit: maxEntry != null,
                        sliderVal: sliderEntry,
                        min: 0, max: 100, divisions: 20,
                        enabled: showParties,
                        valueFmt: (v) => v == 0 ? "Gratis" : "≤ ${v.toInt()} €",
                        onSlide: (v) {
                          sliderEntry = v; maxEntry = v;
                          onlyFree = (v == 0);
                        },
                        onActivate: () { maxEntry = sliderEntry; onlyFree = (sliderEntry == 0); },
                        onDeactivate: () { maxEntry = null; onlyFree = false; },
                      ),
                      const SizedBox(height: 12),

                      // Umkreis
                      sliderBox(
                        label: "UMKREIS${_currentCity.isNotEmpty ? '  –  ${_currentCity.toUpperCase()}' : ''}",
                        hasLimit: radius != null,
                        sliderVal: sliderRadius,
                        min: 1, max: 100, divisions: 99,
                        enabled: true,
                        valueFmt: (v) => "≤ ${v.toInt()} km",
                        onSlide: (v) { sliderRadius = v; radius = v; },
                        onActivate: () { radius = sliderRadius; },
                        onDeactivate: () { radius = null; },
                      ),

                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              // ── Sticky Buttons ───────────────────────────────────────
              Container(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.white12)),
                ),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white54,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(<String, dynamic>{'reset': true}),
                      child: const Text("Zurücksetzen", style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      onPressed: applyAndClose,
                      child: const Text("Übernehmen", style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15,
                      )),
                    ),
                  ),
                ]),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;

    if (result['reset'] == true) {
      setState(() {
        _showParties = true;
        _showBars = true;
        _showFestln = true;
        _onlyFree = false;
        _minAgeFilter = null;
        _maxEntryFilter = null;
        _onlyOpenParties = false;
        _onlyClosedParties = false;
        _radiusKm = 25.0;
        _timeRange = TimeRangeFilter.next14Days;
      });
      await _saveFilterPrefs();
      await _refreshMap();
      if (mounted) await _showCenterSuccess("Filter zurückgesetzt");
      return;
    }

    setState(() {
      _showParties = result['showParties'] as bool? ?? _showParties;
      _showBars = result['showBars'] as bool? ?? _showBars;
      _showFestln = result['showFestln'] as bool? ?? _showFestln;
      _onlyFree = result['onlyFree'] as bool? ?? _onlyFree;
      _minAgeFilter = result['minAge'] as int?;
      _maxEntryFilter = result['maxEntry'] as double?;
      _onlyOpenParties = result['onlyOpen'] as bool? ?? _onlyOpenParties;
      _onlyClosedParties = result['onlyClosed'] as bool? ?? _onlyClosedParties;
      _radiusKm = result['radiusKm'] as double?;
      _timeRange = TimeRangeFilter.fromPref(result['timeRange'] as String?);

      if (!_showParties) {
        _onlyOpenParties = false;
        _onlyClosedParties = false;
        _onlyFree = false;
        _minAgeFilter = null;
        _maxEntryFilter = null;
      }
      if (_onlyOpenParties && _onlyClosedParties) _onlyClosedParties = false;
    });

    await _saveFilterPrefs();
    await _refreshMap();
  }

  // =========================
  // ✅ UI
  // =========================
  @override
  Widget build(BuildContext context) {
    if (_startPos == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppColors.bgTop,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Map fullscreen ──────────────────────────────────────────────
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _startPos!,
              markers: _markers,
              circles: _circles,
              padding: EdgeInsets.only(top: topPad + 130, bottom: 80),
              // Kein Gerätestandort: kein blauer Punkt, kein MyLocation-Button,
              // keine Runtime-Permission. Karte nutzt nur die gewählte Stadt
              // (selectedLat/Lng) als Startkamera.
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              onMapCreated: (controller) async {
                mapController = controller;
                try {
                  await controller.setMapStyle(_mapStyleHidePublicPois);
                } catch (_) {}
              },
              onCameraMove: (pos) => _lastCameraPosition = pos,
              onCameraIdle: _onCameraIdle,
            ),
          ),

          // ── Top gradient fade ───────────────────────────────────────────
          Positioned(
            top: 0, left: 0, right: 0,
            height: topPad + 140,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.bgTop.withValues(alpha: 0.92),
                    AppColors.bgTop.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),

          // ── Top row: menu + title + profile ────────────────────────────
          Positioned(
            top: topPad + 10,
            left: 14,
            right: 14,
            child: Row(
              children: [
                // Menu button
                _FloatingMapButton(
                  icon: Icons.menu_rounded,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MenuScreen()),
                  ),
                ),
                const SizedBox(width: 10),
                // Filter button
                _FloatingMapButton(
                  icon: Icons.tune_rounded,
                  onTap: _openFilterSheet,
                ),
                const Spacer(),
                // Title pill
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.panel.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.accentBorder2, width: 1),
                  ),
                  child: Text(
                    "PartyPin",
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const Spacer(),
                // Reload button
                _FloatingMapButton(
                  icon: Icons.refresh_rounded,
                  loading: _isReloading,
                  onTap: _isReloading ? null : _reload,
                ),
                const SizedBox(width: 10),
                // Profile button mit Profilbild
                GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfileSettingsScreen()),
                  ),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.accentBorder2,
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: profileImageUrl != null &&
                          profileImageUrl!.isNotEmpty
                          ? Image.network(
                        profileImageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: AppColors.panel,
                          child: const Icon(
                            Icons.person_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      )
                          : Container(
                        color: AppColors.panel,
                        child: const Icon(
                          Icons.person_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Search bar ──────────────────────────────────────────────────
          Positioned(
            left: 14,
            right: 14,
            top: topPad + 62,
            child: _SearchCard(
              controller: _searchCtrl,
              onSearch: (input) async {
                final query = input.trim();
                if (query.isEmpty) return;

                final cc = await _getSelectedCountryCode();
                final withCity = "$query, ${_currentCity.trim().isNotEmpty ? _currentCity.trim() : 'Wien'}";

                GeocodedLocation? location = await GeocodingService.getLocationFromAddress(withCity, countryCode: cc);
                location ??= await GeocodingService.getLocationFromAddress(query, countryCode: cc);

                if (!mounted) return;
                if (location != null) {
                  mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(LatLng(location.latitude, location.longitude), 19),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Adresse nicht gefunden."),
                      backgroundColor: AppColors.accent,
                    ),
                  );
                }
              },
              onClear: () => _searchCtrl.clear(),
            ),
          ),

          // ── City Mood Strip (Phase 4) ───────────────────────────────────
          // Slimme atmosphärische Mood-Pillen direkt unter der Search-Bar.
          // Auto-Hide wenn _cityMood.level == quiet. Komplett aus bereits
          // geladenen Party-Daten abgeleitet — keine extra Reads.
          if (_cityMood.isVisible)
            Positioned(
              left: 0,
              right: 0,
              top: topPad + 116,
              child: CityMoodStrip(mood: _cityMood),
            ),

          // ── Trending-Hosts-Pills ────────────────────────────────────────
          // Slim horizontale Pills unter Mood-Strip (wenn vorhanden) bzw.
          // direkt unter der Search-Bar. Auto-Hide wenn keine Trending-Hosts.
          // Tap → öffnet User-Profile mit voller HostStatsCard.
          Positioned(
            left: 0,
            right: 0,
            top: topPad + (_cityMood.isVisible ? 150 : 116),
            child: TrendingHostsPills(
              onTapHost: (username) {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => UserProfileScreen(username: username),
                ));
              },
            ),
          ),
        ],
      ),
    );
  }


  Future<void> _showCenterSuccess(String text) async {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    late OverlayEntry entry;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 140),
    );

    final fade = CurvedAnimation(parent: controller, curve: Curves.easeOut);
    final scale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOutBack),
    );

    entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: FadeTransition(
              opacity: fade,
              child: ScaleTransition(
                scale: scale,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101318).withOpacity(0.96),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.45),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent,
                        ),
                        child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    await controller.forward();
    await Future.delayed(const Duration(milliseconds: 1050));
    if (mounted) {
      await controller.reverse();
      entry.remove();
    }
    controller.dispose();
  }

  Future<void> _reload() async {
    if (_isReloading) return;
    setState(() => _isReloading = true);
    try {
      await _refreshMap();
      if (mounted) await _showCenterSuccess("Karte aktualisiert");
    } finally {
      if (mounted) setState(() => _isReloading = false);
    }
  }

  static Widget _filterToggle(String label, bool value, void Function(bool)? onChanged) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      value: value,
      onChanged: onChanged,
      activeColor: _accent,
      title: Text(label, style: TextStyle(
        color: onChanged != null ? Colors.white : Colors.white38,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      )),
    );
  }
}

class _SearchCard extends StatelessWidget {
  final TextEditingController controller;
  final Future<void> Function(String) onSearch;
  final VoidCallback onClear;

  const _SearchCard({
    required this.controller,
    required this.onSearch,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    // TextField is passed as child so it is built once and never rebuilt
    // when text changes — preserving the IME connection for umlauts (ü/ä/ö).
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      child: Expanded(
        child: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.text, fontSize: 14),
          textInputAction: TextInputAction.search,
          onSubmitted: onSearch,
          decoration: const InputDecoration(
            hintText: "Adresse suchen...",
            hintStyle: TextStyle(color: AppColors.subtle, fontSize: 14),
            border: InputBorder.none,
            isDense: true,
          ),
        ),
      ),
      builder: (context, value, child) {
        final hasText = value.text.trim().isNotEmpty;
        return Container(
          height: 46,
          decoration: BoxDecoration(
            color: AppColors.panelAlt,
            borderRadius: AppRadius.smBr,
            border: Border.all(
              color: hasText ? AppColors.accentBorder3 : AppColors.accentBorder,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              const Icon(Icons.search_rounded, color: AppColors.subtle, size: 20),
              const SizedBox(width: 8),
              child!,
              if (hasText)
                GestureDetector(
                  onTap: onClear,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(Icons.close_rounded, color: AppColors.subtle, size: 18),
                  ),
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }
}

// ── Floating map button ─────────────────────────────────────────────────────

class _FloatingMapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool loading;

  const _FloatingMapButton({
    required this.icon,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.panel.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accentBorder.withValues(alpha: 0.6)),
          boxShadow: const [
            BoxShadow(color: Color(0x33000000), blurRadius: 10, offset: Offset(0, 4)),
          ],
        ),
        child: loading
            ? const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
                ),
              )
            : Icon(icon, color: AppColors.muted, size: 20),
      ),
    );
  }
}

/// Hilfs-Datenklasse für die parallele Bar-Marker-Generierung in
/// `_loadBarsFromFirebase()`. Sammelt alle Eingabewerte, damit Icons in
/// einem `Future.wait` gebatcht erzeugt werden können statt sequenziell.
class _BarMarkerJob {
  const _BarMarkerJob({
    required this.docId,
    required this.data,
    required this.pos,
    required this.name,
    required this.imageUrl,
    required this.hasEvent,
    required this.iconKey,
  });

  final String docId;
  final Map<String, dynamic> data;
  final LatLng pos;
  final String name;
  final String imageUrl;
  final bool hasEvent;
  final String iconKey;
}
