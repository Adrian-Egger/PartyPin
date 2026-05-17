import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Services/timestamp_ext.dart';
import 'bar_event_screen.dart';
import 'bar_settings_screen.dart';
import '../../Theme/app_theme.dart';

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
  // ✅ Clean Design (gleich wie deine anderen Screens)
  static const _bgTop = AppColors.bgTop;
  static const _bgBottom = AppColors.bgBottom;
  static const _panel = AppColors.panel;
  static const _panel2 = AppColors.bgBottom;

  static const _text = AppColors.text;
  static const _muted = AppColors.muted;
  static const _accent = AppColors.accent;

  static const _accentSoft = Color(0x26FF3B30); // ~15%
  static const _accentLine = Color(0x66FF3B30); // ~40%

  bool _showEvent = true;

  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
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

  // ---------------- data helpers ----------------

  DateTime? _readDate(dynamic v) {
    if (v is Timestamp) return v.toLocalDateTime();
    if (v is String) return DateTime.tryParse(v);
    if (v is DateTime) return v;
    return null;
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

  // ---------------- opening hours ----------------

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

  // ---------------- (image picking/upload + quick-edit sheet entfernt) ----------------
  // Der frühere Quick-Edit-Flow (AppBar-Stift → Bottom-Sheet) ist
  // entfernt. Bearbeitet wird ausschließlich über `BarSettingsScreen`,
  // erreichbar über den prominenten Button direkt unter Name/Adresse.

  // ---------------- UI helper cards ----------------

  static Widget _panelCard({
    required String title,
    String? subtitle,
    Widget? trailing,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentBorder, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: _text, fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          if (subtitle != null && subtitle.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 12),
          child,
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

    final bool showEvent = hasAnyEvents ? _showEvent : false;

    final avatar = CircleAvatar(
      radius: 46,
      backgroundColor: _panel,
      backgroundImage: profileImageUrl.isNotEmpty ? NetworkImage(profileImageUrl) : null,
      child: profileImageUrl.isEmpty
          ? const Icon(Icons.local_bar, color: _muted, size: 36)
          : null,
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: Scaffold(
        backgroundColor: _bgTop,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          automaticallyImplyLeading: true,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _accentSoft,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _accentLine, width: 1),
            ),
            child: const Text(
              'Meine Bar 🍹',
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.w900,
                fontSize: 20,
                letterSpacing: 0.2,
              ),
            ),
          ),
          // Hinweis: der frühere AppBar-Stift (Quick-Edit via Bottom-Sheet)
          // wurde entfernt — Bearbeitung läuft jetzt ausschließlich über
          // den prominenten Button direkt unter Name/Adresse, damit klar
          // ist, wo Bearbeiten passiert.
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
            ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
              children: [
                Center(child: avatar),
                const SizedBox(height: 12),

                Text(
                  barName,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _text,
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
                        style: const TextStyle(color: _text, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 6),
                      Text('($ratingCount)', style: const TextStyle(color: _muted, fontWeight: FontWeight.w800)),
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
                        child: Text(
                          fullAddress,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: _muted, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 16),

                // ── PRIMÄRER EDIT-BUTTON ───────────────────────────────
                // Bewusst direkt unter Name + Adresse: sofort sichtbar,
                // konsistent erreichbar (egal ob Events oder Bar-Infos
                // gerade angezeigt werden) und nicht „mitten drin".
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              BarSettingsScreen(barId: widget.barId),
                        ),
                      );
                    },
                    icon: const Icon(Icons.edit, color: Colors.white),
                    label: const Text(
                      'Bar-Infos bearbeiten',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                if (hasAnyEvents) ...[
                  Center(child: _segmented(showEvent: showEvent)),
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
                      style: const TextStyle(color: _muted, height: 1.35, fontWeight: FontWeight.w700),
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
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(
                                  d.short,
                                  style: const TextStyle(color: _muted, fontWeight: FontWeight.w900),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  text,
                                  style: TextStyle(
                                    color: day.closed ? _accent : _muted,
                                    fontWeight: FontWeight.w900,
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

                  // (Der frühere „Bar-Infos bearbeiten"-Button stand hier
                  //  zwischen Öffnungszeiten und Highlights — visuell
                  //  „mittendrin". Er wurde nach oben verschoben, direkt
                  //  unter Name/Adresse.)

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
          ],
        ),
      ),
    );
  }

  Widget _segmented({required bool showEvent}) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.accentBorder, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 8)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segButton(
            selected: showEvent,
            text: 'Events 🎉',
            onTap: () => setState(() => _showEvent = true),
          ),
          const SizedBox(width: 6),
          _segButton(
            selected: !showEvent,
            text: 'Bar-Infos 🍹',
            onTap: () => setState(() => _showEvent = false),
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
            color: selected ? _text : _muted,
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
      style: const TextStyle(color: _text, fontSize: 16, fontWeight: FontWeight.w900),
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
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accentLine, width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 8)),
        ],
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
                color: _panel2,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accentBorder, width: 1),
              ),
              child: const Text(
                'Events konnten nicht geladen werden.',
                style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
          ],

          if (running.isNotEmpty) ...[
            const Text('Läuft gerade 🔥', style: TextStyle(color: _text, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            ...running.map((e) => _eventRow(context, e, running: true)),
            const SizedBox(height: 14),
          ],

          if (upcoming.isNotEmpty) ...[
            const Text('Kommende Events', style: TextStyle(color: _text, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            ...upcoming.map((e) => _eventRow(context, e, running: false)),
          ],

          if (running.isEmpty && upcoming.isEmpty) ...[
            const Text('Aktuell keine Events.', style: TextStyle(color: _muted, fontWeight: FontWeight.w700)),
          ],

          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: _text,
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
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: running ? _accentLine : AppColors.accentBorder, width: 1),
      ),
      child: Row(
        children: [
          Icon(running ? Icons.local_fire_department : Icons.event, color: _muted, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$dateStr · $timeStr — ${title.isEmpty ? 'Event' : title}',
              style: const TextStyle(color: _muted, fontWeight: FontWeight.w900),
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
            icon: const Icon(Icons.edit, color: _muted),
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
        color: _panel2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentBorder, width: 1),
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
              padding: const EdgeInsets.all(12),
              child: Text(
                text,
                style: const TextStyle(color: _muted, height: 1.3, fontWeight: FontWeight.w700),
              ),
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
