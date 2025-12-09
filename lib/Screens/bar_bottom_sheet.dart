// lib/widgets/bar_bottom_sheet.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Gemeinsame Helfer für Start/Ende-Logik (gleich wie im Admin-Screen gedacht)
DateTime _computeEventStart(DateTime eventDateTime) {
  // dein "realer" Start = eventDate - 1h
  return eventDateTime.subtract(const Duration(hours: 1));
}

DateTime _computeEventEnd(
    DateTime eventDateTime,
    bool openEnd,
    String endTimeStr,
    ) {
  final start = _computeEventStart(eventDateTime);

  if (openEnd) {
    // Open End → 12h ab Start
    return start.add(const Duration(hours: 12));
  }

  // Wenn keine valide Endzeit: fallback 12h ab Start
  if (!endTimeStr.contains(':')) {
    return start.add(const Duration(hours: 12));
  }

  final parts = endTimeStr.split(':');
  final h = int.tryParse(parts[0]) ?? 0;
  final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

  var end = DateTime(
    eventDateTime.year,
    eventDateTime.month,
    eventDateTime.day,
    h,
    m,
  );

  // Falls Endzeit vor Start (z. B. über Mitternacht) → +1 Tag
  if (end.isBefore(start)) {
    end = end.add(const Duration(days: 1));
  }

  return end;
}

class BarBottomSheet extends StatefulWidget {
  final String barId;
  final Map<String, dynamic> barData;

  const BarBottomSheet({
    super.key,
    required this.barId,
    required this.barData,
  });

  @override
  State<BarBottomSheet> createState() => _BarBottomSheetState();
}

class _BarBottomSheetState extends State<BarBottomSheet> {
  bool _showEventView = true; // Event-Vorschau <-> Bar-Infos

  // gleiche Reihenfolge wie im Admin-Screen
  static const List<Map<String, String>> _days = [
    {'key': 'mon', 'short': 'Mo'},
    {'key': 'tue', 'short': 'Di'},
    {'key': 'wed', 'short': 'Mi'},
    {'key': 'thu', 'short': 'Do'},
    {'key': 'fri', 'short': 'Fr'},
    {'key': 'sat', 'short': 'Sa'},
    {'key': 'sun', 'short': 'So'},
  ];

