// lib/Screens/admin/admin_pending_bars_tab.dart
//
// Listet alle `bars` mit `status: "pending"` und bietet Approve/Reject in
// einem Tap. Zusätzlich gibt es einen Migrations-Button, der Legacy-Docs
// aus dem alten `barAnfragen`-Collection in `bars` mit Status `pending`
// überträgt — einmalig auszuführen, falls Altdaten vorhanden sind.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import '../bar/AdminCreatesBarScreen.dart';

class AdminPendingBarsTab extends StatelessWidget {
  const AdminPendingBarsTab({super.key});

  CollectionReference<Map<String, dynamic>> get _bars =>
      FirebaseFirestore.instance.collection('bars');
  CollectionReference<Map<String, dynamic>> get _legacyRequests =>
      FirebaseFirestore.instance.collection('barAnfragen');

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream() => _bars
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt', descending: true)
      .snapshots();

  Future<void> _approve(BuildContext context,
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(context,
        title: 'Bar freischalten?',
        body: 'Die Bar wird ab sofort auf der Karte sichtbar und kann sich '
            'einloggen.',
        confirmLabel: 'Freischalten',
        confirmColor: AppColors.success);
    if (!ok) return;
    await doc.reference.update({
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _reject(BuildContext context,
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(context,
        title: 'Anfrage ablehnen?',
        body:
            'Der Account bleibt im Status "rejected". Die Bar kann sich nicht einloggen.',
        confirmLabel: 'Ablehnen',
        confirmColor: AppColors.accent);
    if (!ok) return;
    await doc.reference.update({
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _delete(BuildContext context,
      QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(context,
        title: 'Anfrage löschen?',
        body: 'Komplett aus Firestore entfernen. Kann nicht rückgängig gemacht werden.',
        confirmLabel: 'Löschen',
        confirmColor: AppColors.accent);
    if (!ok) return;
    await doc.reference.delete();
  }

  Future<void> _migrateLegacy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _confirm(context,
        title: 'Legacy-Anfragen migrieren?',
        body: 'Übernimmt alle Docs aus `barAnfragen` ins `bars`-Collection '
            'mit Status "pending". Vorhandene Bars werden NICHT überschrieben.',
        confirmLabel: 'Migrieren',
        confirmColor: AppColors.accent);
    if (!ok) return;

    int migrated = 0;
    int skipped = 0;
    try {
      final snap = await _legacyRequests.get();
      for (final d in snap.docs) {
        final data = d.data();
        final username = (data['username'] ?? '').toString().trim();
        if (username.isEmpty) {
          skipped++;
          continue;
        }
        final target = _bars.doc(username);
        final exists = await target.get();
        if (exists.exists) {
          skipped++;
          continue;
        }
        await target.set({
          'barId': username,
          'barName': data['barName'] ?? data['barname'] ?? 'Bar',
          'barName_lower':
              (data['barName'] ?? data['barname'] ?? 'bar').toString().toLowerCase(),
          'username': username,
          'username_lower': username.toLowerCase(),
          'email': data['email'] ?? '',
          'phoneNumber': data['phoneNumber'] ?? '',
          'description': data['description'] ?? '',
          'address': '',
          'city': '',
          'country': 'Austria',
          if (data['requestedPassword'] != null)
            'requestedPassword': data['requestedPassword'],
          'status': 'pending',
          'createdViaSelfRegistration': true,
          'migratedFromLegacy': true,
          'createdAt': data['createdAt'] ?? FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        migrated++;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Fehler: $e')));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('Migration: $migrated übernommen, $skipped übersprungen.'),
      backgroundColor: AppColors.success,
    ));
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String confirmLabel,
    required Color confirmColor,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.panel,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBr),
            title: Text(title,
                style: const TextStyle(
                    color: AppColors.text, fontWeight: FontWeight.w700)),
            content: Text(body,
                style: const TextStyle(color: AppColors.muted, height: 1.4)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Abbrechen',
                    style: TextStyle(color: AppColors.muted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: confirmColor),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Bar-Anfragen mit Status „pending". Tap öffnet den vollen Editor.',
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ),
              TextButton.icon(
                onPressed: () => _migrateLegacy(context),
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: const Text('Legacy übernehmen',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4)),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _stream(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Fehler: ${snap.error}',
                        style: const TextStyle(color: AppColors.accent)),
                  ),
                );
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return _emptyState();
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) =>
                    _PendingBarCard(
                      doc: docs[i],
                      onApprove: () => _approve(context, docs[i]),
                      onReject: () => _reject(context, docs[i]),
                      onDelete: () => _delete(context, docs[i]),
                    ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined,
                size: 48, color: AppColors.muted.withOpacity(0.5)),
            const SizedBox(height: 12),
            const Text('Keine offenen Anfragen',
                style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Sobald sich eine Bar registriert, taucht sie hier auf.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _PendingBarCard extends StatelessWidget {
  const _PendingBarCard({
    required this.doc,
    required this.onApprove,
    required this.onReject,
    required this.onDelete,
  });

  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onDelete;

  String _formatTs(dynamic v) {
    if (v is Timestamp) {
      final dt = v.toDate().toLocal();
      return '${dt.day.toString().padLeft(2, '0')}.'
          '${dt.month.toString().padLeft(2, '0')}.${dt.year} · '
          '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final name = (data['barName'] ?? 'Unbenannt').toString();
    final email = (data['email'] ?? '').toString();
    final city = (data['city'] ?? '').toString();
    final address = (data['address'] ?? '').toString();
    final phone = (data['phoneNumber'] ?? '').toString();
    final created = _formatTs(data['createdAt']);
    final logo = (data['profileImageUrl'] ?? '').toString().trim();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.mdBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadius.mdBr,
          onTap: () {
            // Voller Editor: bestehende AdminCreatesBarScreen, lädt die Bar
            // bei Eingabe der barId. Der Admin kann dort die kompletten
            // Felder pflegen und am Ende über das vorhandene Status-Dropdown
            // approven.
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminCreateBarScreen(),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.panelAlt,
                    borderRadius: BorderRadius.circular(10),
                    image: logo.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(logo), fit: BoxFit.cover)
                        : null,
                  ),
                  child: logo.isEmpty
                      ? const Icon(Icons.local_bar_rounded,
                          color: AppColors.muted)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              color: AppColors.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      if (address.isNotEmpty || city.isNotEmpty)
                        Text(
                          [address, city]
                              .where((s) => s.isNotEmpty)
                              .join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12),
                        ),
                      if (email.isNotEmpty)
                        Text(email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.subtle, fontSize: 12)),
                      if (phone.isNotEmpty)
                        Text(phone,
                            style: const TextStyle(
                                color: AppColors.subtle, fontSize: 12)),
                      if (created.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('eingereicht: $created',
                              style: const TextStyle(
                                  color: AppColors.subtle,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic)),
                        ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _ActionChip(
                            label: 'Freischalten',
                            icon: Icons.check_rounded,
                            color: AppColors.success,
                            onTap: onApprove,
                          ),
                          _ActionChip(
                            label: 'Ablehnen',
                            icon: Icons.block_rounded,
                            color: AppColors.accent,
                            onTap: onReject,
                          ),
                          _ActionChip(
                            label: 'Löschen',
                            icon: Icons.delete_outline_rounded,
                            color: AppColors.muted,
                            onTap: onDelete,
                            outlined: true,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.outlined = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: outlined ? Colors.transparent : color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: outlined ? color.withOpacity(0.5) : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}
