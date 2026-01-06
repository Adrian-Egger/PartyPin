// lib/Screens/bar_event_screen.dart
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'home_shell.dart';

class BarEventScreen extends StatefulWidget {
  final String barId;

  /// - wenn null => "Neues Event erstellen"
  /// - wenn gesetzt => "Event bearbeiten"
  final String? eventId;

  const BarEventScreen({
    super.key,
    required this.barId,
    this.eventId,
  });

  @override
  State<BarEventScreen> createState() => _BarEventScreenState();
}

class _BarEventScreenState extends State<BarEventScreen> {
  // ---------- THEME (schwarz/rot) ----------
  static const Color kBg = Color(0xFF0E0F12);
  static const Color kSurface = Color(0xFF141A22);
  static const Color kRed = Colors.redAccent;

  // ✅ 1:1 wie NewParty: keine extra TimePickerTheme-Spielereien
  ThemeData _pickerTheme(ThemeData base) {
    return ThemeData.dark().copyWith(
      colorScheme: const ColorScheme.dark(
        primary: kRed,
        onPrimary: Colors.white,
        surface: kSurface,
        onSurface: Colors.white,
      ),
      dialogBackgroundColor: kSurface,
    );
  }

  final _titleCtrl = TextEditingController();
  final _taglineCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _musicCtrl = TextEditingController();
  final _entryCtrl = TextEditingController();
  final _dresscodeCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  TimeOfDay? _selectedEndTime;
  bool _openEnd = false;

  // ab wann soll der Event-Loop sichtbar sein?
  DateTime? _visibleFromDateTime;
  String _visibleMode = '7d'; // '7d' | '24h' | 'custom'

  bool _isSaving = false;
  bool _isLoading = true;

  // optionale Felder
  bool _showMusic = true;
  bool _showEntry = true;
  bool _showDresscode = true;
  bool _showAge = true;

  final List<_EventSection> _sections = [];

  // interne ID (bei neuen Events wird die hier gesetzt)
  String? _eventId;

  CollectionReference<Map<String, dynamic>> get _eventsCol =>
      FirebaseFirestore.instance.collection('bars').doc(widget.barId).collection('events');

  DocumentReference<Map<String, dynamic>> _eventRef(String eventId) => _eventsCol.doc(eventId);

