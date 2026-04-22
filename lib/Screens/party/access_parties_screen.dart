import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/lang.dart';
import '../home/home_shell.dart';
import '../../Theme/app_theme.dart';
import '../../Services/timestamp_ext.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Status
// ─────────────────────────────────────────────────────────────────────────────
enum _Status { host, approved, pending, going, maybe }

extension _StatusX on _Status {
  String get label => switch (this) {
        _Status.host     => 'Host',
        _Status.approved => 'Zugelassen',
        _Status.pending  => 'Anfrage läuft',
        _Status.going    => 'Dabei',
        _Status.maybe    => 'Vielleicht',
      };

  Color get color => switch (this) {
        _Status.host     => AppColors.accent,
        _Status.approved => const Color(0xFF34C759),
        _Status.going    => const Color(0xFF34C759),
        _Status.pending  => const Color(0xFFFF9500),
        _Status.maybe    => const Color(0xFFFF9500),
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────────────────────────────────────
class _Party {
  final String id;
  final String name;
  final _Status status;
  final DateTime? start;
  final String address;
  final String host;
  final String description;
  final int? guestLimit;
  final int? minAge;
  final double? price;
  final String type;

  const _Party({
    required this.id,
    required this.name,
    required this.status,
    required this.start,
    required this.address,
    required this.host,
    required this.description,
    this.guestLimit,
    this.minAge,
    this.price,
    required this.type,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────
class AccessPartiesScreen extends StatefulWidget {
  const AccessPartiesScreen({super.key});

  @override
  State<AccessPartiesScreen> createState() => _AccessPartiesScreenState();
}

class _AccessPartiesScreenState extends State<AccessPartiesScreen> {
  String? _me;
  String? _fullName;
  bool _loading = true;

  final List<_Party> _requested = [];
  final List<_Party> _enrolled = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final me = (prefs.getString('currentUsername') ?? '').trim();
    final vorname = (prefs.getString('vorname') ?? '').trim();
    final nachname = (prefs.getString('nachname') ?? '').trim();
    final fullName = ('$vorname $nachname').trim();

    if (me.isEmpty) {
      if (!mounted) return;
      setState(() { _loading = false; _me = null; });
      return;
    }
    _me = me;
    _fullName = fullName.isEmpty ? null : fullName;
    await _load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  bool _isClosed(Map<String, dynamic> d) =>
      (d['type'] ?? '').toString().trim().toLowerCase() == 'closed' ||
      d['isClosed'] == true;

  DateTime? _startOf(Map<String, dynamic> d) {
    DateTime? base;
    final v = d['date'];
    if (v is Timestamp) base = v.toLocalDateTime();
    if (v is String) base = DateTime.tryParse(v);
    if (base == null) return null;
    final t = (d['time'] ?? '').toString().split(':');
    final hh = t.isNotEmpty ? int.tryParse(t[0]) ?? 0 : 0;
    final mm = t.length > 1 ? int.tryParse(t[1]) ?? 0 : 0;
    return DateTime(base.year, base.month, base.day, hh, mm);
  }

  bool _expired(Map<String, dynamic> d) {
    final s = _startOf(d);
    return s != null && DateTime.now().isAfter(s.add(const Duration(hours: 24)));
  }

  bool _isHost(Map<String, dynamic> d) {
    final hUid  = ((d['hostUid'] ?? d['hostId']) ?? '').toString().trim();
    final hName = (d['hostName'] ?? '').toString().trim();
    final me   = _me?.trim() ?? '';
    final full = _fullName?.trim() ?? '';
    return (me.isNotEmpty && hUid == me) || (full.isNotEmpty && hName == full);
  }

  _Party _build(String id, Map<String, dynamic> d, _Status s) => _Party(
        id: id,
        name: (d['name'] ?? 'Party').toString().trim(),
        status: s,
        start: _startOf(d),
        address: (d['address'] ?? '').toString().trim(),
        host: (d['hostName'] ?? '').toString().trim(),
        description: (d['description'] ?? '').toString().trim(),
        guestLimit: d['guestLimit'] is int ? d['guestLimit'] as int : null,
        minAge: d['minAge'] is int ? d['minAge'] as int : null,
        price: d['price'] is num ? (d['price'] as num).toDouble() : null,
        type: (d['type'] ?? '').toString(),
      );

  // ── load ───────────────────────────────────────────────────────────────────
  Future<void> _load() async {
    _requested.clear();
    _enrolled.clear();
    final me = _me!;
    final fs = FirebaseFirestore.instance;
    final snap = await fs.collection('Party').get();

    for (final doc in snap.docs) {
      final d = doc.data();
      if (_expired(d)) continue;
      final closed = _isClosed(d);
      final host   = _isHost(d);

      if (host) {
        _enrolled.add(_build(doc.id, d, _Status.host));
        continue;
      }

      if (closed) {
        final approved = (d['approvedUsers'] as List?)?.cast<String>() ?? [];
        if (approved.contains(me)) {
          _enrolled.add(_build(doc.id, d, _Status.approved));
          continue;
        }
        try {
          final req = await fs.collection('Party').doc(doc.id).collection('requests').doc(me).get();
          final st = req.data()?['status'] as String?;
          if (st == 'pending')  _requested.add(_build(doc.id, d, _Status.pending));
          if (st == 'approved') _enrolled.add(_build(doc.id, d, _Status.approved));
        } catch (_) {}
      } else {
        try {
          final rsvp = await fs.collection('Party').doc(doc.id).collection('rsvps').doc(me).get();
          final st = rsvp.data()?['status'] as String?;
          if (st == 'going') _enrolled.add(_build(doc.id, d, _Status.going));
          if (st == 'maybe') _requested.add(_build(doc.id, d, _Status.maybe));
        } catch (_) {}
      }
    }

    int cmp(_Party a, _Party b) {
      if (a.start == null && b.start == null) return a.name.compareTo(b.name);
      if (a.start == null) return 1;
      if (b.start == null) return -1;
      return a.start!.compareTo(b.start!);
    }
    _requested.sort(cmp);
    _enrolled.sort(cmp);
  }

  // ── date fmt ───────────────────────────────────────────────────────────────
  String _fmt(DateTime dt) {
    final d  = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final h  = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$d.$mo.${dt.year}  $h:$mi';
  }

  // ── bottom sheet ───────────────────────────────────────────────────────────
  void _showDetail(_Party p) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PartyDetailSheet(
        party: p,
        fmtDate: _fmt,
        onOpenMap: () {
          Navigator.pop(context);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => HomeShell(initialIndex: 2, initialOpenPartyId: p.id),
            ),
          );
        },
      ),
    );
  }

  // ── widgets ────────────────────────────────────────────────────────────────
  Widget _badge(_Status s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: s.color.withOpacity(0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: s.color.withOpacity(0.45)),
        ),
        child: Text(
          s.label,
          style: TextStyle(
            color: s.color,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _card(_Party p) => GestureDetector(
        onTap: () => _showDetail(p),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.accentBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(Icons.celebration_rounded, color: AppColors.accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (p.start != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          _fmt(p.start!),
                          style: const TextStyle(color: AppColors.muted, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 6),
                      _badge(p.status),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 18),
              ],
            ),
          ),
        ),
      );