  @override
  Widget build(BuildContext context) {
    final barData = widget.barData;

    // ---------- BAR-DATEN ----------
    final barName = (barData['barName'] ?? 'Bar').toString();
    final address = (barData['address'] ?? '').toString();
    final city = (barData['city'] ?? '').toString();
    final country = (barData['country'] ?? '').toString();
    final description = (barData['description'] ?? '').toString();
    final profileImageUrl =
    (barData['profileImageUrl'] ?? '').toString().trim();

    final fullAddress = [
      address,
      [city, country].where((e) => e.trim().isNotEmpty).join(', ')
    ].where((e) => e.trim().isNotEmpty).join(' · ');

    // Bar-Rating (Durchschnitt + Anzahl)
    final double? ratingAvg = barData['ratingAvg'] != null
        ? (barData['ratingAvg'] as num).toDouble()
        : null;
    final int ratingCount = barData['ratingCount'] != null
        ? (barData['ratingCount'] as num).toInt()
        : 0;

    // Öffnungszeiten + Bar-Highlights aus Firestore
    final Map<String, dynamic>? openingHoursRaw =
    barData['openingHours'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(barData['openingHours'])
        : null;

    final List<Map<String, dynamic>> barHighlights =
    _safeHighlights(barData['barHighlights']);

    // ---------- EVENT-DATEN (aus der Bar) ----------
    final bool eventActive = barData['eventActive'] == true;

    DateTime? eventDateTime;
    final rawDate = barData['eventDate'];
    if (rawDate is Timestamp) {
      eventDateTime = rawDate.toDate();
    } else if (rawDate is String) {
      eventDateTime = DateTime.tryParse(rawDate);
    }

    final bool eventOpenEnd = barData['eventOpenEnd'] == true;
    final String eventEndTimeStr =
    (barData['eventEndTime'] ?? '').toString().trim();

    final String eventTitle =
    (barData['eventTitle'] ?? '').toString().trim();
    final String eventTagline =
    (barData['eventTagline'] ?? '').toString().trim();
    final String eventDesc =
    (barData['eventDescription'] ?? '').toString().trim();

    final bool entryEnabled = barData['eventEntryEnabled'] != false;
    final bool ageEnabled = barData['eventAgeEnabled'] != false;
    final bool musicEnabled = barData['eventMusicEnabled'] != false;
    final bool dresscodeEnabled =
        barData['eventDresscodeEnabled'] != false;

    final String entryRaw =
    (barData['eventEntry'] ?? '').toString().trim();
    final String ageRaw =
    (barData['eventAge'] ?? '').toString().trim();
    final String musicRaw =
    (barData['eventMusic'] ?? '').toString().trim();
    final String dresscodeRaw =
    (barData['eventDresscode'] ?? '').toString().trim();

    final String entryText = entryEnabled
        ? (entryRaw.isEmpty ? 'Details folgen' : entryRaw)
        : 'Kein Eintritt';
    final String ageText = ageEnabled
        ? (ageRaw.isEmpty ? 'Standard (z. B. 18+)' : ageRaw)
        : 'Kein Mindestalter';
    final String musicText = musicEnabled
        ? (musicRaw.isEmpty ? 'Musik wird noch bekannt gegeben' : musicRaw)
        : 'Keine Musikangabe';
    final String dresscodeText = dresscodeEnabled
        ? (dresscodeRaw.isEmpty ? 'Kein Dresscode vorgegeben' : dresscodeRaw)
        : 'Kein Dresscode';

    final List<Map<String, dynamic>> sections =
    _safeSections(barData['eventSections']);

    // ---------- Event-Status-Logik ----------
    final now = DateTime.now();
    bool hasEvent = eventActive && eventDateTime != null;
    bool showEventCard = false; // 2 Tage davor bis Event-Ende
    bool eventRunningWindow = false; // Start bis Event-Ende

    DateTime? eventStartUi;
    DateTime? eventEndUi;

    if (hasEvent) {
      eventStartUi = _computeEventStart(eventDateTime!);
      eventEndUi = _computeEventEnd(eventDateTime!, eventOpenEnd, eventEndTimeStr);
      final twoDaysBefore = eventStartUi.subtract(const Duration(days: 2));

      if (now.isAfter(twoDaysBefore) && now.isBefore(eventEndUi)) {
        showEventCard = true;
      }

      if (now.isAfter(eventStartUi) && now.isBefore(eventEndUi)) {
        eventRunningWindow = true;
      }
    }

    // ---------- AVATAR ----------
    Widget avatar;
    if (profileImageUrl.isNotEmpty) {
      avatar = CircleAvatar(
        radius: 48,
        backgroundColor: const Color(0xFF1C1F26),
        backgroundImage: NetworkImage(profileImageUrl),
      );
    } else {
      avatar = Container(
        width: 96,
        height: 96,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF1C1F26),
        ),
        child: const Icon(Icons.local_bar, color: Colors.white70, size: 40),
      );
    }

