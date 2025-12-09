// lib/Screens/bar_event_screen.dart
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class BarEventScreen extends StatefulWidget {
  final String barId;

  const BarEventScreen({super.key, required this.barId});

  @override
  State<BarEventScreen> createState() => _BarEventScreenState();
}

class _BarEventScreenState extends State<BarEventScreen> {
  final _titleCtrl = TextEditingController();
  final _taglineCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _musicCtrl = TextEditingController();
  final _entryCtrl = TextEditingController();
  final _dresscodeCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;      // Startzeit
  TimeOfDay? _selectedEndTime;   // Endzeit
  bool _openEnd = false;         // Open End aktiv?

  bool _isSaving = false;

  // optionale Felder
  bool _showMusic = true;
  bool _showEntry = true;
  bool _showDresscode = true;
  bool _showAge = true;

  final List<_EventSection> _sections = [];

  @override
  void initState() {
    super.initState();
    _loadExistingEvent();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _taglineCtrl.dispose();
    _descCtrl.dispose();
    _musicCtrl.dispose();
    _entryCtrl.dispose();
    _dresscodeCtrl.dispose();
    _ageCtrl.dispose();
    for (final s in _sections) {
      s.textCtrl.dispose();
    }
    super.dispose();
  }

  void _resetFormState() {
    _titleCtrl.clear();
    _taglineCtrl.clear();
    _descCtrl.clear();
    _musicCtrl.clear();
    _entryCtrl.clear();
    _dresscodeCtrl.clear();
    _ageCtrl.clear();

    _selectedDate = null;
    _selectedTime = null;
    _selectedEndTime = null;
    _openEnd = false;

    _showMusic = true;
    _showEntry = true;
    _showDresscode = true;
    _showAge = true;

    for (final s in _sections) {
      s.textCtrl.dispose();
    }
    _sections.clear();
    _sections.add(
      _EventSection(
        textCtrl: TextEditingController(),
        imageLeft: true,
      ),
    );
  }

  Future<void> _deleteImageFromStorage(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    try {
      final ref = FirebaseStorage.instance.refFromURL(url);
      await ref.delete();
    } catch (_) {
      // Bild existiert evtl. schon nicht mehr → ignorieren
    }
  }

  /// Hilfsfunktion: eventSections sicher in eine Liste von Maps verwandeln
  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// endDateTime für Auto-Cleanup berechnen (mit OpenEnd + eventEndTime)
  DateTime _computeEventEndForCleanup({
    required DateTime startDateTime, // eventDate (Start) aus Firestore
    required bool openEnd,
    required String endTimeStr,
  }) {
    // dein "Start" im System = eventDate - 1h
    final start = startDateTime.subtract(const Duration(hours: 1));

    if (openEnd) {
      // Open End → Timer/Cleanup 12h ab Start
      return start.add(const Duration(hours: 12));
    }

    // Keine Endzeit hinterlegt → fallback 12h
    if (!endTimeStr.contains(':')) {
      return start.add(const Duration(hours: 12));
    }

    final parts = endTimeStr.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    // Endzeit auf gleiche Datum-Basis wie Start
    var end = DateTime(
      startDateTime.year,
      startDateTime.month,
      startDateTime.day,
      h,
      m,
    );

    // Falls Endzeit früher als Start (z. B. über Mitternacht), dann +1 Tag
    if (end.isBefore(start)) {
      end = end.add(const Duration(days: 1));
    }

    return end;
  }

