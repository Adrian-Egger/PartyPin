import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ FIX: UID Support
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// =======================
// THEME (gleich wie bei dir)
// =======================
const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30);

// =======================
// PAYPAL PLANS
// =======================
enum PayPalPlan { monthly, yearly }

const String _paypalPlanMonthly = "P-55588718AV729883XNE6MJ5Y";
const String _paypalPlanYearly = "P-0WL99384633096336NE6WUSA";

// ✅ Deine echte Functions Base
const String _functionsBase = "https://us-central1-partypin-5dc3f.cloudfunctions.net";

// =======================
// PREMIUM SCREEN
// =======================
class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  PayPalPlan _selectedPlan = PayPalPlan.monthly;
  bool _isLoading = false;

  String? _currentUsername;

  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _paypalLinkSub;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();

    _loadUsername();
    _listenForPaypalReturn();
    _handleInitialPaypalReturn();
  }

  @override
  void dispose() {
    _paypalLinkSub?.cancel();
    super.dispose();
  }

  // ✅ Back-Arrow wie Screenshot
  Widget _backArrow(BuildContext context) {
    return IconButton(
      onPressed: () => Navigator.pop(context),
      icon: const Icon(
        Icons.arrow_back,
        color: _accent,
        size: 26,
      ),
      tooltip: 'Zurück',
    );
  }

  // ✅ Einheitliche AppBar
  PreferredSizeWidget _appBar(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      leading: _backArrow(context),
      title: const Text(
        '⭐ Premium ⭐',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 20,
        ),
      ),
    );
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      // ⚠️ Du hattest "currentUsername" - in anderen Files nutzt du oft "username".
      // Wir lassen es so wie bei dir, aber robust weiter unten.
      _currentUsername = (prefs.getString('currentUsername') ?? prefs.getString('username'))?.trim();
    });
  }

  void _listenForPaypalReturn() {
    _paypalLinkSub = _appLinks.uriLinkStream.listen((Uri uri) async {
      await _handlePaypalUri(uri);
    });
  }

  Future<void> _handleInitialPaypalReturn() async {
    try {
      final Uri? initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handlePaypalUri(initialUri);
      }
    } catch (_) {}
  }

  Future<void> _handlePaypalUri(Uri uri) async {
    if (!mounted) return;
    if (uri.scheme != 'partypin') return;

    if (uri.host == 'paypal-return') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zahlung abgeschlossen. Premium wird gleich aktiviert…')),
      );
    } else if (uri.host == 'paypal-cancel') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zahlung abgebrochen.')),
      );
    }
  }

  String _planIdFor(PayPalPlan plan) =>
      plan == PayPalPlan.monthly ? _paypalPlanMonthly : _paypalPlanYearly;

  String _planPriceText(PayPalPlan plan) =>
      plan == PayPalPlan.monthly ? '1,49 € / Monat' : '14,99 € / Jahr';

  String _payButtonLabel() => 'Mit PayPal zahlen';

  String _savingsText() => 'Spare ca. 2,89 € pro Jahr';

  // ===========================
  // ✅ FIX: Premium zuverlässig erkennen (UID -> users/{username} -> Query username)
  // ===========================

  bool _parsePremium(dynamic v) {
    if (v == true) return true;
    if (v is String) return v.trim().toLowerCase() == 'true';
    if (v is num) return v == 1;
    return false;
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _userDocByUidStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.trim().isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').doc(uid).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _userDocByUsernameStream(String username) {
    final u = username.trim();
    if (u.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').doc(u).snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _userByUsernameQueryStream(String username) {
    final u = username.trim();
    if (u.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: u)
        .limit(1)
        .snapshots();
  }

  /// Liefert: (isPremium, isLoading)
  Widget _premiumGateBuilder({
    required String username,
    required Widget Function(bool isPremium) builder,
  }) {
    // 1) users/{uid}
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _userDocByUidStream(),
      builder: (context, uidSnap) {
        if (uidSnap.connectionState == ConnectionState.waiting) {
          return builder(false); // UI weiter unten kann Loading anzeigen, wenn du willst
        }

        if (uidSnap.data?.exists == true) {
          final data = uidSnap.data?.data() ?? {};
          final isPremium = _parsePremium(data['premium']);
          return builder(isPremium);
        }

        // 2) users/{username}
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _userDocByUsernameStream(username),
          builder: (context, userSnap) {
            if (userSnap.connectionState == ConnectionState.waiting) {
              return builder(false);
            }

            if (userSnap.data?.exists == true) {
              final data = userSnap.data?.data() ?? {};
              final isPremium = _parsePremium(data['premium']);
              return builder(isPremium);
            }

            // 3) Query users where username == X
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _userByUsernameQueryStream(username),
              builder: (context, qSnap) {
                final docs = qSnap.data?.docs ?? const [];
                final isPremium = docs.isNotEmpty ? _parsePremium(docs.first.data()['premium']) : false;
                return builder(isPremium);
              },
            );
          },
        );
      },
    );
  }

  // ===========================

  Future<void> _openSubscriptionCheckout() async {
    final u = _currentUsername?.trim() ?? '';
    if (u.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _panel,
          content: Text(
            'Kein Username gefunden. Bitte neu einloggen.',
            style: TextStyle(color: _textPrimary),
          ),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final planId = _planIdFor(_selectedPlan);

      final res = await http.post(
        Uri.parse('$_functionsBase/createPayPalCheckout'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': u, 'planId': planId}),
      );

      if (res.statusCode != 200) {
        throw Exception(res.body);
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final approveLink = (json['approveLink'] ?? '').toString();
      if (approveLink.isEmpty) throw Exception('approveLink fehlt');

      final ok = await launchUrl(
        Uri.parse(approveLink),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw Exception('Konnte PayPal-Seite nicht öffnen.');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _panel,
          content: Text(
            'Fehler beim Öffnen von PayPal: $e',
            style: const TextStyle(color: _textPrimary),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ✅ Ersetze NUR diese Funktion in deinem Code:
  Widget _premiumFeaturesCard() {
    const panel = Color(0xFF141A22);
    const accentRed = Color(0xFFFF3B30);

    Widget row(IconData ic, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ic, color: accentRed, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white70,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Was du mit Premium bekommst',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 10),
          row(Icons.people_alt_rounded, 'Du siehst, ob Freunde von dir zu einer Party gehen.'),
          row(Icons.add_a_photo_rounded, 'Du kannst bei deinen eigenen Partys Bilder hinzufügen.'),
          row(Icons.verified_rounded, 'Premium-Badge & Zugriff auf zukünftige Premium-Features.'),
          row(Icons.rocket_launch_rounded, 'Early Access für neue Features, die zukünftig kommen.'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF090B10);
    const panel = Color(0xFF141A22);
    const accentRed = Color(0xFFFF3B30);

    final username = (_currentUsername ?? '').trim();

    if (username.isEmpty) {
      return Scaffold(
        backgroundColor: bg,
        appBar: _appBar(context),
        body: const Center(
          child: Text(
            'Kein Benutzer gefunden. Bitte neu einloggen.',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    final yearlySelected = _selectedPlan == PayPalPlan.yearly;

    // ✅ FIX: nicht mehr nur users/{username} – sondern UID/username/query fallback
    return _premiumGateBuilder(
      username: username,
      builder: (isPremium) {
        // ✅ Premium aktiv
        if (isPremium) {
          return Scaffold(
            backgroundColor: bg,
            appBar: _appBar(context),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accentRed.withOpacity(0.9), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: accentRed.withOpacity(0.12),
                        blurRadius: 18,
                        spreadRadius: 2,
                      )
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: accentRed.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: accentRed),
                        ),
                        child: const Text(
                          '⭐ PREMIUM AKTIV ⭐',
                          style: TextStyle(
                            color: accentRed,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '🥳🔥 Du bist bereits stolzer Besitzer\n'
                            'eines Premium-Accounts! 🔥🥳',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '✅ Danke für deinen Support!\n'
                            'Du hast alle Premium-Features freigeschaltet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.check_circle, color: Colors.white),
                          label: const Text(
                            'Alles klar',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentRed,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        // ✅ NICHT Premium
        return Scaffold(
          backgroundColor: bg,
          appBar: _appBar(context),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: panel,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Free',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Schalte Premium frei für Live-Freunde-Status etc.',
                        style: TextStyle(color: Colors.white70, height: 1.4),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _premiumFeaturesCard(),
                const SizedBox(height: 16),
                const Text(
                  'Wähle dein Abo',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                _planCard(
                  title: 'Monatlich',
                  subtitle: 'Flexibel kündbar – ideal zum Testen.',
                  price: _planPriceText(PayPalPlan.monthly),
                  selected: _selectedPlan == PayPalPlan.monthly,
                  highlight: null,
                  onTap: () => setState(() => _selectedPlan = PayPalPlan.monthly),
                ),
                const SizedBox(height: 10),
                _planCard(
                  title: 'Jährlich',
                  subtitle: 'Bestes Angebot – weniger Aufwand.',
                  price: _planPriceText(PayPalPlan.yearly),
                  selected: yearlySelected,
                  highlight: _savingsText(),
                  onTap: () => setState(() => _selectedPlan = PayPalPlan.yearly),
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _isLoading ? null : _openSubscriptionCheckout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.payment, size: 18),
                      const SizedBox(width: 10),
                      Text(
                        _isLoading ? 'Lädt…' : _payButtonLabel(),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '• ${_planPriceText(_selectedPlan)}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F121A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: const Text(
                    'Hinweis: Abos werden über PayPal abgewickelt. Premium wird nach erfolgreicher Bestätigung automatisch aktiviert. '
                        'Kündigung in PayPal deaktiviert Premium automatisch.',
                    style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _planCard({
    required String title,
    required String subtitle,
    required String price,
    required bool selected,
    required VoidCallback onTap,
    String? highlight,
  }) {
    const accentRed = Color(0xFFFF3B30);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E2230) : const Color(0xFF141824),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? accentRed : Colors.white12,
            width: selected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? accentRed : Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      if (highlight != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: accentRed.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: accentRed),
                          ),
                          child: Text(
                            highlight,
                            style: const TextStyle(
                              color: accentRed,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              price,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ),
    );
  }
}
