// lib/Screens/festl/festl_bottom_sheet.dart
//
// Premium Event-Sheet für ein Festl. Design-Sprache angelehnt an Apple Maps
// Places, Airbnb Experiences und Spotify Events: großer Hero mit Titelbild +
// Gradient, Info als moderne Cards, horizontale Highlight-Karten, Material-3
// Buttons über volle Breite. Dunkles Theme mit Magenta/Lila-Akzent, sanfte
// Stagger-Einblendung.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../Theme/app_theme.dart';
import '../../Services/timestamp_ext.dart';

class FestlBottomSheet extends StatefulWidget {
  final String festlId;
  final Map<String, dynamic> festlData;

  /// Aktueller Nutzer — nötig für die "Ich komme"-Zusage. Null (z. B.
  /// Bar-Account oder Username nicht gesetzt) → Button wird ausgeblendet.
  final String? currentUsername;

  /// Avatar des aktuellen Nutzers, wird bei der Zusage denormalisiert
  /// mitgespeichert (0 extra Reads für andere Clients).
  final String? currentAvatarUrl;

  /// Usernames meiner Freunde — für "wie viele Freunde kommen". Nur diese
  /// werden gezählt, fremde Teilnehmer nicht.
  final Set<String> friendUsernames;

  const FestlBottomSheet({
    super.key,
    required this.festlId,
    required this.festlData,
    this.currentUsername,
    this.currentAvatarUrl,
    this.friendUsernames = const <String>{},
  });

  @override
  State<FestlBottomSheet> createState() => _FestlBottomSheetState();
}

/// Ein Festl-Teilnehmer (denormalisiert aus `festln/{id}/attendees`).
class _FestlAttendee {
  const _FestlAttendee({required this.username, this.avatarUrl});
  final String username;
  final String? avatarUrl;
}

