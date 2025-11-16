// lib/Screens/feedback_screen.dart
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'party_map_screen.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  // Farben
  static const _bgTop = Color(0xFF0E0F12);
  static const _bgBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF1C1F26);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _text = Colors.white;
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);
  static const _ok = Color(0xFF22C55E); // Grün beim Erfolg

  // Limits
  static const int kWindowLimit = 3;
  static const Duration kWindow = Duration(hours: 24);

  // State
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _feedbackController = TextEditingController();
  final ValueNotifier<Duration> _remainingVN = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _isLockedVN = ValueNotifier(false);

  int _usedInWindow = 0;
  DateTime? _lockUntilLocal;
  Timer? _ticker;
  Key _streamKey = UniqueKey();

  // kurzer Erfolgs-Flash
  bool _sentFlash = false;

  // Hints
  final List<String> _hints = const [
    "Hast du einen Vorschlag?",
    "Was können wir verbessern?",
    "Dein Feedback ist wichtig.",
    "Teile uns deine Idee mit.",
  ];
  String get _hint => _hints[Random().nextInt(_hints.length)];
  int get _remainingToday =>
      (kWindowLimit - _usedInWindow).clamp(0, kWindowLimit);

  @override
  void initState() {
    super.initState();
    _loadUserName();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _remainingVN.dispose();
    _isLockedVN.dispose();
    _nameController.dispose();
    _feedbackController.dispose();
    super.dispose();
  }

  // Helpers
  DateTime _nowUtc() => DateTime.now().toUtc();

  String _fmt(DateTime dt) {
    final l = dt.toLocal();
    final dd = l.day.toString().padLeft(2, '0');
    final mm = l.month.toString().padLeft(2, '0');
    final yyyy = l.year.toString().padLeft(4, '0');
    final HH = l.hour.toString().padLeft(2, '0');
    final MM = l.minute.toString().padLeft(2, '0');
    return "$dd.$mm.$yyyy $HH:$MM";
  }

  String _fmtDur(Duration d) {
    if (d.isNegative) return "00:00:00";
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return "${h.toString().padLeft(2, '0')}:"
        "${m.toString().padLeft(2, '0')}:"
        "${s.toString().padLeft(2, '0')}";
  }

  String _docIdForName(String name) {
    if (name.trim().isEmpty) {
      return DateTime.now().millisecondsSinceEpoch.toString();
    }
    return name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
  }

  // Init
  Future<void> _loadUserName() async {
    final prefs = await SharedPreferences.getInstance();
    final vorname = prefs.getString("vorname") ?? "";
    final nachname = prefs.getString("nachname") ?? "";
    _nameController.text = "$vorname $nachname".trim();
    await _refreshQuota24h();
  }

  // Quota
  Future<void> _refreshQuota24h() async {
    _ticker?.cancel();

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _usedInWindow = 0;
        _lockUntilLocal = null;
      });
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      return;
    }

    try {
      final docRef = FirebaseFirestore.instance
          .collection("feedbacks")
          .doc(_docIdForName(name));
      final snap = await docRef.get();

      final nowUtc = _nowUtc();
      final windowStartUtc = nowUtc.subtract(kWindow);

      List<DateTime> subsUtc = [];
      final data = snap.data();
      if (data != null) {
        final raw = (data['submissions'] as List?) ?? const [];
        for (final v in raw) {
          if (v is Timestamp) subsUtc.add(v.toDate().toUtc());
          if (v is String) {
            final p = DateTime.tryParse(v);
            if (p != null) subsUtc.add(p.toUtc());
          }
        }
      }

      subsUtc = subsUtc.where((t) => t.isAfter(windowStartUtc)).toList()..sort();

      DateTime? lockUntil;
      if (subsUtc.length >= kWindowLimit) {
        lockUntil = subsUtc.first.add(kWindow).toLocal();
      }

      setState(() {
        _usedInWindow = subsUtc.length.clamp(0, kWindowLimit);
        _lockUntilLocal = lockUntil;
      });

      _configureTicker();
    } catch (_) {
      setState(() {
        _usedInWindow = 0;
        _lockUntilLocal = null;
      });
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
    }
  }

  void _configureTicker() {
    _ticker?.cancel();

    if (_lockUntilLocal == null) {
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      return;
    }

    _isLockedVN.value = true;

    void tick() {
      final rem = _lockUntilLocal!.difference(DateTime.now());
      if (rem.inSeconds <= 0) {
        _ticker?.cancel();
        _isLockedVN.value = false;
        _remainingVN.value = Duration.zero;
        _lockUntilLocal = null;
        _refreshQuota24h();
      } else {
        _remainingVN.value = rem;
      }
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _reloadAll() async {
    setState(() => _streamKey = UniqueKey());
    await _refreshQuota24h();
    // keine Snackbars
  }

  // Senden
  Future<void> _sendFeedback() async {
    final name = _nameController.text.trim();
    final feedbackText = _feedbackController.text.trim();

    if (feedbackText.isEmpty) {
      HapticFeedback.heavyImpact();
      return;
    }
    if (name.isEmpty) {
      HapticFeedback.heavyImpact();
      return;
    }

    await _refreshQuota24h();
    if (_lockUntilLocal != null) {
      HapticFeedback.heavyImpact();
      return;
    }

    final docRef = FirebaseFirestore.instance
        .collection("feedbacks")
        .doc(_docIdForName(name));

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final nowUtc = _nowUtc();
        final snap = await tx.get(docRef);
        final data = snap.data() as Map<String, dynamic>?;

        List<DateTime> subsUtc = [];
        if (data != null) {
          final raw = (data['submissions'] as List?) ?? const [];
          for (final v in raw) {
            if (v is Timestamp) subsUtc.add(v.toDate().toUtc());
            if (v is String) {
              final p = DateTime.tryParse(v);
              if (p != null) subsUtc.add(p.toUtc());
            }
          }
        }

        final windowStartUtc = nowUtc.subtract(kWindow);
        subsUtc = subsUtc.where((t) => t.isAfter(windowStartUtc)).toList()..sort();

        if (subsUtc.length >= kWindowLimit) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'resource-exhausted',
          );
        }

        final newSubs = [...subsUtc, nowUtc];

        tx.set(
          docRef,
          {
            "userName": name,
            "message": feedbackText,
            "timestamp": FieldValue.serverTimestamp(),
            "submissions": newSubs.map((d) => Timestamp.fromDate(d)).toList(),
          },
          SetOptions(merge: true),
        );
      });

      _feedbackController.clear();
      HapticFeedback.lightImpact();
      await _refreshQuota24h();

      // kurzer grüner Flash
      if (mounted) {
        setState(() => _sentFlash = true);
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) setState(() => _sentFlash = false);
        });
      }
    } catch (_) {
      HapticFeedback.heavyImpact();
      // keine Snackbars
    }
  }

  // UI
  PreferredSizeWidget _appBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      toolbarHeight: 64,
      leading: IconButton(
        tooltip: "Zurück",
        icon: const Icon(Icons.arrow_back, color: _accent),
        onPressed: () {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const PartyMapScreen()),
          );
        },
      ),
      title: const Text(
        "Feedback",
        style: TextStyle(color: _text, fontWeight: FontWeight.w800, fontSize: 22),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            "${_usedInWindow.clamp(0, kWindowLimit)}/$kWindowLimit",
            style: const TextStyle(color: _muted, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          tooltip: "Aktualisieren",
          onPressed: _reloadAll,
          icon: const Icon(Icons.refresh, color: _muted),
        ),
      ],
    );
  }

  Widget _quotaBanner() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLockedVN,
      builder: (_, locked, __) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: _panel,
            border: const Border(
              bottom: BorderSide(color: _panelBorder, width: 0.5),
              top: BorderSide(color: _panelBorder, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(locked ? Icons.lock_clock : Icons.av_timer,
                  size: 18, color: _muted),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _remainingVN,
                  builder: (_, rem, __) => Text(
                    locked
                        ? "24h-Limit erreicht · noch ${_fmtDur(rem)}"
                        : "Heute verfügbar: $_remainingToday von $kWindowLimit",
                    style: const TextStyle(
                        color: _muted, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _messageTile({
    required String message,
    required String user,
    required String date,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _panelBorder, width: 1),
      ),
      child: ListTile(
        leading: const CircleAvatar(
          radius: 18,
          backgroundColor: Colors.white12,
          child: Icon(Icons.feedback, color: _accent, size: 18),
        ),
        title: Text(
          message,
          style: const TextStyle(color: _text, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          "Von: $user",
          style: const TextStyle(color: _muted),
        ),
        trailing: Text(date, style: const TextStyle(color: _muted, fontSize: 12)),
      ),
    );
  }

  Widget _inputBar() {
    final borderColor = _sentFlash ? _ok : Colors.transparent;
    final sendColor = _sentFlash ? _ok : _accent;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        color: Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: _isLockedVN,
                builder: (_, locked, __) => TextField(
                  controller: _feedbackController,
                  maxLines: null,
                  enabled: !locked,
                  style: const TextStyle(color: _text),
                  decoration: InputDecoration(
                    hintText: locked ? "Gesperrt …" : _hint,
                    hintStyle: const TextStyle(color: _muted),
                    contentPadding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                    filled: true,
                    fillColor: _panel,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor, width: _sentFlash ? 1.2 : 0),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _sentFlash ? _ok : _accent, width: 1),
                    ),
                  ),
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<bool>(
              valueListenable: _isLockedVN,
              builder: (_, locked, __) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _remainingVN,
                  builder: (_, rem, __) => ElevatedButton(
                    onPressed: (locked || _feedbackController.text.trim().isEmpty)
                        ? null
                        : _sendFeedback,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: sendColor,
                      disabledBackgroundColor: Colors.white12,
                      foregroundColor: Colors.white,
                      padding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      locked ? _fmtDur(rem) : "Senden",
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: false,
      backgroundColor: _bgTop,
      appBar: _appBar(),
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
          Column(
            children: [
              _quotaBanner(),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  key: _streamKey,
                  stream: FirebaseFirestore.instance
                      .collection("feedbacks")
                      .orderBy("timestamp", descending: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(
                        child: Text("Fehler beim Laden",
                            style: TextStyle(color: _accent)),
                      );
                    }
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child: CircularProgressIndicator(color: _accent));
                    }
                    final docs = snapshot.data?.docs ?? [];
                    if (docs.isEmpty) {
                      return const Center(
                        child: Text("Noch kein Feedback vorhanden",
                            style: TextStyle(color: _muted)),
                      );
                    }

                    return ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 100, top: 8),
                      itemCount: docs.length,
                      itemBuilder: (context, i) {
                        final raw = docs[i].data() as Map<String, dynamic>;
                        final msg = (raw["message"] as String?) ?? "";
                        final user = (raw["userName"] as String?) ?? "Unbekannt";
                        final ts = raw["timestamp"] as Timestamp?;
                        final date = ts == null ? "—" : _fmt(ts.toDate());
                        return _messageTile(message: msg, user: user, date: date);
                      },
                    );
                  },
                ),
              ),
              _inputBar(),
            ],
          ),
        ],
      ),
    );
  }
}
