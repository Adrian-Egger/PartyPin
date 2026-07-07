// lib/Screens/festl/admin_create_festl_screen.dart
//
// Admin-Editor für Festln (kuratierte Events mit eigenem Karten-Symbol).
// Aufbau bewusst an AdminCreateBarScreen angelehnt (Bild-Upload, Geocoding,
// Highlights), aber auf die Festl-Felder zugeschnitten: Veranstalter, Link,
// Zeitraum (Von/Bis) statt Öffnungszeiten. Schreibt in die Collection
// `festln`.
//
// SICHERHEIT: Der Schreibschutz liegt VOLLSTÄNDIG serverseitig in den
// Firestore-Rules (match /festln → isAdmin() via Custom Claim `admin`).
// Der `_checkAdmin()`-Check unten ist NUR ein UX-Gate (Screen für
// Nicht-Admins gar nicht erst zeigen) — KEIN Sicherheitsmechanismus. Selbst
// wenn ein Angreifer diesen Screen erzwingt, lehnt Firestore jeden Write
// eines Nicht-Admins ab.

import 'dart:async' show TimeoutException;
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Theme/app_theme.dart';
import '../../Services/timestamp_ext.dart';
import '../../Services/geocoding_services.dart';
import '../party/map_picker_screen.dart';

class AdminCreateFestlScreen extends StatefulWidget {
  /// Wenn gesetzt, wird ein bestehendes Festl geladen und bearbeitet.
  final String? festlId;

  const AdminCreateFestlScreen({super.key, this.festlId});

  @override
  State<AdminCreateFestlScreen> createState() => _AdminCreateFestlScreenState();
}

class _AdminCreateFestlScreenState extends State<AdminCreateFestlScreen> {
  static const String kAdminUsername = "admin_pp";
  static const String kFestlnCollection = "festln";
  static const _accent = Color(0xFF8E24AA);