  @override
  void initState() {
    super.initState();
    _eventId = widget.eventId;
    _resetFormState();
    _loadIfEdit();
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

    _visibleFromDateTime = null;
    _visibleMode = '7d';

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

  // ----------------------------
  // Helpers
  // ----------------------------

  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  Future<void> _deleteImageFromStorage(String? url) async {
    if (url == null || url.trim().isEmpty) return;
    try {
      final ref = FirebaseStorage.instance.refFromURL(url);
      await ref.delete();
    } catch (_) {
      // ignorieren
    }
  }

  // Cleanup-Zeit berechnen (für "Event vorbei")
  DateTime _computeCleanupAt({
    required DateTime startAt,
    required bool openEnd,
    required String endTimeStr,
  }) {
    // alte Logik: "Start" = startAt - 1h
    final start = startAt.subtract(const Duration(hours: 1));

    if (openEnd) {
      return start.add(const Duration(hours: 12));
    }

    if (!endTimeStr.contains(':')) {
      return start.add(const Duration(hours: 12));
    }

    final parts = endTimeStr.split(':');
    final h = int.tryParse(parts[0]) ?? 0;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    var end = DateTime(startAt.year, startAt.month, startAt.day, h, m);

    if (end.isBefore(start)) {
      end = end.add(const Duration(days: 1));
    }

    if (end.isBefore(start)) {
      return start.add(const Duration(hours: 12));
    }

    return end;
  }

  DateTime _computeDefaultVisibleFrom(DateTime startAt) {
    switch (_visibleMode) {
      case '24h':
        return startAt.subtract(const Duration(hours: 24));
      case '7d':
      default:
        return startAt.subtract(const Duration(days: 7));
    }
  }

  // ----------------------------
  // Loading (Edit)
  // ----------------------------

  DateTime? _readDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  Future<void> _loadIfEdit() async {
    if (_eventId == null) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final snap = await _eventRef(_eventId!).get();
      final data = snap.data();

      if (!mounted) return;

      if (data == null) {
        setState(() => _isLoading = false);
        return;
      }

      // Soft-Cleanup: wenn vorbei -> löschen
      final startAt = _readDate(data['startAt']) ?? _readDate(data['eventDate']);
      final bool openEnd = data['openEnd'] == true;
      final String endTimeStr = (data['endTime'] ?? '').toString().trim();

      if (startAt != null) {
        final cleanupAt = _computeCleanupAt(
          startAt: startAt,
          openEnd: openEnd,
          endTimeStr: endTimeStr,
        );
        if (DateTime.now().isAfter(cleanupAt)) {
          await _deleteEventCompletely(eventId: _eventId!, existingData: data);
          if (!mounted) return;
          _eventId = null;
          _resetFormState();
          setState(() => _isLoading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Event war vorbei → wurde automatisch gelöscht.')),
          );
          return;
        }
      }

      setState(() {
        _resetFormState();

        _titleCtrl.text = (data['title'] ?? data['eventTitle'] ?? '').toString();
        _taglineCtrl.text = (data['tagline'] ?? data['eventTagline'] ?? '').toString();
        _descCtrl.text = (data['desc'] ?? data['eventDescription'] ?? '').toString();

        _musicCtrl.text = (data['music'] ?? data['eventMusic'] ?? '').toString();
        _entryCtrl.text = (data['entry'] ?? data['eventEntry'] ?? '').toString();
        _dresscodeCtrl.text = (data['dresscode'] ?? data['eventDresscode'] ?? '').toString();
        _ageCtrl.text = (data['age'] ?? data['eventAge'] ?? '').toString();

        _showMusic =
            (data['musicEnabled'] is bool ? data['musicEnabled'] : data['eventMusicEnabled']) != false;
        _showEntry =
            (data['entryEnabled'] is bool ? data['entryEnabled'] : data['eventEntryEnabled']) != false;
        _showDresscode =
            (data['dresscodeEnabled'] is bool ? data['dresscodeEnabled'] : data['eventDresscodeEnabled']) !=
                false;
        _showAge = (data['ageEnabled'] is bool ? data['ageEnabled'] : data['eventAgeEnabled']) != false;

        _openEnd = data['openEnd'] == true;

        final DateTime? st = _readDate(data['startAt']) ?? _readDate(data['eventDate']);
        if (st != null) {
          _selectedDate = DateTime(st.year, st.month, st.day);
          _selectedTime = TimeOfDay.fromDateTime(st);
        }

        final String et = (data['endTime'] ?? '').toString().trim();
        if (!_openEnd && et.contains(':')) {
          final parts = et.split(':');
          final h = int.tryParse(parts[0]) ?? 0;
          final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
          _selectedEndTime = TimeOfDay(hour: h, minute: m);
        } else {
          _selectedEndTime = null;
        }

        final DateTime? vf = _readDate(data['visibleFrom']) ?? _readDate(data['eventVisibleFrom']);
        _visibleFromDateTime = vf;

        final storedMode = (data['visibleMode'] ?? '').toString().trim();
        if (storedMode.isNotEmpty) {
          _visibleMode = storedMode;
        } else {
          _visibleMode = (_visibleFromDateTime == null) ? '7d' : 'custom';
        }

        final sections = _safeSections(data['sections'] ?? data['eventSections']);
        _sections.clear();
        for (var i = 0; i < sections.length; i++) {
          final s = sections[i];
          _sections.add(
            _EventSection(
              textCtrl: TextEditingController(text: (s['text'] ?? '').toString()),
              imageUrl: (s['imageUrl'] ?? '').toString(),
              imageLeft: s['imageLeft'] == true,
            ),
          );
        }
        if (_sections.isEmpty) {
          _sections.add(_EventSection(textCtrl: TextEditingController(), imageLeft: true));
        }

        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler beim Laden: $e')),
      );
    }
  }

  // ----------------------------
  // Picking date/time/visibleFrom (✅ Picker wie NewParty)
  // ----------------------------

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final result = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      initialDate: _selectedDate ?? now,
      builder: (context, child) => Theme(data: _pickerTheme(Theme.of(context)), child: child!),
    );
    if (result != null) {
      setState(() => _selectedDate = result);
    }
  }

  Future<void> _pickTime() async {
    final result = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
      builder: (context, child) => Theme(data: _pickerTheme(Theme.of(context)), child: child!),
    );
    if (result != null) {
      setState(() => _selectedTime = result);
    }
  }

  Future<void> _pickEndTime() async {
    final result = await showTimePicker(
      context: context,
      initialTime: _selectedEndTime ?? _selectedTime ?? TimeOfDay.now(),
      builder: (context, child) => Theme(data: _pickerTheme(Theme.of(context)), child: child!),
    );
    if (result != null) {
      setState(() {
        _selectedEndTime = result;
        _openEnd = false;
      });
    }
  }

  Future<void> _pickVisibleFromDateTime() async {
    final now = DateTime.now();
    final base = _visibleFromDateTime ?? now;

    final pickedDate = await showDatePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
      initialDate: base,
      builder: (context, child) => Theme(data: _pickerTheme(Theme.of(context)), child: child!),
    );
    if (pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      builder: (context, child) => Theme(data: _pickerTheme(Theme.of(context)), child: child!),
    );
    if (pickedTime == null) return;

    setState(() {
      _visibleMode = 'custom';
      _visibleFromDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  // ----------------------------
  // Sections
  // ----------------------------

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
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null) return;

    final section = _sections[index];

    await _deleteImageFromStorage(section.imageUrl);

    setState(() {
      section.imageFile = File(picked.path);
      section.imageUrl = null;
    });
  }

  Future<List<Map<String, dynamic>>> _uploadSectionsAndBuildPayload({
    required String eventId,
  }) async {
    final storage = FirebaseStorage.instance;
    final List<Map<String, dynamic>> result = [];

    for (var i = 0; i < _sections.length; i++) {
      final s = _sections[i];
      final text = s.textCtrl.text.trim();
      final hasImageFile = s.imageFile != null;
      final hasImageUrl = s.imageUrl != null && s.imageUrl!.trim().isNotEmpty;

      if (text.isEmpty && !hasImageFile && !hasImageUrl) continue;

      String? imageUrl = s.imageUrl;

      if (s.imageFile != null) {
        try {
          final ref = storage
              .ref()
              .child('bars')
              .child(widget.barId)
              .child('events')
              .child(eventId)
              .child('sections')
              .child('section_${i}_${DateTime.now().millisecondsSinceEpoch}.jpg');

          final task = ref.putFile(s.imageFile!);
          await task.whenComplete(() {}).timeout(const Duration(seconds: 35));
          imageUrl = await ref.getDownloadURL();
        } on TimeoutException {
          imageUrl = '';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Bild-Upload Reihe ${i + 1} Timeout → ohne Bild gespeichert.')),
            );
          }
        } on FirebaseException catch (e) {
          imageUrl = '';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Bild-Upload Reihe ${i + 1} fehlgeschlagen (${e.code}) → ohne Bild.')),
            );
          }
        } catch (e) {
          imageUrl = '';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Bild-Upload Reihe ${i + 1} Fehler: $e → ohne Bild.')),
            );
          }
        }
      }

      result.add({
        'text': text,
        'imageUrl': (imageUrl ?? '').trim(),
        'imageLeft': s.imageLeft,
      });
    }

    return result;
  }

  // ----------------------------
  // Delete Event completely
  // ----------------------------

  Future<void> _deleteEventCompletely({
    required String eventId,
    required Map<String, dynamic> existingData,
  }) async {
    final sections = _safeSections(existingData['sections'] ?? existingData['eventSections']);
    for (final s in sections) {
      final url = (s['imageUrl'] ?? '').toString().trim();
      await _deleteImageFromStorage(url);
    }
    await _eventRef(eventId).delete();
  }

  // ----------------------------
  // Save
  // ----------------------------

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

    if (!_openEnd && _selectedEndTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte eine Endzeit wählen oder „Open End“ aktivieren.')),
      );
      return;
    }

    final startAt = DateTime(
      _selectedDate!.year,
      _selectedDate!.month,
      _selectedDate!.day,
      _selectedTime!.hour,
      _selectedTime!.minute,
    );

    final String endTimeStr = _openEnd || _selectedEndTime == null
        ? ''
        : '${_selectedEndTime!.hour.toString().padLeft(2, '0')}:${_selectedEndTime!.minute.toString().padLeft(2, '0')}';

    final visibleFrom = (_visibleMode == 'custom' && _visibleFromDateTime != null)
        ? _visibleFromDateTime!
        : _computeDefaultVisibleFrom(startAt);

    final cleanupAt = _computeCleanupAt(
      startAt: startAt,
      openEnd: _openEnd,
      endTimeStr: endTimeStr,
    );

    setState(() => _isSaving = true);

    try {
      final String eventId = _eventId ?? _eventsCol.doc().id;
      _eventId = eventId;

      final sectionsPayload = await _uploadSectionsAndBuildPayload(eventId: eventId);

      final payload = <String, dynamic>{
        'active': true,
        'title': title,
        'tagline': _taglineCtrl.text.trim(),
        'desc': desc,
        'startAt': Timestamp.fromDate(startAt),
        'endTime': _openEnd ? '' : endTimeStr,
        'openEnd': _openEnd,
        'visibleFrom': Timestamp.fromDate(visibleFrom),
        'visibleMode': _visibleMode,
        'cleanupAt': Timestamp.fromDate(cleanupAt),
        'sections': sectionsPayload,
        'entry': _entryCtrl.text.trim(),
        'entryEnabled': _showEntry,
        'age': _ageCtrl.text.trim(),
        'ageEnabled': _showAge,
        'music': _musicCtrl.text.trim(),
        'musicEnabled': _showMusic,
        'dresscode': _dresscodeCtrl.text.trim(),
        'dresscodeEnabled': _showDresscode,
        'eventActive': true,
        'eventDate': Timestamp.fromDate(startAt),
        'eventTitle': title,
        'eventTagline': _taglineCtrl.text.trim(),
        'eventDescription': desc,
        'eventVisibleFrom': Timestamp.fromDate(visibleFrom),
        'eventSections': sectionsPayload,
        'eventEntry': _entryCtrl.text.trim(),
        'eventEntryEnabled': _showEntry,
        'eventAge': _ageCtrl.text.trim(),
        'eventAgeEnabled': _showAge,
        'eventMusic': _musicCtrl.text.trim(),
        'eventMusicEnabled': _showMusic,
        'eventDresscode': _dresscodeCtrl.text.trim(),
        'eventDresscodeEnabled': _showDresscode,
        'updatedAt': FieldValue.serverTimestamp(),
        if (widget.eventId == null) 'createdAt': FieldValue.serverTimestamp(),
      };

      await _eventRef(eventId).set(payload, SetOptions(merge: true)).timeout(const Duration(seconds: 20));

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.eventId == null ? '🎉 Event erstellt.' : '✅ Event gespeichert.')),
      );

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell(initialIndex: 1)),
            (route) => false,
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Timeout beim Speichern. Prüfe Internet/Firestore Rules.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler beim Speichern: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ----------------------------
  // UI
  // ----------------------------

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.eventId != null;

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

    String visibleText;
    if (_selectedDate == null || _selectedTime == null) {
      visibleText = '👀 Sichtbarkeit festlegen (erst Datum+Startzeit wählen)';
    } else if (_visibleMode == 'custom' && _visibleFromDateTime != null) {
      final v = _visibleFromDateTime!;
      visibleText =
      'Ab: ${v.day.toString().padLeft(2, '0')}.${v.month.toString().padLeft(2, '0')}.${v.year} '
          '${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
    } else {
      visibleText = _visibleMode == '24h' ? '24h vor Start' : '7 Tage vor Start';
    }

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: kSurface,
        title: Text(
          isEdit ? '🛠️ Event bearbeiten 🎉' : '🍹 Event erstellen 🎉',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 22,
          ),
        ),
      ),
      backgroundColor: kBg,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
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
                          icon: const Icon(Icons.calendar_today, color: kRed),
                          label: Text(dateText, style: const TextStyle(color: Colors.white)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: kSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSaving ? null : _pickTime,
                          icon: const Icon(Icons.schedule, color: kRed),
                          label: Text(timeText, style: const TextStyle(color: Colors.white)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: kSurface,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSaving || _openEnd ? null : _pickEndTime,
                          icon: const Icon(Icons.schedule_outlined, color: kRed),
                          label: Text(endTimeText, style: const TextStyle(color: Colors.white)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            backgroundColor: kSurface,
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
                            if (_openEnd) _selectedEndTime = null;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  _sectionTitle('Sichtbarkeit'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: kSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ab wann soll das Event als Event-Karte erscheinen?',
                          style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _choicePill(
                              label: '7 Tage vorher',
                              selected: _visibleMode == '7d',
                              onTap: _isSaving
                                  ? null
                                  : () => setState(() {
                                _visibleMode = '7d';
                                _visibleFromDateTime = null;
                              }),
                            ),
                            _choicePill(
                              label: '24h vorher',
                              selected: _visibleMode == '24h',
                              onTap: _isSaving
                                  ? null
                                  : () => setState(() {
                                _visibleMode = '24h';
                                _visibleFromDateTime = null;
                              }),
                            ),
                            _choicePill(
                              label: 'Custom',
                              selected: _visibleMode == 'custom',
                              onTap: _isSaving
                                  ? null
                                  : () async {
                                if (_selectedDate == null || _selectedTime == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Bitte zuerst Datum und Startzeit wählen.')),
                                  );
                                  return;
                                }
                                await _pickVisibleFromDateTime();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(visibleText, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      ],
                    ),
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
                        onChanged: (v) => setState(() => _showEntry = v ?? true),
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
                        onChanged: (v) => setState(() => _showAge = v ?? true),
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
                        onChanged: (v) => setState(() => _showMusic = v ?? true),
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
                        onChanged: (v) => setState(() => _showDresscode = v ?? true),
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
                        backgroundColor: kSurface,
                      ),
                      icon: const Icon(Icons.add, color: Colors.redAccent),
                      label: const Text('Reihe hinzufügen', style: TextStyle(color: Colors.redAccent)),
                    ),
                  ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: kSurface,
              boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, -4))],
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const HomeShell(initialIndex: 1)),
                          (route) => false,
                    ),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38)),
                    child: const Text('Abbrechen', style: TextStyle(color: Colors.white70)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveEvent,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    child: _isSaving
                        ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                        : Text(isEdit ? 'Speichern' : 'Erstellen',
                        style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------
  // Widgets
  // ----------------------------

  Widget _sectionTitle(String text) {
    return Row(
      children: [
        const Icon(Icons.local_fire_department, color: Colors.redAccent, size: 18),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
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
          border: Border.all(color: value ? Colors.greenAccent : Colors.white24),
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
              style: TextStyle(color: value ? Colors.greenAccent : Colors.white54, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _choicePill({
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.redAccent.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? Colors.redAccent : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.redAccent : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
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
        labelStyle: TextStyle(color: enabled ? Colors.white70 : Colors.white24),
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: kSurface,
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white24),
          borderRadius: BorderRadius.circular(12),
        ),
        disabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white12),
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: enabled ? Colors.redAccent : Colors.white12),
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
        Expanded(flex: 4, child: _imageCard(index: i, section: s)),
        const SizedBox(width: 10),
        Expanded(flex: 6, child: _contentTextCard(section: s)),
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
                        color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _isSaving ? null : () => _removeSection(i),
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                    tooltip: 'Reihe entfernen',
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: s.imageLeft ? rowChildren : rowChildren.reversed.toList(),
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
        child: Image.file(section.imageFile!, height: 120, width: double.infinity, fit: BoxFit.cover),
      );
    } else if (section.imageUrl != null && section.imageUrl!.isNotEmpty) {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(section.imageUrl!, height: 120, width: double.infinity, fit: BoxFit.cover),
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
      onTap: _isSaving ? null : () => _pickImageForSection(index),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: kSurface,
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
        color: kSurface,
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