  Future<void> _loadExistingEvent() async {
    final barRef =
    FirebaseFirestore.instance.collection('bars').doc(widget.barId);
    final snap = await barRef.get();
    final data = snap.data();

    if (!mounted) return;

    // kein Event vorhanden → leeres Formular mit 1 Reihe
    if (data == null) {
      setState(() {
        _resetFormState();
      });
      return;
    }

    // ------------------- AUTO-CLEANUP: Event abgelaufen? -------------------
    DateTime? eventDateTime;
    final rawDate = data['eventDate'];
    if (rawDate is Timestamp) {
      eventDateTime = rawDate.toDate();
    } else if (rawDate is String) {
      eventDateTime = DateTime.tryParse(rawDate);
    }

    final bool storedOpenEnd = data['eventOpenEnd'] == true;
    final String storedEndTimeStr =
    (data['eventEndTime'] ?? '').toString().trim();

    if (eventDateTime != null) {
      final endForCleanup = _computeEventEndForCleanup(
        startDateTime: eventDateTime,
        openEnd: storedOpenEnd,
        endTimeStr: storedEndTimeStr,
      );

      if (DateTime.now().isAfter(endForCleanup)) {
        // zuerst Bilder aus eventSections löschen
        final sections = _safeSections(data['eventSections']);
        for (final s in sections) {
          final url = (s['imageUrl'] ?? '').toString().trim();
          await _deleteImageFromStorage(url);
        }

        // Event-Daten in Firestore aufräumen (alles leer machen)
        await barRef.update({
          'eventActive': false,
          'eventTitle': FieldValue.delete(),
          'eventTagline': FieldValue.delete(),
          'eventDescription': FieldValue.delete(),
          'eventDate': FieldValue.delete(),
          'eventTime': FieldValue.delete(),
          'eventEndTime': FieldValue.delete(),
          'eventOpenEnd': FieldValue.delete(),
          'eventSections': FieldValue.delete(),
          'eventUpdatedAt': FieldValue.delete(),
          'eventEntry': FieldValue.delete(),
          'eventEntryEnabled': FieldValue.delete(),
          'eventAge': FieldValue.delete(),
          'eventAgeEnabled': FieldValue.delete(),
          'eventMusic': FieldValue.delete(),
          'eventMusicEnabled': FieldValue.delete(),
          'eventDresscode': FieldValue.delete(),
          'eventDresscodeEnabled': FieldValue.delete(),
        });

        // Formular lokal leeren
        setState(() {
          _resetFormState();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Das Event ist abgelaufen. Alle Event-Daten und Bilder wurden gelöscht.',
            ),
          ),
        );
        return;
      }
    }

    // ------------------- Event noch gültig → in Formular laden -------------------
    setState(() {
      _resetFormState(); // vorher alles sauber leeren

      _titleCtrl.text = (data['eventTitle'] ?? '').toString();
      _taglineCtrl.text = (data['eventTagline'] ?? '').toString();
      _descCtrl.text = (data['eventDescription'] ?? '').toString();
      _musicCtrl.text = (data['eventMusic'] ?? '').toString();
      _entryCtrl.text = (data['eventEntry'] ?? '').toString();
      _dresscodeCtrl.text = (data['eventDresscode'] ?? '').toString();
      _ageCtrl.text = (data['eventAge'] ?? '').toString();

      _showMusic =
      data['eventMusicEnabled'] is bool ? data['eventMusicEnabled'] : true;
      _showEntry =
      data['eventEntryEnabled'] is bool ? data['eventEntryEnabled'] : true;
      _showDresscode = data['eventDresscodeEnabled'] is bool
          ? data['eventDresscodeEnabled']
          : true;
      _showAge =
      data['eventAgeEnabled'] is bool ? data['eventAgeEnabled'] : true;

      _openEnd = storedOpenEnd;

      if (eventDateTime != null) {
        _selectedDate = DateTime(
          eventDateTime.year,
          eventDateTime.month,
          eventDateTime.day,
        );
        _selectedTime = TimeOfDay.fromDateTime(eventDateTime);
      }

      if (!_openEnd && storedEndTimeStr.contains(':')) {
        final parts = storedEndTimeStr.split(':');
        final h = int.tryParse(parts[0]) ?? 0;
        final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
        _selectedEndTime = TimeOfDay(hour: h, minute: m);
      } else {
        _selectedEndTime = null;
      }

      final sections = _safeSections(data['eventSections']);
      _sections.clear();
      for (var i = 0; i < sections.length; i++) {
        final s = sections[i];
        final ctrl = TextEditingController(text: (s['text'] ?? '').toString());
        _sections.add(
          _EventSection(
            textCtrl: ctrl,
            imageUrl: (s['imageUrl'] ?? '').toString(),
            imageLeft: s['imageLeft'] == true,
          ),
        );
      }
      if (_sections.isEmpty) {
        _sections.add(
          _EventSection(
            textCtrl: TextEditingController(),
            imageLeft: true,
          ),
        );
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final result = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      initialDate: _selectedDate ?? now,
    );
    if (result != null) {
      setState(() => _selectedDate = result);
    }
  }

  Future<void> _pickTime() async {
    final result = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
    );
    if (result != null) {
      setState(() => _selectedTime = result);
    }
  }

