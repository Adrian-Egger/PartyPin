// lib/Screens/party_map_screen.dart
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../Screens/menu_screen.dart';
import '../Screens/profil_settings_screen.dart';
import '../Services/geocoding_services.dart';
import '../Social/friends_model.dart';
import '../Screens/bar_bottom_sheet.dart';
import '../widgets/party_bottom_sheet.dart';

class PartyMapScreen extends StatefulWidget {
  final String? initialOpenPartyId;

  const PartyMapScreen({super.key, this.initialOpenPartyId});

  @override
  State<PartyMapScreen> createState() => _PartyMapScreenState();
}

class _PartyMapScreenState extends State<PartyMapScreen>
    with SingleTickerProviderStateMixin {
  // Farbschema
  static const _bgTop = Color(0xFF0E0F12);
  static const _bgBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF1C1F26);
  static const _text = Colors.white;
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);

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

  // ✅ Event-Zeitraum (Bars)
  static const int _barEventDaysBefore = 7;
  static const int _barEventHoursAfter = 24;

  GoogleMapController? mapController;
  CameraPosition? _startPos;

  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  final Map<String, Map<String, dynamic>> _partyCache = {};

  // Bar-Marker-Icons cachen
  final Map<String, BitmapDescriptor> _barIconCache = {};
  final Map<String, BitmapDescriptor> _barIconEventRingCache = {};

  String _currentCity = "";
  double _currentLat = 48.2082;
  double _currentLng = 16.3738;

  String? _currentUsername;
  String? _currentFullName;

  bool _isBarAccount = false;
  String? _barId;

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

  final Map<String, bool> _verifiedCache = {};
  bool _ratingPromptShown = false;
  bool _legalWarnDismissed = false;
  bool _isReloading = false;

  // ----- Filter-State -----
  bool _showParties = true;
  bool _showBars = true;
  int? _minAgeFilter;
  double? _maxEntryFilter;
  bool _onlyFree = false;

  // Party-Typ Filter
  bool _onlyClosedParties = false;
  bool _onlyOpenParties = false;

  // Suche
  final TextEditingController _searchCtrl = TextEditingController();

  // FriendsModel + Cache meiner Freunde
  final FriendsModel _friendsModel = FriendsModel();
  Set<String> _myFriendsSet = {};

  // Zoom-State
  double _currentZoom = 13;
  CameraPosition? _lastCameraPosition;
  bool _isUpdatingZoomIcons = false;

  // Status-Cache für geschlossene Partys
  final Map<String, String?> _closedPartyStatus = {};

  // Status-Cache für offene Partys
  final Map<String, String?> _openPartyStatus = {};
  final Map<String, bool> _openPartyIsHost = {};

  // =========================
  // ✅ PREMIUM (Firestore live)
  // =========================
  bool _isPremium = false;
  StreamSubscription? _premiumSub;

  bool _premiumWelcomeDialogOpen = false;
  static const String _prefsSeenPremiumWelcomeKey = 'seen_premium_welcome_v1';
  static const String _prefsLastPremiumStateKey = 'last_premium_state_v1';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _premiumSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _loadSavedLocation();
    await _loadCurrentUser();
    await _bindPremiumStatusFromFirestore();
    await _loadLegalWarnState();
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

  double _searchTop(BuildContext ctx) => 8;

  String _safeDocId(String input) => input
      .trim()
      .replaceAll('/', '_')
      .replaceAll('#', '_')
      .replaceAll('?', '_');

  String _safeUserDocId(String input) => _safeDocId(input);

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
      _currentZoom = 12;
    });
  }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final uname =
    (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '')
        .trim();
    final vorname = (prefs.getString('vorname') ?? '').trim();
    final nachname = (prefs.getString('nachname') ?? '').trim();
    final fullName = ('$vorname $nachname').trim();

    final isBar = prefs.getBool('isBarAccount') ?? false;
    final barId = prefs.getString('barId');

    if (!mounted) return;
    setState(() {
      _currentUsername = uname.isEmpty ? null : uname;
      _currentFullName = fullName.isEmpty ? null : fullName;
      _isBarAccount = isBar;
      _barId = barId;
    });

    if (_isBarAccount) {
      _myFriendsSet = {};
      return;
    }

    if (_currentUsername != null && _currentUsername!.isNotEmpty) {
      try {
        final list = await _friendsModel.myFriends(_currentUsername!);
        _myFriendsSet = list.toSet();
      } catch (_) {
        _myFriendsSet = {};
      }
    }
  }

  // =========================
  // ✅ PREMIUM: Firestore binden + Welcome
  // =========================
  Future<void> _bindPremiumStatusFromFirestore() async {
    _premiumSub?.cancel();

    final prefs = await SharedPreferences.getInstance();
    final uname =
    (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '')
        .trim();

    if (uname.isEmpty) {
      if (!mounted) return;
      setState(() => _isPremium = false);
      return;
    }

    final fs = FirebaseFirestore.instance;

    final directRef = fs.collection('users').doc(_safeUserDocId(uname));
    try {
      final directSnap = await directRef.get();
      if (directSnap.exists) {
        final initial = (directSnap.data()?['premium'] == true);
        if (mounted) setState(() => _isPremium = initial);

        await _maybeShowPremiumWelcomeIfNeeded(initial);

        _premiumSub = directRef.snapshots().listen((snap) async {
          final p = (snap.data()?['premium'] == true);
          if (!mounted) return;
          setState(() => _isPremium = p);
          await _maybeShowPremiumWelcomeIfNeeded(p);
        });
        return;
      }
    } catch (_) {}

    final q =
    fs.collection('users').where('username', isEqualTo: uname).limit(1);

    try {
      final qs = await q.get();
      final p =
      qs.docs.isNotEmpty ? (qs.docs.first.data()['premium'] == true) : false;
      if (mounted) setState(() => _isPremium = p);
      await _maybeShowPremiumWelcomeIfNeeded(p);
    } catch (_) {
      if (mounted) setState(() => _isPremium = false);
    }

    _premiumSub = q.snapshots().listen((qs) async {
      final p =
      qs.docs.isNotEmpty ? (qs.docs.first.data()['premium'] == true) : false;
      if (!mounted) return;
      setState(() => _isPremium = p);
      await _maybeShowPremiumWelcomeIfNeeded(p);
    });
  }

  Future<void> _maybeShowPremiumWelcomeIfNeeded(bool currentPremium) async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getBool(_prefsLastPremiumStateKey) ?? false;

    await prefs.setBool(_prefsLastPremiumStateKey, currentPremium);

    if (!currentPremium) return;
    if (last == true) return;

    final seen = prefs.getBool(_prefsSeenPremiumWelcomeKey) ?? false;
    if (seen) return;

    if (!mounted) return;
    if (_premiumWelcomeDialogOpen) return;

    _premiumWelcomeDialogOpen = true;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF141A22),
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.workspace_premium, color: Colors.amber),
              SizedBox(width: 10),
              Text(
                "Premium aktiviert",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          content: const Text(
            "Du bist jetzt ein Premium-Mitglied.\nHerzlichen Glückwunsch und viel Spaß!",
            style: TextStyle(
              color: Colors.white70,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("OK"),
            ),
          ],
        );
      },
    );

    await prefs.setBool(_prefsSeenPremiumWelcomeKey, true);
    _premiumWelcomeDialogOpen = false;
  }

  // =========================

  Future<void> _loadLegalWarnState() async {
    final prefs = await SharedPreferences.getInstance();
    if (_isBarAccount) {
      if (!mounted) return;
      setState(() {
        _legalWarnDismissed = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _legalWarnDismissed = prefs.getBool('legalWarnDismissed_v1') ?? false;
    });
  }

  Future<void> _dismissLegalWarn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('legalWarnDismissed_v1', true);
    if (mounted) setState(() => _legalWarnDismissed = true);
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

    if (mounted) setState(() {});
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
    return _createBarMarkerIconWithRing(
      imageUrl: imageUrl,
      ringColor: Colors.white,
      ringWidth: 4,
      outerPadding: 0,
    );
  }

  Future<BitmapDescriptor> _createBarMarkerIconWithGreenRing(
      String? imageUrl) async {
    return _createBarMarkerIconWithRing(
      imageUrl: imageUrl,
      ringColor: Colors.greenAccent,
      ringWidth: 6,
      outerPadding: 0,
    );
  }

  Future<BitmapDescriptor> _createBarMarkerIconWithRing({
    required String? imageUrl,
    required Color ringColor,
    required double ringWidth,
    required double outerPadding,
  }) async {
    final int diameter = _barBaseDiameter;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = ui.Size(diameter.toDouble(), diameter.toDouble());
    final center = Offset(size.width / 2, size.height / 2);

    final outerRadius = (diameter / 2).toDouble() - outerPadding;

    canvas.drawCircle(
      center,
      outerRadius,
      Paint()..color = _panel,
    );

    final imageRadius = outerRadius - ringWidth;

    if (imageUrl != null && imageUrl.trim().isNotEmpty) {
      try {
        final uri = Uri.parse(imageUrl);
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final bytes = resp.bodyBytes;
          final ui.Codec codec = await ui.instantiateImageCodec(
            bytes,
            targetWidth: diameter,
            targetHeight: diameter,
          );
          final ui.FrameInfo frameInfo = await codec.getNextFrame();
          final ui.Image image = frameInfo.image;

          final srcRect = Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          );
          final dstRect = Rect.fromCircle(center: center, radius: imageRadius);

          canvas.save();
          canvas.clipPath(Path()..addOval(dstRect));
          canvas.drawImageRect(image, srcRect, dstRect, Paint());
          canvas.restore();
        }
      } catch (_) {}
    } else {
      canvas.drawCircle(
        center,
        imageRadius,
        Paint()..color = const Color(0xFF2A2F3A),
      );
    }

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..color = ringColor
      ..isAntiAlias = true;

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
      dt = raw.toDate();
    } else if (raw is String) {
      dt = DateTime.tryParse(raw);
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

  DateTime? _partyStart(Map<String, dynamic> d) {
    DateTime? base;
    final v = d['date'];
    if (v is Timestamp) {
      base = v.toDate();
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
    final mid = partyId;
    final existing = _markers.where((m) => m.markerId.value == mid).toList();
    if (existing.isEmpty) return;
    final old = existing.first;

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
      _markers.removeWhere((m) => m.markerId.value == mid);
      _markers.add(Marker(
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

  Future<void> _refreshMap() async {
    _partyCache.clear();
    _markers.clear();
    _circles.clear();
    _closedPartyStatus.clear();
    _openPartyStatus.clear();
    _openPartyIsHost.clear();

    await _loadPartiesFromFirebase();
    await _loadBarsFromFirebase();

    if (mounted) setState(() {});
  }

  Future<void> _loadPartiesFromFirebase() async {
    final snapshot = await FirebaseFirestore.instance.collection('Party').get();

    for (final doc in snapshot.docs) {
      try {
        final data = doc.data();
        _partyCache[doc.id] = data;

        if (!_showParties) continue;

        // Alter-Filter
        if (_minAgeFilter != null) {
          int partyAge = 0;
          if (data['minAge'] is int) {
            partyAge = data['minAge'] as int;
          } else {
            final ageStr =
            (data['minAge'] ?? data['age'] ?? data['eventAge'] ?? '')
                .toString()
                .toLowerCase()
                .trim();
            final digits = RegExp(r'\d+').stringMatch(ageStr);
            if (digits != null) partyAge = int.tryParse(digits) ?? 0;
          }
          if (partyAge > _minAgeFilter! && partyAge > 0) continue;
        }

        // Eintritt
        final dynamic rawEntry = data['entryFee'] ?? data['price'];
        double? entryFee;
        if (rawEntry is num) {
          entryFee = rawEntry.toDouble();
        } else {
          final String? entryStr = rawEntry == null ? null : rawEntry.toString();
          if (entryStr != null && entryStr.isNotEmpty) {
            final cleaned = entryStr.replaceAll(',', '.');
            entryFee = double.tryParse(cleaned);
          }
        }

        if (_onlyFree) {
          final fee = entryFee ?? 0.0;
          if (fee > 0.0) continue;
        }
        if (_maxEntryFilter != null && entryFee != null) {
          if (entryFee > _maxEntryFilter!) continue;
        }

        // abgelaufen
        if (_isExpiredWithGrace(data)) continue;

        // Position
        final pos = _parseLatLng(data);
        if (pos == null) continue;

        // (optional) Event-Kreis
        if (data['eventActive'] == true && data['eventDate'] is Timestamp) {
          final eventStart = (data['eventDate'] as Timestamp).toDate();
          final eventEnd = eventStart.add(const Duration(days: 7));
          if (DateTime.now().isBefore(eventEnd)) {
            _circles.add(
              Circle(
                circleId: CircleId('event_circle_${doc.id}'),
                center: pos,
                radius: 180,
                fillColor: Colors.greenAccent.withOpacity(0.20),
                strokeColor: Colors.greenAccent,
                strokeWidth: 2,
                zIndex: 0,
              ),
            );
          }
        }

        // friends-only Sichtbarkeit
        final visibility = (data['visibility'] ?? 'public').toString();
        final excluded =
            (data['excludedFriends'] as List?)?.cast<String>() ?? const <String>[];
        final isFriendOnly = visibility == 'friends';

        final isHostForThisParty = _isHostForPartyData(data);
        final hostUsername =
        ((data['hostId'] ?? data['hostUid']) ?? '').toString().trim();

        if (isFriendOnly && !isHostForThisParty) {
          final me = _currentUsername?.trim();
          final isFriend =
              me != null && me.isNotEmpty && _myFriendsSet.contains(hostUsername);
          final isExcluded = me != null && excluded.contains(me);
          if (!isFriend || isExcluded) continue;
        }

        // open/closed filter
        final isClosed = _isClosedDoc(data);
        if (_onlyClosedParties && !isClosed) continue;
        if (_onlyOpenParties && isClosed) continue;

        if (isClosed) {
          // ---------------------------
          // 🔒 CLOSED PARTY (verschoben)
          // ---------------------------
          final rng = Random(doc.id.hashCode);

          final fakeCenter = _offsetWithinRadiusMeters(
            center: pos,
            minMeters: 400,
            maxMeters: 650,
            rng: rng,
          );

          final markerPos = fakeCenter;

          String? myStatus;

          if (!_isBarAccount && _currentUsername != null && !isHostForThisParty) {
            myStatus = await _myRequestStatus(doc.id, _currentUsername!);
          }

          _closedPartyStatus[doc.id] = myStatus;

          _circles.add(Circle(
            circleId: CircleId(doc.id),
            center: fakeCenter,
            radius: 1000,
            fillColor: Colors.grey.withOpacity(0.22),
            strokeColor: Colors.grey.shade500,
            strokeWidth: 2,
            zIndex: 1,
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));

          _markers.add(Marker(
            markerId: MarkerId('hit_${doc.id}'),
            position: markerPos,
            icon: _hitboxIcon ??
                BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
            anchor: const Offset(0.5, 0.5),
            zIndex: 9,
            consumeTapEvents: true,
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));

          BitmapDescriptor icon;
          if (isHostForThisParty) {
            icon = _lockIconBlue ?? BitmapDescriptor.defaultMarker;
          } else if (myStatus == 'approved') {
            icon = _lockIconGreen ?? BitmapDescriptor.defaultMarker;
          } else if (myStatus == 'declined') {
            icon = _lockIconRed ?? BitmapDescriptor.defaultMarker;
          } else {
            icon = _lockIconGrey ?? BitmapDescriptor.defaultMarker;
          }

          _markers.add(Marker(
            markerId: MarkerId('lock_${doc.id}'),
            position: markerPos,
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            zIndex: 10,
            consumeTapEvents: true,
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));
        } else {
          // ---------------------------
          // 🎉 OPEN PARTY (echter Ort)
          // ---------------------------
          String? myStatus;

          if (!_isBarAccount && _currentUsername != null && !isHostForThisParty) {
            // 1) rsvps
            myStatus = await _myOpenRsvpStatus(doc.id);

            // 2) wenn nicht gesetzt, requests (pending -> orange)
            myStatus ??= await _myOpenRequestStatus(doc.id);
          }

          _openPartyStatus[doc.id] = myStatus; // going/maybe/pending/null
          _openPartyIsHost[doc.id] = isHostForThisParty;

          final icon = isFriendOnly
              ? _iconForFriendsPartyMarker(doc.id)
              : _iconForOpenPartyMarker(doc.id);

          _markers.add(
            Marker(
              markerId: MarkerId(doc.id),
              position: pos,
              icon: icon,
              anchor: const Offset(0.5, 0.5),
              zIndex: 5,
              consumeTapEvents: true,
              onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
            ),
          );
        }
      } catch (_) {
        continue;
      }
    }
  }

  Future<void> _loadBarsFromFirebase() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('bars')
          .where('status', isEqualTo: 'approved')
          .get();

      final now = DateTime.now();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (!_showBars) continue;

        // Event abgelaufen -> zurücksetzen
        if (data['eventActive'] == true && data['eventDate'] is Timestamp) {
          final dt = (data['eventDate'] as Timestamp).toDate();
          final start = dt.subtract(const Duration(hours: 1));
          if (now.isAfter(start.add(const Duration(hours: _barEventHoursAfter)))) {
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

        final barName = (data['barName'] ?? 'Bar').toString();
        final imageUrl = (data['profileImageUrl'] ?? '').toString().trim();
        final baseKey = imageUrl.isEmpty ? '__default' : imageUrl;

        final hasEvent = _barHasVisibleEvent(data, now);

        BitmapDescriptor icon;
        if (hasEvent) {
          final key = 'event|$baseKey';
          if (_barIconEventRingCache.containsKey(key)) {
            icon = _barIconEventRingCache[key]!;
          } else {
            icon = await _createBarMarkerIconWithGreenRing(
                imageUrl.isEmpty ? null : imageUrl);
            _barIconEventRingCache[key] = icon;
          }
        } else {
          final key = 'normal|$baseKey';
          if (_barIconCache.containsKey(key)) {
            icon = _barIconCache[key]!;
          } else {
            icon = await _createBarMarkerIcon(imageUrl.isEmpty ? null : imageUrl);
            _barIconCache[key] = icon;
          }
        }

        _markers.add(
          Marker(
            markerId: MarkerId('bar_${doc.id}'),
            position: pos,
            icon: icon,
            infoWindow: InfoWindow(title: barName),
            onTap: () => _openBarSheet(data, doc.id),
          ),
        );
      }
    } catch (_) {}
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

    final myDocId = _safeDocId(username);
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
          backgroundColor: const Color(0xFF141A22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.report_gmailerrorred_rounded, color: Colors.redAccent),
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
                    dropdownColor: const Color(0xFF1C1F26),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1F26),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.redAccent),
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
                      fillColor: const Color(0xFF1C1F26),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.redAccent),
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
              child: const Text('Abbrechen', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
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
      const SnackBar(content: Text('Meldung wurde gesendet. Danke.')),
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
    final myDocId = _safeDocId(username);
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
      date = (data['date'] as Timestamp).toDate();
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

    if (_currentUsername == username) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _setLockIconForPartyStatus(partyId, status: status);
        }
      });
    }
  }

  void _setLockIconForPartyStatus(String partyId, {required String? status}) {
    _closedPartyStatus[partyId] = status;

    final lockId = 'lock_$partyId';
    final hitId = 'hit_$partyId';

    final existing = _markers.where((m) => m.markerId.value == lockId).toList();
    if (existing.isEmpty) return;
    final old = existing.first;

    BitmapDescriptor icon;
    if (status == 'approved') {
      icon = _lockIconGreen ?? BitmapDescriptor.defaultMarker;
    } else if (status == 'declined') {
      icon = _lockIconRed ?? BitmapDescriptor.defaultMarker;
    } else {
      icon = _lockIconGrey ?? BitmapDescriptor.defaultMarker;
    }

    setState(() {
      _markers.removeWhere((m) => m.markerId.value == lockId);
      _markers.add(Marker(
        markerId: MarkerId(lockId),
        position: old.position,
        icon: icon,
        anchor: const Offset(0.5, 0.5),
        zIndex: 10,
        consumeTapEvents: true,
        onTap: () => _openPartySheet(_partyCache[partyId]!, partyId),
      ));

      // hitbox sicherstellen
      if (_markers.every((m) => m.markerId.value != hitId)) {
        _markers.add(Marker(
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

  Future<void> _onCameraIdle() async {
    if (_lastCameraPosition == null) return;

    final newZoom = _lastCameraPosition!.zoom;
    if ((newZoom - _currentZoom).abs() < 0.5) return;

    _currentZoom = newZoom;

    if (_isUpdatingZoomIcons) return;
    _isUpdatingZoomIcons = true;

    try {
      await _updateCustomMarkerSizesForZoom();
    } finally {
      _isUpdatingZoomIcons = false;
    }
  }

  Future<void> _updateCustomMarkerSizesForZoom() async {
    final scale = _zoomToScale(_currentZoom);

    final lockDiameter = (_lockBaseDiameter * scale).round();
    final friendsDiameter = (_friendsBaseDiameter * scale).round();
    final hitDiameter = (_hitBaseDiameter * scale).round();

    _lockIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: lockDiameter,
      circleColor: const Color(0xFF1976D2),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconGrey = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: lockDiameter,
      circleColor: const Color(0xFF424242),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: lockDiameter,
      circleColor: const Color(0xFF2E7D32),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _lockIconRed = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: lockDiameter,
      circleColor: const Color(0xFFD32F2F),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));

    _hitboxIcon = BitmapDescriptor.fromBytes(
      await _drawTransparentCircle(diameter: hitDiameter),
    );

    _friendsOnlyIcon = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: friendsDiameter,
      circleColor: const Color(0xFF6A1B9A),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));

    _friendsIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: friendsDiameter,
      circleColor: const Color(0xFF1976D2),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: friendsDiameter,
      circleColor: const Color(0xFF2E7D32),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconOrange = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: friendsDiameter,
      circleColor: const Color(0xFFF57C00),
      icon: Icons.people_alt_rounded,
      iconColor: Colors.white,
      iconScale: .60,
    ));
    _friendsIconPurple = _friendsOnlyIcon;

    _partyIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: lockDiameter,
      circleColor: const Color(0xFF1976D2),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: lockDiameter,
      circleColor: const Color(0xFF2E7D32),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconOrange = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: lockDiameter,
      circleColor: const Color(0xFFF57C00),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));
    _partyIconRed = BitmapDescriptor.fromBytes(await _drawCircleWithEmoji(
      diameter: lockDiameter,
      circleColor: const Color(0xFFD32F2F),
      emoji: "🎉",
      emojiColor: Colors.white,
      emojiScale: .62,
    ));

    _rebuildMarkersWithNewIcons();
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
      _markers
        ..clear()
        ..addAll(newMarkers);
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
    bool onlyFree = _onlyFree;
    int? minAge = _minAgeFilter;
    double? maxEntry = _maxEntryFilter;

    bool onlyOpen = _onlyOpenParties;
    bool onlyClosed = _onlyClosedParties;

    final ageCtrl = TextEditingController(text: minAge != null ? minAge.toString() : '');
    final entryCtrl = TextEditingController(text: maxEntry != null ? maxEntry.toString() : '');

    final result = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSB) {
              void turnOffPartySubFiltersIfNeeded() {
                if (!showParties) {
                  onlyOpen = false;
                  onlyClosed = false;
                  onlyFree = false;
                  minAge = null;
                  maxEntry = null;
                  ageCtrl.text = '';
                  entryCtrl.text = '';
                }
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.filter_list, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        "Filter",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    value: showParties,
                    onChanged: (v) => setSB(() {
                      showParties = v;
                      turnOffPartySubFiltersIfNeeded();
                    }),
                    activeColor: _accent,
                    title: const Text("Partys anzeigen", style: TextStyle(color: Colors.white)),
                  ),
                  SwitchListTile(
                    value: onlyOpen,
                    onChanged: showParties
                        ? (v) => setSB(() {
                      onlyOpen = v;
                      if (v) onlyClosed = false;
                    })
                        : null,
                    activeColor: _accent,
                    title: const Text("Nur offene Partys", style: TextStyle(color: Colors.white)),
                  ),
                  SwitchListTile(
                    value: onlyClosed,
                    onChanged: showParties
                        ? (v) => setSB(() {
                      onlyClosed = v;
                      if (v) onlyOpen = false;
                    })
                        : null,
                    activeColor: _accent,
                    title: const Text("Nur geschlossene Partys", style: TextStyle(color: Colors.white)),
                  ),
                  SwitchListTile(
                    value: showBars,
                    onChanged: (v) => setSB(() => showBars = v),
                    activeColor: _accent,
                    title: const Text("Bars anzeigen", style: TextStyle(color: Colors.white)),
                  ),
                  const Divider(color: Colors.white24, height: 24),
                  SwitchListTile(
                    value: onlyFree,
                    onChanged: showParties ? (v) => setSB(() => onlyFree = v) : null,
                    activeColor: _accent,
                    title: const Text("Nur gratis Partys (0 € Eintritt)", style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: ageCtrl,
                    enabled: showParties,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Dein Alter (z. B. 16, 18, 21)",
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _accent)),
                    ),
                    onChanged: (_) {
                      final val = int.tryParse(ageCtrl.text.trim());
                      minAge = val;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: entryCtrl,
                    enabled: showParties,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: "Max. Eintritt (€)",
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white38)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _accent)),
                    ),
                    onChanged: (_) {
                      final val = double.tryParse(entryCtrl.text.trim().replaceAll(',', '.'));
                      maxEntry = val;
                    },
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop(<String, dynamic>{'reset': true});
                        },
                        child: const Text("Zurücksetzen", style: TextStyle(color: Colors.white70)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          final localMinAge = int.tryParse(ageCtrl.text.trim());
                          final localMaxEntry = double.tryParse(entryCtrl.text.trim().replaceAll(',', '.'));

                          bool finalOnlyOpen = onlyOpen;
                          bool finalOnlyClosed = onlyClosed;
                          bool finalOnlyFree = onlyFree;

                          int? finalMinAge = localMinAge;
                          double? finalMaxEntry = localMaxEntry;

                          if (!showParties) {
                            finalOnlyOpen = false;
                            finalOnlyClosed = false;
                            finalOnlyFree = false;
                            finalMinAge = null;
                            finalMaxEntry = null;
                          }

                          if (finalOnlyOpen && finalOnlyClosed) {
                            finalOnlyClosed = false;
                          }

                          Navigator.of(ctx).pop(<String, dynamic>{
                            'showParties': showParties,
                            'showBars': showBars,
                            'onlyFree': finalOnlyFree,
                            'minAge': finalMinAge,
                            'maxEntry': finalMaxEntry,
                            'onlyOpen': finalOnlyOpen,
                            'onlyClosed': finalOnlyClosed,
                            'reset': false,
                          });
                        },
                        child: const Text("Übernehmen"),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );

    ageCtrl.dispose();
    entryCtrl.dispose();

    if (result == null) return;

    if (result['reset'] == true) {
      setState(() {
        _showParties = true;
        _showBars = true;
        _onlyFree = false;
        _minAgeFilter = null;
        _maxEntryFilter = null;
        _onlyOpenParties = false;
        _onlyClosedParties = false;
      });
      await _refreshMap();
      return;
    }

    setState(() {
      _showParties = result['showParties'] as bool? ?? _showParties;
      _showBars = result['showBars'] as bool? ?? _showBars;

      _onlyFree = result['onlyFree'] as bool? ?? _onlyFree;
      _minAgeFilter = result['minAge'] as int?;
      _maxEntryFilter = result['maxEntry'] as double?;

      _onlyOpenParties = result['onlyOpen'] as bool? ?? _onlyOpenParties;
      _onlyClosedParties = result['onlyClosed'] as bool? ?? _onlyClosedParties;

      if (!_showParties) {
        _onlyOpenParties = false;
        _onlyClosedParties = false;
        _onlyFree = false;
        _minAgeFilter = null;
        _maxEntryFilter = null;
      }

      if (_onlyOpenParties && _onlyClosedParties) {
        _onlyClosedParties = false;
      }
    });

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

    return Scaffold(
      backgroundColor: _bgBottom,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF141A22),
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isPremium) ...[
              const Text(
                "Premium Map",
                style: TextStyle(
                  color: _text, // oder Colors.white
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ]
            else ...[
              const Text(
                "Party Map",
                style: TextStyle(
                  color: _text,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
        leadingWidth: 96,
        leading: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.menu, color: _accent),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MenuScreen()),
              ),
            ),
            IconButton(
              tooltip: 'Filter',
              onPressed: _openFilterSheet,
              icon: const Icon(Icons.filter_list, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Neu laden',
            onPressed: _isReloading ? null : _reload,
            icon: _isReloading
                ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
                : const Icon(Icons.refresh, color: Colors.white),
          ),
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileSettingsScreen()),
            ),
            icon: const CircleAvatar(
              radius: 16,
              backgroundColor: _accent,
              child: Icon(Icons.person, color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_bgTop, _bgBottom],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _startPos!,
              markers: _markers,
              circles: _circles,
              padding: const EdgeInsets.only(top: 140, bottom: 90),
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
          Positioned(
            left: 12,
            right: 12,
            top: _searchTop(context),
            child: _SearchCard(
              controller: _searchCtrl,
              onSearch: (input) async {
                final query = input.trim();
                if (query.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Bitte eine Adresse eingeben.")),
                  );
                  return;
                }

                final cc = await _getSelectedCountryCode();
                final withCity =
                    "$query, ${_currentCity.trim().isNotEmpty ? _currentCity.trim() : 'Wien'}";

                GeocodedLocation? location = await GeocodingService.getLocationFromAddress(
                  withCity,
                  countryCode: cc,
                );

                location ??= await GeocodingService.getLocationFromAddress(
                  query,
                  countryCode: cc,
                );

                if (!mounted) return;

                if (location != null) {
                  final pos = LatLng(location.latitude, location.longitude);
                  mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 19));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Adresse nicht gefunden.")),
                  );
                }
              },
              onClear: () {
                _searchCtrl.clear();
              },
            ),
          ),
          if (!_legalWarnDismissed && !_isBarAccount)
            Positioned(
              left: 12,
              right: 12,
              top: _searchTop(context) + 64,
              child: _legalWarningBanner(),
            ),
        ],
      ),
    );
  }

  Widget _legalWarningBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        border: Border.all(color: const Color(0xFFFFEEBA)),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Color(0x22000000), blurRadius: 8, offset: Offset(0, 3))
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFF856404)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              "WICHTIG: Das Erstellen von Fake-Partys ist rechtlich VERBOTEN. Nur echte, wahrheitsgemäße Angaben machen.",
              style: TextStyle(color: Color(0xFF856404), fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: "Hinweis ausblenden",
            onPressed: _dismissLegalWarn,
            icon: const Icon(Icons.close, color: Color(0xFF856404)),
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
}

class _SearchCard extends StatefulWidget {
  final TextEditingController controller;
  final Future<void> Function(String) onSearch;
  final VoidCallback onClear;

  const _SearchCard({
    required this.controller,
    required this.onSearch,
    required this.onClear,
  });

  @override
  State<_SearchCard> createState() => _SearchCardState();
}

class _SearchCardState extends State<_SearchCard> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(covariant _SearchCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.controller.text.trim().isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.redAccent.withOpacity(.85), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.5),
              blurRadius: 16,
              offset: const Offset(0, 8),
            )
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.search, color: Colors.redAccent),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: widget.controller,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.search,
                onSubmitted: widget.onSearch,
                decoration: const InputDecoration(
                  hintText: "Adresse eingeben",
                  hintStyle: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600),
                  border: InputBorder.none,
                ),
              ),
            ),
            if (hasText)
              IconButton(
                onPressed: widget.onClear,
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                tooltip: 'Löschen',
              )
            else
              IconButton(
                onPressed: () => widget.onSearch(widget.controller.text),
                icon: const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                tooltip: 'Suchen',
              ),
          ],
        ),
      ),
    );
  }
}
