// lib/Screens/party/ticket_purchase_section.dart
// Wird vom PartyBottomSheet eingebunden, sobald die Party Tickets verkauft.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as fs;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Services/stripe_service.dart';
import '../../Theme/app_theme.dart';

class TicketPurchaseSection extends StatefulWidget {
  const TicketPurchaseSection({
    super.key,
    required this.partyId,
    required this.partyData,
  });

  final String partyId;
  final Map<String, dynamic> partyData;

  @override
  State<TicketPurchaseSection> createState() => _TicketPurchaseSectionState();
}

class _TicketPurchaseSectionState extends State<TicketPurchaseSection> {
  int _quantity = 1;
  bool _busy = false;
  String? _error;

  int get _priceCents =>
      (widget.partyData['ticketPriceCents'] as num?)?.toInt() ?? 0;
  int get _ticketsAvailable =>
      (widget.partyData['ticketsAvailable'] as num?)?.toInt() ?? 0;
  int get _ticketsSold =>
      (widget.partyData['ticketsSold'] as num?)?.toInt() ?? 0;

  String _formatEur(int cents) =>
      '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';

  /// Holt den Status der E-Mail des Käufers:
  ///   - email          : verifizierte Adresse (oder leer)
  ///   - pendingEmail   : angefragte, noch nicht bestätigte Adresse
  ///   - docId          : Firestore-Doc-ID des Users (für Verifikations-Call)
  Future<_BuyerEmailStatus> _resolveBuyerEmailStatus() async {
    // 1) Firebase-Auth-Mail (z. B. Google/Apple Sign-In) gilt als verifiziert.
    final authEmail = FirebaseAuth.instance.currentUser?.email;
    if (authEmail != null && authEmail.isNotEmpty) {
      return _BuyerEmailStatus(email: authEmail);
    }

    final prefs = await SharedPreferences.getInstance();
    final docId = _userDocIdFromPrefs(prefs);

    String email = '';
    String pendingEmail = '';

    if (docId != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(docId)
            .get();
        final data = snap.data();
        email = (data?['email'] as String?)?.trim() ?? '';
        pendingEmail = (data?['pendingEmail'] as String?)?.trim() ?? '';
      } catch (_) {}
    }

    // Fallback: Cache aus Prefs (entspricht früherem Verhalten).
    if (email.isEmpty) {
      final cached = prefs.getString('userEmail') ?? '';
      if (cached.isNotEmpty) email = cached;
    }

    if (email.isNotEmpty) {
      await prefs.setString('userEmail', email);
    }

