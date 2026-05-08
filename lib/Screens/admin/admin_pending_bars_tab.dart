// lib/Screens/admin/admin_pending_bars_tab.dart
//
// Listet alle `bars` mit `status: "pending"` und bietet Approve / Reject /
// Delete in einem Tap. Manuell reloadbar — kein App-Restart, keine
// Navigation, keine Crashes wenn Firestore mal scheitert.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import '../bar/AdminCreatesBarScreen.dart';

class AdminPendingBarsTab extends StatefulWidget {
  const AdminPendingBarsTab({super.key});

  @override
  State<AdminPendingBarsTab> createState() => _AdminPendingBarsTabState();
}

class _AdminPendingBarsTabState extends State<AdminPendingBarsTab> {
  CollectionReference<Map<String, dynamic>> get _bars =>
      FirebaseFirestore.instance.collection('bars');

  late Future<QuerySnapshot<Map<String, dynamic>>> _future;
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _fetch() {
    return _bars
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .get();
  }

  /// Manueller Reload. Setzt das Future neu — der FutureBuilder
  /// re-evaluiert sich, ohne dass der Tab neu aufgebaut oder neu
  /// navigiert werden muss. Wirft die `_fetch()` einen Fehler (Index
  /// fehlt, kein Netz, Rules verweigern), zeigt der catch-Block die
  /// SnackBar — kein Crash, kein roter Screen.
  Future<void> _reload() async {
    if (_reloading) return;
    setState(() {
      _reloading = true;
      _future = _fetch();
    });
    try {
      await _future;
    } catch (_) {
      if (!mounted) return;
      _snack('Anfragen konnten nicht neu geladen werden.');
    } finally {
      if (mounted) setState(() => _reloading = false);
    }
  }

  void _snack(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppColors.success : AppColors.accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
    ));
  }

  Future<void> _approve(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(
      title: 'Bar freischalten?',
      body: 'Die Bar wird ab sofort auf der Karte sichtbar und kann sich '
          'einloggen.',
      confirmLabel: 'Freischalten',
      confirmColor: AppColors.success,
    );
    if (!ok) return;
    try {
      await doc.reference.update({
        'status': 'approved',
        'approvedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _reload();
    } catch (e) {
      _snack('Freischalten fehlgeschlagen: $e');
    }
  }

  Future<void> _reject(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(
      title: 'Anfrage ablehnen?',
      body: 'Der Account bleibt im Status "rejected". Die Bar kann sich '
          'nicht einloggen.',
      confirmLabel: 'Ablehnen',
      confirmColor: AppColors.accent,
    );
    if (!ok) return;
    try {
      await doc.reference.update({
        'status': 'rejected',
        'rejectedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await _reload();
    } catch (e) {
      _snack('Ablehnen fehlgeschlagen: $e');
    }
  }

  Future<void> _delete(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final ok = await _confirm(
      title: 'Anfrage löschen?',
      body: 'Komplett aus Firestore entfernen. Kann nicht rückgängig gemacht '
          'werden.',
      confirmLabel: 'Löschen',
      confirmColor: AppColors.accent,
    );
    if (!ok) return;
    try {
      await doc.reference.delete();
      await _reload();
    } catch (e) {
      _snack('Löschen fehlgeschlagen: $e');
    }
  }

  Future<bool> _confirm({
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
              IconButton(
                onPressed: _reloading ? null : _reload,
                tooltip: 'Neu laden',
                color: AppColors.muted,
                icon: _reloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                // Sichtbarer Fehlerstate, damit eine leere Liste nicht
                // als „keine Anfragen" missverstanden wird. Zusätzlich
                // hat der initState-Fehler keine Reload-Trigger-Chance
                // — dieser Button ist die einzige Recovery-Option ohne
                // App-Restart.
                return _ErrorState(
                  onRetry: _reloading ? null : _reload,
                );
              }
              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return _emptyState();
              }
              return RefreshIndicator(
                onRefresh: _reload,
                color: AppColors.accent,
                backgroundColor: AppColors.panel,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _PendingBarCard(
                    doc: docs[i],
                    onApprove: () => _approve(docs[i]),
                    onReject: () => _reject(docs[i]),
                    onDelete: () => _delete(docs[i]),
                  ),
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({this.onRetry});
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded,
                size: 40, color: AppColors.muted),
            const SizedBox(height: 8),
            const Text(
              'Anfragen konnten nicht geladen werden.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Erneut versuchen'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.accentBorder),
                shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
              ),
            ),
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
