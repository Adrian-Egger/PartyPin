// lib/Screens/bar/bar_settings_screen.dart
//
// Zentraler Edit-Screen fuer Bar-Inhaber. Ersetzt das alte 700-Zeilen-Mega-
// BottomSheet. Eine scrollbare Seite mit klar getrennten Sections:
//
//   • Profil       — Logo + Bar-Name
//   • Kontakt      — Email + Telefon
//   • Standort     — Adresse / Stadt / Land (Geocoding beim Save)
//   • Beschreibung — Lange Textbeschreibung
//   • Oeffnungszeiten — Tageweise mit Closed-Toggle und Zeitpicker
//   • Highlights   — Add/remove mit Bild + Text
//
// "Speichern"-Button am Bottom schreibt alle Felder in einem Rutsch
// in das bars/{barId}-Doc. Geocoding nur, wenn Adressfelder geandert wurden.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:image_picker/image_picker.dart';

import '../../Theme/app_theme.dart';

class BarSettingsScreen extends StatefulWidget {
  const BarSettingsScreen({super.key, required this.barId});

  final String barId;

  @override
  State<BarSettingsScreen> createState() => _BarSettingsScreenState();
}

class _BarSettingsScreenState extends State<BarSettingsScreen> {
  static const _days = [
    _Day('mon', 'Montag', 'Mo'),
    _Day('tue', 'Dienstag', 'Di'),
    _Day('wed', 'Mittwoch', 'Mi'),
    _Day('thu', 'Donnerstag', 'Do'),
    _Day('fri', 'Freitag', 'Fr'),
    _Day('sat', 'Samstag', 'Sa'),
    _Day('sun', 'Sonntag', 'So'),
  ];

  // Form controllers
  final _barNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _countryCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  // Address-Snapshot zum Erkennen, ob Geocoding noetig ist.
  String _initialAddress = '';
  String _initialCity = '';
  String _initialCountry = '';

  String? _logoUrl;
  File? _newLogoFile;

  final Map<String, _Hours> _opening = {};

  final List<_Highlight> _highlights = [];