  Widget _section(String label, IconData icon, List<_Party> items, String empty) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                Icon(icon, size: 14, color: AppColors.accent),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.panel,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.accentBorder),
                  ),
                  child: Text(
                    '${items.length}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(empty, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            )
          else
            ...items.map(_card),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => Scaffold(
        backgroundColor: AppColors.bgTop,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            color: AppColors.accent,
            onPressed: () => Navigator.pop(context),
          ),
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: AppRadius.fullBr,
              border: Border.all(color: AppColors.accentBorder2, width: 1),
            ),
            child: Text(
              Lang.t('access_parties_header'),
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.bgTop, AppColors.bgBottom],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
              : _me == null
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Bitte Username in den Einstellungen setzen.',
                          style: TextStyle(color: AppColors.muted),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      color: AppColors.accent,
                      onRefresh: () async {
                        setState(() => _loading = true);
                        await _load();
                        if (!mounted) return;
                        setState(() => _loading = false);
                      },
                      child: ListView(
                        padding: const EdgeInsets.only(top: 8, bottom: 32),
                        children: [
                          _section('Offene Anfragen', Icons.hourglass_top_rounded, _requested, 'Keine offenen Anfragen.'),
                          const SizedBox(height: 24),
                          // ── Divider ──────────────────────────────────────
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(child: Divider(color: AppColors.accentBorder, thickness: 1)),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text(
                                    'Zugelassen & Eingetragen',
                                    style: TextStyle(
                                      color: AppColors.muted.withOpacity(0.7),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                                Expanded(child: Divider(color: AppColors.accentBorder, thickness: 1)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _section('Zugelassen & Eingetragen', Icons.check_circle_outline_rounded, _enrolled, 'Noch keine Einträge oder Zusagen.'),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Detail Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────
class _PartyDetailSheet extends StatelessWidget {
  final _Party party;
  final String Function(DateTime) fmtDate;
  final VoidCallback onOpenMap;

  const _PartyDetailSheet({
    required this.party,
    required this.fmtDate,
    required this.onOpenMap,
  });

  Widget _row(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: AppColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = party.status;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF15171C),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // ── handle ──────────────────────────────────────────────────────
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.accentBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            // ── content ─────────────────────────────────────────────────────
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  // Title row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          party.name,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w800,
                            fontSize: 22,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: s.color.withOpacity(0.14),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: s.color.withOpacity(0.45)),
                        ),
                        child: Text(
                          s.label,
                          style: TextStyle(color: s.color, fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // For pending closed-party requests only show limited info
                  if (s == _Status.pending && party.type.toLowerCase() == 'closed') ...[
                    if (party.start != null)
                      _row(Icons.calendar_today_rounded, 'Datum & Uhrzeit', fmtDate(party.start!)),
                    if (party.minAge != null) ...[
                      const SizedBox(height: 8),
                      _chip(Icons.cake_rounded, 'Ab ${party.minAge}'),
                    ],
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.panel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accentBorder),
                      ),
                      child: Row(
                        children: const [
                          Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.muted),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Weitere Details werden nach Freigabe sichtbar.',
                              style: TextStyle(color: AppColors.muted, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    // Info rows
                    if (party.start != null)
                      _row(Icons.calendar_today_rounded, 'Datum & Uhrzeit', fmtDate(party.start!)),
                    if (party.address.isNotEmpty)
                      _row(Icons.location_on_rounded, 'Adresse', party.address),
                    if (party.host.isNotEmpty)
                      _row(Icons.person_rounded, 'Host', party.host),
                    if (party.description.isNotEmpty)
                      _row(Icons.notes_rounded, 'Beschreibung', party.description),

                    // Extras
                    if (party.guestLimit != null || party.minAge != null || (party.price != null && party.price! > 0)) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (party.guestLimit != null)
                            _chip(Icons.group_rounded, '${party.guestLimit} Gäste'),
                          if (party.minAge != null) ...[
                            const SizedBox(width: 8),
                            _chip(Icons.cake_rounded, 'Ab ${party.minAge}'),
                          ],
                          if (party.price != null && party.price! > 0) ...[
                            const SizedBox(width: 8),
                            _chip(Icons.euro_rounded, '${party.price!.toStringAsFixed(2)} €'),
                          ],
                        ],
                      ),
                    ],

                    const SizedBox(height: 28),

                    // Map button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onOpenMap,
                        icon: const Icon(Icons.map_rounded),
                        label: const Text(
                          'Auf Karte öffnen',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.accentBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppColors.accent),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      );
}
