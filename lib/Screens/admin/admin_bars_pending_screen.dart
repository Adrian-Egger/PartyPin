// lib/Screens/admin/admin_bars_pending_screen.dart
//
// Operational Readiness Sprint (2026-05-17):
// Minimaler Admin-Screen für Bar-Freischaltungen. Ersetzt das manuelle
// "in der Firebase Console status auf 'approved' setzen".
//
// Schreibpfade gehen ausschließlich über die CFs adminApproveBar /
// adminRejectBar — die Rules erlauben dem Client kein Status-Edit.
//
// Sichtbarkeit:
//   Der Screen ist nur erreichbar wenn der eingeloggte User das
//   Custom-Claim `admin: true` hat. Der Menu-Eintrag ist sonst
//   gar nicht da (siehe menu_screen.dart-Integration).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';

class AdminBarsPendingScreen extends StatefulWidget {
  const AdminBarsPendingScreen({super.key});

  @override
  State<AdminBarsPendingScreen> createState() =>
      _AdminBarsPendingScreenState();
}

class _AdminBarsPendingScreenState extends State<AdminBarsPendingScreen> {
  bool _checkingAdmin = true;
  bool _isAdmin = false;
  String? _adminError;

  @override
  void initState() {
    super.initState();
    _verifyAdmin();
  }

  /// Defense in depth: auch wenn der Menu-Eintrag versehentlich gezeigt
  /// wird, hier nochmal Custom-Claim prüfen. Falls nicht admin: Screen
  /// zeigt Fehler statt der Liste.
  Future<void> _verifyAdmin() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) setState(() {
          _checkingAdmin = false;
          _isAdmin = false;
          _adminError = 'Nicht eingeloggt.';
        });
        return;
      }
      final token = await user.getIdTokenResult(true);
      final isAdmin = token.claims?['admin'] == true;
      if (mounted) setState(() {
        _checkingAdmin = false;
        _isAdmin = isAdmin;
        if (!isAdmin) _adminError = 'Kein Admin-Zugriff.';
      });
    } catch (e) {
      if (mounted) setState(() {
        _checkingAdmin = false;
        _isAdmin = false;
        _adminError = 'Auth-Check fehlgeschlagen.';
      });
    }
  }

  Future<void> _approve(String barId) async {
    if (!await _confirm(
      title: 'Bar freischalten?',
      msg: 'Diese Bar wird nach Approve für alle User sichtbar.',
      okLabel: 'Freischalten',
      okColor: AppColors.success,
    )) {
      return;
    }
    await _callCf('adminApproveBar', {'uid': barId}, 'Freigeschaltet.');
  }

  Future<void> _reject(String barId) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Bar ablehnen?',
            style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Optional kannst du einen kurzen Grund angeben (max. 500 Zeichen). '
              'Bar wird auf rejected gesetzt und ist nicht sichtbar.',
              style: TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLength: 500,
              maxLines: 3,
              style: const TextStyle(color: AppColors.text),
              decoration: InputDecoration(
                hintText: 'Grund (optional)',
                hintStyle: const TextStyle(color: AppColors.muted),
                filled: true,
                fillColor: AppColors.bgTop,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Ablehnen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _callCf(
      'adminRejectBar',
      {'uid': barId, 'reason': reasonCtrl.text.trim()},
      'Abgelehnt.',
    );
  }

  Future<bool> _confirm({
    required String title,
    required String msg,
    required String okLabel,
    required Color okColor,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(title,
            style: const TextStyle(
                color: AppColors.text, fontWeight: FontWeight.w800)),
        content: Text(msg, style: const TextStyle(color: AppColors.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: okColor,
              foregroundColor: Colors.white,
            ),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<void> _callCf(
      String name, Map<String, dynamic> data, String successMsg) async {
    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable(name)
          .call(data);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(successMsg),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Fehler: ${e.message ?? e.code}'),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Fehler: $e'),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        title: const Text('Pending Bars',
            style: TextStyle(color: AppColors.text)),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      body: _checkingAdmin
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : !_isAdmin
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _adminError ?? 'Kein Zugriff.',
                      style: const TextStyle(color: AppColors.muted),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('bars')
                      .where('status', isEqualTo: 'pending')
                      .orderBy('createdAt', descending: true)
                      .limit(100)
                      .snapshots(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: AppColors.accent),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Fehler: ${snap.error}\n\n'
                            'Falls "requires an index": Firestore-Index '
                            'auf bars (status ASC, createdAt DESC) im '
                            'Console-Link in den Fehler-Logs anlegen.',
                            style: const TextStyle(color: AppColors.muted),
                          ),
                        ),
                      );
                    }
                    final docs = snap.data?.docs ?? const [];
                    if (docs.isEmpty) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Keine pending Bars. Aufgeräumt.',
                            style: TextStyle(color: AppColors.muted),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final d = docs[i].data();
                        return _PendingBarTile(
                          barId: docs[i].id,
                          data: d,
                          onApprove: () => _approve(docs[i].id),
                          onReject: () => _reject(docs[i].id),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class _PendingBarTile extends StatelessWidget {
  const _PendingBarTile({
    required this.barId,
    required this.data,
    required this.onApprove,
    required this.onReject,
  });

  final String barId;
  final Map<String, dynamic> data;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  String? get _logoUrl {
    final s = (data['profileImageUrl'] ?? '').toString().trim();
    return s.isEmpty ? null : s;
  }

  String _fmtDate(dynamic v) {
    if (v is Timestamp) {
      final dt = v.toDate();
      return '${dt.day.toString().padLeft(2, '0')}.'
          '${dt.month.toString().padLeft(2, '0')}.${dt.year} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final barName = (data['barName'] ?? '').toString();
    final username = (data['username'] ?? '').toString();
    final city = (data['city'] ?? '').toString();
    final email = (data['email'] ?? '').toString();
    final createdAt = _fmtDate(data['createdAt']);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.bgTop,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accentBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: _logoUrl != null
                    ? CachedNetworkImage(
                        imageUrl: _logoUrl!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const Icon(
                            Icons.local_bar_rounded,
                            color: AppColors.muted),
                      )
                    : const Icon(Icons.local_bar_rounded,
                        color: AppColors.muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      barName.isEmpty ? '(kein Name)' : barName,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@$username · $city',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (email.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          email,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (createdAt.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          createdAt,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 10.5),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: BorderSide(color: AppColors.accent.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