  Future<void> _pickEndTime() async {
    final result = await showTimePicker(
      context: context,
      initialTime: _selectedEndTime ?? _selectedTime ?? TimeOfDay.now(),
    );
    if (result != null) {
      setState(() {
        _selectedEndTime = result;
        _openEnd = false; // wenn explizit Endzeit gewählt wird → kein Open End
      });
    }
  }

  void _addSection() {
    final index = _sections.length;
    _sections.add(
      _EventSection(
        textCtrl: TextEditingController(),
        imageLeft: index.isEven,
      ),
    );
    setState(() {});
  }

  void _removeSection(int index) async {
    final section = _sections[index];

    // Bild in Storage löschen, falls vorhanden
    await _deleteImageFromStorage(section.imageUrl);

    if (_sections.length == 1) {
      section.textCtrl.clear();
      section.imageFile = null;
      section.imageUrl = null;
    } else {
      section.textCtrl.dispose();
      _sections.removeAt(index);
    }
    setState(() {});
  }

  Future<void> _pickImageForSection(int index) async {
    final picker = ImagePicker();
    final picked =
    await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;

    final section = _sections[index];

    // altes Bild in Storage löschen (falls vorhanden)
    await _deleteImageFromStorage(section.imageUrl);

    setState(() {
      section.imageFile = File(picked.path);
      section.imageUrl = null; // wird neu hochgeladen
    });
  }

