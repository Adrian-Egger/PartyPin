// lib/Screens/access_parties_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Screens/home_shell.dart';

const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30);

class AccessPartiesScreen extends StatefulWidget {
  const AccessPartiesScreen({super.key});

  @override
  State<AccessPartiesScreen> createState() => _AccessPartiesScreenState();
}

class _AccessPartiesScreenState extends State<AccessPartiesScreen> {
  String? _me;
  String? _fullName;
  bool _loading = true;

  // ✅ 2 Listen:
  // 1) Angefragt (Closed: requests/pending)
  final List<_PartyItem> _requested = [];

  // 2) Eingetragen/Zugelassen (Closed approved + Open rsvp going/maybe + Host)
  final List<_PartyItem> _enrolled = [];

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
      setState(() {
        _loading = false;
        _me = null;
        _fullName = fullName.isEmpty ? null : fullName;
      });
      return;
    }

    _me = me;
    _fullName = fullName.isEmpty ? null : fullName;

    await _loadAccessibleParties();

    if (!mounted) return;
    setState(() => _loading = false);
  }

  bool _isClosedDoc(Map<String, dynamic> d) {
    final t = (d['type'] ?? '').toString().trim().toLowerCase();
    final b = d['isClosed'] == true;
    return t == 'closed' || b == true;
  }

  DateTime? _partyStart(Map<String, dynamic> d) {
    DateTime? base;
    final v = d['date'];
    if (v is Timestamp) base = v.toDate();
    if (v is String) base = DateTime.tryParse(v);
    if (base == null) return null;

    final timeStr = (d['time'] ?? '').toString().trim();
    int hh = 0, mm = 0;
    if (timeStr.contains(':')) {
      final parts = timeStr.split(':');
      if (parts.isNotEmpty) hh = int.tryParse(parts[0]) ?? 0;
      if (parts.length > 1) mm = int.tryParse(parts[1]) ?? 0;
    }
    return DateTime(base.year, base.month, base.day, hh, mm);
  }

  bool _isExpiredWithGrace(Map<String, dynamic> d) {
    final start = _partyStart(d);
    if (start == null) return false;
    final cutoff = start.add(const Duration(hours: 24));
    return DateTime.now().isAfter(cutoff);
  }

  bool _isHostForPartyData(Map<String, dynamic> data) {
    final hostName = (data['hostName'] ?? '').toString().trim();
    final hostUid =
    ((data['hostUid'] ?? data['hostId']) ?? '').toString().trim();
    final cu = _me?.trim();
    final cf = _fullName?.trim();

    final byUid =
        cu != null && cu.isNotEmpty && hostUid.isNotEmpty && hostUid == cu;
    final byName =
        cf != null && cf.isNotEmpty && hostName.isNotEmpty && hostName == cf;

    return byUid || byName;
  }

  Future<void> _loadAccessibleParties() async {
    _requested.clear();
    _enrolled.clear();

    final me = _me!;
    final fs = FirebaseFirestore.instance;
    final snap = await fs.collection('Party').get();

    for (final doc in snap.docs) {
      final data = doc.data();
      if (_isExpiredWithGrace(data)) continue;

      final partyId = doc.id;
      final name = (data['name'] ?? 'Party').toString().trim();
      final start = _partyStart(data);

      final isClosed = _isClosedDoc(data);
      final isHost = _isHostForPartyData(data);

      if (isClosed) {
        // ✅ Closed:
        // - "Angefragt" = requests/{me}.status == pending
        // - "Eingetragen/Zugelassen" = Host ODER approvedUsers enthält mich ODER requests/{me}.status == approved
        if (isHost) {
          _enrolled.add(_PartyItem(
            partyId: partyId,
            title: name,
            subtitle: "Du bist Host",
            start: start,
          ));
          continue;
        }

        final approvedUsers =
            (data['approvedUsers'] as List?)?.cast<String>() ??
                const <String>[];
        if (approvedUsers.contains(me)) {
          _enrolled.add(_PartyItem(
            partyId: partyId,
            title: name,
            subtitle: "Zugelassen",
            start: start,
          ));
          continue;
        }

        try {
          final req = await fs
              .collection('Party')
              .doc(partyId)
              .collection('requests')
              .doc(me)
              .get();
          final st = req.data()?['status'] as String?;

          if (st == 'pending') {
            _requested.add(_PartyItem(
              partyId: partyId,
              title: name,
              subtitle: "Anfrage läuft",
              start: start,
            ));
          } else if (st == 'approved') {
            _enrolled.add(_PartyItem(
              partyId: partyId,
              title: name,
              subtitle: "Zugelassen",
              start: start,
            ));
          }
        } catch (_) {}

        continue;
      }

      // ✅ Open/Friends:
      // "Eingetragen/Zugelassen" = Host ODER rsvps going/maybe
      if (isHost) {
        _enrolled.add(_PartyItem(
          partyId: partyId,
          title: name,
          subtitle: "Du bist Host",
          start: start,
        ));
        continue;
      }

      try {
        final rsvp = await fs
            .collection('Party')
            .doc(partyId)
            .collection('rsvps')
            .doc(me)
            .get();
        final st = rsvp.data()?['status'] as String?;
        if (st == 'going' || st == 'maybe') {
          _enrolled.add(_PartyItem(
            partyId: partyId,
            title: name,
            subtitle: st == 'going' ? "Du gehst" : "Vielleicht",
            start: start,
          ));
        }
      } catch (_) {}
    }

    int cmp(_PartyItem a, _PartyItem b) {
      final at = a.start;
      final bt = b.start;
      if (at == null && bt == null) return a.title.compareTo(b.title);
      if (at == null) return 1;
      if (bt == null) return -1;
      return at.compareTo(bt);
    }

    _requested.sort(cmp);
    _enrolled.sort(cmp);
  }

  String _fmtDate(DateTime? dt) {
    if (dt == null) return "";
    return "${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} "
        "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  void _openPartyMapTab() {
    // ✅ Über HomeShell öffnen (BottomNav bleibt da) -> Map Tab
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const HomeShell(initialIndex: 2),
      ),
    );
  }

  Widget _sectionTitle(String t, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t,
              style: const TextStyle(
                color: _textPrimary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _panelBorder),
            ),
            child: Text(
              "$count",
              style: const TextStyle(
                color: _textSecondary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _partyTile(_PartyItem it) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _panelBorder),
      ),
      child: ListTile(
        leading: const Icon(Icons.celebration, color: _accent),
        title: Text(
          it.title,
          style: const TextStyle(
            color: _textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          "${it.subtitle}${it.start != null ? " • ${_fmtDate(it.start)}" : ""}",
          style: const TextStyle(
            color: _textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: const Icon(Icons.map, color: Colors.white54),
        onTap: _openPartyMapTab, // ✅ exakt so gewünscht: HomeShell -> Party Map Tab
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Partys",
          style: TextStyle(
            color: _textPrimary,
            fontWeight: FontWeight.w900,
            fontSize: 22,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: _accent,
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_gradTop, _gradBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _accent))
            : (_me == null)
            ? const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "Bitte Username in den Einstellungen setzen.",
              style: TextStyle(
                color: _textSecondary,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : RefreshIndicator(
          color: _accent,
          onRefresh: () async {
            setState(() => _loading = true);
            await _loadAccessibleParties();
            if (!mounted) return;
            setState(() => _loading = false);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 18),
            children: [
              _sectionTitle("🕒 Angefragte Partys", _requested.length),
              if (_requested.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Text(
                    "Keine offenen Anfragen.",
                    style: TextStyle(
                      color: _textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                ..._requested.map(_partyTile),

              _sectionTitle(
                  "✅ Eingetragene / Zugelassene Partys",
                  _enrolled.length),
              if (_enrolled.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  child: Text(
                    "Noch keine Einträge oder Zusagen.",
                    style: TextStyle(
                      color: _textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else
                ..._enrolled.map(_partyTile),
            ],
          ),
        ),
      ),
    );
  }
}

class _PartyItem {
  final String partyId;
  final String title;
  final String subtitle;
  final DateTime? start;

  _PartyItem({
    required this.partyId,
    required this.title,
    required this.subtitle,
    required this.start,
  });
}