  // Firestore-Timeout: verhindert, dass ein hängender Read/Write den
  // Speichern-Spinner unendlich stehen lässt.
  static const Duration _dbTimeout = Duration(seconds: 15);

  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  final _organizerCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: "Austria");
  final _descCtrl = TextEditingController();
  final _minAgeCtrl = TextEditingController();

  DateTime? _startDate;
  TimeOfDay? _startTime;
  DateTime? _endDate;
  TimeOfDay? _endTime;

  // Standort: frisch auf der Karte gewählt (gewinnt vor Geocoding) bzw.
  // bereits gespeicherter Punkt (Fallback beim Bearbeiten).
  double? _pickedLat;
  double? _pickedLng;
  double? _existingLat;
  double? _existingLng;

  bool _isSaving = false;
  bool _uploadingImage = false;
  String _status = "approved";

  String? _profileImageUrl;

  String? _editingDocId;

  final List<_FestlHighlight> _highlights = [];

  @override
  void initState() {
    super.initState();
    _checkAdmin();
    _addHighlightRow();
    if (widget.festlId != null) {
      _loadExisting(widget.festlId!);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _organizerCtrl.dispose();
    _linkCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _countryCtrl.dispose();
    _descCtrl.dispose();
    _minAgeCtrl.dispose();
    for (final h in _highlights) {
      h.textCtrl.dispose();
    }
    super.dispose();
  }

  // UX-Gate (kein Sicherheitsmechanismus — siehe Datei-Header): blendet den
  // Screen für Nicht-Admins aus. Der echte Schutz sind die Firestore-Rules.
  Future<void> _checkAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final me = prefs.getString("currentUsername");
    if (!mounted) return;
    if (me != kAdminUsername) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Kein Zugriff (nur Admin).")),
      );
      Navigator.of(context).pop();
    }
  }

  bool get _isMobile {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  // ---------------------------------------------------------------------------
  // Laden (Edit)
  // ---------------------------------------------------------------------------

  Future<void> _loadExisting(String docId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection(kFestlnCollection)
          .doc(docId)
          .get();
      final data = doc.data();
      if (data == null || !mounted) return;

      setState(() {
        _editingDocId = doc.id;
        _nameCtrl.text = (data['festlName'] ?? '').toString();
        _idCtrl.text = (data['festlId'] ?? doc.id).toString();
        _organizerCtrl.text = (data['organizer'] ?? '').toString();
        _linkCtrl.text = (data['link'] ?? '').toString();
        _addressCtrl.text = (data['address'] ?? '').toString();
        _cityCtrl.text = (data['city'] ?? '').toString();
        _countryCtrl.text = (data['country'] ?? 'Austria').toString();
        _descCtrl.text = (data['description'] ?? '').toString();
        _minAgeCtrl.text =
            data['minAge'] != null ? data['minAge'].toString() : '';
        _status = (data['status'] ?? 'approved').toString();
        _profileImageUrl = (data['profileImageUrl'] ?? '').toString();
        _existingLat = (data['lat'] as num?)?.toDouble();
        _existingLng = (data['lng'] as num?)?.toDouble();

        final start = data['startTime'];
        if (start is Timestamp) {
          final dt = start.toLocalDateTime();
          _startDate = DateTime(dt.year, dt.month, dt.day);
          _startTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
        }
        final end = data['endTime'];
        if (end is Timestamp) {
          final dt = end.toLocalDateTime();
          _endDate = DateTime(dt.year, dt.month, dt.day);
          _endTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
        }

        for (final h in _highlights) {
          h.textCtrl.dispose();
        }
        _highlights.clear();
        final rawH = data['festlHighlights'];
        if (rawH is List) {
          for (final item in rawH) {
            if (item is! Map) continue;
            final m = Map<String, dynamic>.from(item);
            _highlights.add(_FestlHighlight(
              textCtrl: TextEditingController(text: (m['text'] ?? '').toString()),
              imageUrl: (m['imageUrl'] ?? '').toString(),
            ));
          }
        }
        if (_highlights.isEmpty) _addHighlightRow();
      });
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Bild-Upload
  // ---------------------------------------------------------------------------

  Future<Uint8List?> _pickBytes({required String storagePathPrefix}) async {
    if (!_isMobile) {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return null;
      final file = result.files.first;
      if (file.bytes != null) return file.bytes;
      if (file.path != null) return await File(file.path!).readAsBytes();
      return null;
    } else {
      final picker = ImagePicker();
      final picked =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return null;
      return await File(picked.path).readAsBytes();
    }
  }

  Future<String?> _uploadBytes(Uint8List bytes, String path) async {
    final ref = FirebaseStorage.instance.ref().child(path);
    await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return await ref.getDownloadURL();
  }

  Future<void> _pickCover() async {
    if (_uploadingImage) return;
    setState(() => _uploadingImage = true);
    try {
      final bytes = await _pickBytes(storagePathPrefix: 'festlnInfos');
      if (bytes == null) return;
      final url = await _uploadBytes(
        bytes,
        'festlnInfos/cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      if (!mounted) return;
      setState(() => _profileImageUrl = url);
    } catch (e) {
      _snack("Fehler beim Bild-Upload: $e");
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Highlights
  // ---------------------------------------------------------------------------

  void _addHighlightRow() {
    setState(() => _highlights.add(_FestlHighlight(textCtrl: TextEditingController())));
  }

  void _removeHighlightRow(int i) {
    setState(() {
      if (_highlights.length == 1) {
        _highlights[i].textCtrl.clear();
        _highlights[i].imageUrl = null;
      } else {
        _highlights[i].textCtrl.dispose();
        _highlights.removeAt(i);
      }
    });
  }

  Future<void> _pickHighlightImage(int i) async {
    if (_isSaving) return;
    try {
      final bytes = await _pickBytes(storagePathPrefix: 'festlnInfos');
      if (bytes == null) return;
      final url = await _uploadBytes(
        bytes,
        'festlnInfos/highlight_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
      );
      if (!mounted) return;
      setState(() => _highlights[i].imageUrl = url);
    } catch (e) {
      _snack("Fehler beim Highlight-Upload: $e");
    }
  }

  List<Map<String, dynamic>> _buildHighlightsPayload() {
    final out = <Map<String, dynamic>>[];
    for (final h in _highlights) {
      final text = h.textCtrl.text.trim();
      final img = (h.imageUrl ?? '').trim();
      if (text.isEmpty && img.isEmpty) continue;
      out.add({'text': text, 'imageUrl': img});
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Datum / Zeit
  // ---------------------------------------------------------------------------

  Future<void> _pickDate({required bool isStart}) async {
    final base = isStart ? _startDate : _endDate;
    final date = await showDatePicker(
      context: context,
      initialDate: base ?? _startDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    setState(() {
      if (isStart) {
        _startDate = date;
      } else {
        _endDate = date;
      }
    });
  }

  Future<void> _pickTime({required bool isStart}) async {
    final base = isStart ? _startTime : _endTime;
    final t = await showTimePicker(
      context: context,
      initialTime: base ?? const TimeOfDay(hour: 18, minute: 0),
    );
    if (t == null) return;
    setState(() {
      if (isStart) {
        _startTime = t;
      } else {
        _endTime = t;
      }
    });
  }

  DateTime? _combine(DateTime? d, TimeOfDay? t) {
    if (d == null) return null;
    final tod = t ?? const TimeOfDay(hour: 0, minute: 0);
    return DateTime(d.year, d.month, d.day, tod.hour, tod.minute);
  }

  // ---------------------------------------------------------------------------
  // Speichern
  // ---------------------------------------------------------------------------

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppColors.success : AppColors.accent,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _save() async {
    if (_isSaving) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      _snack("Bitte alle Pflichtfelder korrekt ausfüllen.");
      return;
    }

    final start = _combine(_startDate, _startTime);
    if (start == null) {
      _snack("Bitte ein Startdatum wählen.");
      return;
    }
    final end = _combine(_endDate, _endTime);
    if (end != null && end.isBefore(start)) {
      _snack("Das Ende darf nicht vor dem Start liegen.");
      return;
    }

    final name = _nameCtrl.text.trim();
    final rawId = _idCtrl.text.trim();
    final city = _cityCtrl.text.trim();

    setState(() => _isSaving = true);

    // WICHTIG: ALLES ab hier läuft im try/finally, damit der Speichern-
    // Spinner in JEDEM Fall (Fehler, Timeout, früher return) wieder
    // zurückgesetzt wird und nicht unendlich lädt.
    try {
      // docId: beim Bearbeiten IMMER das geladene Doc (verhindert Orphans,
      // wenn das ID-Feld geändert würde). Beim Neuanlegen: Slug aus ID-Feld
      // (falls gesetzt) oder Name, kollisionssicher hochgezählt.
      final String docId;
      if (_editingDocId != null) {
        docId = _editingDocId!;
      } else {
        final base = _slugify(rawId.isNotEmpty ? rawId : name);
        docId = await _uniqueDocId(base);
      }

      // Koordinaten bestimmen: 1) frisch auf Karte gewählt → exakt nutzen.
      // 2) sonst Adresse geocodieren. 3) sonst (beim Bearbeiten) den bereits
      // gespeicherten Punkt behalten, damit ein Geocoding-Ausfall nicht das
      // Festl von der Karte wirft.
      GeoPoint? geo;
      if (_pickedLat != null && _pickedLng != null) {
        geo = GeoPoint(_pickedLat!, _pickedLng!);
      } else {
        geo = await _geocode(
          address: _addressCtrl.text.trim(),
          city: city,
          country: _countryCtrl.text.trim(),
        );
        if (geo == null && _existingLat != null && _existingLng != null) {
          geo = GeoPoint(_existingLat!, _existingLng!);
        }
      }
      if (geo == null) {
        _snack("Standort nicht gefunden. Bitte Adresse prüfen oder Standort "
            "auf der Karte wählen.");
        return; // finally setzt den Spinner zurück
      }

      final docRef = FirebaseFirestore.instance
          .collection(kFestlnCollection)
          .doc(docId);
      final existing = await docRef.get().timeout(_dbTimeout);

      final minAge = int.tryParse(_minAgeCtrl.text.trim());

      final data = <String, dynamic>{
        "festlName": name,
        "festlId": docId,
        "organizer": _organizerCtrl.text.trim(),
        "link": _linkCtrl.text.trim(),
        "description": _descCtrl.text.trim(),
        "address": _addressCtrl.text.trim(),
        "city": city,
        "country": _countryCtrl.text.trim(),
        "status": _status,
        "createdByAdmin": true,
        "startTime": Timestamp.fromDate(start),
        "endTime": end != null ? Timestamp.fromDate(end) : null,
        "minAge": minAge,
        "festlHighlights": _buildHighlightsPayload(),
        "location": geo,
        "lat": geo.latitude,
        "lng": geo.longitude,
        "city_lower": city.toLowerCase(),
        "festlName_lower": name.toLowerCase(),
        "updatedAt": FieldValue.serverTimestamp(),
        if (_profileImageUrl != null && _profileImageUrl!.isNotEmpty)
          "profileImageUrl": _profileImageUrl,
        if (!existing.exists) "createdAt": FieldValue.serverTimestamp(),
      };

      if (existing.exists) {
        await docRef.update(data).timeout(_dbTimeout);
        _snack("Festl aktualisiert.", ok: true);
      } else {
        await docRef.set(data).timeout(_dbTimeout);
        _snack("Festl angelegt.", ok: true);
      }
      if (!mounted) return;
      _editingDocId = docId;
      Navigator.of(context).pop();
    } on TimeoutException {
      _snack("Zeitüberschreitung. Bitte Internetverbindung prüfen und erneut "
          "versuchen.");
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('permission-denied') || msg.contains('permission_denied')) {
        _snack("Keine Berechtigung: Dieser Account hat keine Admin-Rechte. "
            "Bitte als Admin neu einloggen.");
      } else {
        _snack("Fehler beim Speichern: $e");
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _slugify(String name) {
    final lower = name.toLowerCase().trim()
        .replaceAll('ä', 'ae').replaceAll('ö', 'oe').replaceAll('ü', 'ue')
        .replaceAll('ß', 'ss');
    final cleaned = lower
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-z0-9_\-]'), '_')
        .replaceAll(RegExp(r'^_+'), '')
        .replaceAll(RegExp(r'_+$'), '');
    return cleaned.isEmpty
        ? 'festl_${DateTime.now().millisecondsSinceEpoch}'
        : cleaned;
  }

  Future<String> _uniqueDocId(String base) async {
    final col = FirebaseFirestore.instance.collection(kFestlnCollection);
    var candidate = base;
    var i = 0;
    while ((await col.doc(candidate).get().timeout(_dbTimeout)).exists) {
      candidate = '$base$i';
      i++;
    }
    return candidate;
  }

  // ---------------------------------------------------------------------------
  // Löschen
  // ---------------------------------------------------------------------------

  Future<void> _delete() async {
    final id = _editingDocId ?? widget.festlId;
    if (id == null || _isSaving) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text('Festl löschen?',
            style: TextStyle(color: AppColors.text)),
        content: const Text(
          'Das Festl wird endgültig aus der Collection entfernt und '
          'verschwindet von der Karte. Diese Aktion kann nicht rückgängig '
          'gemacht werden.',
          style: TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance
          .collection(kFestlnCollection)
          .doc(id)
          .delete();
      _snack('Festl gelöscht.', ok: true);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _snack('Fehler beim Löschen: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<GeoPoint?> _geocode({
    required String address,
    required String city,
    required String country,
  }) async {
    // Mehrere Kombinationen versuchen (robuster als ein einziger String):
    // vollständig → Adresse+Stadt → nur Adresse. Erste Treffer gewinnt.
    final attempts = <String>[
      [address, city, country].where((e) => e.isNotEmpty).join(', '),
      [address, city].where((e) => e.isNotEmpty).join(', '),
      address,
    ];

    for (final q in attempts) {
      if (q.trim().isEmpty) continue;
      try {
        final loc = await GeocodingService.getLocationFromAddress(q);
        if (loc != null) return GeoPoint(loc.latitude, loc.longitude);
      } catch (_) {
        // nächste Kombination versuchen
      }
    }
    return null;
  }

  // Standort auf der Karte wählen (wie bei normalen Partys). Übernimmt die
  // exakten Koordinaten und füllt Adresse/Stadt/Land per Reverse-Geocoding.
  Future<void> _openMapPicker() async {
    FocusScope.of(context).unfocus();

    LatLng initial = LatLng(
      _pickedLat ?? _existingLat ?? 48.2082,
      _pickedLng ?? _existingLng ?? 16.3738,
    );

    // Wenn noch kein Punkt existiert, aber eine Stadt getippt wurde: dort
    // zentrieren, damit man nicht in Wien startet.
    if (_pickedLat == null && _existingLat == null) {
      final city = _cityCtrl.text.trim();
      if (city.isNotEmpty) {
        try {
          final loc = await GeocodingService.getLocationFromAddress(
              [city, _countryCtrl.text.trim()]
                  .where((e) => e.isNotEmpty)
                  .join(', '));
          if (loc != null) initial = LatLng(loc.latitude, loc.longitude);
        } catch (_) {}
      }
    }

    if (!mounted) return;
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => MapPickerScreen(initial: initial)),
    );
    if (picked == null || !mounted) return;

    setState(() {
      _pickedLat = picked.latitude;
      _pickedLng = picked.longitude;
    });

    // Reverse-Geocoding: Adressfelder aus dem gewählten Punkt füllen.
    try {
      final placemarks = await GeocodingService.placemarkFromCoordinates(
          picked.latitude, picked.longitude);
      if (placemarks.isNotEmpty && mounted) {
        final p = placemarks.first;
        String street = (p.street ?? '').trim();
        String number = (p.subThoroughfare ?? '').trim();
        if (number.isNotEmpty && street.contains(number)) number = '';
        final fullStreet =
            [street, number].where((e) => e.isNotEmpty).join(' ');
        final city = (p.locality ?? p.subAdministrativeArea ?? '').trim();
        final country = (p.country ?? '').trim();

        setState(() {
          if (fullStreet.isNotEmpty) _addressCtrl.text = fullStreet;
          if (city.isNotEmpty) _cityCtrl.text = city;
          if (country.isNotEmpty) _countryCtrl.text = country;
        });
      }
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Standort übernommen'),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  InputDecoration _dec(String label,
      {String? hint, IconData? icon, Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.muted),
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.muted),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.panel,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
    );
  }

  String? _req(String? v, String label) =>
      (v == null || v.trim().isEmpty) ? "$label darf nicht leer sein." : null;

  String _fmtDate(DateTime? d) => d == null
      ? "Datum"
      : "${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}";

  String _fmtTime(TimeOfDay? t) => t == null
      ? "Zeit"
      : "${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}";

  @override
  Widget build(BuildContext context) {
    final isEditing = _editingDocId != null || widget.festlId != null;
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        elevation: 0,
        title: Text(isEditing ? 'Festl bearbeiten' : 'Neues Festl'),
      ),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // Cover
            InkWell(
              onTap: _uploadingImage ? null : _pickCover,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 150,
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.accentBorder),
                  image: (_profileImageUrl != null &&
                          _profileImageUrl!.isNotEmpty)
                      ? DecorationImage(
                          image: NetworkImage(_profileImageUrl!),
                          fit: BoxFit.cover)
                      : null,
                ),
                alignment: Alignment.center,
                child: (_profileImageUrl == null || _profileImageUrl!.isEmpty)
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _uploadingImage
                              ? const CircularProgressIndicator()
                              : const Icon(Icons.add_a_photo_outlined,
                                  color: AppColors.muted, size: 28),
                          const SizedBox(height: 6),
                          const Text('Titelbild (optional)',
                              style: TextStyle(color: AppColors.muted)),
                        ],
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 14),

            TextFormField(
              controller: _nameCtrl,
              style: const TextStyle(color: AppColors.text),
              decoration: _dec("Festl-Name", icon: Icons.festival_outlined),
              validator: (v) => _req(v, "Festl-Name"),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _idCtrl,
              enabled: !isEditing,
              style: const TextStyle(color: AppColors.text),
              decoration: _dec(
                isEditing ? "Festl-ID (fix)" : "Festl-ID (optional)",
                hint: isEditing ? null : "leer = automatisch",
                icon: Icons.tag,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _organizerCtrl,
              style: const TextStyle(color: AppColors.text),
              decoration: _dec("Veranstalter", icon: Icons.person_outline),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _linkCtrl,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: AppColors.text),
              decoration:
                  _dec("Link (optional)", hint: "https://…", icon: Icons.link),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              minLines: 3,
              maxLines: null,
              maxLength: 800,
              style: const TextStyle(color: AppColors.text),
              decoration: _dec("Beschreibung", icon: Icons.notes),
              validator: (v) => _req(v, "Beschreibung"),
            ),
            const SizedBox(height: 12),

            // Ort
            TextFormField(
              controller: _addressCtrl,
              style: const TextStyle(color: AppColors.text),
              decoration: _dec(
                "Adresse",
                hint: "z. B. Hauptplatz 1",
                icon: Icons.place_outlined,
                suffix: IconButton(
                  tooltip: "Standort auf Karte wählen",
                  onPressed: _isSaving ? null : _openMapPicker,
                  icon: const Icon(Icons.map_rounded, color: _accent),
                ),
              ),
              validator: (v) {
                // Adresse ist nur Pflicht, wenn KEIN Punkt auf der Karte
                // gewählt wurde (dann reichen die Koordinaten).
                if ((v == null || v.trim().isEmpty) && _pickedLat == null) {
                  return "Adresse eingeben oder Standort auf der Karte wählen.";
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isSaving ? null : _openMapPicker,
                icon: Icon(
                  _pickedLat != null
                      ? Icons.check_circle
                      : Icons.my_location_rounded,
                  size: 18,
                  color: _pickedLat != null ? AppColors.success : _accent,
                ),
                label: Text(
                  _pickedLat != null
                      ? "Standort auf Karte gewählt ✓"
                      : "Standort auf Karte wählen",
                  style: TextStyle(
                    color: _pickedLat != null ? AppColors.success : _accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _cityCtrl,
                    style: const TextStyle(color: AppColors.text),
                    decoration: _dec("Stadt", icon: Icons.location_city),
                    validator: (v) {
                      if ((v == null || v.trim().isEmpty) &&
                          _pickedLat == null) {
                        return "Stadt darf nicht leer sein.";
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _countryCtrl,
                    style: const TextStyle(color: AppColors.text),
                    decoration: _dec("Land", icon: Icons.public),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _minAgeCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppColors.text),
              decoration:
                  _dec("Mindestalter (optional)", icon: Icons.cake_outlined),
            ),
            const SizedBox(height: 18),

            // Zeitraum
            _label("Zeitraum"),
            const SizedBox(height: 8),
            _dateTimeRow(
              label: "Von",
              date: _startDate,
              time: _startTime,
              onDate: () => _pickDate(isStart: true),
              onTime: () => _pickTime(isStart: true),
            ),
            const SizedBox(height: 8),
            _dateTimeRow(
              label: "Bis",
              date: _endDate,
              time: _endTime,
              onDate: () => _pickDate(isStart: false),
              onTime: () => _pickTime(isStart: false),
            ),
            const SizedBox(height: 18),

            // Highlights
            Row(
              children: [
                _label("Highlights"),
                const Spacer(),
                TextButton.icon(
                  onPressed: _addHighlightRow,
                  icon: const Icon(Icons.add, color: _accent, size: 18),
                  label: const Text("Hinzufügen",
                      style: TextStyle(color: _accent)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...List.generate(_highlights.length, _highlightCard),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_rounded),
                label: Text(isEditing ? "Aktualisieren" : "Festl speichern",
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            if (isEditing) ...[
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  onPressed: _isSaving ? null : _delete,
                  icon: const Icon(Icons.delete_outline, color: AppColors.accent),
                  label: const Text('Festl löschen',
                      style: TextStyle(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(t,
      style: const TextStyle(
          color: AppColors.text, fontSize: 16, fontWeight: FontWeight.w800));

  Widget _dateTimeRow({
    required String label,
    required DateTime? date,
    required TimeOfDay? time,
    required VoidCallback onDate,
    required VoidCallback onTime,
  }) {
    return Row(
      children: [
        SizedBox(
            width: 42,
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.muted, fontWeight: FontWeight.w700))),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onDate,
            icon: const Icon(Icons.calendar_today, size: 16, color: _accent),
            label: Text(_fmtDate(date),
                style: const TextStyle(color: AppColors.text)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.accentBorder),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onTime,
            icon: const Icon(Icons.access_time, size: 16, color: _accent),
            label: Text(_fmtTime(time),
                style: const TextStyle(color: AppColors.text)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.accentBorder),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _highlightCard(int i) {
    final h = _highlights[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Highlight ${i + 1}',
                  style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                onPressed: _isSaving ? null : () => _removeHighlightRow(i),
                icon: const Icon(Icons.delete_outline, color: _accent, size: 18),
              ),
            ],
          ),
          InkWell(
            onTap: _isSaving ? null : () => _pickHighlightImage(i),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 130,
              decoration: BoxDecoration(
                color: AppColors.bgBottom,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white24),
                image: (h.imageUrl != null && h.imageUrl!.isNotEmpty)
                    ? DecorationImage(
                        image: NetworkImage(h.imageUrl!), fit: BoxFit.cover)
                    : null,
              ),
              alignment: Alignment.center,
              child: (h.imageUrl == null || h.imageUrl!.isEmpty)
                  ? const Icon(Icons.add_a_photo_outlined,
                      color: Colors.white70)
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: h.textCtrl,
            maxLines: 3,
            minLines: 1,
            style: const TextStyle(color: AppColors.text),
            decoration: const InputDecoration(
              hintText: 'Kurztext (z. B. Line-up, Act, Programm)…',
              hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
              border: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }
}

class _FestlHighlight {
  _FestlHighlight({required this.textCtrl, this.imageUrl});
  final TextEditingController textCtrl;
  String? imageUrl;
}
