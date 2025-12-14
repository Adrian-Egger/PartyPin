// lib/Screens/admin_create_bar_screen.dart
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geocoding/geocoding.dart' as geocoding;

class AdminCreateBarScreen extends StatefulWidget {
  const AdminCreateBarScreen({Key? key}) : super(key: key);

  @override
  State<AdminCreateBarScreen> createState() => _AdminCreateBarScreenState();
}

class _AdminCreateBarScreenState extends State<AdminCreateBarScreen> {
  // muss zu MenuScreen._adminUsername passen
  static const String kAdminUsername = "admin_pp";

  // ✅ DEINE Collection aus Firestore
  static const String kBarRequestsCollection = "barAnfragen";

  final _formKey = GlobalKey<FormState>();

  final _barNameController = TextEditingController();
  final _barIdController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _countryController = TextEditingController(text: "Austria");
  final _descController = TextEditingController();

  bool _isSaving = false;
  bool _uploadingImage = false;
  String _status = "approved";

  // Profilbild
  File? _pickedImageFile; // für Android/iOS/Desktop (für Preview)
  String? _profileImageUrl; // Download-URL von Firebase Storage

  // aktuell geladene Bar (für Update)
  String? _editingBarDocId;

  // Admin-Bereich: 0 = Bars, 1 = Bar-Anfragen, 2 = Stats
  int _selectedSection = 0;
  Future<Map<String, dynamic>>? _statsFuture;

  // Bar-Highlights (Bild + kurzer Text)
  final List<_BarHighlight> _barHighlights = [];

  // Öffnungszeiten (mon..sun)
  final Map<String, _OpeningHoursDay> _openingHours = {};

