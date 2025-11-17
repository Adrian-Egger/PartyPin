// lib/Screens/party_map_screen.dart
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Screens/new_party.dart';
import '../Screens/menu_screen.dart';
import '../Screens/profil_settings_screen.dart';
import '../Screens/feedback_screen.dart';
import '../Social/friends.dart';
import '../Services/geocoding_services.dart';
import '../widgets/party_bottom_sheet.dart';

class PartyMapScreen extends StatefulWidget {
  const PartyMapScreen({super.key});
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

  GoogleMapController? mapController;
  CameraPosition? _startPos;

  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  final Map<String, Map<String, dynamic>> _partyCache = {};

  // Indizes: 0=Feedback, 1=Map, 2=Freunde, 3=Neue Party
  int _currentIndex = 1;
  String _currentCity = "";
  double _currentLat = 48.2082;
  double _currentLng = 16.3738;

  String? _currentUsername;
  String? _currentFullName;

  BitmapDescriptor? _lockIconGrey;
  BitmapDescriptor? _lockIconGreen;
  BitmapDescriptor? _lockIconBlue;
  BitmapDescriptor? _lockIconRed;
  BitmapDescriptor? _hitboxIcon;

  final Map<String, bool> _verifiedCache = {};
  bool _ratingPromptShown = false;
  bool _legalWarnDismissed = false;
  bool _isReloading = false;