  bool _loading = true;
  bool _saving = false;
  String? _error;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    for (final d in _days) {
      _opening[d.key] = _Hours(closed: false);
    }
    _load();
  }

  @override
  void dispose() {
    _barNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _countryCtrl.dispose();
    _descCtrl.dispose();
    for (final h in _highlights) {
      h.text.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('bars')
          .doc(widget.barId)
          .get();
      if (!snap.exists) {
        setState(() {
          _loading = false;
          _error = 'Bar nicht gefunden.';
        });
        return;
      }
      final d = snap.data() ?? {};

      _barNameCtrl.text = (d['barName'] ?? '').toString();
      _emailCtrl.text = (d['email'] ?? '').toString();
      _phoneCtrl.text = (d['phoneNumber'] ?? '').toString();
      _addressCtrl.text = (d['address'] ?? '').toString();
      _cityCtrl.text = (d['city'] ?? '').toString();
      _countryCtrl.text = (d['country'] ?? '').toString();
      _descCtrl.text = (d['description'] ?? '').toString();
      _logoUrl = (d['profileImageUrl'] ?? '').toString().trim();
      if (_logoUrl!.isEmpty) _logoUrl = null;

      _initialAddress = _addressCtrl.text;
      _initialCity = _cityCtrl.text;
      _initialCountry = _countryCtrl.text;

      // Oeffnungszeiten parsen
      final openingMap = (d['openingHours'] as Map?) ?? {};
      for (final day in _days) {
        final entry = openingMap[day.key] as Map?;
        if (entry == null) continue;
        _opening[day.key] = _Hours(
          closed: entry['closed'] == true,
          from: _parseTime(entry['open']),
          to: _parseTime(entry['close']),
        );
      }

      // Highlights parsen
      final hl = (d['barHighlights'] as List?) ?? const [];
      for (final raw in hl) {
        if (raw is Map) {
          _highlights.add(_Highlight(
            text: TextEditingController(
                text: (raw['text'] ?? '').toString()),
            imageUrl: (raw['imageUrl'] ?? '').toString().trim(),
          ));
        }
      }
      if (_highlights.isEmpty) {
        _highlights.add(_Highlight(text: TextEditingController()));
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Fehler beim Laden: $e';
      });
    }
  }

  TimeOfDay? _parseTime(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    final p = raw.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _fmtTime(TimeOfDay? t) =>
      t == null ? '--:--' : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';

  // ── Logo ─────────────────────────────────────────────────────────────

  Future<void> _pickLogo() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1080,
      );
      if (picked == null) return;
      setState(() => _newLogoFile = File(picked.path));
    } catch (_) {}
  }

  Future<String?> _uploadLogoIfNew() async {
    if (_newLogoFile == null) return _logoUrl;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref()
          .child('bar_avatars')
          .child('${widget.barId}-$ts.jpg');
      await ref.putFile(_newLogoFile!,
          SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (_) {
      return _logoUrl;
    }
  }

  // ── Highlights ───────────────────────────────────────────────────────

  void _addHighlight() {
    setState(() =>
        _highlights.add(_Highlight(text: TextEditingController())));
  }

  void _removeHighlight(int index) {
    setState(() {
      _highlights[index].text.dispose();
      _highlights.removeAt(index);
      if (_highlights.isEmpty) {
        _highlights.add(_Highlight(text: TextEditingController()));
      }
    });
  }

  Future<void> _pickHighlightImage(int index) async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1080,
      );
      if (picked == null) return;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref()
          .child('bar_highlights')
          .child('${widget.barId}-h$index-$ts.jpg');
      await ref.putFile(File(picked.path),
          SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      if (!mounted) return;
      setState(() => _highlights[index].imageUrl = url);
    } catch (_) {}
  }

  // ── Save ─────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (_saving) return;
    final name = _barNameCtrl.text.trim();
    if (name.isEmpty) {
      _showSnack('Bar-Name darf nicht leer sein.', AppColors.accent);
      return;
    }

    setState(() => _saving = true);
    try {
      final logoUrl = await _uploadLogoIfNew();

      final addr = _addressCtrl.text.trim();
      final city = _cityCtrl.text.trim();
      final country = _countryCtrl.text.trim();
      final addressChanged = addr != _initialAddress ||
          city != _initialCity ||
          country != _initialCountry;

      Map<String, double>? geoUpdate;
      if (addressChanged && addr.isNotEmpty && city.isNotEmpty) {
        geoUpdate = await _geocode('$addr, $city, $country');
      }

      final openingPayload = <String, dynamic>{
        for (final d in _days)
          d.key: {
            'closed': _opening[d.key]!.closed,
            'open': _opening[d.key]!.closed
                ? null
                : (_opening[d.key]!.from == null
                    ? null
                    : _fmtTime(_opening[d.key]!.from)),
            'close': _opening[d.key]!.closed
                ? null
                : (_opening[d.key]!.to == null
                    ? null
                    : _fmtTime(_opening[d.key]!.to)),
          }
      };

      final highlightsPayload = _highlights
          .where((h) => h.text.text.trim().isNotEmpty || h.imageUrl.isNotEmpty)
          .map((h) => {
                'text': h.text.text.trim(),
                'imageUrl': h.imageUrl,
              })
          .toList();

      final data = <String, dynamic>{
        'barName': name,
        'barName_lower': name.toLowerCase(),
        'email': _emailCtrl.text.trim(),
        'phoneNumber': _phoneCtrl.text.trim(),
        'address': addr,
        'city': city,
        'city_lower': city.toLowerCase(),
        'country': country,
        'description': _descCtrl.text.trim(),
        'openingHours': openingPayload,
        'barHighlights': highlightsPayload,
        if (logoUrl != null && logoUrl.isNotEmpty)
          'profileImageUrl': logoUrl,
        if (geoUpdate != null) ...{
          'lat': geoUpdate['lat'],
          'lng': geoUpdate['lng'],
          'location': GeoPoint(geoUpdate['lat']!, geoUpdate['lng']!),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('bars')
          .doc(widget.barId)
          .set(data, SetOptions(merge: true));

      if (!mounted) return;
      _showSnack('Änderungen gespeichert ✅', AppColors.success);
      // kurz warten, dann zurueck
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      _showSnack('Fehler beim Speichern: $e', AppColors.accent);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Map<String, double>?> _geocode(String query) async {
    try {
      final results = await geo.locationFromAddress(query);
      if (results.isEmpty) return null;
      return {
        'lat': results.first.latitude,
        'lng': results.first.longitude,
      };
    } catch (_) {
      return null;
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
    ));
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        elevation: 0,
        title: const Text('Bar-Einstellungen'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.muted)),
                  ),
                )
              : _buildBody(),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:
                        RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Speichern',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        _section(
          icon: Icons.local_bar_rounded,
          title: 'Profil',
          child: Column(
            children: [
              GestureDetector(
                onTap: _pickLogo,
                child: Row(
                  children: [
                    _logoPreview(),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Bar-Logo',
                              style: TextStyle(
                                  color: AppColors.text,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(
                            _newLogoFile != null
                                ? 'Neu — wird beim Speichern hochgeladen'
                                : (_logoUrl == null
                                    ? 'Kein Logo · tippen zum Hinzufügen'
                                    : 'Tippen zum Ändern'),
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.edit_outlined,
                        color: AppColors.muted),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _field(
                controller: _barNameCtrl,
                label: 'Bar-Name',
                icon: Icons.storefront_rounded,
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.contact_mail_outlined,
          title: 'Kontakt',
          child: Column(
            children: [
              _field(
                controller: _emailCtrl,
                label: 'E-Mail',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
              ),
              _field(
                controller: _phoneCtrl,
                label: 'Telefon',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.location_on_outlined,
          title: 'Standort',
          subtitle:
              'Wenn du die Adresse änderst, suchen wir die Koordinaten neu.',
          child: Column(
            children: [
              _field(
                controller: _addressCtrl,
                label: 'Straße + Nr.',
                icon: Icons.home_outlined,
              ),
              _field(
                controller: _cityCtrl,
                label: 'Stadt',
                icon: Icons.location_city_outlined,
              ),
              _field(
                controller: _countryCtrl,
                label: 'Land',
                icon: Icons.flag_outlined,
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.description_outlined,
          title: 'Beschreibung',
          child: TextField(
            controller: _descCtrl,
            maxLines: 5,
            maxLength: 500,
            style: const TextStyle(color: AppColors.text),
            decoration: InputDecoration(
              hintText: 'Was macht deine Bar besonders?',
              hintStyle: const TextStyle(color: AppColors.subtle),
              filled: true,
              fillColor: AppColors.panelAlt,
              border: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide: const BorderSide(color: AppColors.accentBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide: const BorderSide(color: AppColors.accentBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide:
                    const BorderSide(color: AppColors.accent, width: 1.5),
              ),
            ),
          ),
        ),
        _section(
          icon: Icons.access_time_rounded,
          title: 'Öffnungszeiten',
          child: Column(
            children: _days.map(_buildOpeningRow).toList(),
          ),
        ),
        _section(
          icon: Icons.star_outline_rounded,
          title: 'Highlights',
          subtitle: 'Maximal 5 Cards mit Bild + kurzem Text.',
          child: Column(
            children: [
              for (var i = 0; i < _highlights.length; i++)
                _buildHighlightCard(i),
              if (_highlights.length < 5)
                TextButton.icon(
                  onPressed: _addHighlight,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Highlight hinzufügen'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accent,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logoPreview() {
    final w = 60.0;
    if (_newLogoFile != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(_newLogoFile!,
            width: w, height: w, fit: BoxFit.cover),
      );
    }
    if (_logoUrl != null && _logoUrl!.isNotEmpty) {
      return Container(
        width: w,
        height: w,
        decoration: BoxDecoration(
          color: AppColors.panelAlt,
          borderRadius: BorderRadius.circular(12),
          image: DecorationImage(
            image: NetworkImage(_logoUrl!),
            fit: BoxFit.cover,
          ),
        ),
      );
    }
    return Container(
      width: w,
      height: w,
      decoration: BoxDecoration(
        color: AppColors.panelAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: const Icon(Icons.add_a_photo_outlined,
          color: AppColors.muted),
    );
  }

  Widget _buildOpeningRow(_Day d) {
    final h = _opening[d.key]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(d.short,
                style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800)),
          ),
          Expanded(
            child: h.closed
                ? Text(
                    'geschlossen',
                    style: TextStyle(
                        color: AppColors.muted.withOpacity(0.7),
                        fontStyle: FontStyle.italic),
                  )
                : Row(
                    children: [
                      _timeButton(
                        label: _fmtTime(h.from),
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime:
                                h.from ?? const TimeOfDay(hour: 18, minute: 0),
                          );
                          if (picked != null) {
                            setState(() => h.from = picked);
                          }
                        },
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child:
                            Text('–', style: TextStyle(color: AppColors.muted)),
                      ),
                      _timeButton(
                        label: _fmtTime(h.to),
                        onTap: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime:
                                h.to ?? const TimeOfDay(hour: 23, minute: 0),
                          );
                          if (picked != null) {
                            setState(() => h.to = picked);
                          }
                        },
                      ),
                    ],
                  ),
          ),
          Switch(
            value: !h.closed,
            activeColor: AppColors.accent,
            onChanged: (open) => setState(() {
              h.closed = !open;
              if (h.closed) {
                h.from = null;
                h.to = null;
              }
            }),
          ),
        ],
      ),
    );
  }

  Widget _timeButton({required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.panelAlt,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accentBorder),
        ),
        child: Text(label,
            style: const TextStyle(
                color: AppColors.text,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _buildHighlightCard(int i) {
    final h = _highlights[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panelAlt,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => _pickHighlightImage(i),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.bgTop,
                    borderRadius: BorderRadius.circular(8),
                    image: h.imageUrl.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(h.imageUrl),
                            fit: BoxFit.cover)
                        : null,
                  ),
                  child: h.imageUrl.isEmpty
                      ? const Icon(Icons.add_photo_alternate_outlined,
                          color: AppColors.muted)
                      : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: h.text,
                  maxLength: 80,
                  maxLines: 2,
                  style: const TextStyle(color: AppColors.text),
                  decoration: const InputDecoration(
                    hintText: 'Kurzer Text…',
                    hintStyle: TextStyle(color: AppColors.subtle),
                    border: InputBorder.none,
                    counterText: '',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.muted, size: 20),
                onPressed: () => _removeHighlight(i),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.mdBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle,
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12, height: 1.35)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(color: AppColors.text),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: AppColors.muted, size: 20),
          filled: true,
          fillColor: AppColors.panelAlt,
          border: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide: const BorderSide(color: AppColors.accentBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide: const BorderSide(color: AppColors.accentBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide:
                const BorderSide(color: AppColors.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _Day {
  const _Day(this.key, this.label, this.short);
  final String key;
  final String label;
  final String short;
}

class _Hours {
  _Hours({this.closed = false, this.from, this.to});
  bool closed;
  TimeOfDay? from;
  TimeOfDay? to;
}

class _Highlight {
  _Highlight({required this.text, this.imageUrl = ''});
  TextEditingController text;
  String imageUrl;
}
