import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../Screens/bar_event_screen.dart';

class MyBarScreen extends StatelessWidget {
  final String barId;
  const MyBarScreen({super.key, required this.barId});

  Stream<DocumentSnapshot<Map<String, dynamic>>> _barStream() {
    return FirebaseFirestore.instance.collection('bars').doc(barId).snapshots();
  }

  Query<Map<String, dynamic>> _eventsQuery() {
    // Upcoming + running: wir holen die nächsten Events und filtern lokal (kein Composite Index nötig)
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

  static const List<Map<String, String>> _days = [
    {'key': 'mon', 'short': 'Mo'},
    {'key': 'tue', 'short': 'Di'},
    {'key': 'wed', 'short': 'Mi'},
    {'key': 'thu', 'short': 'Do'},
    {'key': 'fri', 'short': 'Fr'},
    {'key': 'sat', 'short': 'Sa'},
    {'key': 'sun', 'short': 'So'},
  ];

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

    final Map<String, dynamic>? openingHours = b['openingHours'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(b['openingHours'])
        : null;

    final highlights = _safeHighlights(b['barHighlights']);

    // Events: lokal filtern (active, nicht vorbei, startAt vorhanden)
    final now = DateTime.now();
    final filtered = widget.eventDocs
        .map((d) => _EventItem(id: d.id, data: d.data()))
        .where((e) {
      if (!_isActive(e.data)) return false;
      if (_readDate(e.data['startAt']) == null) return false;
      if (!_notOver(e.data)) return false;
      // harte Vergangenheit raus (wenn cleanupAt fehlt: zeigen wir trotzdem)
      final startAt = _readDate(e.data['startAt']);
      if (startAt != null && startAt.isBefore(now.subtract(const Duration(days: 30)))) return false;
      return true;
    })
        .toList();

    final running = filtered.where((e) => _isRunning(e.data)).toList();
    final upcoming = filtered.where((e) => !_isRunning(e.data)).toList();

    final hasAnyEvents = running.isNotEmpty || upcoming.isNotEmpty;

    // Wenn keine Events: Toggle aus, automatisch Bar-Infos
    if (!hasAnyEvents && _showEvent) _showEvent = false;

    final avatar = CircleAvatar(
      radius: 46,
      backgroundColor: _card,
      backgroundImage: profileImageUrl.isNotEmpty ? NetworkImage(profileImageUrl) : null,
      child: profileImageUrl.isEmpty
          ? const Icon(Icons.local_bar, color: Colors.white70, size: 36)
          : null,
    );

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        title: const Text('Meine Bar', style: TextStyle(fontWeight: FontWeight.w900)),
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
                      selected: _showEvent,
                      text: 'Events 🎉',
                      onTap: () => setState(() => _showEvent = true),
                    ),
                    const SizedBox(width: 6),
                    _segButton(
                      selected: !_showEvent,
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

          if (_showEvent && hasAnyEvents)
            _eventsView(
              context: context,
              running: running,
              upcoming: upcoming,
              loading: widget.eventsLoading,
              error: widget.eventsError,
            )
          else
            _barInfosView(
              description: description,
              openingHours: openingHours,
              highlights: highlights,
            ),
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
    final dateStr =
        '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

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

  // ---------------- Bar Infos ----------------

  Widget _barInfosView({
    required String description,
    required Map<String, dynamic>? openingHours,
    required List<Map<String, dynamic>> highlights,
  }) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitleCentered('Bar-Infos 🍹'),
              const SizedBox(height: 12),
              Text(
                description.trim().isNotEmpty ? description : 'Keine zusätzlichen Bar-Infos hinterlegt.',
                style: const TextStyle(color: Colors.white70, height: 1.35),
              ),
            ],
          ),
        ),

        if (openingHours != null && openingHours.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitleCentered('Öffnungszeiten ⏰'),
                const SizedBox(height: 12),
                _openingHoursView(openingHours),
              ],
            ),
          ),
        ],

        if (highlights.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitleCentered('Highlights ✨'),
                const SizedBox(height: 12),
                ...highlights.map(_highlightCard),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _openingHoursView(Map<String, dynamic> opening) {
    final rows = <Widget>[];

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
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  short,
                  style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  closed ? 'geschlossen' : '$openStr – $closeStr',
                  style: TextStyle(
                    color: closed ? _accent : Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(children: rows);
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