  // Suche
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSavedLocation();
    _loadCurrentUser();
    _loadLegalWarnState();
    _prepareIcons().then((_) async {
      await _refreshMap();
      _maybePromptForRating();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Position der Suche: kleiner Rand unter der AppBar
  double _searchTop(BuildContext ctx) {
    return 8; // ggf. auf 12/16 anpassen
  }

  // ---------- kleine Helfer ----------
  String _safeDocId(String input) =>
      input.trim().replaceAll('/', '_').replaceAll('#', '_').replaceAll('?', '_');

  // ---------- Setup ----------
  Future<void> _loadSavedLocation() async {
    final prefs = await SharedPreferences.getInstance();
    _currentCity = prefs.getString('city') ?? "Wien";
    _currentLat = prefs.getDouble('selectedLat') ?? 48.2082;
    _currentLng = prefs.getDouble('selectedLng') ?? 16.3738;
    setState(() {
      _startPos = CameraPosition(
        target: LatLng(_currentLat, _currentLng),
        zoom: 13,
      );
    });
  }

  // Username + voller Name laden
  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final uname =
    (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '')
        .trim();
    final vorname = (prefs.getString('vorname') ?? '').trim();
    final nachname = (prefs.getString('nachname') ?? '').trim();
    final fullName = ('$vorname $nachname').trim();

    setState(() {
      _currentUsername = uname.isEmpty ? null : uname;
      _currentFullName = fullName.isEmpty ? null : fullName;
    });
  }

  Future<void> _loadLegalWarnState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _legalWarnDismissed = prefs.getBool('legalWarnDismissed_v1') ?? false;
    });
  }

  Future<void> _dismissLegalWarn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('legalWarnDismissed_v1', true);
    if (mounted) setState(() => _legalWarnDismissed = true);
  }

  Future<void> _prepareIcons() async {
    _lockIconBlue = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: 112,
      circleColor: const Color(0xFF1976D2),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .52,
    ));
    _lockIconGrey = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: 128,
      circleColor: const Color(0xFF424242),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .55,
    ));
    _lockIconGreen = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: 128,
      circleColor: const Color(0xFF2E7D32),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .55,
    ));
    _lockIconRed = BitmapDescriptor.fromBytes(await _drawCircleWithIcon(
      diameter: 128,
      circleColor: const Color(0xFFD32F2F),
      icon: Icons.lock_rounded,
      iconColor: Colors.white,
      iconScale: .55,
    ));
    _hitboxIcon =
        BitmapDescriptor.fromBytes(await _drawTransparentCircle(diameter: 240));
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

    final circlePaint = Paint()..color = circleColor;
    canvas.drawCircle(center, diameter / 2, circlePaint);

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
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));

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
    final circlePaint = Paint()..color = const Color(0x00000000);
    canvas.drawCircle(center, diameter / 2, circlePaint);
    final picture = recorder.endRecording();
    final img = await picture.toImage(diameter, diameter);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
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

  // ---------- Parser / Flags ----------
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
    final cutoff = start.add(const Duration(hours: 12));
    return DateTime.now().isAfter(cutoff);
  }

  bool _isActive(Map<String, dynamic> d) => !_isExpiredWithGrace(d);

  bool _isInRatingWindow(Map<String, dynamic> d) {
    final start = _partyStart(d);
    if (start == null) return false;
    final nextDayMidnight =
    DateTime(start.year, start.month, start.day).add(const Duration(days: 1));
    return DateTime.now().isAfter(nextDayMidnight);
  }

  // ---------- Host-Erkennung (zentral!) ----------
  bool _isHostForPartyData(Map<String, dynamic> data) {
    final hostName = (data['hostName'] ?? '').toString().trim();
    final hostUid = ((data['hostUid'] ?? data['hostId']) ?? '').toString().trim();
    final cu = _currentUsername?.trim();
    final cf = _currentFullName?.trim();

    final byUid = cu != null &&
        cu.isNotEmpty &&
        hostUid.isNotEmpty &&
        hostUid == cu;

    final byName = cf != null &&
        cf.isNotEmpty &&
        hostName.isNotEmpty &&
        hostName == cf;

    return byUid || byName;
  }

  // ---------- Verified ----------
  Future<bool> _isUserVerified(String usernameDocId) async {
    if (_verifiedCache.containsKey(usernameDocId)) {
      return _verifiedCache[usernameDocId]!;
    }
    try {
      final snap =
      await FirebaseFirestore.instance.collection('users').doc(usernameDocId).get();
      final verified = (snap.data()?['verified'] == true);
      _verifiedCache[usernameDocId] = verified;
      return verified;
    } catch (_) {
      _verifiedCache[usernameDocId] = false;
      return false;
    }
  }

  // ---------- RSVP ----------
  Future<String?> _myOpenRsvpStatus(String partyId) async {
    if (_currentUsername == null) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('Party')
          .doc(partyId)
          .collection('rsvps')
          .doc(_currentUsername!)
          .get();
      return snap.data()?['status'] as String?;
    } catch (_) {
      return null;
    }
  }

  void _setOpenMarkerColor(String partyId,
      {required String? status, required bool isHost}) {
    final mid = partyId;
    final existing = _markers.where((m) => m.markerId.value == mid).toList();
    if (existing.isEmpty) return;
    final old = existing.first;

    double hue;
    if (isHost) {
      hue = BitmapDescriptor.hueBlue;
    } else if (status == 'going') {
      hue = BitmapDescriptor.hueGreen;
    } else if (status == 'maybe') {
      hue = BitmapDescriptor.hueOrange;
    } else {
      hue = BitmapDescriptor.hueRed;
    }

    setState(() {
      _markers.removeWhere((m) => m.markerId.value == mid);
      _markers.add(Marker(
        markerId: MarkerId(mid),
        position: old.position,
        icon: BitmapDescriptor.defaultMarkerWithHue(hue),
        onTap: () => _openPartySheet(_partyCache[partyId]!, partyId),
      ));
    });
  }

  // ---------- Daten ----------
  Future<void> _refreshMap() async {
    _partyCache.clear();
    _markers.clear();
    _circles.clear();
    await _loadPartiesFromFirebase();
    if (mounted) setState(() {});
  }

  Future<void> _loadPartiesFromFirebase() async {
    final snapshot = await FirebaseFirestore.instance.collection('Party').get();

    for (final doc in snapshot.docs) {
      try {
        final data = doc.data();
        _partyCache[doc.id] = data;
        if (_isExpiredWithGrace(data)) continue;

        final pos = _parseLatLng(data);
        if (pos == null) continue;

        final isClosed = _isClosedDoc(data);

        if (isClosed) {
          final r = Random();
          final shift = LatLng(
            pos.latitude + (r.nextDouble() - .5) / 500,
            pos.longitude + (r.nextDouble() - .5) / 500,
          );

          bool isHostForThisParty = _isHostForPartyData(data);
          String? myStatus;
          if (_currentUsername != null && !isHostForThisParty) {
            myStatus = await _myRequestStatus(doc.id, _currentUsername!);
          }

          _circles.add(Circle(
            circleId: CircleId(doc.id),
            center: shift,
            radius: 1000,
            fillColor: Colors.grey.withOpacity(0.22),
            strokeColor: Colors.grey.shade500,
            strokeWidth: 2,
            zIndex: 1,
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));

          _markers.add(Marker(
            markerId: MarkerId('hit_${doc.id}'),
            position: shift,
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
            position: shift,
            icon: icon,
            anchor: const Offset(0.5, 0.5),
            zIndex: 10,
            consumeTapEvents: true,
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));
        } else {
          bool isHostForThisParty = _isHostForPartyData(data);
          String? myOpenStatus;
          if (_currentUsername != null && !isHostForThisParty) {
            myOpenStatus = await _myOpenRsvpStatus(doc.id);
          }

          double hue;
          if (isHostForThisParty) {
            hue = BitmapDescriptor.hueBlue;
          } else if (myOpenStatus == 'going') {
            hue = BitmapDescriptor.hueGreen;
          } else if (myOpenStatus == 'maybe') {
            hue = BitmapDescriptor.hueOrange;
          } else {
            hue = BitmapDescriptor.hueRed;
          }

          _markers.add(Marker(
            markerId: MarkerId(doc.id),
            position: pos,
            icon: BitmapDescriptor.defaultMarkerWithHue(hue),
            onTap: () => _openPartySheet(_partyCache[doc.id]!, doc.id),
          ));
        }
      } catch (_) {
        continue;
      }
    }
  }

  Future<String?> _myRequestStatus(String partyId, String username) async {
    try {
      final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
      try {
        final partyDoc = await partyRef.get();
        final arr =
            (partyDoc.data()?['approvedUsers'] as List?)?.cast<String>() ??
                const <String>[];
        if (arr.contains(username)) return 'approved';
      } catch (_) {}
      try {
        final reqSnap = await partyRef.collection('requests').doc(username).get();
        final m = reqSnap.data();
        if (m == null) return null;
        final s = m['status'] as String?;
        if (s == 'approved' || s == 'declined' || s == 'pending') return s;
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------- Ratings ----------
  Future<void> _setRating(String partyId, String username, String value) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final ratingRef = partyRef.collection('ratings').doc(username);

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final partySnap = await tx.get(partyRef);
        final partyData = partySnap.data() ?? {};
        final ratingSnap = await tx.get(ratingRef);

        // Host sauber bestimmen: hostUid bevorzugen, sonst sicherer Name
        final hostUid =
        ((partyData['hostUid'] ?? partyData['hostId']) ?? '').toString().trim();
        final hostName = (partyData['hostName'] ?? '').toString().trim();
        final hostDocId = hostUid.isNotEmpty ? hostUid : _safeDocId(hostName);
        if (hostDocId.isEmpty) {
          throw StateError("Kein Host für Aggregation vorhanden.");
        }

        // Bewertung erst ab dem Folgetag
        DateTime? start;
        final v = partyData['date'];
        if (v is Timestamp) {
          start = v.toDate();
        } else if (v is String) {
          start = DateTime.tryParse(v);
        }
        if (start != null) {
          start = DateTime(start.year, start.month, start.day, 0, 0);
        }
        if (start == null ||
            DateTime.now().isBefore(start.add(const Duration(days: 1)))) {
          throw StateError("Bewertung erst ab dem nächsten Tag möglich.");
        }

        // User-Dokument des Hosts
        final userRef =
        FirebaseFirestore.instance.collection('users').doc(hostDocId);
        final userSnap = await tx.get(userRef);

        // Vorherige Stimme des aktuellen Users zu dieser Party
        final prevVal = (ratingSnap.data()?['value'] as String?);
        int deltaGood = 0, deltaBad = 0;
        if (value == 'good') deltaGood++;
        if (value == 'bad') deltaBad++;
        if (prevVal == 'good') deltaGood--;
        if (prevVal == 'bad') deltaBad--;
        final changed = (deltaGood != 0 || deltaBad != 0);

        // 1) Party-spezifische Stimme speichern
        tx.set(
          ratingRef,
          {
            'username': username,
            'value': value,
            'ts': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        // 2) Benutzer-Scoped Rating-Schema mitschreiben: pro Party, pro Rater
        final perPartyUserRatingRef = userRef
            .collection('partyRatings')
            .doc(partyId)
            .collection('byUser')
            .doc(username);
        tx.set(
          perPartyUserRatingRef,
          {
            'partyId': partyId,
            'fromUser': username,
            'value': value,
            'ts': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        // 3) Aggregation aktualisieren
        if (changed) {
          tx.set(
            partyRef,
            {
              'ratingsGood': FieldValue.increment(deltaGood),
              'ratingsBad': FieldValue.increment(deltaBad),
            },
            SetOptions(merge: true),
          );

          final currentGood = (userSnap.data()?['partyScoreGood'] ?? 0) as int;
          final currentBad = (userSnap.data()?['partyScoreBad'] ?? 0) as int;
          final newGood = currentGood + deltaGood;
          final newBad = currentBad + deltaBad;
          final total = newGood + newBad;
          final pct = total > 0 ? ((newGood / total) * 100).round() : 0;

          tx.set(
            userRef,
            {
              'partyScoreGood': newGood,
              'partyScoreBad': newBad,
              'partyScorePct': pct,
              'partyScoreUpdatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              value == 'good' ? "Danke für die positive Bewertung!" : "Danke für dein Feedback!"),
        ),
      );
    } on StateError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Bewertung nicht möglich: ${e.message}")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Bewerten: $e")),
      );
    }
  }

  Future<bool> _userHasRated(String partyId, String username) async {
    final snap = await FirebaseFirestore.instance
        .collection('Party')
        .doc(partyId)
        .collection('ratings')
        .doc(username)
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
      final status = myRsvp.data()?['status'] as String?;
      if (status != 'going' && status != 'maybe') continue;

      final rated = await _userHasRated(pid, _currentUsername!);
      if (rated) continue;

      _ratingPromptShown = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
        Text("Wie war „${data['name'] ?? 'die Party'}“? Jetzt bewerten."),
        action: SnackBarAction(label: "ÖFFNEN", onPressed: () => _openPartySheet(data, pid)),
      ));
      break;
    }
  }

  // ---------- Report ----------
  Future<void> _sendReportDialog(String partyId) async {
    final outerContext = context;
    final controller = TextEditingController();

    final quickReasons = <String>[
      'Fake Spam',
      'Gefährlich Illegal',
      'Unangemessene Inhalte',
      'Ort Adresse falsch',
      'Lärmbläschen',
      'Sonstiges',
    ];

    String? selectedReason;
    bool isSubmitting = false;

    await showDialog(
      context: context,
      useRootNavigator: true,
      barrierDismissible: !isSubmitting,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setSB) => WillPopScope(
          onWillPop: () async => !isSubmitting,
          child: AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text("Party melden", style: TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Grund auswählen:",
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: quickReasons.map((r) {
                      final selected = r == selectedReason;
                      return ChoiceChip(
                        label: Text(r),
                        selected: selected,
                        onSelected: (v) => setSB(() => selectedReason = v ? r : null),
                        labelStyle: TextStyle(
                            color: selected ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w700),
                        selectedColor: Colors.redAccent,
                        backgroundColor: Colors.grey[800],
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: selected ? Colors.redAccent : Colors.grey[700]!,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                  const Text("Optionaler Hinweis:",
                      style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: controller,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "z. B. was genau passiert ist…",
                      hintStyle: TextStyle(color: Colors.white38),
                      enabledBorder:
                      OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder:
                      OutlineInputBorder(borderSide: BorderSide(color: Colors.white54)),
                    ),
                  ),
                ],
              ),
            ),
            actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            actions: [
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () => Navigator.of(dialogCtx, rootNavigator: true).pop(),
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                child: const Text("Abbrechen"),
              ),
              ElevatedButton(
                onPressed: (selectedReason == null || isSubmitting)
                    ? null
                    : () async {
                  if (_currentUsername == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content:
                          Text("Bitte Username in den Einstellungen setzen.")),
                    );
                    return;
                  }
                  setSB(() => isSubmitting = true);
                  try {
                    final party = _partyCache[partyId] ?? {};
                    final partyName = (party['name'] ?? '').toString();

                    await FirebaseFirestore.instance
                        .collection('Meldungen')
                        .add({
                      'partyId': partyId,
                      'partyName': partyName,
                      'partyDate': party['date'] ?? FieldValue.serverTimestamp(),
                      'partyAddress': (party['address'] ?? '').toString(),
                      'hostName': (party['hostName'] ?? '').toString(),
                      'hostId': (party['hostId'] ?? '').toString(),
                      'reporterName': _currentUsername,
                      'reason': selectedReason,
                      'note': controller.text.trim(),
                      'createdAt': FieldValue.serverTimestamp(),
                    });

                    if (!mounted) return;
                    Navigator.of(dialogCtx, rootNavigator: true).pop();
                    if (Navigator.of(outerContext).canPop()) {
                      Navigator.of(outerContext).pop();
                    }
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text("Meldung gesendet")));
                  } on FirebaseException catch (e) {
                    setSB(() => isSubmitting = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Fehler: ${e.message ?? e.code}")));
                  } catch (e) {
                    setSB(() => isSubmitting = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Unerwarteter Fehler: $e")));
                  }
                },
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(96, 44)),
                child: isSubmitting
                    ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("Senden"),
              ),
            ],
          ),
        ),
      ),
    );
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
        onReport: () => _sendReportDialog(partyId),
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
        setClosedLockIcon: (status) => _setLockIconForPartyStatus(partyId, status: status),
        onEditedParty: () async {
          setState(() => _currentIndex = 1);
          await _refreshMap();
          if (mounted) Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _setRsvpStatus(String partyId, String username, String status) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final rsvpRef = partyRef.collection('rsvps').doc(username);
    final comingRef = partyRef.collection('coming').doc(username);
    final maybeRef = partyRef.collection('maybe').doc(username);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
          rsvpRef,
          {
            'username': username,
            'status': status,
            'timestamp': FieldValue.serverTimestamp()
          },
          SetOptions(merge: true));
      if (status == 'going') {
        tx.set(comingRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.delete(maybeRef);
      } else {
        tx.set(maybeRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.delete(comingRef);
      }
    });

    final data = _partyCache[partyId];
    final isHost = data != null && _isHostForPartyData(data);
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
    _setOpenMarkerColor(partyId, status: null, isHost: isHost);
  }

  Future<void> _sendJoinRequest(String partyId, String username) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final reqRef = partyRef.collection('requests').doc(username);
    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
          reqRef,
          {
            'username': username,
            'status': 'pending',
            'timestamp': FieldValue.serverTimestamp()
          },
          SetOptions(merge: true));
    });
  }

  Future<void> _updateRequestStatus(
      String partyId, String username, String status) async {
    final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
    final reqRef = partyRef.collection('requests').doc(username);
    final apprRef = partyRef.collection('approved').doc(username);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      tx.set(
          reqRef,
          {
            'username': username,
            'status': status,
            'handledAt': FieldValue.serverTimestamp()
          },
          SetOptions(merge: true));
      if (status == 'approved') {
        tx.set(apprRef, {'username': username, 'timestamp': FieldValue.serverTimestamp()});
        tx.set(partyRef, {
          'approvedUsers': FieldValue.arrayUnion([username])
        }, SetOptions(merge: true));
      } else {
        tx.delete(apprRef);
        tx.set(partyRef, {
          'approvedUsers': FieldValue.arrayRemove([username])
        }, SetOptions(merge: true));
      }
    });

    if (_currentUsername == username) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setLockIconForPartyStatus(partyId, status: status);
      });
    }
  }

  void _setLockIconForPartyStatus(String partyId, {required String? status}) {
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

  Future<void> _showCenterSuccess(String text) async {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    if (overlay == null) return;

    late OverlayEntry entry;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    );
    final fade = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final scale = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );

    entry = OverlayEntry(
      builder: (ctx) => Positioned.fill(
        child: IgnorePointer(
          child: Center(
            child: FadeTransition(
              opacity: fade,
              child: ScaleTransition(
                scale: scale,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey[900]!.withOpacity(0.96),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 10))
                    ],
                    border: Border.all(color: Colors.greenAccent.withOpacity(0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                          width: 28,
                          height: 28,
                          decoration: const BoxDecoration(
                              shape: BoxShape.circle, color: Colors.green),
                          child: const Icon(Icons.check_rounded,
                              color: Colors.white, size: 18)),
                      const SizedBox(width: 12),
                      Text(text,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: .2)),
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
    await Future.delayed(const Duration(milliseconds: 1200));
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

  Future<bool> _ensureLegalConsentBeforeCreating() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAccepted = prefs.getBool('legal_consent_create_v1') ?? false;
    if (alreadyAccepted) return true;

    final acceptedNow = await _showLegalGateDialog();
    if (acceptedNow) {
      await prefs.setBool('legal_consent_create_v1', true);
      await prefs.setString(
          'legal_consent_create_v1_date', DateTime.now().toIso8601String());
    }
    return acceptedNow;
  }

  Future<bool> _showLegalGateDialog() async {
    bool checkbox = false;
    bool accepted = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSB) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: Row(
                children: const [
                  Icon(Icons.gavel_outlined, color: Colors.redAccent),
                  SizedBox(width: 8),
                  Text("Rechtlicher Hinweis", style: TextStyle(color: Colors.white)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Das Erstellen von Fake-Partys ist VERBOTEN. Du bestätigst, dass alle Angaben wahrheitsgemäß sind und die Veranstaltung wirklich stattfindet.",
                      style: TextStyle(
                          color: Colors.white70,
                          height: 1.35,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: checkbox,
                      onChanged: (v) => setSB(() => checkbox = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: Colors.redAccent,
                      title: const Text(
                        "Ich habe den Hinweis gelesen und stimme zu.",
                        style: TextStyle(color: Colors.white),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              actions: [
                OutlinedButton.icon(
                  onPressed: () {
                    accepted = false;
                    Navigator.of(ctx).pop();
                  },
                  icon: const Icon(Icons.close, color: Colors.redAccent),
                  label: const Text("Abbrechen",
                      style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                if (checkbox)
                  ElevatedButton.icon(
                    onPressed: () {
                      accepted = true;
                      Navigator.of(ctx).pop();
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label:
                    const Text("Fertig", style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding:
                      const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );

    return accepted;
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (_startPos == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator(color: _accent)));
    }

    return Scaffold(
      // WICHTIG: nicht mehr hinter die AppBar zeichnen
      appBar: AppBar(
        elevation: 0,
        backgroundColor:Color(0xFF141A22),
        centerTitle: true,
        title: const Text(
          "Party Map",
          style: TextStyle(
            color: _text,
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu, color: _accent),
          onPressed: () =>
              Navigator.push(context, MaterialPageRoute(builder: (_) => const MenuScreen())),
        ),
        actions: [
          IconButton(
            tooltip: 'Neu laden',
            onPressed: _isReloading ? null : _reload,
            icon: _isReloading
                ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.refresh, color: Colors.white),
          ),
          IconButton(
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ProfileSettingsScreen())),
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
          // Hintergrund-Gradient
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

          // Google Map füllt den ganzen Body
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: _startPos!,
              markers: _markers,
              circles: _circles,
              zoomControlsEnabled: true,
              zoomGesturesEnabled: true,
              onMapCreated: (controller) => mapController = controller,
            ),
          ),

          // Suchleiste schwebend knapp unter Titel
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
                    "${query}, ${_currentCity.trim().isEmpty ? 'Wien' : _currentCity.trim()}";

                // 1. Versuch: Adresse + aktuelle Stadt
                GeocodedLocation? location =
                await GeocodingService.getLocationFromAddress(withCity,
                    countryCode: cc);

                // 2. Versuch: nur die Eingabe
                location ??= await GeocodingService.getLocationFromAddress(query,
                    countryCode: cc);

                if (location != null) {
                  final pos = LatLng(location.latitude, location.longitude);
                  setState(() {
                    _markers.add(Marker(
                      markerId: MarkerId("${query}|${_currentCity.trim()}"),
                      position: pos,
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueRed),
                    ));
                  });
                  mapController?.animateCamera(
                      CameraUpdate.newLatLngZoom(pos, 15));
                } else {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Adresse nicht gefunden.")),
                  );
                }
              },
              onClear: () => _searchCtrl.clear(),
            ),
          ),

          // Gelbes Legal-Banner knapp unter der Suchleiste
          if (!_legalWarnDismissed)
            Positioned(
              left: 12,
              right: 12,
              top: _searchTop(context) + 64,
              child: _legalWarningBanner(),
            ),
        ],
      ),

      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: _panel,
        selectedItemColor: _accent,
        unselectedItemColor: _muted,
        currentIndex: _currentIndex,
        onTap: _onBottomNavTapped,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.feedback), label: "Feedback"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: "Freunde"),
          BottomNavigationBarItem(icon: Icon(Icons.add), label: "Neue Party"),
        ],
      ),
    );
  }

  // NEU: ohne äußeren Top-Margin, damit keine gelben „Striche“ entstehen
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
              style:
              TextStyle(color: Color(0xFF856404), fontWeight: FontWeight.w800),
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

  void _onBottomNavTapped(int index) async {
    if (_currentIndex == index) return;
    setState(() => _currentIndex = index);

    if (index == 0) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const FeedbackScreen()),
      );
    } else if (index == 1) {
      await _refreshMap();
    } else if (index == 2) {
      final me = (_currentUsername ?? '').trim();
      if (me.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Username fehlt. In den Einstellungen setzen.')),
        );
        return;
      }
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => FriendsScreen(currentUsername: me)),
      );
    } else if (index == 3) {
      final ok = await _ensureLegalConsentBeforeCreating();
      if (!ok) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NewPartyScreen()),
      );
      setState(() => _currentIndex = 1);
      await _refreshMap();
    }
  }
}

// ---------- Suchkarte ----------
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
                controller: controller,
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.search,
                onSubmitted: onSearch,
                decoration: const InputDecoration(
                  hintText: "Adresse eingeben",
                  hintStyle:
                  TextStyle(color: Colors.white54, fontWeight: FontWeight.w600),
                  border: InputBorder.none,
                ),
              ),
            ),
            if (controller.text.isNotEmpty)
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                tooltip: 'Löschen',
              )
            else
              IconButton(
                onPressed: () => onSearch(controller.text),
                icon:
                const Icon(Icons.arrow_forward_rounded, color: Colors.white),
                tooltip: 'Suchen',
              ),
          ],
        ),
      ),
    );
  }
}
