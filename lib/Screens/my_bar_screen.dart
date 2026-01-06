import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../Screens/bar_event_screen.dart';

class MyBarScreen extends StatelessWidget {
  final String barId;
  const MyBarScreen({super.key, required this.barId});

  Stream<DocumentSnapshot<Map<String, dynamic>>> _barStream() {
    return FirebaseFirestore.instance.collection('bars').doc(barId).snapshots();
  }

  Query<Map<String, dynamic>> _eventsQuery() {
    return FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('events')
        .orderBy('startAt', descending: false)
        .limit(80);
  }

  @override
  Widget build(BuildContext context) {
    final id = barId.trim();
    if (id.isEmpty) {
      return const Scaffold(body: Center(child: Text('Keine Bar-ID vorhanden.')));
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _barStream(),
      builder: (context, barSnap) {
        if (barSnap.hasError) {
          return const Scaffold(body: Center(child: Text('Bar konnte nicht geladen werden.')));
        }
        if (!barSnap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!(barSnap.data?.exists ?? false)) {
          return const Scaffold(body: Center(child: Text('Bar existiert nicht (mehr).')));
        }

        final barData = barSnap.data!.data();
        if (barData == null) {
          return const Scaffold(body: Center(child: Text('Bar-Daten fehlen.')));
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _eventsQuery().snapshots(),
          builder: (context, evSnap) {
            final docs = evSnap.data?.docs ?? const [];

            return _MyBarBody(
              barId: id,
              barData: barData,
              eventDocs: docs,
              eventsError: evSnap.hasError ? evSnap.error : null,
              eventsLoading: evSnap.connectionState == ConnectionState.waiting && !evSnap.hasData,
            );
          },
        );
      },
    );
  }
}

class _MyBarBody extends StatefulWidget {
  final String barId;
  final Map<String, dynamic> barData;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> eventDocs;
  final Object? eventsError;
  final bool eventsLoading;

  const _MyBarBody({
    required this.barId,
    required this.barData,
    required this.eventDocs,
    required this.eventsError,
    required this.eventsLoading,
  });

  @override
  State<_MyBarBody> createState() => _MyBarBodyState();
}

