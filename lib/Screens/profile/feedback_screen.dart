// lib/Screens/feedback_screen.dart
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../Theme/app_theme.dart';

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

  // ✅ ECHTER Username (für Block/Reports) – aus SharedPreferences
  String _myUsername = "";

  // ✅ ECHTE users/{docId} – damit Ban/Blocked immer das richtige Doc trifft
  String _myUserDocId = "";

  // ✅ ID, die wir für Block-Liste verwenden (users/{docId})
  String _myBlockOwnerId = "";

  // ✅ Blockliste (aus Firestore)
  Set<String> _blockedIds = <String>{};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _blockedSub;

  // ✅ BAN-Status (Admin setzt users/{docId}.banned = true)
  bool _isBanned = false;
  String _banReason = "";
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _banSub;

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
    await _ensureMyUsernameAndBlockOwnerId();

    _bindBlockedUsers(); // ✅ Blockliste live
    _bindBanStatus(); // ✅ Ban live

    await Future.wait([
      _refreshQuota24h(force: true),
      _loadFeedbacks(),
    ]);
  }

  @override
  void dispose() {
    _banSub?.cancel();
    _blockedSub?.cancel();
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
        Color color = AppColors.panel,
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

  // ✅ users/{docId} sicher auflösen (Admin nutzt doc.id aus Search)
  Future<void> _resolveMyUserDocId() async {
    // Wenn kein Username: fallback auf userKey
    if (_myUsername.isEmpty) {
      _myUserDocId = _userKey.isNotEmpty ? _userKey : "unknown";
      return;
    }

    try {
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isEqualTo: _myUsername)
          .limit(1)
          .get();

      if (q.docs.isNotEmpty) {
        _myUserDocId = q.docs.first.id; // ✅ echte DocId
      } else {
        // Fallback (falls eure alte Struktur docId == username war)
        _myUserDocId = _myUsername;
      }
    } catch (_) {
      _myUserDocId = _myUsername;
    }

    if (_myUserDocId.isEmpty) _myUserDocId = "unknown";
  }

  Future<void> _ensureMyUsernameAndBlockOwnerId() async {
    final prefs = await SharedPreferences.getInstance();
    _myUsername = (prefs.getString("username") ?? "").trim();

    await _resolveMyUserDocId();

    // Für Blockliste/Ban: nimm users/{docId}
    _myBlockOwnerId = _myUserDocId;

    if (_myBlockOwnerId.isEmpty) {
      _myBlockOwnerId = "unknown";
    }
  }

  void _bindBlockedUsers() {
    _blockedSub?.cancel();

    if (_myUserDocId.isEmpty || _myUserDocId == "unknown") {
      setState(() => _blockedIds = <String>{});
      return;
    }

    // ✅ users/{meDocId}/blocked/{blockedId}
    _blockedSub = FirebaseFirestore.instance
        .collection('users')
        .doc(_myUserDocId)
        .collection('blocked')
        .snapshots()
        .listen((qs) {
      final ids = qs.docs.map((d) => d.id).toSet();
      if (!mounted) return;
      setState(() => _blockedIds = ids);
    });
  }

  void _bindBanStatus() {
    _banSub?.cancel();

    if (_myUserDocId.isEmpty || _myUserDocId == "unknown") {
      setState(() {
        _isBanned = false;
        _banReason = "";
      });
      return;
    }

    // ✅ Admin setzt: users/{docId}.banned = true
    _banSub = FirebaseFirestore.instance
        .collection('users')
        .doc(_myUserDocId)
        .snapshots()
        .listen((snap) {
      final data = snap.data() ?? {};
      final banned = data['banned'] == true;
      final reason = (data['banReason'] ?? '').toString().trim();

      if (!mounted) return;
      setState(() {
        _isBanned = banned;
        _banReason = reason;
      });

      if (banned) {
        _feedbackController.clear();
        _sendingVN.value = false;
      }
    });
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

  // ✅ ermittelt eine stabile "Author ID" fürs Blocken/Reports:
  // bevorzugt: authorUsername -> username -> userKey -> userName(lower)
  String _authorIdFromDoc(Map<String, dynamic> raw) {
    final a = (raw['authorUsername'] as String?)?.trim();
    if (a != null && a.isNotEmpty) return a;

    final u = (raw['username'] as String?)?.trim();
    if (u != null && u.isNotEmpty) return u;

    final k = (raw['userKey'] as String?)?.trim();
    if (k != null && k.isNotEmpty) return "userKey:$k";

    final n = (raw['userName'] as String?)?.trim().toLowerCase();
    if (n != null && n.isNotEmpty) return "name:$n";

    return "unknown";
  }

  String _authorLabel(Map<String, dynamic> raw) {
    final user = (raw["userName"] as String?) ?? "Unbekannt";
    return user;
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

      // 3) Eigenes letztes Feedback (falls existiert) – NUR wenn nicht gebannt.
      // Query benötigt Composite-Index (userKey ASC, timestamp DESC) —
      // siehe firestore.indexes.json. Bei FAILED_PRECONDITION früher
      // wurde der Fehler hier still geschluckt, sodass das eigene
      // Feedback unsichtbar verschwand. Jetzt: lesbares Logging,
      // damit ein fehlender Index sofort auffällt.
      QueryDocumentSnapshot<Map<String, dynamic>>? mine;
      if (!_isBanned) {
        try {
          final qMine = await FirebaseFirestore.instance
              .collection("feedbacks")
              .where("userKey", isEqualTo: _userKey)
              .orderBy("timestamp", descending: true)
              .limit(1)
              .get();
          if (qMine.docs.isNotEmpty) mine = qMine.docs.first;
        } catch (e) {
          debugPrint('[feedback] mine-query failed: $e');
        }
      }

      // 4) rand nachschreiben für Zukunft (nur die geladenen)
      await _ensureRandForDocs(docs);

      // 5) Zusammenbauen:
      final ids = docs.map((d) => d.id).toSet();
      final result = <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      if (mine != null && !ids.contains(mine.id)) result.add(mine);

      docs.shuffle();
      result.addAll(docs.take(10));

      // ✅ Block-Filter + Hidden-Filter (Admin setzt hidden=true)
      final filtered = result.where((d) {
        final raw = d.data();
        if (raw['hidden'] == true) return false; // ✅ content removed/hidden
        final authorId = _authorIdFromDoc(raw);
        return !_blockedIds.contains(authorId);
      }).toList();

      if (!mounted) return;
      setState(() {
        _feedbackDocs = filtered;
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

    // ✅ gebannte User dürfen nichts posten
    if (_isBanned) {
      HapticFeedback.heavyImpact();
      _toast("Dein Account ist gesperrt.", color: AppColors.accent, icon: Icons.block);
      return;
    }

    final feedbackText = _feedbackController.text.trim();
    if (feedbackText.isEmpty) {
      HapticFeedback.heavyImpact();
      _toast("Bitte Text eingeben.",
          color: AppColors.accent, icon: Icons.warning_amber_rounded);
      return;
    }

    await _refreshQuota24h(force: false);
    if (_lockUntilLocal != null) {
      HapticFeedback.heavyImpact();
      _toast("Limit erreicht. Warte: ${_fmtDur(_remainingVN.value)}",
          color: AppColors.accent, icon: Icons.lock_clock);
      return;
    }

    if (_userKey.isEmpty) {
      HapticFeedback.heavyImpact();
      _toast("UserKey fehlt (App neu starten).",
          color: AppColors.accent, icon: Icons.error_outline);
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
          throw FirebaseException(
              plugin: 'cloud_firestore', code: 'resource-exhausted');
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
        // ✅ WICHTIG für Block/Reports: authorUsername + username mitschreiben
        // ✅ WICHTIG für Admin-Ban: authorUserDocId mitschreiben
        tx.set(
          feedbackRef,
          {
            "userKey": _userKey,
            "userName": _displayName(),
            "username": _myUsername,
            "authorUsername": _myUsername,
            "authorUserDocId": _myUserDocId, // ✅ neu
            "message": feedbackText,
            "timestamp": FieldValue.serverTimestamp(),
            "rand": Random().nextDouble(),

            // ✅ Admin-MODERATION: content removal
            "hidden": false,
          },
        );
      });

      _feedbackController.clear();
      HapticFeedback.lightImpact();
      _toast("Gesendet ✅", color: AppColors.success, icon: Icons.check_circle_rounded);

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
      _toast("Firestore Fehler: ${e.code}",
          color: AppColors.accent, icon: Icons.error_outline);
      await _refreshQuota24h(force: true);
    } catch (e) {
      HapticFeedback.heavyImpact();
      _toast("Fehler: $e", color: AppColors.accent, icon: Icons.error_outline);
      await _refreshQuota24h(force: true);
    } finally {
      _sendingVN.value = false;
    }
  }

  // ===========================
  // ✅ MELDEN + BLOCKIEREN
  // ===========================

  Future<void> _reportFeedback({
    required String feedbackDocId,
    required Map<String, dynamic> raw,
  }) async {
    final authorId = _authorIdFromDoc(raw);
    final authorLabel = _authorLabel(raw);

    final reason = await _pickReportReason();
    if (reason == null) return;

    final details = await _optionalReportDetails();
    if (!mounted) return;

    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'open',

        // wer meldet
        'reporterId': _myUserDocId,
        'reporterUsername':
        _myUsername.isNotEmpty ? _myUsername : _usernameFallback,
        'reporterUserKey': _userKey,

        // wen/was
        'reportedUserId': authorId,
        'reportedUsername': authorLabel,
        'targetType': 'feedback',
        'targetId': feedbackDocId,
        'reason': reason,
        'details': details,
      });

      HapticFeedback.lightImpact();
      _toast("Gemeldet ✅", color: AppColors.success, icon: Icons.check_circle_rounded);
    } catch (e) {
      HapticFeedback.heavyImpact();
      _toast("Melden fehlgeschlagen: $e",
          color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _blockUser({
    required Map<String, dynamic> raw,
  }) async {
    final authorId = _authorIdFromDoc(raw);
    final authorLabel = _authorLabel(raw);

    if (authorId == "unknown") {
      _toast("Blockieren nicht möglich (User unbekannt).",
          color: AppColors.accent, icon: Icons.warning_amber_rounded);
      return;
    }

    // sich selbst nicht blocken
    if (authorId == _myUserDocId) {
      _toast("Du kannst dich nicht selbst blockieren.",
          color: AppColors.accent, icon: Icons.warning_amber_rounded);
      return;
    }

    final ok = await _confirm(
      title: "User blockieren?",
      msg:
      "Willst du \"$authorLabel\" blockieren?\nDanach siehst du nichts mehr von diesem User (z.B. Feedbacks).",
      okText: "Blockieren",
    );
    if (!ok) return;

    try {
      // ✅ users/{meDocId}/blocked/{authorId}
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_myUserDocId)
          .collection('blocked')
          .doc(authorId)
          .set({
        'blockedUserId': authorId,
        'blockedUsername': authorLabel,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // ✅ sofort aus UI entfernen
      if (mounted) {
        setState(() {
          _blockedIds.add(authorId);
          _feedbackDocs = _feedbackDocs.where((d) {
            final a = _authorIdFromDoc(d.data());
            return a != authorId;
          }).toList();
        });
      }

      HapticFeedback.lightImpact();
      _toast("User blockiert ✅", color: AppColors.success, icon: Icons.check_circle_rounded);
    } catch (e) {
      HapticFeedback.heavyImpact();
      _toast("Blockieren fehlgeschlagen: $e",
          color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<String?> _pickReportReason() async {
    const reasons = <String>[
      'Hate Speech',
      'Belästigung',
      'Nacktheit/Sexuell',
      'Gewalt',
      'Spam',
      'Sonstiges',
    ];

    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: reasons.length,
            separatorBuilder: (_, __) =>
            const Divider(height: 1, color: AppColors.accentBorder),
            itemBuilder: (_, i) {
              return ListTile(
                title: Text(reasons[i],
                    style: const TextStyle(
                        color: AppColors.text, fontWeight: FontWeight.w700)),
                onTap: () => Navigator.of(ctx).pop(reasons[i]),
              );
            },
          ),
        );
      },
    );
  }

  Future<String> _optionalReportDetails() async {
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.panel,
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text("Details (optional)",
              style: TextStyle(color: AppColors.text)),
          content: TextField(
            controller: ctrl,
            maxLines: 3,
            style: const TextStyle(color: AppColors.text),
            decoration: const InputDecoration(
              hintText: "Kurz erklären…",
              hintStyle: TextStyle(color: AppColors.muted),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accentBorder)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(""),
              child: const Text("Überspringen",
                  style: TextStyle(color: AppColors.muted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text("OK",
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800)),
            ),
          ],
        );
      },
    );
    return (res ?? "").trim();
  }

  Future<bool> _confirm({
    required String title,
    required String msg,
    required String okText,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.panel,
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(title, style: const TextStyle(color: AppColors.text)),
          content: Text(msg,
              style: const TextStyle(color: AppColors.muted, height: 1.25)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text("Abbrechen",
                  style: TextStyle(color: AppColors.muted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(okText,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800)),
            ),
          ],
        );
      },
    );
    return res == true;
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
        icon: const Icon(Icons.arrow_back, color: AppColors.accent),
        onPressed: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).maybePop();
        },
      )
          : null,
      automaticallyImplyLeading: false,
      title: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.accentBorder2, width: 1),
        ),
        child: const Text(
          "Feedback",
          style: TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w700,
            fontSize: 15,
            letterSpacing: -0.2,
          ),
        ),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.panelAlt,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.accentBorder, width: 1),
          ),
          child: Text(
            "${_usedInWindow.clamp(0, kWindowLimit)}/$kWindowLimit",
            style: const TextStyle(color: AppColors.muted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          tooltip: "Aktualisieren",
          onPressed: _reloadAll,
          icon: const Icon(Icons.refresh, color: AppColors.muted),
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
            color: AppColors.panel,
            border: const Border(
              bottom: BorderSide(color: AppColors.accentBorder, width: 0.5),
              top: BorderSide(color: AppColors.accentBorder, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(locked ? Icons.lock_clock : Icons.av_timer,
                  size: 18, color: AppColors.muted),
              const SizedBox(width: 8),
              Expanded(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _remainingVN,
                  builder: (_, rem, __) => Text(
                    locked
                        ? "24h-Limit erreicht · noch ${_fmtDur(rem)}"
                        : "Heute verfügbar: $_remainingToday von $kWindowLimit",
                    style: const TextStyle(
                        color: AppColors.muted, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ✅ Menü (3 Punkte) pro Feedback
  Widget _moreMenu({
    required String feedbackDocId,
    required Map<String, dynamic> raw,
    required bool isMine,
  }) {
    final authorId = _authorIdFromDoc(raw);

    return PopupMenuButton<String>(
      color: AppColors.panel,
      icon: const Icon(Icons.more_vert, color: AppColors.muted),
      onSelected: (v) async {
        HapticFeedback.selectionClick();
        if (v == 'report') {
          await _reportFeedback(feedbackDocId: feedbackDocId, raw: raw);
        } else if (v == 'block') {
          if (authorId == _myUserDocId || isMine) {
            _toast("Du kannst dich nicht selbst blockieren.",
                color: AppColors.accent, icon: Icons.warning_amber_rounded);
            return;
          }
          await _blockUser(raw: raw);
        }
      },
      itemBuilder: (ctx) {
        return <PopupMenuEntry<String>>[
          PopupMenuItem(
            value: 'report',
            child: Row(
              children: const [
                Icon(Icons.flag_outlined, size: 18, color: AppColors.accent),
                SizedBox(width: 10),
                Text("Melden",
                    style: TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'block',
            child: Row(
              children: const [
                Icon(Icons.block, size: 18, color: AppColors.accent),
                SizedBox(width: 10),
                Text("Blockieren",
                    style: TextStyle(
                        color: AppColors.accent, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ];
      },
    );
  }

  // ✅ nur dünn umranden (kein linker Streifen mehr)
  Widget _messageTile({
    required String message,
    required String user,
    required String date,
    required bool isMine,
    required String feedbackDocId,
    required Map<String, dynamic> raw,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentBorder, width: 1),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.accentBorder,
          child: Icon(
            isMine ? Icons.person_rounded : Icons.chat_bubble_rounded,
            color: isMine ? AppColors.success : AppColors.accent,
            size: 16,
          ),
        ),
        title: Text(
          message,
          style: const TextStyle(color: AppColors.text, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          isMine ? "Von: $user (du)" : "Von: $user",
          style: const TextStyle(color: AppColors.muted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(date, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(width: 6),
            _moreMenu(feedbackDocId: feedbackDocId, raw: raw, isMine: isMine),
          ],
        ),
      ),
    );
  }

  Widget _inputBar() {
    final borderColor = _sentFlash ? AppColors.success : AppColors.accent;
    final sendColor = _sentFlash ? AppColors.success : AppColors.accent;

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
                  enabled: !locked && !_isBanned,
                  style: const TextStyle(color: AppColors.text),
                  decoration: InputDecoration(
                    hintText: _isBanned ? "Account gesperrt" : (locked ? "Gesperrt …" : _hint),
                    hintStyle: const TextStyle(color: AppColors.muted),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                    filled: true,
                    fillColor: AppColors.panel,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor, width: 1),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _sentFlash ? AppColors.success : AppColors.accent, width: 1.2),
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
                            final disabled = _isBanned || locked || sending || !canSend;
                            return ElevatedButton(
                              onPressed: disabled ? null : _sendFeedback,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: sendColor,
                                disabledBackgroundColor: Colors.white12,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: sending
                                  ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                                  : Text(
                                locked ? _fmtDur(rem) : "Senden",
                                style: const TextStyle(fontWeight: FontWeight.w700),
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
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_feedbackError) {
      return const Center(
        child: Text("Fehler beim Laden", style: TextStyle(color: AppColors.accent)),
      );
    }
    if (_feedbackDocs.isEmpty) {
      return const Center(
        child: Text("Noch kein Feedback vorhanden", style: TextStyle(color: AppColors.muted)),
      );
    }

    final myKey = _userKey.trim();
    final myName = _displayName().trim().toLowerCase();

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 100, top: 8),
      itemCount: _feedbackDocs.length,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemBuilder: (context, i) {
        final doc = _feedbackDocs[i];
        final raw = doc.data();

        // ✅ Admin-MODERATION: ausgeblendetes content nie anzeigen
        if (raw['hidden'] == true) return const SizedBox.shrink();

        // ✅ Block-Filter
        final authorId = _authorIdFromDoc(raw);
        if (_blockedIds.contains(authorId)) return const SizedBox.shrink();

        final msg = (raw["message"] as String?) ?? "";
        final user = (raw["userName"] as String?) ?? "Unbekannt";
        final key = (raw["userKey"] as String?) ?? "";

        final ts = raw["timestamp"] as Timestamp?;
        final date = ts == null ? "—" : _fmt(ts.toDate());

        final isMine =
            (myKey.isNotEmpty && key == myKey) || (myName.isNotEmpty && user.trim().toLowerCase() == myName);

        return _messageTile(
          message: msg,
          user: user,
          date: date,
          isMine: isMine,
          feedbackDocId: doc.id,
          raw: raw,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Wenn gebannt: klare Sperr-Ansicht
    if (_isBanned) {
      return Scaffold(
        backgroundColor: AppColors.bgTop,
        appBar: _appBar(),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.bgTop, AppColors.bgBottom],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.panel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.accent, width: 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.block, color: AppColors.accent, size: 42),
                  const SizedBox(height: 10),
                  const Text(
                    "Account gesperrt",
                    style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w900, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _banReason.isNotEmpty ? "Grund: $_banReason" : "Du kannst diese Funktion nicht mehr nutzen.",
                    style: const TextStyle(color: AppColors.muted, height: 1.25),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // ✅ normal
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: Scaffold(
        backgroundColor: AppColors.bgTop,
        appBar: _appBar(),
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.bgTop, AppColors.bgBottom],
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
