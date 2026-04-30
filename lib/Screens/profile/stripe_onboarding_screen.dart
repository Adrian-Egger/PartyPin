// lib/Screens/profile/stripe_onboarding_screen.dart
// Hosts onboarden ihren Stripe-Connect-Express-Account, damit sie
// Tickets verkaufen können.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../Services/stripe_service.dart';
import '../../Theme/app_theme.dart';

class StripeOnboardingScreen extends StatefulWidget {
  const StripeOnboardingScreen({super.key});

  @override
  State<StripeOnboardingScreen> createState() => _StripeOnboardingScreenState();
}

class _StripeOnboardingScreenState extends State<StripeOnboardingScreen> {
  bool _busy = false;
  String? _error;

  Stream<DocumentSnapshot<Map<String, dynamic>>>? _userStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance.collection('users').doc(uid).snapshots();
  }

  Future<void> _startOnboarding() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = await StripeService.createHostOnboardingUrl();
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw 'Browser konnte nicht geöffnet werden.';
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await StripeService.refreshHostStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Status aktualisiert: ${res['status']}'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// DEBUG-ONLY: Simuliert ein erfolgreiches Onboarding, indem die
  /// Stripe-Felder im User-Doc auf "active" gesetzt werden.
  /// Echte Käufe schlagen damit fehl (kein echter Stripe-Account),
  /// aber UI-Flows (Toggle, Eingaben, Sichtbarkeit) sind testbar.
  Future<void> _devBypass(bool enable) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        enable
            ? {
                'stripeAccountId': 'acct_DEV_BYPASS',
                'stripeChargesEnabled': true,
                'stripePayoutsEnabled': true,
                'stripeDetailsSubmitted': true,
                'stripeOnboardingStatus': 'active',
                'stripeIsDevBypass': true,
                'stripeStatusUpdatedAt': FieldValue.serverTimestamp(),
              }
            : {
                'stripeAccountId': FieldValue.delete(),
                'stripeChargesEnabled': false,
                'stripePayoutsEnabled': false,
                'stripeDetailsSubmitted': false,
                'stripeOnboardingStatus': 'incomplete',
                'stripeIsDevBypass': false,
                'stripeStatusUpdatedAt': FieldValue.serverTimestamp(),
              },
        SetOptions(merge: true),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(enable
              ? '🧪 Test-Bypass aktiviert (Käufe werden trotzdem fehlschlagen)'
              : '🧪 Test-Bypass deaktiviert'),
          backgroundColor: enable ? Colors.purple : AppColors.muted,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        title: const Text('Tickets verkaufen'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.bgTop, AppColors.bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _userStream(),
            builder: (context, snap) {
              final data = snap.data?.data() ?? {};
              final hasAccount = (data['stripeAccountId'] ?? '').toString().isNotEmpty;
              final detailsSubmitted = data['stripeDetailsSubmitted'] == true;
              final chargesEnabled = data['stripeChargesEnabled'] == true;
              final payoutsEnabled = data['stripePayoutsEnabled'] == true;
              final fullyActive = chargesEnabled && payoutsEnabled;
              final isDevBypass = data['stripeIsDevBypass'] == true;

              return SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.panel,
                        borderRadius: AppRadius.smBr,
                        border: Border.all(color: AppColors.accentBorder),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            fullyActive
                                ? Icons.verified_rounded
                                : hasAccount
                                    ? Icons.hourglass_top_rounded
                                    : Icons.payment_rounded,
                            size: 56,
                            color: fullyActive
                                ? AppColors.success
                                : AppColors.accent,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            fullyActive
                                ? 'Bereit für Tickets!'
                                : hasAccount
                                    ? 'Onboarding läuft'
                                    : 'Stripe verbinden',
                            style: const TextStyle(
                              color: AppColors.text,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            fullyActive
                                ? 'Du kannst jetzt für deine Partys Tickets aktivieren. Auszahlungen gehen direkt an dein Bankkonto.'
                                : hasAccount
                                    ? 'Wir warten auf die Verifizierung. Sobald Stripe alles bestätigt hat, kannst du Tickets verkaufen.'
                                    : 'Um Tickets zu verkaufen, brauchst du einen Stripe-Account. Stripe übernimmt Bezahlung und Auszahlung an dich.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppColors.muted,
                              height: 1.4,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _StatusRow(
                      label: 'Daten eingereicht',
                      ok: detailsSubmitted,
                    ),
                    _StatusRow(
                      label: 'Zahlungen aktiv',
                      ok: chargesEnabled,
                    ),
                    _StatusRow(
                      label: 'Auszahlungen aktiv',
                      ok: payoutsEnabled,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!,
                          style: const TextStyle(color: Colors.redAccent),
                          textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _busy ? null : _startOnboarding,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: AppRadius.smBr),
                      ),
                      icon: _busy
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.open_in_new_rounded, size: 18),
                      label: Text(
                        hasAccount && !fullyActive
                            ? 'Onboarding fortsetzen'
                            : fullyActive
                                ? 'Stripe-Dashboard öffnen'
                                : 'Onboarding starten',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (hasAccount)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _refresh,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('Status aktualisieren'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.text,
                          side: const BorderSide(color: AppColors.accentBorder),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: AppRadius.smBr),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Plattform-Gebühr: 3 % pro Ticket. 97 % gehen direkt an dich. Stripe-Gebühren (~1,5 % + 0,25 €) gehen ebenfalls von deinem Anteil ab.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),

                    // ── DEBUG-ONLY: Test-Bypass ─────────────────────────────
                    if (kDebugMode) ...[
                      const SizedBox(height: 28),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.purple.withAlpha(30),
                          borderRadius: AppRadius.smBr,
                          border: Border.all(
                              color: Colors.purple.withAlpha(110),
                              width: 1.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.science_rounded,
                                    color: Colors.purple, size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'Debug-Modus',
                                  style: TextStyle(
                                    color: Colors.purple,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isDevBypass
                                  ? 'Test-Bypass ist aktiv. Du kannst Tickets in der UI aktivieren, aber echte Käufe schlagen fehl.'
                                  : 'Stripe-Onboarding überspringen, um die UI zu testen. Käufe funktionieren damit nicht echt.',
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ElevatedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _devBypass(!isDevBypass),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDevBypass
                                    ? AppColors.muted
                                    : Colors.purple,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: AppRadius.smBr),
                              ),
                              icon: Icon(
                                isDevBypass
                                    ? Icons.toggle_off_outlined
                                    : Icons.bolt_rounded,
                                size: 16,
                              ),
                              label: Text(
                                isDevBypass
                                    ? 'Bypass deaktivieren'
                                    : 'Test-Bypass aktivieren',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.ok});
  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            size: 18,
            color: ok ? AppColors.success : AppColors.muted,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: ok ? AppColors.text : AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