class _FestlBottomSheetState extends State<FestlBottomSheet>
    with SingleTickerProviderStateMixin {
  // ── Festl-Farbwelt (Magenta/Lila) ─────────────────────────────────────────
  static const Color _magenta = Color(0xFFC24BE6);
  static const Color _purple = Color(0xFF8E24AA);
  static const LinearGradient _brandGradient = LinearGradient(
    colors: [_magenta, _purple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  late final AnimationController _ctrl;

  Map<String, dynamic> get _d => widget.festlData;

  // ── Teilnahme-State ─────────────────────────────────────────────────────────
  CollectionReference<Map<String, dynamic>> get _attendeesRef =>
      FirebaseFirestore.instance
          .collection('festln')
          .doc(widget.festlId)
          .collection('attendees');

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _attSub;
  List<_FestlAttendee> _attendees = const [];
  bool _attendeesLoaded = false;
  bool _busy = false; // Zusage wird gerade geschrieben.

  String? get _me {
    final u = widget.currentUsername?.trim();
    return (u == null || u.isEmpty) ? null : u;
  }

  bool get _isGoing =>
      _me != null && _attendees.any((a) => a.username == _me);

  /// Freunde die zugesagt haben (nur Freunde, keine Fremden).
  List<_FestlAttendee> get _friendsGoing {
    final fs = widget.friendUsernames;
    if (fs.isEmpty) return const [];
    return _attendees.where((a) => fs.contains(a.username)).toList();
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();

    // Live-Stream der Zusagen: Button-Status + Freunde-Anzeige aktualisieren
    // sich in Echtzeit, ohne extra Reads (ein Snapshot-Listener).
    _attSub = _attendeesRef.snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _attendees = snap.docs.map((d) {
          final m = d.data();
          final av = (m['avatarUrl'] ?? '').toString().trim();
          return _FestlAttendee(
            username: (m['username'] ?? d.id).toString().trim(),
            avatarUrl: av.isEmpty ? null : av,
          );
        }).where((a) => a.username.isNotEmpty).toList();
        _attendeesLoaded = true;
      });
    }, onError: (_) {
      if (mounted) setState(() => _attendeesLoaded = true);
    });
  }

  @override
  void dispose() {
    _attSub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  // ── Zusage setzen / entfernen ────────────────────────────────────────────────

  Future<void> _toggleGoing() async {
    final me = _me;
    if (me == null || _busy) return;

    setState(() => _busy = true);
    final wasGoing = _isGoing;
    try {
      final ref = _attendeesRef.doc(me);
      if (wasGoing) {
        await ref.delete();
      } else {
        await ref.set({
          'username': me,
          'avatarUrl': (widget.currentAvatarUrl ?? '').trim(),
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasGoing ? 'Zusage entfernt.' : 'Du kommst! 🎡'),
          backgroundColor: wasGoing ? _purple : _magenta,
          duration: const Duration(milliseconds: 1400),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Zusage konnte nicht gespeichert werden.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Daten-Helfer ───────────────────────────────────────────────────────────

  String _two(int n) => n.toString().padLeft(2, '0');

  DateTime? _asDate(dynamic v) {
    if (v is Timestamp) return v.toLocalDateTime();
    if (v is DateTime) return v;
    return null;
  }

  String _fmtDate(DateTime d) => "${_two(d.day)}.${_two(d.month)}.${d.year}";
  String _fmtTime(DateTime d) => "${_two(d.hour)}:${_two(d.minute)}";
  String _fmtDateTime(DateTime d) => "${_fmtDate(d)} • ${_fmtTime(d)}";

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Kompakter Zeitraum für den Chip (z. B. "02.07. – 03.07." oder "02.07.").
  String _rangeChip() {
    final s = _asDate(_d['startTime']);
    if (s == null) return '';
    final e = _asDate(_d['endTime']);
    if (e == null || _sameDay(s, e)) return "${_two(s.day)}.${_two(s.month)}.";
    return "${_two(s.day)}.${_two(s.month)}. – ${_two(e.day)}.${_two(e.month)}.";
  }

  List<Map<String, dynamic>> get _highlights {
    final raw = _d['festlHighlights'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((m) =>
            (m['text'] ?? '').toString().trim().isNotEmpty ||
            (m['imageUrl'] ?? '').toString().trim().isNotEmpty)
        .toList();
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _launch(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Konnte nicht geöffnet werden.')),
        );
      }
    }
  }

  void _openLink(String url) {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final uri = Uri.tryParse(u);
    if (uri != null) _launch(uri);
  }

  void _openRoute() {
    final lat = (_d['lat'] as num?)?.toDouble();
    final lng = (_d['lng'] as num?)?.toDouble();
    final address = (_d['address'] ?? '').toString().trim();
    final city = (_d['city'] ?? '').toString().trim();

    String query;
    if (lat != null && lng != null) {
      query = '$lat,$lng';
    } else {
      query = [address, city].where((e) => e.isNotEmpty).join(', ');
    }
    if (query.isEmpty) return;

    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(query)}',
    );
    _launch(uri);
  }

  // ── Stagger-Reveal ──────────────────────────────────────────────────────────

  Widget _reveal(int index, Widget child) {
    final begin = (index * 0.09).clamp(0.0, 0.6);
    final anim = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(begin, (begin + 0.5).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, ch) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 22 * (1 - anim.value)),
          child: ch,
        ),
      ),
      child: child,
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, scrollCtrl) {
        return Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.bgTop, AppColors.bgBottom],
            ),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Color(0x338E24AA), width: 1),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scrollCtrl,
            padding: EdgeInsets.zero,
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            children: [
              _grabber(),
              _reveal(0, _hero()),
              const SizedBox(height: 18),
              _reveal(1, _metaChips()),
              const SizedBox(height: 20),
              _reveal(2, _participationSection()),
              const SizedBox(height: 4),
              _reveal(3, _infoSection()),
              _reveal(4, _descriptionSection()),
              _reveal(5, _highlightsSection()),
              _reveal(6, _actions()),
              const SizedBox(height: 28),
            ],
          ),
        );
      },
    );
  }

  Widget _grabber() {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12, bottom: 10),
        width: 42,
        height: 5,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }

  // ── HERO ────────────────────────────────────────────────────────────────────

  Widget _hero() {
    final name = (_d['festlName'] ?? 'Festl').toString();
    final cover = (_d['profileImageUrl'] ?? '').toString().trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Bild oder Gradient-Placeholder
              if (cover.isNotEmpty)
                Image.network(
                  cover,
                  fit: BoxFit.cover,
                  frameBuilder: (ctx, child, frame, wasSync) {
                    if (wasSync || frame != null) {
                      return AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 550),
                        curve: Curves.easeOut,
                        child: child,
                      );
                    }
                    return _heroPlaceholder();
                  },
                  errorBuilder: (_, __, ___) => _heroPlaceholder(),
                )
              else
                _heroPlaceholder(),

              // Lesbarkeits-Gradient
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.15),
                      Colors.black.withValues(alpha: 0.78),
                    ],
                    stops: const [0.35, 0.65, 1.0],
                  ),
                ),
              ),

              // Close-Button oben rechts
              Positioned(
                top: 12,
                right: 12,
                child: _circleButton(
                  icon: Icons.close_rounded,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),

              // Badge + Titel unten links
              Positioned(
                left: 18,
                right: 18,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _festlBadge(),
                    const SizedBox(height: 10),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                        letterSpacing: -0.4,
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 12),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A1650), Color(0xFF1C1F26)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        '🎡',
        style: TextStyle(
          fontSize: 72,
          shadows: [
            Shadow(color: _magenta.withValues(alpha: 0.6), blurRadius: 30),
          ],
        ),
      ),
    );
  }

  Widget _festlBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: _brandGradient,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: _magenta.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🎡', style: TextStyle(fontSize: 13)),
          SizedBox(width: 6),
          Text(
            'FESTL',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  // ── META CHIPS ───────────────────────────────────────────────────────────────

  Widget _metaChips() {
    final organizer = (_d['organizer'] ?? '').toString().trim();
    final range = _rangeChip();
    final minAge = _d['minAge'];
    final ageEstimated = _d['minAgeEstimated'] == true;

    final chips = <Widget>[
      if (range.isNotEmpty) _chip('📅', range),
      // Alters-Chip nur, wenn wirklich ein Wert da ist. Bei Kirtag,
      // Frühschoppen & Co. sagt die Quelle nichts über ein Mindestalter
      // -- dort lieber gar keinen Chip als eine geratene Grenze, die
      // jemanden vor der Tür stehen lässt. "ca." markiert die aus der
      // Kategorie abgeleiteten Werte (siehe minAgeEstimated).
      if (minAge != null)
        _chip('🔞', ageEstimated ? 'ca. $minAge+' : '$minAge+'),
      if (organizer.isNotEmpty) _chip('👤', organizer),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: chips,
      ),
    );
  }

  Widget _chip(String emoji, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: _purple.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _magenta.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── INFO CARDS ───────────────────────────────────────────────────────────────

  Widget _infoSection() {
    final address = (_d['address'] ?? '').toString().trim();
    final city = (_d['city'] ?? '').toString().trim();
    final organizer = (_d['organizer'] ?? '').toString().trim();
    final minAge = _d['minAge'];
    final ort = [address, city].where((e) => e.isNotEmpty).join(', ');

    // Bei importierten Festln liefert die Quelle kein Alter -- der Wert
    // ist dann aus der Kategorie geschätzt und MUSS als solcher
    // erkennbar sein. Sonst verlässt sich jemand auf eine Zahl, die wir
    // erfunden haben, und steht vor verschlossener Tür.
    final ageEstimated = _d['minAgeEstimated'] == true;

    final compact = <Widget>[
      if (ort.isNotEmpty) _infoCard('📍', 'Ort', city.isNotEmpty ? city : ort),
      if (minAge != null)
        _infoCard(
          '🔞',
          ageEstimated ? 'Mindestalter (geschätzt)' : 'Mindestalter',
          ageEstimated ? 'ca. $minAge+' : '$minAge+',
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          _timeframeCard(),
          if (compact.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (compact.length == 2)
              // IntrinsicHeight ist hier NICHT optional: die Row steht in
              // einer scrollbaren Column, ihre Höhe ist also unbegrenzt.
              // CrossAxisAlignment.stretch verlangt darin eine unendliche
              // Höhe -- der Sheet blieb dadurch komplett leer. Getriggert
              // wurde das erst, als importierte Festln ein Mindestalter
              // bekamen und damit zum ersten Mal ZWEI Karten nebeneinander
              // standen (vorher gab es immer nur die Ort-Karte).
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: compact[0]),
                    const SizedBox(width: 12),
                    Expanded(child: compact[1]),
                  ],
                ),
              )
            else
              compact.first,
          ],
          if (organizer.isNotEmpty) ...[
            const SizedBox(height: 12),
            _infoCard('👤', 'Veranstalter', organizer),
          ],
        ],
      ),
    );
  }

  BoxDecoration get _cardDeco => BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.panelAlt, AppColors.panel],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      );

  Widget _emojiBadge(String emoji) {
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _purple.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _magenta.withValues(alpha: 0.28)),
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 20)),
    );
  }

  Widget _infoCard(String emoji, String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco,
      child: Row(
        children: [
          _emojiBadge(emoji),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeframeCard() {
    final start = _asDate(_d['startTime']);
    if (start == null) return const SizedBox.shrink();
    final end = _asDate(_d['endTime']);
    final multi = end != null && !_sameDay(start, end);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _emojiBadge('📅'),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Zeitraum',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _fmtDateTime(start),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (multi) ...[
                  const SizedBox(height: 4),
                  Text(
                    'bis',
                    style: TextStyle(
                      color: _magenta.withValues(alpha: 0.9),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fmtDateTime(end),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ] else if (end != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'bis ${_fmtTime(end)} Uhr',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── DESCRIPTION ──────────────────────────────────────────────────────────────

  Widget _descriptionSection() {
    final desc = (_d['description'] ?? '').toString().trim();
    if (desc.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('Über das Festl'),
          const SizedBox(height: 12),
          Text(
            desc,
            style: const TextStyle(
              color: Color(0xFFE7EAF0),
              fontSize: 16,
              height: 1.62,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            gradient: _brandGradient,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  // ── HIGHLIGHTS ───────────────────────────────────────────────────────────────

  Widget _highlightsSection() {
    final items = _highlights;
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _sectionTitle('Highlights'),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 244,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              physics: const BouncingScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) => _highlightCard(items[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _highlightCard(Map<String, dynamic> h) {
    final text = (h['text'] ?? '').toString().trim();
    final img = (h['imageUrl'] ?? '').toString().trim();

    // "Titel + Beschreibung": erste Zeile als Titel, Rest als Text.
    String title = text;
    String? body;
    final nl = text.indexOf('\n');
    if (nl > 0) {
      title = text.substring(0, nl).trim();
      body = text.substring(nl + 1).trim();
    }

    return Container(
      width: 230,
      decoration: _cardDeco,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (img.isNotEmpty)
            SizedBox(
              height: 132,
              width: double.infinity,
              child: Image.network(
                img,
                fit: BoxFit.cover,
                frameBuilder: (ctx, child, frame, wasSync) {
                  if (wasSync || frame != null) {
                    return AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 450),
                      child: child,
                    );
                  }
                  return Container(color: AppColors.panelAlt);
                },
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.panelAlt,
                  alignment: Alignment.center,
                  child: const Text('🎡', style: TextStyle(fontSize: 32)),
                ),
              ),
            )
          else
            Container(
              height: 132,
              width: double.infinity,
              decoration: const BoxDecoration(gradient: _brandGradient),
              alignment: Alignment.center,
              child: const Text('🎡', style: TextStyle(fontSize: 40)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? 'Highlight' : title,
                    maxLines: body == null ? 3 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  if (body != null && body.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Expanded(
                      child: Text(
                        body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── TEILNAHME ("Ich komme" + Freunde) ────────────────────────────────────────

  Widget _participationSection() {
    // Ohne eingeloggten Nutzer (Bar-Account / Username fehlt) keine Zusage.
    if (_me == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDeco,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _comingButton(),
            const SizedBox(height: 14),
            _friendsGoingRow(),
          ],
        ),
      ),
    );
  }

  Widget _comingButton() {
    final going = _isGoing;

    // Animierter Wechsel zwischen "Ich komme" (Gradient) und
    // "Zusage entfernen" (dezent, mit Häkchen).
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: going
            ? _comingButtonGoing(key: const ValueKey('going'))
            : _comingButtonDefault(key: const ValueKey('default')),
      ),
    );
  }

  Widget _comingButtonDefault({Key? key}) {
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        gradient: _brandGradient,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: _magenta.withValues(alpha: 0.5),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy ? null : _toggleGoing,
          borderRadius: BorderRadius.circular(18),
          child: Center(
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white),
                  )
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('✅', style: TextStyle(fontSize: 18)),
                      SizedBox(width: 10),
                      Text(
                        'Ich komme',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _comingButtonGoing({Key? key}) {
    return Material(
      key: key,
      color: _purple.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _busy ? null : _toggleGoing,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _magenta.withValues(alpha: 0.55)),
          ),
          child: Center(
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: _magenta, size: 20),
                      const SizedBox(width: 9),
                      const Text(
                        'Du kommst',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '· Zusage entfernen',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // ── Freunde-die-kommen Zeile ─────────────────────────────────────────────────

  Widget _friendsGoingRow() {
    // Solange die Zusagen laden: dezenter Platzhalter (kein Layout-Sprung).
    if (!_attendeesLoaded) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: _magenta.withValues(alpha: 0.6)),
          ),
          const SizedBox(width: 10),
          Text(
            'Freunde werden geladen …',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    final friends = _friendsGoing;
    final count = friends.length;

    if (count == 0) {
      return Row(
        children: [
          Icon(Icons.group_outlined,
              color: AppColors.muted.withValues(alpha: 0.8), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Keiner deiner Freunde kommt bisher',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    }

    final namesLine = _friendsNamesLine(friends.map((f) => f.username).toList());

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openFriendsList(friends),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              _friendsAvatarStack(friends),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 1 ? '1 Freund kommt' : '$count Freunde kommen',
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                    if (namesLine != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        namesLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: AppColors.muted.withValues(alpha: 0.7), size: 22),
            ],
          ),
        ),
      ),
    );
  }

  /// "Max kommt" / "Max und Lisa kommen" / "Max, Lisa und 5 weitere Freunde
  /// kommen." — nur Freunde-Usernames.
  String? _friendsNamesLine(List<String> names) {
    if (names.isEmpty) return null;
    if (names.length == 1) return '${names[0]} kommt';
    if (names.length == 2) return '${names[0]} und ${names[1]} kommen';
    final rest = names.length - 2;
    final tail = rest == 1 ? 'weiterer Freund kommt' : 'weitere Freunde kommen';
    return '${names[0]}, ${names[1]} und $rest $tail';
  }

  Widget _friendsAvatarStack(List<_FestlAttendee> friends) {
    const size = 34.0;
    const maxShown = 3;
    final shown = friends.take(maxShown).toList();
    final overlap = size * 0.38;

    return SizedBox(
      height: size,
      width: size + (shown.length - 1) * (size - overlap),
      child: Stack(
        children: [
          for (int i = 0; i < shown.length; i++)
            Positioned(
              left: i * (size - overlap),
              child: _friendAvatar(shown[i], size),
            ),
        ],
      ),
    );
  }

  Widget _friendAvatar(_FestlAttendee f, double size) {
    final url = f.avatarUrl ?? '';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.panel,
        border: Border.all(color: _magenta.withValues(alpha: 0.85), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 120),
              errorWidget: (_, __, ___) => _avatarInitial(f, size),
              placeholder: (_, __) => _avatarInitial(f, size),
            )
          : _avatarInitial(f, size),
    );
  }

  Widget _avatarInitial(_FestlAttendee f, double size) {
    final initial =
        f.username.isNotEmpty ? f.username[0].toUpperCase() : '?';
    return Container(
      alignment: Alignment.center,
      decoration: const BoxDecoration(gradient: _brandGradient),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // ── Freunde-Liste (Tap auf die Anzeige) ──────────────────────────────────────

  void _openFriendsList(List<_FestlAttendee> friends) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBottom],
          ),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _grabber(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
                child: Row(
                  children: [
                    const Text('🎡', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 10),
                    Text(
                      friends.length == 1
                          ? '1 Freund kommt'
                          : '${friends.length} Freunde kommen',
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  itemCount: friends.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final f = friends[i];
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _purple.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: _magenta.withValues(alpha: 0.22)),
                      ),
                      child: Row(
                        children: [
                          _friendAvatar(f, 40),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              f.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Icon(Icons.check_circle_rounded,
                              color: _magenta, size: 20),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── ACTIONS ──────────────────────────────────────────────────────────────────

  Widget _actions() {
    final link = (_d['link'] ?? '').toString().trim();
    final lat = (_d['lat'] as num?)?.toDouble();
    final lng = (_d['lng'] as num?)?.toDouble();
    final hasRoute = (lat != null && lng != null) ||
        (_d['address'] ?? '').toString().trim().isNotEmpty ||
        (_d['city'] ?? '').toString().trim().isNotEmpty;

    final buttons = <Widget>[];

    if (link.isNotEmpty) {
      buttons.add(_primaryButton(
        icon: Icons.open_in_new_rounded,
        label: 'Mehr Infos',
        onTap: () => _openLink(link),
      ));
    }
    if (hasRoute) {
      buttons.add(_secondaryButton(
        icon: Icons.directions_rounded,
        label: 'Route öffnen',
        onTap: _openRoute,
      ));
    }
    if (buttons.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 30, 16, 0),
      child: Column(
        children: [
          for (int i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            buttons[i],
          ],
        ],
      ),
    );
  }

  Widget _primaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _brandGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: _purple.withValues(alpha: 0.45),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 21),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _secondaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: AppColors.panelAlt,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _magenta.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: _magenta, size: 21),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