  /// Hochladen der Section-Bilder + Payload bauen.
  Future<List<Map<String, dynamic>>> _uploadSectionsAndBuildPayload() async {
    final storage = FirebaseStorage.instance;
    final List<Map<String, dynamic>> result = [];

    for (var i = 0; i < _sections.length; i++) {
      final s = _sections[i];
      final text = s.textCtrl.text.trim();
      final bool hasImageFile = s.imageFile != null;
      final bool hasImageUrl =
          s.imageUrl != null && s.imageUrl!.trim().isNotEmpty;

      // komplett leere Reihe weglassen
      if (text.isEmpty && !hasImageFile && !hasImageUrl) {
        continue;
      }

      String? imageUrl = s.imageUrl;

      if (s.imageFile != null) {
        try {
          final ref = storage
              .ref()
              .child('bars')
              .child(widget.barId)
              .child('events')
              .child('sections')
              .child(
              'section_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg');

          final taskSnapshot = await ref.putFile(s.imageFile!);

          if (taskSnapshot.state == TaskState.success) {
            imageUrl = await ref.getDownloadURL();
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Bild-Upload für Reihe ${i + 1} fehlgeschlagen (State: ${taskSnapshot.state}). Event wird trotzdem gespeichert.',
                  ),
                ),
              );
            }
          }
        } on FirebaseException catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Bild-Upload für Reihe ${i + 1} fehlgeschlagen (${e.code}): ${e.message}. Event wird ohne Bild gespeichert.',
                ),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Unbekannter Fehler beim Bild-Upload (Reihe ${i + 1}): $e. Event wird ohne Bild gespeichert.',
                ),
              ),
            );
          }
        }
      }

      result.add({
        'text': text,
        'imageUrl': imageUrl ?? '',
        'imageLeft': s.imageLeft,
      });
    }

    return result;
  }

  Future<void> _saveEvent() async {
    final title = _titleCtrl.text.trim();
    final desc = _descCtrl.text.trim();

    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte einen Event-Titel eingeben.')),
      );
      return;
    }

    if (_selectedDate == null || _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte Datum und Uhrzeit auswählen.')),
      );
      return;
    }

    // Entweder Endzeit oder Open End
    if (!_openEnd && _selectedEndTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
          Text('Bitte eine Endzeit wählen oder „Open End“ aktivieren.'),
        ),
      );
      return;
    }

    final dt = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );

    setState(() => _isSaving = true);

    try {
      final sectionsPayload = await _uploadSectionsAndBuildPayload();

      final barRef =
      FirebaseFirestore.instance.collection('bars').doc(widget.barId);

      final Map<String, dynamic> payload = {
        'eventActive': true,
        'eventTitle': title,
        'eventTagline': _taglineCtrl.text.trim(),
        'eventDescription': desc,
        'eventDate': Timestamp.fromDate(dt),
        'eventTime':
        '${_selectedTime!.hour.toString().padLeft(2, '0')}:${_selectedTime!.minute.toString().padLeft(2, '0')}',
        'eventSections': sectionsPayload,
        'eventUpdatedAt': FieldValue.serverTimestamp(),
        'eventOpenEnd': _openEnd,
      };

      if (!_openEnd && _selectedEndTime != null) {
        payload['eventEndTime'] =
        '${_selectedEndTime!.hour.toString().padLeft(2, '0')}:${_selectedEndTime!.minute.toString().padLeft(2, '0')}';
      } else {
        payload['eventEndTime'] = FieldValue.delete();
      }

      payload['eventEntry'] = _entryCtrl.text.trim();
      payload['eventEntryEnabled'] = _showEntry;

      payload['eventAge'] = _ageCtrl.text.trim();
      payload['eventAgeEnabled'] = _showAge;

      payload['eventMusic'] = _musicCtrl.text.trim();
      payload['eventMusicEnabled'] = _showMusic;

      payload['eventDresscode'] = _dresscodeCtrl.text.trim();
      payload['eventDresscodeEnabled'] = _showDresscode;

      await barRef.set(payload, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎉 Event gespeichert und aktiviert.')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler beim Speichern: $e')),
      );
      setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateText = _selectedDate == null
        ? '📅 Datum wählen'
        : '${_selectedDate!.day.toString().padLeft(2, '0')}.'
        '${_selectedDate!.month.toString().padLeft(2, '0')}.'
        '${_selectedDate!.year}';
    final timeText = _selectedTime == null
        ? '⏰ Startzeit wählen'
        : '${_selectedTime!.hour.toString().padLeft(2, '0')}:'
        '${_selectedTime!.minute.toString().padLeft(2, '0')}';

    final endTimeText = _openEnd
        ? 'Open End'
        : _selectedEndTime == null
        ? '🕒 Endzeit wählen'
        : 'Ende: ${_selectedEndTime!.hour.toString().padLeft(2, '0')}:'
        '${_selectedEndTime!.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(
        title: const Text('🍹 Bar-Event hosten'),
        backgroundColor: const Color(0xFF141A22),
      ),
      backgroundColor: const Color(0xFF0E0F12),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _sectionTitle('Allgemeine Infos'),
                  const SizedBox(height: 8),
                  _textField(
                    controller: _titleCtrl,
                    label: 'Event-Titel ✨',
                    hint: 'z. B. Latin Night',
                  ),
                  const SizedBox(height: 10),
                  _textField(
                    controller: _taglineCtrl,
                    label: 'Kurzer Untertitel',
                    hint: 'z. B. Reggaeton • Salsa • Bachata',
                  ),
                  const SizedBox(height: 10),
                  _textField(
                    controller: _descCtrl,
                    label: 'Beschreibung',
                    hint: 'Was macht das Event besonders?',
                    maxLines: 4,
                  ),
                  const SizedBox(height: 20),
                  _sectionTitle('Zeit & Rahmen'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSaving ? null : _pickDate,
                          icon: const Icon(Icons.calendar_today,
                              color: Colors.white),
                          label: Text(
                            dateText,
                            style: const TextStyle(color: Colors.white),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: const Color(0xFF141A22),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSaving ? null : _pickTime,
                          icon: const Icon(Icons.schedule,
                              color: Colors.white),
                          label: Text(
                            timeText,
                            style: const TextStyle(color: Colors.white),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: const Color(0xFF141A22),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Endzeit + Open End
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                          _isSaving || _openEnd ? null : _pickEndTime,
                          icon: const Icon(Icons.schedule_outlined,
                              color: Colors.white),
                          label: Text(
                            endTimeText,
                            style: const TextStyle(color: Colors.white),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: const Color(0xFF141A22),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _toggleChip(
                        label: 'Open End',
                        value: _openEnd,
                        onChanged: (v) {
                          setState(() {
                            _openEnd = v ?? false;
                            if (_openEnd) {
                              _selectedEndTime = null;
                            }
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _textField(
                          controller: _entryCtrl,
                          label: 'Eintritt 💸',
                          hint: 'z. B. 10€ (inkl. 1 Drink)',
                          enabled: _showEntry,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _toggleChip(
                        label: 'Eintritt anzeigen',
                        value: _showEntry,
                        onChanged: (v) =>
                            setState(() => _showEntry = v ?? true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _textField(
                          controller: _ageCtrl,
                          label: 'Mindestalter 🔞',
                          hint: 'z. B. 18+',
                          enabled: _showAge,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _toggleChip(
                        label: 'Alter anzeigen',
                        value: _showAge,
                        onChanged: (v) =>
                            setState(() => _showAge = v ?? true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _textField(
                          controller: _musicCtrl,
                          label: 'Musik / Vibe 🎵',
                          hint: 'z. B. House, Charts, Hip-Hop',
                          enabled: _showMusic,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _toggleChip(
                        label: 'Musik anzeigen',
                        value: _showMusic,
                        onChanged: (v) =>
                            setState(() => _showMusic = v ?? true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _textField(
                          controller: _dresscodeCtrl,
                          label: 'Dresscode 👗',
                          hint: 'z. B. Smart Casual',
                          enabled: _showDresscode,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _toggleChip(
                        label: 'Dresscode anzeigen',
                        value: _showDresscode,
                        onChanged: (v) =>
                            setState(() => _showDresscode = v ?? true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _sectionTitle('Event-Content (Bilder + Text)'),
                  const SizedBox(height: 8),
                  ..._buildContentSections(),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _isSaving ? null : _addSection,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.redAccent),
                        backgroundColor: const Color(0xFF141A22),
                      ),
                      icon: const Icon(Icons.add, color: Colors.redAccent),
                      label: const Text(
                        'Reihe hinzufügen',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tipp: Nutze die Reihen, um Bilder von Drinks, DJs, Specials usw. mit Text zu kombinieren.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF141A22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 10,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () {
                      Navigator.pop(context);
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white38),
                    ),
                    child: const Text(
                      'Abbrechen',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveEvent,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                        : const Text(
                      'Event speichern',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Row(
      children: [
        const Icon(Icons.local_fire_department,
            color: Colors.redAccent, size: 18),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _toggleChip({
    required String label,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: value ? Colors.green.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: value ? Colors.greenAccent : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: value ? Colors.greenAccent : Colors.white38,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: value ? Colors.greenAccent : Colors.white54,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      enabled: enabled,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: enabled ? Colors.white70 : Colors.white24,
        ),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: const Color(0xFF141A22),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        disabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white12),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: enabled ? Colors.redAccent : Colors.white12,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  List<Widget> _buildContentSections() {
    final List<Widget> widgets = [];
    for (var i = 0; i < _sections.length; i++) {
      final s = _sections[i];
      final rowChildren = <Widget>[
        Expanded(
          flex: 4,
          child: _imageCard(
            index: i,
            section: s,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 6,
          child: _contentTextCard(section: s),
        ),
      ];

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    'Reihe ${i + 1}',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _isSaving ? null : () => _removeSection(i),
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent, size: 18),
                    tooltip: 'Reihe entfernen',
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children:
                s.imageLeft ? rowChildren : rowChildren.reversed.toList(),
              ),
            ],
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _imageCard({required int index, required _EventSection section}) {
    Widget child;
    if (section.imageFile != null) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          section.imageFile!,
          height: 120,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
      );
    } else if (section.imageUrl != null && section.imageUrl!.isNotEmpty) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          section.imageUrl!,
          height: 120,
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
          Text(
            'Bild hinzufügen',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      );
    }

    return InkWell(
      onTap: _isSaving ? null : () => _pickImageForSection(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: child,
      ),
    );
  }

  Widget _contentTextCard({required _EventSection section}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      padding: const EdgeInsets.all(8),
      child: TextField(
        controller: section.textCtrl,
        maxLines: 4,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'Text zur Reihe (z. B. Drink-Special, DJ, Aktion)',
          hintStyle: TextStyle(color: Colors.white38, fontSize: 12),
          border: InputBorder.none,
        ),
      ),
    );
  }
}

class _EventSection {
  final TextEditingController textCtrl;
  bool imageLeft;
  File? imageFile;
  String? imageUrl;

  _EventSection({
    required this.textCtrl,
    this.imageLeft = true,
    this.imageFile,
    this.imageUrl,
  });
}
