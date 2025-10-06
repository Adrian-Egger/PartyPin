import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../Screens/party_map_screen.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _feedbackController = TextEditingController();

  final List<String> hints = const [
    "Was können wir besser machen...",
    "Dein Feedback ist uns wichtig!",
    "Sag uns deine Meinung...",
    "Irgendein Verbesserungsvorschlag?",
    "Teile uns deine Gedanken mit..."
  ];

  // === Limit/Timer (rollierendes 24h Fenster) ===
  static const int kWindowLimit = 3;
  static const Duration kWindow = Duration(hours: 24);

  int _usedInWindow = 0;
  DateTime? _lockUntil;                 // lokale Zeit, ab der wieder erlaubt
  Timer? _ticker;

  // Nur diese zwei Widgets werden pro Sekunde aktualisiert:
  final ValueNotifier<Duration> _remainingVN = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _isLockedVN = ValueNotifier(false);

  // UI + Anim (für Toast)
  late AnimationController _snackController;
  late Animation<Offset> _slideAnimation;
  bool _showSnack = false;
  double _bottomPadding = 0;
  String _snackMessage = "Feedback gesendet ✅";
  Key _streamKey = UniqueKey();

  // Style
  Color get bg => Colors.grey[850]!;
  Color get panel => Colors.grey[800]!;
  Color get textPrimary => Colors.white;
  Color get textSecondary => Colors.white70;
  Color get accent => Colors.redAccent;

  String get randomHint {
    final random = Random();
    return hints[random.nextInt(hints.length)];
  }

  // === Time helpers ===
  DateTime _nowUtc() => DateTime.now().toUtc();

  String _formatDateTimeLocal(DateTime dt) {
    // nur für die Liste der Feedbacks – NICHT mehr für Sperrhinweise
    final l = dt.toLocal();
    final dd = l.day.toString().padLeft(2, '0');
    final mm = l.month.toString().padLeft(2, '0');
    final yyyy = l.year.toString().padLeft(4, '0');
    final HH = l.hour.toString().padLeft(2, '0');
    final MM = l.minute.toString().padLeft(2, '0');
    return "$dd.$mm.$yyyy $HH:$MM";
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) return "00:00:00";
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return "${h.toString().padLeft(2,'0')}:"
        "${m.toString().padLeft(2,'0')}:"
        "${s.toString().padLeft(2,'0')}";
  }

  @override
  void initState() {
    super.initState();
    _snackController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: const Offset(0, 0),
    ).animate(CurvedAnimation(parent: _snackController, curve: Curves.easeOut));

    _loadUserName();
    _showInfoOnce();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _remainingVN.dispose();
    _isLockedVN.dispose();
    _snackController.dispose();
    _nameController.dispose();
    _feedbackController.dispose();
    super.dispose();
  }

  Future<void> _loadUserName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final vorname = prefs.getString("vorname") ?? "";
      final nachname = prefs.getString("nachname") ?? "";
      setState(() => _nameController.text = "$vorname $nachname".trim());
      await _refreshQuota24h();
    } catch (e, st) {
      debugPrint("SharedPreferences error: $e\n$st");
    }
  }

  Future<void> _showInfoOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final shown = prefs.getBool('feedbackInfoShown') ?? false;
      if (!shown) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showPrizeDialog());
        await prefs.setBool('feedbackInfoShown', true);
      }
    } catch (e, st) {
      debugPrint("SharedPreferences infoOnce error: $e\n$st");
    }
  }

  // ---------- Firestore helpers ----------
  String _docIdForName(String name) {
    if (name.isEmpty) return DateTime.now().millisecondsSinceEpoch.toString();
    return name.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
  }

  /// Quota neu berechnen, Lock und schlanken Timer setzen.
  Future<void> _refreshQuota24h() async {
    final name = _nameController.text.trim();

    _ticker?.cancel(); // alten Timer stoppen

    if (name.isEmpty) {
      setState(() {
        _usedInWindow = 0;
        _lockUntil = null;
      });
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      return;
    }

    final docRef = FirebaseFirestore.instance
        .collection("feedbacks")
        .doc(_docIdForName(name));

    try {
      final snap = await docRef.get();
      final data = snap.data();
      final nowUtc = _nowUtc();
      final windowStartUtc = nowUtc.subtract(kWindow);

      // submissions: List<Timestamp/String>
      List<DateTime> subsUtc = [];
      if (data != null) {
        final raw = (data['submissions'] as List?) ?? const [];
        for (final v in raw) {
          if (v is Timestamp) {
            subsUtc.add(v.toDate().toUtc());
          } else if (v is String) {
            final p = DateTime.tryParse(v);
            if (p != null) subsUtc.add(p.toUtc());
          }
        }
      }

      subsUtc = subsUtc.where((t) => t.isAfter(windowStartUtc)).toList()..sort();
      final used = subsUtc.length;

      DateTime? lockUntilLocal;
      if (used >= kWindowLimit) {
        lockUntilLocal = subsUtc.first.add(kWindow).toLocal();
      }

      setState(() {
        _usedInWindow = used.clamp(0, kWindowLimit);
        _lockUntil = lockUntilLocal;
      });

      _configureTicker();
    } catch (e, st) {
      debugPrint("refreshQuota24h error: $e\n$st");
      setState(() {
        _usedInWindow = 0;
        _lockUntil = null;
      });
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
    }
  }

  /// Startet einen schlanken Ticker, der NUR die kleinen Widgets updated (kein setState()).
  void _configureTicker() {
    _ticker?.cancel();

    if (_lockUntil == null) {
      _isLockedVN.value = false;
      _remainingVN.value = Duration.zero;
      return;
    }

    _isLockedVN.value = true;

    void tick() {
      final rem = _lockUntil!.difference(DateTime.now());
      if (rem.isNegative || rem.inSeconds <= 0) {
        _ticker?.cancel();
        _isLockedVN.value = false;
        _remainingVN.value = Duration.zero;
        _lockUntil = null;
        _refreshQuota24h(); // einmalig sanft neu laden
      } else {
        _remainingVN.value = rem;
      }
    }

    tick(); // sofort
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _reloadAll() async {
    setState(() => _streamKey = UniqueKey()); // Liste neu binden
    await _refreshQuota24h();
    _showSnackBar("Aktualisiert");
  }

  /// Senden mit 24h-Rolling-Window
  Future<void> _sendFeedback() async {
    final name = _nameController.text.trim();
    final feedbackText = _feedbackController.text.trim();

    if (feedbackText.isEmpty) {
      _showSnackBar("Bitte Feedback eingeben!");
      HapticFeedback.heavyImpact();
      return;
    }
    if (name.isEmpty) {
      _showSnackBar("Name fehlt!");
      HapticFeedback.heavyImpact();
      return;
    }

    // vor dem Schreiben Quota prüfen
    await _refreshQuota24h();
    if (_lockUntil != null) {
      final rem = _lockUntil!.difference(DateTime.now());
      _showSnackBar("Limit erreicht – noch ${_formatDuration(rem)}.");
      HapticFeedback.heavyImpact();
      return;
    }

    final docRef = FirebaseFirestore.instance
        .collection("feedbacks")
        .doc(_docIdForName(name));

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final nowUtc = _nowUtc();

        // Aktuelle subs holen
        final snap = await tx.get(docRef);
        final data = snap.data() as Map<String, dynamic>?;

        List<DateTime> subsUtc = [];
        if (data != null) {
          final raw = (data['submissions'] as List?) ?? const [];
          for (final v in raw) {
            if (v is Timestamp) subsUtc.add(v.toDate().toUtc());
            else if (v is String) {
              final p = DateTime.tryParse(v);
              if (p != null) subsUtc.add(p.toUtc());
            }
          }
        }

        // 24h-Fenster prüfen
        final windowStartUtc = nowUtc.subtract(kWindow);
        subsUtc = subsUtc.where((t) => t.isAfter(windowStartUtc)).toList()..sort();

        if (subsUtc.length >= kWindowLimit) {
          final nextLocal = subsUtc.first.add(kWindow).toLocal();
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'resource-exhausted',
            message: nextLocal.toIso8601String(), // nur intern: wir berechnen Dauer daraus
          );
        }

        final newSubs = [...subsUtc, nowUtc];

        tx.set(
          docRef,
          {
            "userName": name,
            "message": feedbackText,
            "timestamp": FieldValue.serverTimestamp(), // Sortierung/Anzeige
            "submissions": newSubs.map((d) => Timestamp.fromDate(d)).toList(),
          },
          SetOptions(merge: true),
        );
      });

      _feedbackController.clear();
      HapticFeedback.lightImpact();
      await _refreshQuota24h();
      _showSnackBar("Feedback gesendet ✅");
    } on FirebaseException catch (e, st) {
      debugPrint("Firestore write error: code=${e.code} – ${e.message}\n$st");
      if (e.code == 'resource-exhausted') {
        // keine Datumsausgabe mehr – nur Restdauer
        Duration? rem;
        if (e.message != null) {
          final p = DateTime.tryParse(e.message!);
          if (p != null) rem = p.toLocal().difference(DateTime.now());
        }
        final msg = rem == null
            ? "Limit erreicht – bitte warte noch."
            : "Limit erreicht – noch ${_formatDuration(rem)}.";
        _showSnackBar(msg);
      } else {
        _showSnackBar("Fehler beim Speichern (${e.code}).");
      }
      HapticFeedback.heavyImpact();
    } catch (e, st) {
      debugPrint("Unexpected write error: $e\n$st");
      HapticFeedback.heavyImpact();
      _showSnackBar("Fehler beim Speichern! Schau Konsole.");
    }
  }

  // ---------- UI Helpers ----------
  void _showSnackBar(String message) async {
    setState(() {
      _snackMessage = message;
      _showSnack = true;
      _bottomPadding = 70;
    });
    _snackController.forward();
    await Future.delayed(const Duration(seconds: 2));
    _snackController.reverse();
    await Future.delayed(const Duration(milliseconds: 240));
    if (!mounted) return;
    setState(() {
      _showSnack = false;
      _bottomPadding = 0;
    });
  }

  void _showPrizeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: bg,
        title: Text("GEWINNE einen PREMIUM ACCOUNT!",
            style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
        content: const Text(
          "Mit jedem hilfreichen Feedback erhältst du die Chance, "
              "einen von 10 Premium-Accounts zu gewinnen, die gerade in Entwicklung sind.",
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("OK", style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _infoPanel({required String label, required String value, IconData? icon}) {
    return Container(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: textSecondary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(color: textSecondary, fontSize: 12, height: 1.2)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _limitBanner24hVN() {
    return ValueListenableBuilder<bool>(
      valueListenable: _isLockedVN,
      builder: (_, locked, __) {
        if (!locked) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.lock_clock, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _remainingVN,
                  builder: (_, rem, __) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Gesperrt (24h-Fenster voll)",
                          style: TextStyle(color: textSecondary, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        "Noch ${_formatDuration(rem)}",
                        style: TextStyle(color: textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _counterRow24h() {
    final used = _usedInWindow.clamp(0, kWindowLimit);
    final remaining = (kWindowLimit - used).clamp(0, kWindowLimit);
    final value = used / kWindowLimit;

    return Container(
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.av_timer, color: textSecondary),
              const SizedBox(width: 8),
              Text(
                "Letzte 24h: $used / $kWindowLimit",
                style: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                remaining > 0 ? "$remaining übrig" : "gesperrt",
                style: TextStyle(color: textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
              backgroundColor: Colors.grey[700],
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _counterChip24h() {
    final used = _usedInWindow.clamp(0, kWindowLimit);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.countertops, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            "$used/$kWindowLimit",
            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hintText = randomHint;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        elevation: 0.5,
        title: const Text(
          "Feedback",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.white),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: accent),
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => const PartyMapScreen()),
            );
          },
        ),
        actions: [
          _counterChip24h(),
          IconButton(
            tooltip: "Reload",
            onPressed: _reloadAll,
            icon: const Icon(Icons.refresh),
            color: Colors.white70,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Stack(
        children: [
          AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.only(bottom: _bottomPadding),
            curve: Curves.easeOut,
            child: Container(
              color: bg,
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  // Liste (letzte Meldungen aller Benutzer)
                  Expanded(
                    child: StreamBuilder<QuerySnapshot>(
                      key: _streamKey,
                      stream: FirebaseFirestore.instance
                          .collection("feedbacks")
                          .orderBy("timestamp", descending: true)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          debugPrint('Stream error: ${snapshot.error}');
                          return Center(
                            child: Text(
                              "Fehler beim Laden",
                              style: TextStyle(color: accent, fontWeight: FontWeight.w600),
                            ),
                          );
                        }
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final docs = snapshot.data?.docs ?? [];
                        if (docs.isEmpty) {
                          return Center(
                            child: Text(
                              "Noch kein Feedback vorhanden",
                              style: TextStyle(color: textSecondary),
                            ),
                          );
                        }

                        return ListView.builder(
                          physics: const BouncingScrollPhysics(),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final raw = docs[index].data() as Map<String, dynamic>;
                            final message = (raw["message"] as String?) ?? "";
                            final userName = (raw["userName"] as String?) ?? "Unbekannt";
                            final ts = raw["timestamp"] as Timestamp?;
                            final dateString = ts == null
                                ? "—"
                                : _formatDateTimeLocal(ts.toDate());

                            return Card(
                              elevation: 0,
                              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              color: panel,
                              child: ListTile(
                                leading: Icon(Icons.feedback, color: accent),
                                title: Text(message,
                                    style: TextStyle(fontSize: 16, color: textPrimary)),
                                subtitle: Text("Von: $userName",
                                    style: TextStyle(color: textSecondary)),
                                trailing: Text(dateString,
                                    style: TextStyle(fontSize: 11, color: textSecondary)),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 12),

                  _infoPanel(label: "Dein Name", value: _nameController.text, icon: Icons.person),

                  const SizedBox(height: 10),

                  _counterRow24h(),

                  const SizedBox(height: 10),

                  _limitBanner24hVN(),

                  const SizedBox(height: 10),

                  // Eingabe + Senden (nur dieser Block reagiert jede Sekunde über ValueListenable)
                  Row(
                    children: [
                      Expanded(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _isLockedVN,
                          builder: (_, locked, __) => TextField(
                            controller: _feedbackController,
                            maxLines: null,
                            enabled: !locked,
                            style: TextStyle(color: textPrimary),
                            decoration: InputDecoration(
                              hintText: locked ? "Warte …" : hintText,
                              hintStyle: TextStyle(color: textSecondary),
                              contentPadding:
                              const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.transparent)),
                              enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(color: Colors.transparent)),
                              focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: accent)),
                              filled: true,
                              fillColor: panel,
                            ),
                            onChanged: (_) => setState(() {}),
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
                            builder: (_, rem, __) => ElevatedButton(
                              onPressed: (locked || _feedbackController.text.trim().isEmpty)
                                  ? null
                                  : _sendFeedback,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                disabledBackgroundColor: Colors.grey[700],
                                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                elevation: 3,
                              ),
                              child: Text(
                                locked ? _formatDuration(rem) : "Senden",
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),

          // Slide-Toast
          if (_showSnack)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                    decoration: BoxDecoration(
                      color: panel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.check_circle, color: Colors.greenAccent[400]),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _snackMessage,
                            style: TextStyle(color: textPrimary, fontSize: 15),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