    final bool showAnyEventUi =
        hasEvent && showEventCard && eventDateTime != null && eventEndUi != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 16),

            // ---------- Bar-Header ----------
            avatar,
            const SizedBox(height: 14),
            Text(
              barName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),

            // Durchschnitts-Bewertung der Bar
            if (ratingAvg != null && ratingCount > 0) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.star,
                      color: Colors.amber, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    ratingAvg.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '($ratingCount)',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 8),
            if (fullAddress.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.location_on,
                      color: Colors.redAccent, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      fullAddress,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFB6BDC8),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            if (description.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  description,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ),
            const SizedBox(height: 18),

            // Toggle Event <-> Bar-Infos
            if (showAnyEventUi) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('Event 🎉'),
                    selected: _showEventView,
                    onSelected: (_) {
                      setState(() => _showEventView = true);
                    },
                    selectedColor: Colors.redAccent,
                    backgroundColor: const Color(0xFF1C1F26),
                    labelStyle: TextStyle(
                      color: _showEventView ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Bar-Infos 🍹'),
                    selected: !_showEventView,
                    onSelected: (_) {
                      setState(() => _showEventView = false);
                    },
                    selectedColor: Colors.redAccent,
                    backgroundColor: const Color(0xFF1C1F26),
                    labelStyle: TextStyle(
                      color: !_showEventView ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Inhalt je nach Ansicht
            if (showAnyEventUi && _showEventView)
              _buildEventInfoCard(
                context: context,
                eventDateTime: eventDateTime!,
                eventEndDateTime: eventEndUi!,
                eventRunning: eventRunningWindow,
                eventData: barData,
                entryText: entryText,
                ageText: ageText,
                musicText: musicText,
                dresscodeText: dresscodeText,
                sections: sections,
                eventTitle: eventTitle,
                eventTagline: eventTagline,
                eventDesc: eventDesc,
              )
            else
              _buildBarInfoContent(
                description: description,
                openingHours: openingHoursRaw,
                barHighlights: barHighlights,
              ),

            const SizedBox(height: 12),

            // Beispiel: Feedbackstream unterhalb (kannst du einbauen, wo du willst)
            // BarFeedbackStream(barId: widget.barId),
          ],
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  List<Map<String, dynamic>> _safeHighlights(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // kleine Chips (für Vorschau)
  Widget _smallInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 13),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildBarInfoContent({
    required String description,
    required Map<String, dynamic>? openingHours,
    required List<Map<String, dynamic>> barHighlights,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Beschreibung
          Text(
            description.trim().isNotEmpty
                ? description
                : 'Keine zusätzlichen Bar-Infos hinterlegt.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.35,
            ),
          ),

          // Öffnungszeiten
          if (openingHours != null && openingHours.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Öffnungszeiten',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            _buildOpeningHoursView(openingHours),
          ],

          // Highlights
          if (barHighlights.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Bar-Highlights',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            ..._buildHighlightCards(barHighlights),
          ],
        ],
      ),
    );
  }

  Widget _buildOpeningHoursView(Map<String, dynamic> opening) {
    final List<Widget> rows = [];

    for (final d in _days) {
      final key = d['key']!;
      final short = d['short']!;
      final raw = opening[key];

      bool closed = false;
      String openStr = '--:--';
      String closeStr = '--:--';

      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        closed = map['closed'] == true;
        final o = (map['open'] ?? '').toString();
        final c = (map['close'] ?? '').toString();
        if (o.isNotEmpty) openStr = o;
        if (c.isNotEmpty) closeStr = c;
      }

      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  short,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  closed ? 'geschlossen' : '$openStr – $closeStr',
                  style: TextStyle(
                    color: closed ? Colors.redAccent : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  List<Widget> _buildHighlightCards(List<Map<String, dynamic>> highlights) {
    final List<Widget> widgets = [];
    for (final h in highlights) {
      final text = (h['text'] ?? '').toString().trim();
      final imageUrl = (h['imageUrl'] ?? '').toString().trim();

      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
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
                    height: 140,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              if (text.isNotEmpty)
                Padding(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return widgets;
  }

  // -------------------------------- Event-Teil --------------------------------

  // Event-VORSCHAU (oben im Bar-Sheet)
  Widget _buildEventInfoCard({
    required BuildContext context,
    required DateTime eventDateTime,
    required DateTime eventEndDateTime,
    required bool eventRunning,
    required Map<String, dynamic> eventData,
    required String entryText,
    required String ageText,
    required String musicText,
    required String dresscodeText,
    required List<Map<String, dynamic>> sections,
    required String eventTitle,
    required String eventTagline,
    required String eventDesc,
  }) {
    final now = DateTime.now();
    final start = _computeEventStart(eventDateTime);
    final end = eventEndDateTime;

    String label;
    if (now.isBefore(start)) {
      final diff = start.difference(now);
      label = '⏱️ Event startet in ${_formatDuration(diff)}';
    } else if (now.isAfter(start) && now.isBefore(end)) {
      final diff = end.difference(now);
      label = '🔥 Event läuft noch ${_formatDuration(diff)}';
    } else {
      label = 'Event ist bereits vorbei.';
    }

    final dateStr =
        '${eventDateTime.day.toString().padLeft(2, '0')}.'
        '${eventDateTime.month.toString().padLeft(2, '0')}.'
        '${eventDateTime.year}';
    final timeStr =
        '${eventDateTime.hour.toString().padLeft(2, '0')}:'
        '${eventDateTime.minute.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titel + Datum/Zeit
          Text(
            eventRunning ? 'Live-Event 🔥' : 'Nächstes Event 🎉',
            style: const TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            eventTitle.isEmpty ? 'Event' : eventTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.calendar_month, color: Colors.white70, size: 18),
              const SizedBox(width: 6),
              Text(
                '$dateStr · $timeStr',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),

          const SizedBox(height: 10),
          // Timer/Status-Zeile
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer, color: Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          // Info-Chips – OHNE Untertitel/Beschreibung, damit es clean bleibt
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _smallInfoChip(Icons.attach_money, entryText),
              _smallInfoChip(Icons.cake, ageText),
              _smallInfoChip(Icons.music_note, musicText),
              _smallInfoChip(Icons.checkroom, dresscodeText),
            ],
          ),
          const SizedBox(height: 12),

          // Nur der Event-Infos Button rechts
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => EventBottomSheet(
                    eventData: eventData,
                    barId: widget.barId,
                  ),
                );
              },
              child: const Text(
                'Event-Infos',
                style:
                TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds <= 0) return '0 Min';
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final mins = d.inMinutes.remainder(60);

    final parts = <String>[];
    if (days > 0) parts.add('${days}T');
    if (hours > 0) parts.add('${hours}h');
    if (mins > 0) parts.add('${mins}m');

    return parts.join(' ');
  }
}

