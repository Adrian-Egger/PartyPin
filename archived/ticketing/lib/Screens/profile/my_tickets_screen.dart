// lib/Screens/profile/my_tickets_screen.dart
// Liste aller bezahlten Tickets des eingeloggten Users + QR-Detail.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../Theme/app_theme.dart';

class MyTicketsScreen extends StatelessWidget {
  const MyTicketsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        title: const Text('Meine Tickets'),
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
        child: uid == null
            ? const _Empty(text: 'Bitte einloggen.')
            : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('tickets')
                    .where('buyerUid', isEqualTo: uid)
                    .where('status', isEqualTo: 'paid')
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final docs = snap.data?.docs ?? [];
                  if (docs.isEmpty) {
                    return const _Empty(text: 'Du hast noch keine Tickets gekauft.');
                  }
                  // Client-side sort (vermeidet Composite-Index-Pflicht)
                  docs.sort((a, b) {
                    final ta = a.data()['createdAt'];
                    final tb = b.data()['createdAt'];
                    if (ta is Timestamp && tb is Timestamp) {
                      return tb.compareTo(ta);
                    }
                    return 0;
                  });
                  return ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: docs.length,
                    itemBuilder: (context, i) => _TicketCard(doc: docs[i]),
                  );
                },
              ),
      ),
    );
  }
}

class _TicketCard extends StatelessWidget {
  const _TicketCard({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  String _formatEur(int cents) =>
      '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final partyName = (d['partyName'] ?? 'Party').toString();
    final qty = (d['quantity'] as num?)?.toInt() ?? 1;
    final total = (d['totalAmountCents'] as num?)?.toInt() ?? 0;
    final partyTime = (d['partyTime'] ?? '').toString();

    DateTime? date;
    final pd = d['partyDate'];
    if (pd is Timestamp) date = pd.toDate();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.accent.withAlpha(25),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.confirmation_number_rounded,
              color: AppColors.accent),
        ),
        title: Text(
          partyName,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${date != null ? "${date.day}.${date.month}.${date.year}" : ""}'
            '${partyTime.isNotEmpty ? "  ·  $partyTime" : ""}'
            '\n$qty × · ${_formatEur(total)}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
        trailing: const Icon(Icons.qr_code_2_rounded, color: AppColors.accent),
        onTap: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.grey[900],
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => _TicketQrSheet(ticket: d, ticketId: doc.id),
          );
        },
      ),
    );
  }
}

class _TicketQrSheet extends StatelessWidget {
  const _TicketQrSheet({required this.ticket, required this.ticketId});
  final Map<String, dynamic> ticket;
  final String ticketId;

  String _formatEur(int cents) =>
      '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';

  @override
  Widget build(BuildContext context) {
    final qty = (ticket['quantity'] as num?)?.toInt() ?? 1;
    final total = (ticket['totalAmountCents'] as num?)?.toInt() ?? 0;
    final partyName = (ticket['partyName'] ?? 'Party').toString();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.accentBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              partyName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '$qty Ticket${qty == 1 ? "" : "s"} · ${_formatEur(total)}',
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
                data: ticketId,
                version: QrVersions.auto,
                size: 260,
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
            const Text(
              'Zeige diesen QR-Code beim Einlass.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              style: const TextStyle(color: AppColors.muted),
              textAlign: TextAlign.center),
        ),
      );
}
