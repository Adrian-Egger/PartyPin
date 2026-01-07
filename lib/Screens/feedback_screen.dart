// lib/Screens/feedback_screen.dart
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FeedbackScreen extends StatefulWidget {
  // steuert ob links oben der rote Pfeil angezeigt wird
  final bool openedFromMenu;

  const FeedbackScreen({
    super.key,
    this.openedFromMenu = false,
  });

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
  static const _ok = Color(0xFF22C55E);
  static const _warn = Color(0xFFFFB020);
  static const _err = Color(0xFFFF3B30);
  static const _info = Color(0xFF3AA0FF);

  // ✅ mehr rot, aber clean:
  static const _accentSoft = Color(0x26FF3B30); // ~15% rot
  static const _accentLine = Color(0x66FF3B30); // ~40% rot

  // Limits
  static const int kWindowLimit = 3;
  static const Duration kWindow = Duration(hours: 24);

  // State
  final _nameController = TextEditingController();
  final _feedbackController = TextEditingController();

  // Rebuild-arm: UI-Status über Notifier
  final ValueNotifier<Duration> _remainingVN = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _isLockedVN = ValueNotifier(false);
  final ValueNotifier<bool> _sendingVN = ValueNotifier(false);
  final ValueNotifier<bool> _canSendVN = ValueNotifier(false);

  int _usedInWindow = 0;
  DateTime? _lockUntilLocal;
  Timer? _ticker;

  // Feedback-Liste
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _feedbackDocs = const [];
  bool _isLoadingFeedback = true;
  bool _feedbackError = false;

  bool _sentFlash = false;

  // Firestore Reads minimieren: Quota-Refresh nicht zu oft
  DateTime _lastQuotaFetchLocal = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _quotaMinInterval = Duration(seconds: 6);

  // Device/User key für Quota + "eigenes Feedback anzeigen"
  String _userKey = "";

  // ✅ damit niemals "Anonym" geschrieben wird:
  String _usernameFallback = "Unbekannt";

  // Hints
  static const List<String> _hints = [
    "Hast du einen Vorschlag?",
    "Was können wir verbessern?",
    "Dein Feedback ist wichtig.",
    "Teile uns deine Idee mit.",
  ];
  String get _hint => _hints[Random().nextInt(_hints.length)];
  int get _remainingToday => (kWindowLimit - _usedInWindow).clamp(0, kWindowLimit);

  @override
  void initState() {
    super.initState();

    _feedbackController.addListener(() {
      final can = _feedbackController.text.trim().isNotEmpty;
      if (_canSendVN.value != can) _canSendVN.value = can;
    });

    _init();
  }

  Future<void> _init() async {
    await _loadUserNameAndFallback();
    await _ensureUserKey();

    await Future.wait([
      _refreshQuota24h(force: true),
      _loadFeedbacks(),
    ]);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _remainingVN.dispose();
    _isLockedVN.dispose();
    _sendingVN.dispose();
    _canSendVN.dispose();
    _nameController.dispose();
    _feedbackController.dispose();
    super.dispose();
  }

  // Helpers
  DateTime _nowUtc() => DateTime.now().toUtc();

  // ✅ Tastatur überall schließen (Tap irgendwo)
  void _dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _toast(
      String msg, {
        Color color = _info,
        IconData icon = Icons.info_outline,
      }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: color,
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
      ),
    );
  }

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

  Future<void> _loadUserNameAndFallback() async {
    final prefs = await SharedPreferences.getInstance();
    final vorname = (prefs.getString("vorname") ?? "").trim();
    final nachname = (prefs.getString("nachname") ?? "").trim();
    final username = (prefs.getString("username") ?? "").trim();

    final fullName = ("$vorname $nachname").trim();
    _nameController.text = fullName;

    // ✅ niemals "Anonym": Fallback ist username -> sonst "Unbekannt"
    _usernameFallback = username.isNotEmpty ? username : "Unbekannt";
  }

  String _randomKey() {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    final r = Random();
    return List.generate(24, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> _ensureUserKey() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = (prefs.getString("feedback_user_key") ?? "").trim();
    if (existing.isNotEmpty) {
      _userKey = existing;
      return;
    }
    final key = _randomKey();
    await prefs.setString("feedback_user_key", key);
    _userKey = key;
  }

  // ✅ niemals "Anonym"
  String _displayName() {
    final name = _nameController.text.trim();
    if (name.isNotEmpty) return name;
    return _usernameFallback; // "username" oder "Unbekannt"
  }

  // ✅ schreibt fehlendes rand bei geladenen docs einmalig nach
  Future<void> _ensureRandForDocs(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    try {
      final batch = FirebaseFirestore.instance.batch();
      bool hasAny = false;

      for (final d in docs) {
        final data = d.data();
        if (!data.containsKey('rand') || data['rand'] == null) {
          batch.set(d.reference, {'rand': Random().nextDouble()},
              SetOptions(merge: true));
          hasAny = true;
        }
      }

      if (hasAny) await batch.commit();
    } catch (_) {
      // ignorieren
    }
  }

  // ✅ 10 zufällige Feedbacks + eigenes letztes Feedback zusätzlich oben rein (falls vorhanden)
  Future<void> _loadFeedbacks() async {
    if (!mounted) return;
    setState(() {
      _isLoadingFeedback = true;
      _feedbackError = false;
    });

    try {
      final docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final r = Random().nextDouble();

      // 1) Random via rand (10)
      final q1 = await FirebaseFirestore.instance
          .collection("feedbacks")
          .where("rand", isGreaterThanOrEqualTo: r)
          .orderBy("rand")
          .limit(10)
          .get();
      docs.addAll(q1.docs);

      if (docs.length < 10) {
        final q2 = await FirebaseFirestore.instance
            .collection("feedbacks")
            .where("rand", isLessThan: r)
            .orderBy("rand")
            .limit(10 - docs.length)
            .get();
        docs.addAll(q2.docs);
      }

      // 2) Fallback (falls rand noch nicht überall): letzte 100 -> shuffle -> take 10
      if (docs.isEmpty) {
        final qFallback = await FirebaseFirestore.instance
            .collection("feedbacks")
            .orderBy("timestamp", descending: true)
            .limit(100)
            .get();
        final fallback = qFallback.docs.toList()..shuffle();
        docs.addAll(fallback.take(10));
      }

      // 3) Eigenes letztes Feedback (falls existiert)
      QueryDocumentSnapshot<Map<String, dynamic>>? mine;
      try {
        final qMine = await FirebaseFirestore.instance
            .collection("feedbacks")
            .where("userKey", isEqualTo: _userKey)
            .orderBy("timestamp", descending: true)
            .limit(1)
            .get();
        if (qMine.docs.isNotEmpty) mine = qMine.docs.first;
      } catch (_) {}

      // 4) rand nachschreiben für Zukunft (nur die geladenen)
      await _ensureRandForDocs(docs);

      // 5) Zusammenbauen:
      final ids = docs.map((d) => d.id).toSet();
      final result = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      if (mine != null && !ids.contains(mine.id)) result.add(mine);

      docs.shuffle();
      result.addAll(docs.take(10));

      if (!mounted) return;
      setState(() {
        _feedbackDocs = result;
        _isLoadingFeedback = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _feedbackError = true;
        _isLoadingFeedback = false;
      });
    }
  }

  // Quota (Reads reduzieren) -> eigenes Doc in feedback_quota/{userKey}
  Future<void> _refreshQuota24h({bool force = false}) async {
    _ticker?.cancel();

    final nowLocal = DateTime.now();
    if (!force && nowLocal.difference(_lastQuotaFetchLocal) < _quotaMinInterval) {
      _configureTicker();
      return;
    }
    _lastQuotaFetchLocal = nowLocal;

    if (_userKey.isEmpty) {
      _usedInWindow = 0;
      _lockUntilLocal = null;
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      if (mounted) setState(() {});
      return;
    }

    try {
      final docRef =
      FirebaseFirestore.instance.collection("feedback_quota").doc(_userKey);
      final snap = await docRef.get();

      final nowUtc = _nowUtc();
      final windowStartUtc = nowUtc.subtract(kWindow);

      final data = snap.data();
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

      subsUtc = subsUtc.where((t) => t.isAfter(windowStartUtc)).toList()..sort();

      DateTime? lockUntil;
      if (subsUtc.length >= kWindowLimit) {
        lockUntil = subsUtc.first.add(kWindow).toLocal();
      }

      _usedInWindow = subsUtc.length.clamp(0, kWindowLimit);
      _lockUntilLocal = lockUntil;

      _configureTicker();
      if (mounted) setState(() {});
    } catch (_) {
      _usedInWindow = 0;
      _lockUntilLocal = null;
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      if (mounted) setState(() {});
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
        _refreshQuota24h(force: true);
      } else {
        _remainingVN.value = rem;
      }
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _reloadAll() async {
    await Future.wait([
      _refreshQuota24h(force: true),
      _loadFeedbacks(),
    ]);
  }

  Future<void> _sendFeedback() async {
    if (_sendingVN.value) return;

    final feedbackText = _feedbackController.text.trim();
    if (feedbackText.isEmpty) {
      HapticFeedback.heavyImpact();
      _toast("Bitte Text eingeben.", color: _warn, icon: Icons.warning_amber_rounded);
      return;
    }

    await _refreshQuota24h(force: false);
    if (_lockUntilLocal != null) {
      HapticFeedback.heavyImpact();
      _toast("Limit erreicht. Warte: ${_fmtDur(_remainingVN.value)}",
          color: _warn, icon: Icons.lock_clock);
      return;
    }

    if (_userKey.isEmpty) {
      HapticFeedback.heavyImpact();
      _toast("UserKey fehlt (App neu starten).", color: _err, icon: Icons.error_outline);
      return;
    }

    _sendingVN.value = true;

    final quotaRef =
    FirebaseFirestore.instance.collection("feedback_quota").doc(_userKey);
    final feedbackRef =
    FirebaseFirestore.instance.collection("feedbacks").doc(); // auto-id

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final nowUtc = _nowUtc();

        // Quota lesen
        final quotaSnap = await tx.get(quotaRef);
        final data = quotaSnap.data() as Map<String, dynamic>?;

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
          throw FirebaseException(plugin: 'cloud_firestore', code: 'resource-exhausted');
        }

        final newSubs = [...subsUtc, nowUtc];

        // Quota schreiben
        tx.set(
          quotaRef,
          {
            "submissions": newSubs.map((d) => Timestamp.fromDate(d)).toList(),
            "updatedAt": FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );

        // Feedback schreiben
        tx.set(
          feedbackRef,
          {
            "userKey": _userKey,
            "userName": _displayName(),
            "message": feedbackText,
            "timestamp": FieldValue.serverTimestamp(),
            "rand": Random().nextDouble(),
          },
        );
      });

      _feedbackController.clear();
      HapticFeedback.lightImpact();
      _toast("Gesendet ✅", color: _ok, icon: Icons.check_circle_rounded);

      await Future.wait([
        _refreshQuota24h(force: true),
        _loadFeedbacks(),
      ]);

      if (mounted) {
        setState(() => _sentFlash = true);
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) setState(() => _sentFlash = false);
        });
      }
    } on FirebaseException catch (e) {
      HapticFeedback.heavyImpact();
      _toast("Firestore Fehler: ${e.code}", color: _err, icon: Icons.error_outline);
      await _refreshQuota24h(force: true);
    } catch (e) {
      HapticFeedback.heavyImpact();
      _toast("Fehler: $e", color: _err, icon: Icons.error_outline);
      await _refreshQuota24h(force: true);
    } finally {
      _sendingVN.value = false;
    }
  }

  // UI
  PreferredSizeWidget _appBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      toolbarHeight: 64,
      leading: widget.openedFromMenu
          ? IconButton(
        tooltip: "Zurück",
        icon: const Icon(Icons.arrow_back, color: _accent),
        onPressed: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).maybePop();
        },
      )
          : null,
      automaticallyImplyLeading: false,
      // ✅ Emojis + etwas größer + rot-akzent via Chip
      title: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _accentSoft,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _accentLine, width: 1),
        ),
        child: const Text(
          "Feedback💬 ",
          style: TextStyle(
            color: _text,
            fontWeight: FontWeight.w900,
            fontSize: 24,
            letterSpacing: 0.2,
          ),
        ),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _accentLine, width: 1),
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

  // ✅ nur dünn umranden (kein linker Streifen mehr)
  Widget _messageTile({
    required String message,
    required String user,
    required String date,
    required bool isMine,
  }) {
    final borderColor = isMine ? _ok : _accentLine;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1), // ✅ dünn, clean
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000),
              blurRadius: 12,
              offset: Offset(0, 8)),
        ],
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: Colors.white12,
          child: Icon(
            isMine ? Icons.person : Icons.feedback,
            color: isMine ? _ok : _accent,
            size: 18,
          ),
        ),
        title: Text(
          message,
          style: const TextStyle(
              color: _text, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          isMine ? "Von: $user (du)" : "Von: $user",
          style: const TextStyle(color: _muted),
        ),
        trailing: Text(
          date,
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ),
    );
  }

  Widget _inputBar() {
    final borderColor = _sentFlash ? _ok : _accentLine; // ✅ immer leichter rot
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
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 14, horizontal: 12),
                    filled: true,
                    fillColor: _panel,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor, width: 1),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                          color: _sentFlash ? _ok : _accent, width: 1.2),
                    ),
                  ),
                  textInputAction: TextInputAction.newline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<bool>(
              valueListenable: _isLockedVN,
              builder: (_, locked, __) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: _remainingVN,
                  builder: (_, rem, __) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: _sendingVN,
                      builder: (_, sending, __) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: _canSendVN,
                          builder: (_, canSend, __) {
                            final disabled = locked || sending || !canSend;
                            return ElevatedButton(
                              onPressed: disabled ? null : _sendFeedback,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: sendColor,
                                disabledBackgroundColor: Colors.white12,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14, horizontal: 18),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                              child: sending
                                  ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                                  : Text(
                                locked ? _fmtDur(rem) : "Senden",
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedbackList() {
    if (_isLoadingFeedback) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (_feedbackError) {
      return const Center(
        child: Text("Fehler beim Laden", style: TextStyle(color: _accent)),
      );
    }
    if (_feedbackDocs.isEmpty) {
      return const Center(
        child: Text("Noch kein Feedback vorhanden",
            style: TextStyle(color: _muted)),
      );
    }

    final myKey = _userKey.trim();
    final myName = _displayName().trim().toLowerCase();

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 100, top: 8),
      itemCount: _feedbackDocs.length,
      // ✅ Bonus: auch beim Scrollen weg (optional, schadet nicht)
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemBuilder: (context, i) {
        final raw = _feedbackDocs[i].data();
        final msg = (raw["message"] as String?) ?? "";
        final user = (raw["userName"] as String?) ?? "Unbekannt";
        final key = (raw["userKey"] as String?) ?? "";

        final ts = raw["timestamp"] as Timestamp?;
        final date = ts == null ? "—" : _fmt(ts.toDate());

        // ✅ IMMER als "mein" erkennen, wenn:
        // - userKey passt ODER
        // - userName passt (Fallback)
        final isMine = (myKey.isNotEmpty && key == myKey) ||
            (myName.isNotEmpty && user.trim().toLowerCase() == myName);

        return _messageTile(message: msg, user: user, date: date, isMine: isMine);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ WICHTIG: GestureDetector um ALLES, damit Tap überall die Tastatur schließt
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: Scaffold(
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
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _dismissKeyboard,
                    child: _buildFeedbackList(),
                  ),
                ),
                _inputBar(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