/// BottomSheet nur für das Event – wird vom Button geöffnet
class EventBottomSheet extends StatelessWidget {
  final Map<String, dynamic> eventData;
  final String barId;

  const EventBottomSheet({
    super.key,
    required this.eventData,
    required this.barId,
  });

  @override
  Widget build(BuildContext context) {
    final bool eventActive = eventData['eventActive'] == true;

    DateTime? eventDateTime;
    final rawDate = eventData['eventDate'];
    if (rawDate is Timestamp) {
      eventDateTime = rawDate.toDate();
    } else if (rawDate is String) {
      eventDateTime = DateTime.tryParse(rawDate);
    }

    final bool eventOpenEnd = eventData['eventOpenEnd'] == true;
    final String eventEndTimeStr =
    (eventData['eventEndTime'] ?? '').toString().trim();

    final String eventTitle =
    (eventData['eventTitle'] ?? '').toString().trim();
    final String eventTagline =
    (eventData['eventTagline'] ?? '').toString().trim();
    final String eventDesc =
    (eventData['eventDescription'] ?? '').toString().trim();

    final bool entryEnabled = eventData['eventEntryEnabled'] != false;
    final bool ageEnabled = eventData['eventAgeEnabled'] != false;
    final bool musicEnabled = eventData['eventMusicEnabled'] != false;
    final bool dresscodeEnabled =
        eventData['eventDresscodeEnabled'] != false;

    final String entryRaw =
    (eventData['eventEntry'] ?? '').toString().trim();
    final String ageRaw =
    (eventData['eventAge'] ?? '').toString().trim();
    final String musicRaw =
    (eventData['eventMusic'] ?? '').toString().trim();
    final String dresscodeRaw =
    (eventData['eventDresscode'] ?? '').toString().trim();

    final String entryText = entryEnabled
        ? (entryRaw.isEmpty ? 'Details folgen' : entryRaw)
        : 'Kein Eintritt';
    final String ageText = ageEnabled
        ? (ageRaw.isEmpty ? 'Standard (z. B. 18+)' : ageRaw)
        : 'Kein Mindestalter';
    final String musicText = musicEnabled
        ? (musicRaw.isEmpty ? 'Musik wird noch bekannt gegeben' : musicRaw)
        : 'Keine Musikangabe';
    final String dresscodeText = dresscodeEnabled
        ? (dresscodeRaw.isEmpty ? 'Kein Dresscode vorgegeben' : dresscodeRaw)
        : 'Kein Dresscode';

    final List<Map<String, dynamic>> sections =
    _safeSections(eventData['eventSections']);

    final now = DateTime.now();
    bool hasEvent = eventActive && eventDateTime != null;
    bool eventRunning = false;
    bool ratingAllowed = false; // Bewertung ab Start bis +12h

    if (hasEvent) {
      final start = _computeEventStart(eventDateTime!);
      final endUi =
      _computeEventEnd(eventDateTime!, eventOpenEnd, eventEndTimeStr);
      final twoDaysBefore = start.subtract(const Duration(days: 2));
      final ratingEnd = start.add(const Duration(hours: 12));

      // EventBottomSheet sichtbar: 2 Tage vorher bis Event-Ende
      if (now.isBefore(twoDaysBefore) || now.isAfter(endUi)) {
        hasEvent = false;
      }

      // "läuft" im Sinne von BottomSheet: ab Start bis Event-Ende
      if (now.isAfter(start) && now.isBefore(endUi)) {
        eventRunning = true;
      }

      // Bewertung: ab Start bis +12h
      if (now.isAfter(start) && now.isBefore(ratingEnd)) {
        ratingAllowed = true;
      }
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF090B10),
          borderRadius: BorderRadius.circular(24),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              if (hasEvent && eventDateTime != null)
                EventDetailsCard(
                  barId: barId,
                  title: eventTitle,
                  tagline: eventTagline,
                  desc: eventDesc,
                  eventDateTime: eventDateTime!,
                  eventRunning: eventRunning,
                  entryText: entryText,
                  ageText: ageText,
                  musicText: musicText,
                  dresscodeText: dresscodeText,
                  sections: sections,
                  ratingAllowed: ratingAllowed,
                )
              else
                const NoEventCard(),
            ],
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }
}