    return _BuyerEmailStatus(
      email: email,
      pendingEmail: pendingEmail,
      docId: docId,
    );
  }

  String? _userDocIdFromPrefs(SharedPreferences prefs) {
    final vorname = (prefs.getString('vorname') ?? '').trim();
    final nachname = (prefs.getString('nachname') ?? '').trim();
    final id = '$vorname $nachname'.trim();
    return id.isEmpty ? null : id;
  }

  /// Fragt eine neue E-Mail ab und löst direkt den Verifikations-Flow aus.
  /// Liefert true, wenn die Bestätigungs-Mail rausging (Kauf wird trotzdem
  /// abgebrochen — der User muss erst den Link klicken).
  Future<bool> _promptAndRequestVerification(String docId) async {
    final controller = TextEditingController();
    String? errorText;
    bool sending = false;

    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: AppColors.panel,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
            title: Row(
              children: const [
                Icon(Icons.mark_email_read_outlined,
                    color: AppColors.accent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Deine E-Mail für den QR-Code:',
                    style: TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Wir senden dir einen Bestätigungslink. Erst nach dem '
                  'Klick wird die Mail aktiv und für den QR-Code-Versand '
                  'verwendet.',
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  enabled: !sending,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(color: AppColors.text),
                  decoration: InputDecoration(
                    hintText: 'deine@email.com',
                    hintStyle: const TextStyle(color: AppColors.muted),
                    errorText: errorText,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: AppRadius.smBr,
                      borderSide:
                          const BorderSide(color: AppColors.accentBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: AppRadius.smBr,
                      borderSide: const BorderSide(color: AppColors.accent),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen',
                    style: TextStyle(color: AppColors.muted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                ),
                onPressed: sending
                    ? null
                    : () async {
                        final email = controller.text.trim().toLowerCase();
                        if (email.isEmpty ||
                            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                .hasMatch(email)) {
                          setLocal(() =>
                              errorText = 'Bitte gültige E-Mail eingeben');
                          return;
                        }
                        setLocal(() {
                          sending = true;
                          errorText = null;
                        });
                        try {
                          await StripeService.requestEmailVerification(
                            docId: docId,
                            email: email,
                          );
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } on FirebaseFunctionsException catch (e) {
                          setLocal(() {
                            sending = false;
                            errorText = e.message == 'invalid_email_format'
                                ? 'Ungültiges E-Mail-Format'
                                : (e.message ?? e.code);
                          });
                        } catch (e) {
                          setLocal(() {
                            sending = false;
                            errorText = e.toString();
                          });
                        }
                      },
                child: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Bestätigung senden',
                        style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        );
      },
    );

    return sent == true;
  }

  Future<void> _buy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await _resolveBuyerEmailStatus();

      // Fall 1: Es gibt noch keine verifizierte Mail.
      if (status.email.isEmpty) {
        // 1a) Es liegt bereits eine pending Mail vor → Warnung anzeigen.
        if (status.pendingEmail.isNotEmpty) {
          setState(() => _error =
              'Bitte zuerst E-Mail bestätigen — Bestätigungslink wurde an '
              '${status.pendingEmail} verschickt.');
          return;
        }

        // 1b) Noch keine Mail überhaupt — Eingabe abfragen + Verifikation
        // anfordern. Kauf wird abgebrochen, der User muss erst den Link
        // klicken und es dann erneut versuchen.
        if (status.docId == null) {
          setState(() => _error =
              'Profil konnte nicht ermittelt werden. Bitte einmal aus- und '
              'wieder einloggen.');
          return;
        }
        final sent = await _promptAndRequestVerification(status.docId!);
        if (sent && mounted) {
          setState(() => _error =
              'Bestätigungs-E-Mail verschickt. Klicke den Link in der Mail '
              'und starte den Kauf danach erneut.');
        }
        return;
      }

      // Fall 2: Verifizierte Mail vorhanden → Kauf läuft normal weiter.
      // (pendingEmail wird ignoriert, alte Mail bleibt aktiv.)
      final ticketId = await StripeService.purchaseTickets(
        partyId: widget.partyId,
        quantity: _quantity,
        buyerEmail: status.email,
      );

      if (!mounted) return;
      _showPaidSheet(ticketId);
    } on fs.StripeException catch (e) {
      // User Cancel ist kein Fehler
      if (e.error.code == fs.FailureCode.Canceled) return;
      setState(() => _error = e.error.localizedMessage ?? e.error.code.name);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPaidSheet(String ticketId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PaidTicketView(ticketId: ticketId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final price = _priceCents;
    if (price <= 0) return const SizedBox.shrink();

    final soldOut = _ticketsAvailable > 0 && _ticketsSold >= _ticketsAvailable;
    final maxByAvail = _ticketsAvailable > 0
        ? (_ticketsAvailable - _ticketsSold).clamp(0, 20)
        : 20;
    final canIncrease = _quantity < maxByAvail;
    final canDecrease = _quantity > 1;
    final total = price * _quantity;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.confirmation_number_outlined,
                  color: AppColors.accent, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Tickets',
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Preis pro Ticket',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
              Text(
                _formatEur(price),
                style: const TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Anzahl',
                  style: TextStyle(color: AppColors.muted, fontSize: 13)),
              Row(
                children: [
                  IconButton.outlined(
                    onPressed: canDecrease && !_busy
                        ? () => setState(() => _quantity--)
                        : null,
                    icon: const Icon(Icons.remove, size: 18),
                    style: IconButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.accentBorder),
                      minimumSize: const Size(40, 40),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '$_quantity',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    onPressed: canIncrease && !_busy
                        ? () => setState(() => _quantity++)
                        : null,
                    icon: const Icon(Icons.add, size: 18),
                    style: IconButton.styleFrom(
                      foregroundColor: AppColors.text,
                      side: const BorderSide(color: AppColors.accentBorder),
                      minimumSize: const Size(40, 40),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.accent.withAlpha(20),
              borderRadius: AppRadius.smBr,
              border: Border.all(color: AppColors.accent.withAlpha(60)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Gesamt',
                    style: TextStyle(
                      color: AppColors.text,
                      fontWeight: FontWeight.w700,
                    )),
                Text(
                  _formatEur(total),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center),
          ],
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
              elevation: 0,
            ),
            onPressed: (soldOut || _busy) ? null : _buy,
            icon: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.lock_outline, size: 16),
            label: Text(
              soldOut ? 'Ausverkauft' : 'Ticket kaufen',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Sichere Zahlung über Stripe · Karte, Apple Pay, Google Pay',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _BuyerEmailStatus {
  const _BuyerEmailStatus({
    required this.email,
    this.pendingEmail = '',
    this.docId,
  });

  final String email;
  final String pendingEmail;
  final String? docId;
}

class _PaidTicketView extends StatelessWidget {
  const _PaidTicketView({required this.ticketId});
  final String ticketId;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, controller) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('tickets')
            .doc(ticketId)
            .snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data();
          final status = (data?['status'] ?? 'pending').toString();
          final qrPayload = ticketId; // identisch zur Backend-Generierung

          return SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.accentBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                Icon(
                  status == 'paid' ? Icons.check_circle : Icons.timer_outlined,
                  size: 56,
                  color: status == 'paid' ? AppColors.success : AppColors.accent,
                ),
                const SizedBox(height: 12),
                Text(
                  status == 'paid'
                      ? 'Bezahlung erfolgreich!'
                      : 'Bezahlung wird verarbeitet…',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  status == 'paid'
                      ? 'Dein Ticket wurde an deine E-Mail gesendet.'
                      : 'Wir warten auf die Bestätigung von Stripe…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: QrImageView(
                    data: qrPayload,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Ticket-ID: ${ticketId.substring(0, 8).toUpperCase()}…',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: AppRadius.smBr),
                    ),
                    child: const Text('Schließen',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