  // Farben
  static const _bg = Color(0xFF0E0F12);
  static const _panel = Color(0xFF15171C);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _card = Color(0xFF1C1F26);
  static const _textPrimary = Colors.white;
  static const _textSecondary = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);
  static const _secondary = Color(0xFF00C2A8);

  // Wochentage-Definition
  static const List<_DayMeta> _days = [
    _DayMeta(key: 'mon', label: 'Montag', short: 'Mo', emoji: '📅'),
    _DayMeta(key: 'tue', label: 'Dienstag', short: 'Di', emoji: '📅'),
    _DayMeta(key: 'wed', label: 'Mittwoch', short: 'Mi', emoji: '📅'),
    _DayMeta(key: 'thu', label: 'Donnerstag', short: 'Do', emoji: '📅'),
    _DayMeta(key: 'fri', label: 'Freitag', short: 'Fr', emoji: '🎉'),
    _DayMeta(key: 'sat', label: 'Samstag', short: 'Sa', emoji: '🎉'),
    _DayMeta(key: 'sun', label: 'Sonntag', short: 'So', emoji: '🌙'),
  ];

  @override
  void initState() {
    super.initState();
    _initOpeningHoursDefaults();
    _addHighlightRow(); // mindestens 1 Highlight
    _checkAdmin();
    _statsFuture = _fetchStats();
  }

  // ✅ Timestamp lesbar (Datum + Uhrzeit)
  String formatTimestamp(dynamic value) {
    if (value == null) return '';
    if (value is Timestamp) {
      final dt = value.toDate();
      return "${dt.day.toString().padLeft(2, '0')}."
          "${dt.month.toString().padLeft(2, '0')}."
          "${dt.year}  "
          "${dt.hour.toString().padLeft(2, '0')}:"
          "${dt.minute.toString().padLeft(2, '0')}:"
          "${dt.second.toString().padLeft(2, '0')}";
    }
    return value.toString();
  }

  Future<void> _checkAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final currentUsername = prefs.getString("currentUsername");

    if (!mounted) return;

    if (currentUsername != kAdminUsername) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Kein Zugriff (nur Admin).")),
      );
      Navigator.of(context).pop();
    }
  }

  void _initOpeningHoursDefaults() {
    _openingHours.clear();
    for (final d in _days) {
      _openingHours[d.key] = _OpeningHoursDay(
        closed: false,
        from: null,
        to: null,
      );
    }
  }

  @override
  void dispose() {
    _barNameController.dispose();
    _barIdController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _countryController.dispose();
    _descController.dispose();
    for (final h in _barHighlights) {
      h.textCtrl.dispose();
    }
    super.dispose();
  }

  InputDecoration _dec({
    required String label,
    String? hint,
    IconData? icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textSecondary),
      hintText: hint,
      hintStyle: const TextStyle(color: _textSecondary),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      suffixIcon: suffix,
      filled: true,
      fillColor: _card,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
      errorStyle: const TextStyle(color: _accent),
    );
  }

  // ---------------------------------------------------------------------------
  // Bild auswählen & hochladen
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUploadImage() async {
    if (_uploadingImage) return;

    try {
      setState(() => _uploadingImage = true);

      Uint8List? bytes;
      String fileName;

      // WEB oder Desktop: FilePicker
      if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
        final result = await FilePicker.platform.pickFiles(type: FileType.image);
        if (result == null || result.files.isEmpty) {
          setState(() => _uploadingImage = false);
          return;
        }

        final file = result.files.first;
        if (file.bytes == null) {
          if (file.path == null) {
            setState(() => _uploadingImage = false);
            return;
          }
          final f = File(file.path!);
          bytes = await f.readAsBytes();
        } else {
          bytes = file.bytes!;
        }

        fileName =
        'barInfos/profile_${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      } else {
        // Android / iOS: ImagePicker (Galerie)
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        if (picked == null) {
          setState(() => _uploadingImage = false);
          return;
        }
        final file = File(picked.path);
        bytes = await file.readAsBytes();
        fileName =
        'barInfos/profile_${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
        _pickedImageFile = file;
      }

      if (bytes == null) {
        setState(() => _uploadingImage = false);
        return;
      }

      final ref = FirebaseStorage.instance.ref().child(fileName);
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();

      setState(() {
        _profileImageUrl = url;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Profilbild hochgeladen.")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Bild-Upload: $e")),
      );
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Bar-Highlights (Bild + Text)
  // ---------------------------------------------------------------------------

  void _addHighlightRow() {
    _barHighlights.add(_BarHighlight(textCtrl: TextEditingController()));
    setState(() {});
  }

  void _removeHighlightRow(int index) {
    if (_barHighlights.length == 1) {
      _barHighlights[index].textCtrl.clear();
      _barHighlights[index].imageFile = null;
      _barHighlights[index].imageUrl = null;
    } else {
      _barHighlights[index].textCtrl.dispose();
      _barHighlights.removeAt(index);
    }
    setState(() {});
  }

  Future<void> _pickImageForHighlight(int index) async {
    if (_isSaving) return;

    try {
      Uint8List? bytes;
      String fileName;

      if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
        final result = await FilePicker.platform.pickFiles(type: FileType.image);
        if (result == null || result.files.isEmpty) return;
        final file = result.files.first;
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (file.path != null) {
          final f = File(file.path!);
          bytes = await f.readAsBytes();
        }
        fileName =
        'barInfos/highlight_${DateTime.now().millisecondsSinceEpoch}_${file.name}';
      } else {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        if (picked == null) return;
        final f = File(picked.path);
        bytes = await f.readAsBytes();
        fileName =
        'barInfos/highlight_${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
        _barHighlights[index].imageFile = f;
      }

      if (bytes == null) return;

      final ref = FirebaseStorage.instance.ref().child(fileName);
      await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();

      setState(() {
        _barHighlights[index].imageUrl = url;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Highlight-Bild-Upload: $e")),
      );
    }
  }

  Future<List<Map<String, dynamic>>> _uploadHighlightsAndBuildPayload() async {
    final storage = FirebaseStorage.instance;
    final List<Map<String, dynamic>> result = [];

    for (var i = 0; i < _barHighlights.length; i++) {
      final h = _barHighlights[i];
      final text = h.textCtrl.text.trim();
      final hasImageFile = h.imageFile != null;
      final hasImageUrl = h.imageUrl != null && h.imageUrl!.isNotEmpty;

      if (text.isEmpty && !hasImageFile && !hasImageUrl) continue;

      String? imageUrl = h.imageUrl;

      if (h.imageFile != null && (imageUrl == null || imageUrl.isEmpty)) {
        final fileName =
            'barInfos/highlight_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        final ref = storage.ref().child(fileName);
        await ref.putFile(h.imageFile!);
        imageUrl = await ref.getDownloadURL();
      }

      result.add({
        'text': text,
        'imageUrl': imageUrl,
      });
    }

    return result;
  }

  List<Widget> _buildHighlightRows() {
    final List<Widget> widgets = [];
    for (var i = 0; i < _barHighlights.length; i++) {
      final h = _barHighlights[i];

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1C1F26),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Highlight ${i + 1}',
                      style: const TextStyle(
                        color: _textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _isSaving ? null : () => _removeHighlightRow(i),
                      icon: const Icon(Icons.delete_outline, color: _accent, size: 18),
                      tooltip: 'Highlight entfernen',
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _highlightImageCard(index: i, highlight: h),
                const SizedBox(height: 8),
                _highlightTextCard(highlight: h),
              ],
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _highlightImageCard({
    required int index,
    required _BarHighlight highlight,
  }) {
    Widget child;
    if (!kIsWeb && highlight.imageFile != null) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          highlight.imageFile!,
          height: 140,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
      );
    } else if (highlight.imageUrl != null && highlight.imageUrl!.trim().isNotEmpty) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          highlight.imageUrl!,
          height: 140,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
      );
    } else {
      child = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.add_a_photo, color: Colors.white70),
          SizedBox(height: 4),
          Text('Bild hinzufügen', style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      );
    }

    return InkWell(
      onTap: _isSaving ? null : () => _pickImageForHighlight(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: child,
      ),
    );
  }

  Widget _highlightTextCard({required _BarHighlight highlight}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: highlight.textCtrl,
        maxLines: 3,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          labelText: 'Kurztext zum Highlight',
          labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
          hintText: 'z. B. Signature Drink, DJ, Interior, Aktion ...',
          hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
          border: InputBorder.none,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Öffnungszeiten
  // ---------------------------------------------------------------------------

  String _formatTimeOfDay(TimeOfDay? t) {
    if (t == null) return '--:--';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  TimeOfDay? _parseTimeOfDay(String? s) {
    if (s == null) return null;
    final text = s.trim();
    if (text.isEmpty) return null;
    final parts = text.split(':');
    if (parts.length != 2) return null;
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    if (hh == null || mm == null) return null;
    if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
    return TimeOfDay(hour: hh, minute: mm);
  }

  Future<void> _pickOpeningTime(String dayKey, bool isFrom) async {
    final day = _openingHours[dayKey];
    if (day == null || day.closed) return;

    final initial = isFrom
        ? (day.from ?? const TimeOfDay(hour: 18, minute: 0))
        : (day.to ?? const TimeOfDay(hour: 23, minute: 0));

    final result = await showTimePicker(context: context, initialTime: initial);
    if (result == null) return;

    setState(() {
      if (isFrom) {
        day.from = result;
      } else {
        day.to = result;
      }
    });
  }

  void _toggleDayClosed(String dayKey) {
    final day = _openingHours[dayKey];
    if (day == null) return;
    setState(() {
      day.closed = !day.closed;
      if (day.closed) {
        day.from = null;
        day.to = null;
      }
    });
  }

  Map<String, dynamic> _buildOpeningHoursPayload() {
    final Map<String, dynamic> map = {};
    _openingHours.forEach((key, value) {
      map[key] = {
        'closed': value.closed,
        'open': value.from == null ? null : _formatTimeOfDay(value.from),
        'close': value.to == null ? null : _formatTimeOfDay(value.to),
      };
    });
    return map;
  }

  Widget _buildOpeningHoursSection() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: const [
              Icon(Icons.access_time, color: _secondary),
              SizedBox(width: 8),
              Text(
                "Öffnungszeiten",
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            "Trage für jeden Tag die Zeiten ein oder markiere ihn als geschlossen.",
            style: TextStyle(color: _textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 14),
          ..._days.map(_buildOpeningRow),
        ],
      ),
    );
  }

  Widget _buildOpeningRow(_DayMeta dayMeta) {
    final day = _openingHours[dayMeta.key]!;
    final closed = day.closed;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Row(
              children: [
                Text(dayMeta.emoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 4),
                Text(
                  dayMeta.short,
                  style: const TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (closed)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.redAccent),
                ),
                child: const Text(
                  "Geschlossen",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                      _isSaving ? null : () => _pickOpeningTime(dayMeta.key, true),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        backgroundColor: const Color(0xFF141A22),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      child: Text(
                        "von ${_formatTimeOfDay(day.from)}",
                        style: const TextStyle(color: _textPrimary, fontSize: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                      _isSaving ? null : () => _pickOpeningTime(dayMeta.key, false),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        backgroundColor: const Color(0xFF141A22),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      child: Text(
                        "bis ${_formatTimeOfDay(day.to)}",
                        style: const TextStyle(color: _textPrimary, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(width: 6),
          InkWell(
            onTap: _isSaving ? null : () => _toggleDayClosed(dayMeta.key),
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: closed ? Colors.redAccent.withOpacity(0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: closed ? Colors.redAccent : Colors.white24,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    closed ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 15,
                    color: closed ? Colors.redAccent : Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  const Text("geschlossen",
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Geocoding: Adresse -> Koordinaten
  // ---------------------------------------------------------------------------

  Future<GeoPoint?> _geocodeAddress({
    required String address,
    required String city,
    required String country,
  }) async {
    final full = '$address, $city, $country';
    try {
      final locations = await geocoding.locationFromAddress(full);

      if (locations.isEmpty) {
        if (!mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Adresse konnte nicht gefunden werden. Bitte prüfen.')),
        );
        return null;
      }

      final loc = locations.first;
      return GeoPoint(loc.latitude, loc.longitude);
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Adresse konnte nicht geocodiert werden: $e')),
      );
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Formular / Daten-Logik (Bars)
  // ---------------------------------------------------------------------------

  void _clearForm() {
    setState(() {
      _editingBarDocId = null;
      _barNameController.clear();
      _barIdController.clear();
      _addressController.clear();
      _cityController.clear();
      _countryController.text = "Austria";
      _descController.clear();
      _status = "approved";
      _pickedImageFile = null;
      _profileImageUrl = null;

      for (final h in _barHighlights) {
        h.textCtrl.dispose();
      }
      _barHighlights.clear();
      _addHighlightRow();

      _initOpeningHoursDefaults();
    });
  }

  void _loadBarIntoForm(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    setState(() {
      _editingBarDocId = doc.id;
      _barNameController.text = (data['barName'] ?? '').toString();
      _barIdController.text = (data['barId'] ?? '').toString();
      _addressController.text = (data['address'] ?? '').toString();
      _cityController.text = (data['city'] ?? '').toString();
      _countryController.text = (data['country'] ?? 'Austria').toString();
      _descController.text = (data['description'] ?? '').toString();
      _status = (data['status'] ?? 'approved').toString();
      _profileImageUrl = (data['profileImageUrl'] ?? '').toString();
      _pickedImageFile = null;

      for (final h in _barHighlights) {
        h.textCtrl.dispose();
      }
      _barHighlights.clear();

      final rawHighlights = data['barHighlights'];
      if (rawHighlights is List) {
        for (final item in rawHighlights) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item as Map);
          final ctrl = TextEditingController(text: (map['text'] ?? '').toString());
          _barHighlights.add(
            _BarHighlight(
              textCtrl: ctrl,
              imageUrl: (map['imageUrl'] ?? '').toString(),
            ),
          );
        }
      }
      if (_barHighlights.isEmpty) _addHighlightRow();

      _initOpeningHoursDefaults();
      final rawHours = data['openingHours'];
      if (rawHours is Map) {
        final map = Map<String, dynamic>.from(rawHours);
        for (final d in _days) {
          final rawDay = map[d.key];
          if (rawDay is! Map) continue;
          final dm = Map<String, dynamic>.from(rawDay as Map);
          final closed = dm['closed'] == true;
          final openStr = (dm['open'] ?? '').toString();
          final closeStr = (dm['close'] ?? '').toString();
          _openingHours[d.key] = _OpeningHoursDay(
            closed: closed,
            from: closed ? null : _parseTimeOfDay(openStr),
            to: closed ? null : _parseTimeOfDay(closeStr),
          );
        }
      }
    });
  }

  Future<void> _saveBar() async {
    if (_isSaving) return;

    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bitte alle Pflichtfelder korrekt ausfüllen.")),
      );
      return;
    }

    final barName = _barNameController.text.trim();
    final barId = _barIdController.text.trim();
    final address = _addressController.text.trim();
    final city = _cityController.text.trim();
    final country = _countryController.text.trim();
    final desc = _descController.text.trim();

    setState(() => _isSaving = true);

    try {
      final geo = await _geocodeAddress(address: address, city: city, country: country);
      if (geo == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Adresse konnte nicht geocodiert werden. Bitte prüfen.')),
        );
        setState(() => _isSaving = false);
        return;
      }

      final docId = barId;
      final docRef = FirebaseFirestore.instance.collection("bars").doc(docId);
      final existing = await docRef.get();

      final highlightsPayload = await _uploadHighlightsAndBuildPayload();
      final openingHoursPayload = _buildOpeningHoursPayload();

      final data = <String, dynamic>{
        "barName": barName,
        "barId": barId,
        "address": address,
        "city": city,
        "country": country,
        "description": desc,
        "status": _status,
        "createdByAdmin": true,
        "updatedAt": FieldValue.serverTimestamp(),
        "barHighlights": highlightsPayload,
        "openingHours": openingHoursPayload,

        "location": geo,
        "lat": geo.latitude,
        "lng": geo.longitude,
        "city_lower": city.toLowerCase(),
        "barName_lower": barName.toLowerCase(),

        if (_profileImageUrl != null && _profileImageUrl!.isNotEmpty)
          "profileImageUrl": _profileImageUrl,
        if (!existing.exists) "createdAt": FieldValue.serverTimestamp(),
      };

      if (existing.exists) {
        await docRef.update(data);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Bar aktualisiert.")),
        );
      } else {
        await docRef.set(data);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Bar angelegt.")),
        );
      }

      setState(() {
        _editingBarDocId = docId;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Speichern: $e")),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Stats-Logik
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _fetchStats() async {
    final fs = FirebaseFirestore.instance;

    final usersSnap = await fs.collection('users').get();
    final totalUsers = usersSnap.size;

    final partiesSnap = await fs.collection('Party').get();
    final totalParties = partiesSnap.size;

    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));

    final todaysQuerySnap = await fs
        .collection('Party')
        .where('requests.startTime', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
        .where('requests.startTime', isLessThan: Timestamp.fromDate(endOfDay))
        .get();

    final todaysParties = todaysQuerySnap.size;

    final activeParties = todaysQuerySnap.docs.where((doc) {
      final data = doc.data() as Map<String, dynamic>;
      final req = data['requests'] as Map<String, dynamic>?;
      final ts = req?['startTime'] as Timestamp?;
      if (ts == null) return false;
      final start = ts.toDate();
      return !start.isAfter(now);
    }).length;

    final approvedBarsSnap =
    await fs.collection('bars').where('status', isEqualTo: 'approved').get();
    final pendingBarsSnap =
    await fs.collection('bars').where('status', isEqualTo: 'pending').get();
    final declinedBarsSnap =
    await fs.collection('bars').where('status', isEqualTo: 'declined').get();

    return {
      "totalUsers": totalUsers,
      "totalParties": totalParties,
      "todaysParties": todaysParties,
      "activeParties": activeParties,
      "approvedBars": approvedBarsSnap.size,
      "pendingBars": pendingBarsSnap.size,
      "declinedBars": declinedBarsSnap.size,
    };
  }

  void _reloadStats() {
    setState(() {
      _statsFuture = _fetchStats();
    });
  }

  // ---------------------------------------------------------------------------
  // Helper: Status (nur Bars)
  // ---------------------------------------------------------------------------

  Color _statusColor(String status) {
    switch (status) {
      case "approved":
        return Colors.greenAccent.shade400;
      case "pending":
        return Colors.orangeAccent.shade400;
      case "declined":
        return Colors.redAccent.shade400;
      default:
        return _textSecondary;
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case "approved":
        return "approved (sichtbar auf Map)";
      case "pending":
        return "pending (noch nicht anzeigen)";
      case "declined":
        return "declined (ausgeblendet)";
      default:
        return status;
    }
  }

  // ---------------------------------------------------------------------------
  // Bar-Anfragen (auslesen + Details + löschen mit doppelter Nachfrage)
  //   ✅ Status entfernt
  //   ✅ createdAt lesbar
  // ---------------------------------------------------------------------------

  Future<void> _confirmAndDeleteBarRequest(DocumentSnapshot doc) async {
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text("Anfrage löschen?", style: TextStyle(color: _textPrimary)),
        content: const Text(
          "Willst du diese Bar-Anfrage wirklich löschen?",
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Abbrechen"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Löschen", style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
    if (first != true) return;

    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text("Wirklich endgültig löschen?",
            style: TextStyle(color: _textPrimary)),
        content: const Text(
          "Diese Aktion kann nicht rückgängig gemacht werden.",
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("Abbrechen"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Endgültig löschen", style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );
    if (second != true) return;

    try {
      await doc.reference.delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bar-Anfrage gelöscht.")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Löschen: $e")),
      );
    }
  }

  void _openBarRequestDetails(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};

    final barName =
    (data['barname'] ?? data['barName'] ?? data['name'] ?? 'Bar-Anfrage')
        .toString();

    Widget row(String label, dynamic value, {bool isTimestamp = false}) {
      final v = isTimestamp ? formatTimestamp(value) : (value ?? '').toString().trim();
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: _textSecondary, fontSize: 11)),
              const SizedBox(height: 4),
              Text(
                v,
                style: const TextStyle(
                  color: _textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 14,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_bar, color: _secondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          barName,
                          style: const TextStyle(
                            color: _textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: _textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  row("Barname", data['barname'] ?? data['barName']),
                  row("Username", data['username']),
                  row("E-Mail", data['email']),
                  row("Telefon", data['phoneNumber']),
                  row("Hinweis", data['availabilityNote']),
                  row("Erstellt am", data['createdAt'], isTimestamp: true),

                  const SizedBox(height: 6),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await _confirmAndDeleteBarRequest(doc);
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text(
                        "Anfrage löschen",
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBarRequestsSection() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.mark_email_unread, color: _secondary),
              SizedBox(width: 8),
              Text(
                "Bar-Anfragen",
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 520,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection(kBarRequestsCollection)
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: _secondary),
                  );
                }

                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      "Fehler beim Laden:\n${snapshot.error}",
                      style: const TextStyle(color: _accent),
                    ),
                  );
                }

                final docs = snapshot.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      "Keine Bar-Anfragen vorhanden.",
                      style: TextStyle(color: _textSecondary),
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(color: _panelBorder),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = (doc.data() as Map<String, dynamic>?) ?? {};

                    final name = (data['barname'] ??
                        data['barName'] ??
                        data['name'] ??
                        'Unbenannt')
                        .toString();

                    final created = formatTimestamp(data['createdAt']);
                    final username = (data['username'] ?? '').toString().trim();

                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.inbox, color: _secondary),
                      title: Text(
                        name,
                        style: const TextStyle(
                          color: _textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // ✅ statt Status: Username + Datum/Uhrzeit
                      subtitle: Text(
                        [
                          if (username.isNotEmpty) username,
                          if (created.isNotEmpty) created,
                        ].join(" • "),
                        style: const TextStyle(color: _textSecondary, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: "Löschen",
                        onPressed: () => _confirmAndDeleteBarRequest(doc),
                        icon: const Icon(Icons.delete_outline, color: _accent),
                      ),
                      onTap: () => _openBarRequestDetails(doc),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI-Bausteine
  // ---------------------------------------------------------------------------

  Widget _buildSectionSelector() {
    Widget chip({required int index, required String text}) {
      final selected = _selectedSection == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _selectedSection = index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? _accent : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: Text(
              text,
              style: TextStyle(
                color: selected ? Colors.white : _textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          chip(index: 0, text: "Bars verwalten"),
          const SizedBox(width: 4),
          chip(index: 1, text: "Bar-Anfragen"),
          const SizedBox(width: 4),
          chip(index: 2, text: "Statistiken"),
        ],
      ),
    );
  }

  Widget _buildStatTile({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _panelBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: _secondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: _textSecondary, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsSection() {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics, color: _secondary),
              const SizedBox(width: 8),
              const Text(
                "Übersicht & Statistiken",
                style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _reloadStats,
                icon: const Icon(Icons.refresh, color: _textSecondary),
                tooltip: "Aktualisieren",
              ),
            ],
          ),
          const SizedBox(height: 12),
          FutureBuilder<Map<String, dynamic>>(
            future: _statsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: CircularProgressIndicator(color: _secondary),
                  ),
                );
              }

              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    "Fehler beim Laden der Statistiken:\n${snapshot.error}",
                    style: const TextStyle(color: _accent),
                  ),
                );
              }

              final data = snapshot.data ?? {};
              final totalUsers = data["totalUsers"] ?? 0;
              final totalParties = data["totalParties"] ?? 0;
              final todaysParties = data["todaysParties"] ?? 0;
              final activeParties = data["activeParties"] ?? 0;
              final approvedBars = data["approvedBars"] ?? 0;
              final pendingBars = data["pendingBars"] ?? 0;
              final declinedBars = data["declinedBars"] ?? 0;

              return Column(
                children: [
                  _buildStatTile(
                    title: "Registrierte User gesamt",
                    value: totalUsers.toString(),
                    icon: Icons.people_alt,
                  ),
                  const SizedBox(height: 10),
                  _buildStatTile(
                    title: "Partys gesamt",
                    value: totalParties.toString(),
                    icon: Icons.celebration,
                  ),
                  const SizedBox(height: 10),
                  _buildStatTile(
                    title: "Partys heute (Startdatum = heute)",
                    value: todaysParties.toString(),
                    icon: Icons.today,
                  ),
                  const SizedBox(height: 10),
                  _buildStatTile(
                    title: "Aktuell laufende Partys (Start heute, schon gestartet)",
                    value: activeParties.toString(),
                    icon: Icons.access_time_filled,
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: _panelBorder),
                  const SizedBox(height: 12),
                  Row(
                    children: const [
                      Icon(Icons.local_bar, color: _secondary),
                      SizedBox(width: 8),
                      Text(
                        "Bars nach Status",
                        style: TextStyle(
                          color: _textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatTile(
                          title: "approved",
                          value: approvedBars.toString(),
                          icon: Icons.check_circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatTile(
                          title: "pending",
                          value: pendingBars.toString(),
                          icon: Icons.access_time,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatTile(
                          title: "declined",
                          value: declinedBars.toString(),
                          icon: Icons.cancel,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBarsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Liste aller Bars
        Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _panelBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.list, color: _secondary),
                  const SizedBox(width: 8),
                  const Text(
                    "Bestehende Bars",
                    style: TextStyle(
                      color: _textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _clearForm,
                    icon: const Icon(Icons.add, color: _accent),
                    label: const Text(
                      "Neue Bar",
                      style: TextStyle(color: _accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('bars')
                      .orderBy('barName')
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !snapshot.hasData) {
                      return const Center(
                        child: CircularProgressIndicator(color: _secondary),
                      );
                    }
                    final docs = snapshot.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const Center(
                        child: Text("Noch keine Bars angelegt.",
                            style: TextStyle(color: _textSecondary)),
                      );
                    }
                    return ListView.separated(
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(color: _panelBorder),
                      itemBuilder: (context, index) {
                        final d = docs[index].data() as Map<String, dynamic>;
                        final name = (d['barName'] ?? 'Unbenannt').toString();
                        final city = (d['city'] ?? '').toString();
                        final status = (d['status'] ?? 'approved').toString();
                        final sel = docs[index].id == _editingBarDocId;

                        return ListTile(
                          dense: true,
                          selected: sel,
                          selectedTileColor: Colors.white.withOpacity(0.05),
                          leading: const Icon(Icons.local_bar, color: _secondary),
                          title: Text(
                            name,
                            style: const TextStyle(
                              color: _textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  city,
                                  style: const TextStyle(
                                    color: _textSecondary,
                                    fontSize: 12,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (city.isNotEmpty && status.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                const Text("•",
                                    style: TextStyle(color: _textSecondary, fontSize: 12)),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                status,
                                style: TextStyle(
                                  color: _statusColor(status),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _loadBarIntoForm(docs[index]),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Formular
        Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _panelBorder),
          ),
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                const Icon(Icons.local_bar, size: 52, color: _secondary),
                const SizedBox(height: 12),
                Text(
                  _editingBarDocId == null ? "Neue Bar anlegen" : "Bar bearbeiten",
                  style: const TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 20),

                // Profilbild
                Row(
                  children: [
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: Colors.grey[800],
                      backgroundImage: (() {
                        ImageProvider? img;
                        if (!kIsWeb && _pickedImageFile != null) {
                          img = FileImage(_pickedImageFile!);
                        } else if (_profileImageUrl != null &&
                            _profileImageUrl!.isNotEmpty) {
                          img = NetworkImage(_profileImageUrl!);
                        }
                        return img;
                      })(),
                      child: (() {
                        final hasImage =
                            (!kIsWeb && _pickedImageFile != null) ||
                                (_profileImageUrl != null &&
                                    _profileImageUrl!.isNotEmpty);
                        if (hasImage) return null;
                        return const Icon(Icons.local_bar,
                            color: _textSecondary, size: 32);
                      })(),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _uploadingImage ? null : _pickAndUploadImage,
                        icon: _uploadingImage
                            ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                            : const Icon(Icons.photo_library),
                        label: Text(
                          _uploadingImage
                              ? "Bild wird hochgeladen..."
                              : "Bild wählen (Galerie / Ordner)",
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                TextFormField(
                  controller: _barNameController,
                  inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'^\s'))],
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: "Name des Lokals / der Bar",
                    icon: Icons.storefront,
                    hint: "z. B. Club XY",
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return "Pflichtfeld";
                    if (v.trim().length < 2) return "Zu kurz";
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _barIdController,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: "Bar-ID (intern, nicht öffentlich)",
                    icon: Icons.tag,
                    hint: "z. B. club_xy_wien",
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_.-]')),
                  ],
                  validator: (v) {
                    final val = v?.trim() ?? '';
                    if (val.isEmpty) return "Pflichtfeld";
                    if (val.length < 3) return "Mind. 3 Zeichen";
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _addressController,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: "Adresse",
                    icon: Icons.location_on,
                    hint: "Straße Hausnummer",
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? "Pflichtfeld" : null,
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _cityController,
                        style: const TextStyle(color: _textPrimary),
                        decoration: _dec(
                          label: "Stadt",
                          icon: Icons.location_city,
                          hint: "z. B. Wien",
                        ),
                        validator: (v) =>
                        (v == null || v.trim().isEmpty) ? "Pflichtfeld" : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _countryController,
                        style: const TextStyle(color: _textPrimary),
                        decoration: _dec(label: "Land", icon: Icons.flag),
                        validator: (v) =>
                        (v == null || v.trim().isEmpty) ? "Pflichtfeld" : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _descController,
                  maxLines: 3,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: "Beschreibung",
                    icon: Icons.notes,
                    hint: "Musik, Zielgruppe, Öffnungszeiten, Specials...",
                  ),
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: _status,
                  dropdownColor: _panel,
                  decoration: _dec(
                    label: "Status / Sichtbarkeit",
                    icon: Icons.visibility,
                  ),
                  selectedItemBuilder: (context) {
                    final values = ["approved", "pending", "declined"];
                    return values.map((v) {
                      final color = _statusColor(v);
                      final label = _statusLabel(v);
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(Icons.circle, size: 12, color: color),
                            const SizedBox(width: 6),
                            Text(
                              label,
                              style: TextStyle(
                                color: color,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList();
                  },
                  style: const TextStyle(color: _textPrimary, fontSize: 14),
                  items: [
                    DropdownMenuItem(
                      value: "approved",
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 12, color: _statusColor("approved")),
                          const SizedBox(width: 6),
                          Text(_statusLabel("approved")),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: "pending",
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 12, color: _statusColor("pending")),
                          const SizedBox(width: 6),
                          Text(_statusLabel("pending")),
                        ],
                      ),
                    ),
                    DropdownMenuItem(
                      value: "declined",
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 12, color: _statusColor("declined")),
                          const SizedBox(width: 6),
                          Text(_statusLabel("declined")),
                        ],
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _status = v);
                  },
                ),
                const SizedBox(height: 20),

                _buildOpeningHoursSection(),
                const SizedBox(height: 20),

                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: const [
                      Icon(Icons.photo_library, color: _secondary, size: 18),
                      SizedBox(width: 6),
                      Text(
                        "Bar-Highlights (Bilder + Text)",
                        style: TextStyle(
                          color: _textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ..._buildHighlightRows(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isSaving ? null : _addHighlightRow,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      backgroundColor: const Color(0xFF141A22),
                    ),
                    icon: const Icon(Icons.add, color: Colors.redAccent),
                    label: const Text('Highlight hinzufügen',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Diese Highlights + Öffnungszeiten werden in der Bar-Ansicht angezeigt.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveBar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      disabledBackgroundColor: Colors.redAccent.withOpacity(0.4),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                        : const Text(
                      "Bar speichern",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 4,
        title: const Text(
          "Admin-Bereich",
          style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSectionSelector(),
                      const SizedBox(height: 18),
                      if (_selectedSection == 0)
                        _buildBarsSection()
                      else if (_selectedSection == 1)
                        _buildBarRequestsSection()
                      else
                        _buildStatsSection(),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------- Hilfs-Klassen ----------------

class _BarHighlight {
  final TextEditingController textCtrl;
  File? imageFile;
  String? imageUrl;

  _BarHighlight({
    required this.textCtrl,
    this.imageFile,
    this.imageUrl,
  });
}

class _OpeningHoursDay {
  bool closed;
  TimeOfDay? from;
  TimeOfDay? to;

  _OpeningHoursDay({
    required this.closed,
    required this.from,
    required this.to,
  });
}

class _DayMeta {
  final String key;
  final String label;
  final String short;
  final String emoji;

  const _DayMeta({
    required this.key,
    required this.label,
    required this.short,
    required this.emoji,
  });
}