/// Karte mit den Event-Infos (wird von EventBottomSheet genutzt)
class EventDetailsCard extends StatelessWidget {
  final String barId;
  final String title;
  final String tagline;
  final String desc;
  final DateTime eventDateTime;
  final bool eventRunning;
  final String entryText;
  final String ageText;
  final String musicText;
  final String dresscodeText;
  final List<Map<String, dynamic>> sections;
  final bool ratingAllowed;

  const EventDetailsCard({
    super.key,
    required this.barId,
    required this.title,
    required this.tagline,
    required this.desc,
    required this.eventDateTime,
    required this.eventRunning,
    required this.entryText,
    required this.ageText,
    required this.musicText,
    required this.dresscodeText,
    required this.sections,
    required this.ratingAllowed,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${eventDateTime.day.toString().padLeft(2, '0')}.'
        '${eventDateTime.month.toString().padLeft(2, '0')}.'
        '${eventDateTime.year}';
    final timeStr =
        '${eventDateTime.hour.toString().padLeft(2, '0')}:'
        '${eventDateTime.minute.toString().padLeft(2, '0')}';

    final headline =
    eventRunning ? 'Event läuft gerade 🔥' : 'Nächstes Event 🎉';

    // Gibt es überhaupt irgendein Bild in den Sections?
    final bool hasAnySectionImage = sections.any((s) {
      final imageUrl = (s['imageUrl'] ?? '').toString().trim();
      return imageUrl.isNotEmpty;
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.redAccent.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            headline,
            style: const TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title.isEmpty ? 'Event' : title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (tagline.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              tagline,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.calendar_month,
                  color: Colors.white70, size: 18),
              const SizedBox(width: 6),
              Text(
                '$dateStr · $timeStr',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // "Voll" ausgeschriebene Infos mit farbigen Emojis
          _infoRow('💸', Colors.greenAccent, 'Eintritt', entryText),
          const SizedBox(height: 6),
          _infoRow('🎂', Colors.pinkAccent, 'Mindestalter', ageText),
          const SizedBox(height: 6),
          _infoRow('🎵', Colors.lightBlueAccent, 'Musik', musicText),
          const SizedBox(height: 6),
          _infoRow('👗', Colors.deepPurpleAccent, 'Dresscode', dresscodeText),

          const SizedBox(height: 16),

          // Beschreibung
          if (desc.isNotEmpty)
            Align(
              alignment:
              hasAnySectionImage ? Alignment.centerLeft : Alignment.center,
              child: Text(
                desc,
                textAlign:
                hasAnySectionImage ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: hasAnySectionImage ? 13 : 14,
                  height: 1.35,
                ),
              ),
            ),

          if (sections.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text(
              'Highlights ✨',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            ..._buildSections(sections),
          ],

          if (ratingAllowed) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.center,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: () {
                  _openRatingDialog(context);
                },
                icon: const Icon(Icons.star_rate_rounded, size: 18),
                label: const Text(
                  'Event / Bar bewerten ⭐',
                  style:
                  TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openRatingDialog(BuildContext context) {
    final TextEditingController controller = TextEditingController();
    int selectedRating = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF090B10),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Bar / Event bewerten',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Sterne
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(5, (index) {
                      final starIndex = index + 1;
                      final filled = starIndex <= selectedRating;
                      return IconButton(
                        icon: Icon(
                          filled ? Icons.star : Icons.star_border,
                        ),
                        color: Colors.amber,
                        onPressed: () {
                          setState(() {
                            selectedRating = starIndex;
                          });
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Optionales Feedback für die Bar ...',
                      hintStyle: TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Color(0xFF141A22),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.redAccent),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                          },
                          child: const Text(
                            'Abbrechen',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: selectedRating == 0
                              ? null
                              : () async {
                            final comment = controller.text;
                            Navigator.of(ctx).pop();
                            await _submitRating(
                              context,
                              selectedRating,
                              comment,
                            );
                          },
                          child: const Text('Senden'),
                        ),
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
  }

  Future<void> _submitRating(
      BuildContext context,
      int rating,
      String? comment,
      ) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final barRef = firestore.collection('bars').doc(barId);
      final feedbackRef = barRef.collection('feedback');

      // Feedback-Dokument hinzufügen (für Feedbackstream)
      await feedbackRef.add({
        'rating': rating,
        'comment': comment?.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'eventDateTime': eventDateTime,
      });

      // Durchschnittsrating + Count auf der Bar updaten
      await firestore.runTransaction((tx) async {
        final snap = await tx.get(barRef);
        final data =
            snap.data() as Map<String, dynamic>? ?? {};
        final double oldAvg = data['ratingAvg'] != null
            ? (data['ratingAvg'] as num).toDouble()
            : 0.0;
        final int oldCount = data['ratingCount'] != null
            ? (data['ratingCount'] as num).toInt()
            : 0;

        final int newCount = oldCount + 1;
        final double newAvg =
            ((oldAvg * oldCount) + rating) / newCount;

        tx.set(barRef, {
          'ratingAvg': newAvg,
          'ratingCount': newCount,
        }, SetOptions(merge: true));
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Danke für dein Feedback!'),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fehler beim Speichern der Bewertung.'),
        ),
      );
    }
  }

  Widget _infoRow(
      String emoji, Color emojiColor, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$emoji ',
          style: TextStyle(
            fontSize: 16,
            color: emojiColor,
          ),
        ),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections(List<Map<String, dynamic>> sections) {
    final List<Widget> widgets = [];
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      final text = (s['text'] ?? '').toString();
      final imageUrl = (s['imageUrl'] ?? '').toString();
      final imageLeft = s['imageLeft'] == true;

      // Wenn KEIN Bild da ist → nur Text, mittig und breit
      if (imageUrl.trim().isEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _sectionText(
              text,
              center: true,
              big: true,
            ),
          ),
        );
        continue;
      }

      final rowChildren = <Widget>[
        Expanded(
          flex: 4,
          child: _sectionImage(imageUrl),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 6,
          child: _sectionText(text),
        ),
      ];

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: imageLeft
                ? rowChildren
                : rowChildren.reversed.toList(),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _sectionImage(String imageUrl) {
    if (imageUrl.isEmpty) {
      // Fallback
      return Container(
        height: 90,
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Icon(
            Icons.image_not_supported,
            color: Colors.white38,
            size: 28,
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        imageUrl,
        height: 90,
        width: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _sectionText(String text, {bool center = false, bool big = false}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(big ? 12 : 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          color: Colors.white70,
          fontSize: big ? 13.5 : 12,
          height: 1.3,
        ),
      ),
    );
  }
}

class NoEventCard extends StatelessWidget {
  const NoEventCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: const [
          Icon(Icons.event_busy, color: Colors.white54),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Aktuell ist kein Event eingetragen.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
        ],
      ),
    );
  }
}

/// Feedbackstream für eine Bar
class BarFeedbackStream extends StatelessWidget {
  final String barId;

  const BarFeedbackStream({
    super.key,
    required this.barId,
  });

  @override
  Widget build(BuildContext context) {
    final feedbackQuery = FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('feedback')
        .orderBy('createdAt', descending: true);

    return StreamBuilder<QuerySnapshot>(
      stream: feedbackQuery.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text(
            'Fehler beim Laden des Feedbacks.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Text(
            'Noch kein Feedback vorhanden.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Feedback 📝',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            ...docs.map((d) {
              final data =
                  d.data() as Map<String, dynamic>? ?? {};
              final rating = data['rating'] != null
                  ? (data['rating'] as num).toInt()
                  : 0;
              final comment =
              (data['comment'] ?? '').toString().trim();
              final createdAt = data['createdAt'] as Timestamp?;
              final dateStr = createdAt != null
                  ? '${createdAt.toDate().day.toString().padLeft(2, '0')}.'
                  '${createdAt.toDate().month.toString().padLeft(2, '0')}.'
                  '${createdAt.toDate().year}'
                  : '';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF141A22),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Row(
                          children: List.generate(5, (index) {
                            final filled = index < rating;
                            return Icon(
                              filled ? Icons.star : Icons.star_border,
                              size: 16,
                              color: Colors.amber,
                            );
                          }),
                        ),
                        const SizedBox(width: 8),
                        if (dateStr.isNotEmpty)
                          Text(
                            dateStr,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                    if (comment.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        comment,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