class _MyBarBodyState extends State<_MyBarBody> {
  static const _bg = Color(0xFF090B10);
  static const _card = Color(0xFF1C1F26);
  static const _card2 = Color(0xFF141A22);
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);

  bool _showEvent = true;

  bool get _isMobile {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  }

  static const List<_DayMeta> _days = [
    _DayMeta(key: 'mon', short: 'Mo', emoji: '📅'),
    _DayMeta(key: 'tue', short: 'Di', emoji: '📅'),
    _DayMeta(key: 'wed', short: 'Mi', emoji: '📅'),
    _DayMeta(key: 'thu', short: 'Do', emoji: '📅'),
    _DayMeta(key: 'fri', short: 'Fr', emoji: '🎉'),
    _DayMeta(key: 'sat', short: 'Sa', emoji: '🎉'),
    _DayMeta(key: 'sun', short: 'So', emoji: '🌙'),
  ];

  DocumentReference<Map<String, dynamic>> get _barRef =>
      FirebaseFirestore.instance.collection('bars').doc(widget.barId);

  Future<void> _updateBar(Map<String, dynamic> patch) async {
    await _barRef.set(patch, SetOptions(merge: true));
  }

  // ---------------- data helpers ----------------

  DateTime? _readDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    if (v is DateTime) return v;
    return null;
  }

  List<Map<String, dynamic>> _safeHighlights(dynamic raw) {
    if (raw is List) {
      return raw.where((e) => e is Map).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  Map<String, dynamic>? _safeMap(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  bool _isActive(Map<String, dynamic> e) => e['active'] == true;

  bool _notOver(Map<String, dynamic> e) {
    final cleanupAt = _readDate(e['cleanupAt']);
    if (cleanupAt == null) return true;
    return DateTime.now().isBefore(cleanupAt);
  }

  bool _isRunning(Map<String, dynamic> e) {
    final startAt = _readDate(e['startAt']);
    if (startAt == null) return false;
    final start = startAt.subtract(const Duration(hours: 1));
    final cleanupAt = _readDate(e['cleanupAt']) ?? start.add(const Duration(hours: 12));
    final now = DateTime.now();
    return (now.isAfter(start) || now.isAtSameMomentAs(start)) && now.isBefore(cleanupAt);
  }

  // ---------------- opening hours (Admin-like) ----------------

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

  Map<String, _OpeningHoursDay> _openingDefaults() {
    final m = <String, _OpeningHoursDay>{};
    for (final d in _days) {
      m[d.key] = _OpeningHoursDay(closed: false, from: null, to: null);
    }
    return m;
  }

  Map<String, _OpeningHoursDay> _openingFromBar(Map<String, dynamic>? openingHours) {
    final out = _openingDefaults();
    if (openingHours == null) return out;

    for (final d in _days) {
      final rawDay = openingHours[d.key];
      if (rawDay is! Map) continue;
      final dm = Map<String, dynamic>.from(rawDay as Map);
      final closed = dm['closed'] == true;
      final openStr = (dm['open'] ?? '').toString();
      final closeStr = (dm['close'] ?? '').toString();

      out[d.key] = _OpeningHoursDay(
        closed: closed,
        from: closed ? null : _parseTimeOfDay(openStr),
        to: closed ? null : _parseTimeOfDay(closeStr),
      );
    }
    return out;
  }

  Map<String, dynamic> _buildOpeningHoursPayload(Map<String, _OpeningHoursDay> opening) {
    final Map<String, dynamic> map = {};
    opening.forEach((key, value) {
      map[key] = {
        'closed': value.closed,
        'open': value.from == null ? null : _formatTimeOfDay(value.from),
        'close': value.to == null ? null : _formatTimeOfDay(value.to),
      };
    });
    return map;
  }

  // ---------------- image picking/upload (no dart:io, works on all) ----------------

  Future<_PickedImage?> _pickImageBytes() async {
    if (_isMobile) {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (picked == null) return null;
      final bytes = await picked.readAsBytes();
      final name = picked.name.isNotEmpty ? picked.name : 'image.jpg';
      return _PickedImage(bytes: bytes, name: name);
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return null;
    final name = (file.name.isNotEmpty) ? file.name : 'image.jpg';
    return _PickedImage(bytes: bytes, name: name);
  }

  Future<String?> _uploadHighlightImageAndGetUrl() async {
    final picked = await _pickImageBytes();
    if (picked == null) return null;

    final fileName =
        'barInfos/${widget.barId}/highlight_${DateTime.now().millisecondsSinceEpoch}_${picked.name}';

    final ref = FirebaseStorage.instance.ref().child(fileName);
    await ref.putData(picked.bytes, SettableMetadata(contentType: 'image/jpeg'));
    return await ref.getDownloadURL();
  }

  // ---------------- EDIT SHEET ----------------

  Future<void> _openEditBarDetails() async {
    final b = widget.barData;

    final barName = (b['barName'] ?? '').toString();
    final address = (b['address'] ?? '').toString();
    final city = (b['city'] ?? '').toString();
    final country = (b['country'] ?? '').toString();

    final descCtrl = TextEditingController(text: (b['description'] ?? '').toString());

    final rawOpening = _safeMap(b['openingHours']);
    final opening = _openingFromBar(rawOpening);

    final existingHighlights = _safeHighlights(b['barHighlights']);
    final highlights = <_BarHighlight>[];
    if (existingHighlights.isNotEmpty) {
      for (final h in existingHighlights) {
        highlights.add(
          _BarHighlight(
            textCtrl: TextEditingController(text: (h['text'] ?? '').toString()),
            imageUrl: (h['imageUrl'] ?? '').toString().trim(),
          ),
        );
      }
    } else {
      highlights.add(_BarHighlight(textCtrl: TextEditingController()));
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setLocal) {
            bool saving = false;
            bool sheetClosed = false;

            Future<void> pickTime(String dayKey, bool isFrom) async {
              final day = opening[dayKey];
              if (day == null || day.closed) return;

              final initial = isFrom
                  ? (day.from ?? const TimeOfDay(hour: 18, minute: 0))
                  : (day.to ?? const TimeOfDay(hour: 23, minute: 0));

              final result = await showTimePicker(context: sheetCtx, initialTime: initial);
              if (result == null) return;

              if (!sheetCtx.mounted) return;
              setLocal(() {
                if (isFrom) {
                  day.from = result;
                } else {
                  day.to = result;
                }
              });
            }

            void toggleClosed(String dayKey) {
              final day = opening[dayKey];
              if (day == null) return;
              if (!sheetCtx.mounted) return;
              setLocal(() {
                day.closed = !day.closed;
                if (day.closed) {
                  day.from = null;
                  day.to = null;
                }
              });
            }

            void addHighlight() {
              if (!sheetCtx.mounted) return;
              setLocal(() => highlights.add(_BarHighlight(textCtrl: TextEditingController())));
            }

            void removeHighlight(int index) {
              if (highlights.length == 1) {
                highlights[0].textCtrl.clear();
                highlights[0].imageUrl = '';
              } else {
                highlights[index].textCtrl.dispose();
                highlights.removeAt(index);
              }
              if (!sheetCtx.mounted) return;
              setLocal(() {});
            }

            Future<void> pickHighlightImage(int index) async {
              if (saving) return;
              try {
                final url = await _uploadHighlightImageAndGetUrl();
                if (url == null) return;
                if (!sheetCtx.mounted) return;
                setLocal(() => highlights[index].imageUrl = url);
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Fehler beim Bild-Upload: $e')),
                );
              }
            }

            Widget openingRow(_DayMeta meta) {
              final day = opening[meta.key]!;
              final closed = day.closed;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 86,
                      child: Row(
                        children: [
                          Text(meta.emoji, style: const TextStyle(fontSize: 16)),
                          const SizedBox(width: 4),
                          Text(
                            meta.short,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
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
                            color: _accent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _accent),
                          ),
                          child: const Text(
                            "Geschlossen",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _accent, fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: saving ? null : () => pickTime(meta.key, true),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white24),
                                  backgroundColor: _card2,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                                child: Text(
                                  "von ${_formatTimeOfDay(day.from)}",
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: saving ? null : () => pickTime(meta.key, false),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.white24),
                                  backgroundColor: _card2,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                                child: Text(
                                  "bis ${_formatTimeOfDay(day.to)}",
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: saving ? null : () => toggleClosed(meta.key),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: closed ? _accent.withOpacity(0.14) : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: closed ? _accent : Colors.white24),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              closed ? Icons.check_circle : Icons.radio_button_unchecked,
                              size: 15,
                              color: closed ? _accent : Colors.white54,
                            ),
                            const SizedBox(width: 4),
                            const Text("geschlossen", style: TextStyle(color: Colors.white70, fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            Future<void> saveAll() async {
              if (saving) return;
              if (!sheetCtx.mounted) return;

              setLocal(() => saving = true);

              try {
                final highlightsPayload = <Map<String, dynamic>>[];
                for (final h in highlights) {
                  final t = h.textCtrl.text.trim();
                  final u = (h.imageUrl ?? '').trim();
                  if (t.isEmpty && u.isEmpty) continue;
                  highlightsPayload.add({'text': t, 'imageUrl': u});
                }

                final openingPayload = _buildOpeningHoursPayload(opening);

                await _updateBar({
                  'description': descCtrl.text.trim(),
                  'openingHours': openingPayload,
                  'barHighlights': highlightsPayload,
                  'updatedAt': FieldValue.serverTimestamp(),
                });

                if (!mounted) return;
                if (!sheetCtx.mounted) return;

                // ✅ ab hier: KEIN setLocal mehr, wir schließen
                sheetClosed = true;
                Navigator.of(sheetCtx).pop();

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Gespeichert.')),
                );
              } on FirebaseException catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Firebase: ${e.code} ${e.message ?? ''}')),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Fehler beim Speichern: $e')),
                );
              } finally {
                // ✅ nur wenn Sheet noch offen ist
                if (!sheetClosed && sheetCtx.mounted) {
                  setLocal(() => saving = false);
                }
              }
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 14,
                  bottom: 16 + MediaQuery.of(sheetCtx).viewInsets.bottom,
                ),
                child: SizedBox(
                  height: MediaQuery.of(sheetCtx).size.height * 0.92,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.edit, color: Colors.white70),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Bar bearbeiten',
                              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            onPressed: saving ? null : () => Navigator.of(sheetCtx).pop(),
                            icon: const Icon(Icons.close, color: Colors.white54),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _infoReadOnlyCard(
                                title: 'Fixe Daten (nicht editierbar)',
                                lines: [
                                  if (barName.trim().isNotEmpty) 'Name: $barName',
                                  if (address.trim().isNotEmpty) 'Adresse: $address',
                                  if (city.trim().isNotEmpty || country.trim().isNotEmpty)
                                    'Ort: ${[city, country].where((e) => e.trim().isNotEmpty).join(', ')}',
                                ],
                              ),
                              const SizedBox(height: 12),

                              _panelCard(
                                title: 'Beschreibung',
                                child: TextField(
                                  controller: descCtrl,
                                  maxLines: 4,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor: _card2,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: Colors.white24),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(color: _accent),
                                    ),
                                    hintText: 'Beschreibe deine Bar ...',
                                    hintStyle: const TextStyle(color: Colors.white38),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),

                              _panelCard(
                                title: 'Öffnungszeiten',
                                subtitle: 'Wenn noch leer: Zeiten auswählen oder Tage schließen.',
                                child: Column(
                                  children: _days.map(openingRow).toList(),
                                ),
                              ),
                              const SizedBox(height: 12),

                              _panelCard(
                                title: 'Highlights',
                                trailing: OutlinedButton.icon(
                                  onPressed: saving ? null : addHighlight,
                                  icon: const Icon(Icons.add, color: _accent),
                                  label: const Text('Hinzufügen', style: TextStyle(color: _accent)),
                                  style: OutlinedButton.styleFrom(side: const BorderSide(color: _accent)),
                                ),
                                child: Column(
                                  children: List.generate(highlights.length, (i) {
                                    final h = highlights[i];
                                    final url = (h.imageUrl ?? '').trim();

                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: _card2,
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(color: Colors.white12),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                'Highlight ${i + 1}',
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const Spacer(),
                                              IconButton(
                                                onPressed: saving ? null : () => removeHighlight(i),
                                                icon: const Icon(Icons.delete_outline, color: _accent),
                                              ),
                                            ],
                                          ),
                                          InkWell(
                                            onTap: saving ? null : () => pickHighlightImage(i),
                                            borderRadius: BorderRadius.circular(12),
                                            child: Container(
                                              height: 150,
                                              decoration: BoxDecoration(
                                                color: _card,
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(color: Colors.white24),
                                              ),
                                              child: url.isNotEmpty
                                                  ? ClipRRect(
                                                borderRadius: BorderRadius.circular(12),
                                                child: Image.network(
                                                  url,
                                                  fit: BoxFit.cover,
                                                  width: double.infinity,
                                                ),
                                              )
                                                  : Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: const [
                                                  Icon(Icons.add_a_photo, color: Colors.white70),
                                                  SizedBox(height: 6),
                                                  Text('Bild auswählen', style: TextStyle(color: Colors.white54)),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Container(
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: _card,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: Colors.white24),
                                            ),
                                            child: TextField(
                                              controller: h.textCtrl,
                                              maxLines: 3,
                                              style: const TextStyle(color: Colors.white),
                                              decoration: const InputDecoration(
                                                border: InputBorder.none,
                                                labelText: 'Text',
                                                labelStyle: TextStyle(color: Colors.white54),
                                                hintText: 'Kurztext zum Highlight ...',
                                                hintStyle: TextStyle(color: Colors.white38),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: saving ? null : saveAll,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: saving
                              ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                              : const Text('Speichern', style: TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    descCtrl.dispose();
    for (final h in highlights) {
      h.textCtrl.dispose();
    }
  }

  // UI helper cards
  static Widget _panelCard({
    required String title,
    String? subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
              ),
              if (trailing != null) trailing,
            ],
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  static Widget _infoReadOnlyCard({required String title, required List<String> lines}) {
    final clean = lines.where((e) => e.trim().isNotEmpty).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          if (clean.isEmpty)
            const Text('Keine Daten.', style: TextStyle(color: Colors.white60))
          else
            ...clean.map(
                  (t) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(t, style: const TextStyle(color: Colors.white70)),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- MAIN UI ----------------

  @override
  Widget build(BuildContext context) {
    final b = widget.barData;

    final barName = (b['barName'] ?? 'Meine Bar').toString();
    final address = (b['address'] ?? '').toString();
    final city = (b['city'] ?? '').toString();
    final country = (b['country'] ?? '').toString();
    final description = (b['description'] ?? '').toString();
    final profileImageUrl = (b['profileImageUrl'] ?? '').toString().trim();

    final fullAddress = [
      address,
      [city, country].where((e) => e.trim().isNotEmpty).join(', ')
    ].where((e) => e.trim().isNotEmpty).join(' · ');

    final double? ratingAvg = b['ratingAvg'] != null ? (b['ratingAvg'] as num).toDouble() : null;
    final int ratingCount = b['ratingCount'] != null ? (b['ratingCount'] as num).toInt() : 0;

    final openingMap = _safeMap(b['openingHours']);
    final opening = _openingFromBar(openingMap);

    final highlights = _safeHighlights(b['barHighlights']);

    final now = DateTime.now();
    final filtered = widget.eventDocs
        .map((d) => _EventItem(id: d.id, data: d.data()))
        .where((e) {
      if (!_isActive(e.data)) return false;
      if (_readDate(e.data['startAt']) == null) return false;
      if (!_notOver(e.data)) return false;
      final startAt = _readDate(e.data['startAt']);
      if (startAt != null && startAt.isBefore(now.subtract(const Duration(days: 30)))) return false;
      return true;
    })
        .toList();

    final running = filtered.where((e) => _isRunning(e.data)).toList();
    final upcoming = filtered.where((e) => !_isRunning(e.data)).toList();
    final hasAnyEvents = running.isNotEmpty || upcoming.isNotEmpty;

    // ✅ WICHTIG: kein State-Change im build()
    final bool showEvent = hasAnyEvents ? _showEvent : false;

    final avatar = CircleAvatar(
      radius: 46,
      backgroundColor: _card,
      backgroundImage: profileImageUrl.isNotEmpty ? NetworkImage(profileImageUrl) : null,
      child: profileImageUrl.isEmpty ? const Icon(Icons.local_bar, color: Colors.white70, size: 36) : null,
    );

    final redOutlined = OutlinedButton.styleFrom(
      side: const BorderSide(color: _accent),
      foregroundColor: _accent,
    );

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        foregroundColor: Colors.white, // Icons + Text hell
        title: const Text('Meine Bar⭐'),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w900,
        ),
        actions: [
          IconButton(
            tooltip: 'Bar bearbeiten',
            onPressed: _openEditBarDetails,
            icon: const Icon(Icons.edit, color: Colors.white),
          ),
        ],
      ),

      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
        children: [
          Center(child: avatar),
          const SizedBox(height: 12),
          Text(
            barName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          if (ratingAvg != null && ratingCount > 0) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.star, color: Colors.amber, size: 18),
                const SizedBox(width: 6),
                Text(
                  ratingAvg.toStringAsFixed(1),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 6),
                Text('($ratingCount)', style: const TextStyle(color: Colors.white60)),
              ],
            ),
          ],
          if (fullAddress.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.location_on, color: _accent, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(fullAddress, textAlign: TextAlign.center, style: const TextStyle(color: _muted)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),

          if (hasAnyEvents) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _segButton(
                      selected: showEvent,
                      text: 'Events 🎉',
                      onTap: hasAnyEvents ? () => setState(() => _showEvent = true) : () {},
                    ),
                    const SizedBox(width: 6),
                    _segButton(
                      selected: !showEvent,
                      text: 'Bar-Infos 🍹',
                      onTap: () => setState(() => _showEvent = false),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
          ] else ...[
            _sectionTitleCentered('Bar-Infos 🍹'),
            const SizedBox(height: 10),
          ],

          if (showEvent && hasAnyEvents)
            _eventsView(
              context: context,
              running: running,
              upcoming: upcoming,
              loading: widget.eventsLoading,
              error: widget.eventsError,
            )
          else ...[
            _panelCard(
              title: 'Beschreibung 🥂',
              child: Text(
                description.trim().isNotEmpty ? description : 'Keine Beschreibung hinterlegt.',
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ),
            const SizedBox(height: 12),

            _panelCard(
              title: 'Öffnungszeiten ⏰',
              child: Column(
                children: _days.map((d) {
                  final day = opening[d.key]!;
                  final text = day.closed
                      ? 'geschlossen'
                      : '${_formatTimeOfDay(day.from)} – ${_formatTimeOfDay(day.to)}';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(
                            d.short,
                            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            text,
                            style: TextStyle(
                              color: day.closed ? _accent : Colors.white70,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: redOutlined,
                onPressed: _openEditBarDetails,
                icon: const Icon(Icons.edit),
                label: const Text(
                  'Beschreibung, Öffnungszeiten & Highlights bearbeiten',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (highlights.isNotEmpty)
              _panelCard(
                title: 'Highlights ✨',
                child: Column(
                  children: highlights.map((h) => _highlightCard(h)).toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _segButton({
    required bool selected,
    required String text,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? _accent : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontWeight: FontWeight.w900,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _sectionTitleCentered(String title) {
    return Text(
      title,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  // ---------------- Events ----------------

  Widget _eventsView({
    required BuildContext context,
    required List<_EventItem> running,
    required List<_EventItem> upcoming,
    required bool loading,
    required Object? error,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitleCentered('Events 🎉'),
          const SizedBox(height: 12),
          if (loading) ...[
            const Center(child: CircularProgressIndicator(color: _accent)),
            const SizedBox(height: 10),
          ],
          if (error != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _card2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                'Events konnten nicht geladen werden.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (running.isNotEmpty) ...[
            const Text('Läuft gerade 🔥', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            ...running.map((e) => _eventRow(context, e, running: true)),
            const SizedBox(height: 14),
          ],
          if (upcoming.isNotEmpty) ...[
            const Text('Kommende Events', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            ...upcoming.map((e) => _eventRow(context, e, running: false)),
          ],
          if (running.isEmpty && upcoming.isEmpty) ...[
            const Text('Aktuell keine Events.', style: TextStyle(color: Colors.white60)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BarEventScreen(barId: widget.barId, eventId: null),
                  ),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('Event erstellen', style: TextStyle(fontWeight: FontWeight.w900)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _eventRow(BuildContext context, _EventItem item, {required bool running}) {
    final startAt = _readDate(item.data['startAt']);
    final title = (item.data['title'] ?? '').toString().trim();

    final dt = startAt ?? DateTime.now();
    final dateStr = '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _card2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: running ? _accent.withOpacity(0.6) : Colors.white12),
      ),
      child: Row(
        children: [
          Icon(running ? Icons.local_fire_department : Icons.event, color: Colors.white70, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$dateStr · $timeStr — ${title.isEmpty ? 'Event' : title}',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            tooltip: 'Bearbeiten',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BarEventScreen(barId: widget.barId, eventId: item.id),
                ),
              );
            },
            icon: const Icon(Icons.edit, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _highlightCard(Map<String, dynamic> h) {
    final text = (h['text'] ?? '').toString().trim();
    final imageUrl = (h['imageUrl'] ?? '').toString().trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _card2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
              child: Image.network(
                imageUrl,
                height: 150,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          if (text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(text, style: const TextStyle(color: Colors.white70, height: 1.3)),
            ),
        ],
      ),
    );
  }
}

class _EventItem {
  final String id;
  final Map<String, dynamic> data;
  _EventItem({required this.id, required this.data});
}

class _BarHighlight {
  final TextEditingController textCtrl;
  String? imageUrl;

  _BarHighlight({required this.textCtrl, this.imageUrl});
}

class _OpeningHoursDay {
  bool closed;
  TimeOfDay? from;
  TimeOfDay? to;

  _OpeningHoursDay({required this.closed, required this.from, required this.to});
}

class _DayMeta {
  final String key;
  final String short;
  final String emoji;

  const _DayMeta({required this.key, required this.short, required this.emoji});
}

class _PickedImage {
  final Uint8List bytes;
  final String name;
  _PickedImage({required this.bytes, required this.name});
}
