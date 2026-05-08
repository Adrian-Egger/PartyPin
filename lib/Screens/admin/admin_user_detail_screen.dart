// lib/Screens/admin/admin_user_detail_screen.dart
//
// Admin-Detail-Screen für genau einen User. Lädt den User-Doc, das
// Stripe-Subcollection-Doc und die letzten Parties parallel via Streams.
// Moderations-Aktionen laufen über Cloud Functions, die hinter dem
// `admin`-Custom-Claim gesichert sind — direkter Firestore-Write
// reicht NICHT, weil "User bannen" auch Firebase Auth disablen muss
// (sonst kann der User mit gecachtem Token weiter API-Calls machen)
// und "User löschen" Firestore + Auth gleichzeitig braucht.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../Services/age_services.dart';
import '../../Services/platform_info.dart';
import '../../Theme/app_theme.dart';

class AdminUserDetailScreen extends StatefulWidget {
  const AdminUserDetailScreen({super.key, required this.uid});
  final String uid;

  @override
  State<AdminUserDetailScreen> createState() => _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  bool _busy = false;
  String? _actionError;

  // ── Streams ─────────────────────────────────────────────────────────

  Stream<DocumentSnapshot<Map<String, dynamic>>> _userStream() =>
      FirebaseFirestore.instance.collection('users').doc(widget.uid).snapshots();

  Stream<DocumentSnapshot<Map<String, dynamic>>> _stripeStream() =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .collection('stripe')
          .doc('account')
          .snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> _partiesStream() =>
      FirebaseFirestore.instance
          .collection('Party')
          .where('hostUid', isEqualTo: widget.uid)
          .orderBy('createdAt', descending: true)
          .limit(10)
          .snapshots();

  // ── Cloud-Function-Calls ────────────────────────────────────────────

  Future<void> _callAdminFunction(
    String name, {
    Map<String, dynamic>? data,
    required String successMsg,
  }) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable(name);
      await fn.call(<String, dynamic>{'uid': widget.uid, ...?data});
      if (!mounted) return;
      _toast(successMsg, ok: true);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final msg = (e.message ?? '').trim();
      setState(() => _actionError = msg.isEmpty
          ? 'Aktion fehlgeschlagen (${e.code})'
          : '$msg (${e.code})');
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = 'Aktion fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? AppColors.success : AppColors.accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
    ));
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBr),
        title: const Text('User löschen?',
            style: TextStyle(
                color: AppColors.text, fontWeight: FontWeight.w800)),
        content: const Text(
          'Löscht den User-Doc + Stripe-Subcollection + Firebase-Auth-Account. '
          'Andere Querverweise (Parties, Reports, ...) bleiben unberührt. '
          'Diese Aktion ist nicht rückgängig machbar.',
          style: TextStyle(color: AppColors.muted, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _callAdminFunction('adminDeleteUser', successMsg: 'User gelöscht.');
      if (mounted && _actionError == null) Navigator.of(context).pop();
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        elevation: 0,
        title: const Text('User-Detail'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          _AccountCard(
            uid: widget.uid,
            stream: _userStream(),
            onCopyUid: () => _copy('uid', widget.uid),
            onCopyEmail: (email) => _copy('Email', email),
          ),
          const SizedBox(height: 12),
          _StripeCard(
            stream: _stripeStream(),
            onOpenDashboard: _openStripeDashboard,
          ),
          const SizedBox(height: 12),
          _PartiesCard(stream: _partiesStream()),
          const SizedBox(height: 12),
          _ModerationCard(
            uid: widget.uid,
            userStream: _userStream(),
            busy: _busy,
            actionError: _actionError,
            onBan: () => _callAdminFunction('adminBanUser',
                successMsg: 'User gebannt.'),
            onUnban: () => _callAdminFunction('adminUnbanUser',
                successMsg: 'Ban entfernt.'),
            onDelete: _confirmDelete,
          ),
        ],
      ),
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _toast('$label kopiert.', ok: true);
  }

  Future<void> _openStripeDashboard(String accountId) async {
    final uri = Uri.parse('https://dashboard.stripe.com/connect/accounts/$accountId');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      _toast('Konnte Stripe-Dashboard nicht öffnen.');
    }
  }
}

// ───────────────────────── Sektions-Cards ──────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.icon, required this.child});
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: AppColors.accent, size: 18),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2)),
          ]),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV({required this.k, required this.v, this.copyAction, this.mono = false});
  final String k;
  final String v;
  final VoidCallback? copyAction;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k,
                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(
              v.isEmpty ? '—' : v,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
          if (copyAction != null && v.isNotEmpty)
            IconButton(
              tooltip: 'Kopieren',
              icon: const Icon(Icons.copy_rounded,
                  color: AppColors.muted, size: 16),
              onPressed: copyAction,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }
}

String _fmtTs(dynamic v) {
  if (v is Timestamp) {
    final d = v.toDate();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  if (v is String && v.isNotEmpty) return v;
  return '';
}

// ── Account-Sektion ───────────────────────────────────────────────────

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.uid,
    required this.stream,
    required this.onCopyUid,
    required this.onCopyEmail,
  });
  final String uid;
  final Stream<DocumentSnapshot<Map<String, dynamic>>> stream;
  final VoidCallback onCopyUid;
  final void Function(String email) onCopyEmail;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Account',
      icon: Icons.person_rounded,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return _ErrorBlock(msg: 'Fehler beim Laden: ${snap.error}');
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          if (!snap.data!.exists) {
            return const Text(
              'User-Doc existiert nicht (mehr).',
              style: TextStyle(color: AppColors.muted),
            );
          }
          final d = snap.data!.data() ?? const <String, dynamic>{};
          final email = (d['email'] ?? '').toString();

          // Defensive Geburtstags-Parse — kaputte Werte werden zu null,
          // keine Exception. Alter wird live aus dem geparsten Datum
          // berechnet, NICHT aus einem evtl. veralteten data['age']-Feld.
          final birthday = AgeService.parseBirthday(d['birthday']);
          final birthdayStr =
              birthday != null ? AgeService.formatBirthdayDDMMYYYY(birthday) : '';
          final ageStr = birthday != null
              ? '${AgeService.calcAge(birthday, DateTime.now())} J.'
              : '';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (d['banned'] == true)
                _Pill(label: 'banned', color: Colors.redAccent),
              if (d['admin'] == true)
                _Pill(label: 'admin', color: AppColors.accent),
              const SizedBox(height: 8),
              _KV(k: 'uid',          v: uid, mono: true, copyAction: onCopyUid),
              _KV(k: 'username',     v: (d['username'] ?? '').toString()),
              _KV(
                k: 'email',
                v: email,
                copyAction: email.isEmpty ? null : () => onCopyEmail(email),
              ),
              _KV(k: 'bio',          v: (d['bio'] ?? '').toString()),
              _KV(k: 'birthday',     v: birthdayStr),
              _KV(k: 'age',          v: ageStr),
              _KV(k: 'created',      v: _fmtTs(d['createdAt'])),
              _KV(k: 'last active',  v: _fmtTs(d['lastActive'] ?? d['lastSeen'])),
              _KV(k: 'platform',     v: PlatformInfo.normalize(
                  d['platform']
                      ?? d['devicePlatform']
                      ?? d['os']
                      ?? d['deviceType']
                      ?? d['device'])),
            ],
          );
        },
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.msg});
  final String msg;

  @override
  Widget build(BuildContext context) {
    return Text(msg,
        style: const TextStyle(color: Colors.redAccent, fontSize: 12));
  }
}

// ── Stripe-Sektion ────────────────────────────────────────────────────

class _StripeCard extends StatelessWidget {
  const _StripeCard({required this.stream, required this.onOpenDashboard});
  final Stream<DocumentSnapshot<Map<String, dynamic>>> stream;
  final void Function(String accountId) onOpenDashboard;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Stripe',
      icon: Icons.payment_rounded,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return _ErrorBlock(msg: 'Fehler beim Laden: ${snap.error}');
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final d = snap.data?.data() ?? const <String, dynamic>{};
          final accountId = (d['stripeAccountId'] ?? '').toString();
          final hasAccount = accountId.isNotEmpty;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KV(k: 'account id',
                  v: hasAccount ? accountId : '—', mono: true),
              _KV(k: 'status',
                  v: (d['stripeOnboardingStatus'] ?? '').toString()),
              _KV(k: 'charges',
                  v: d['stripeChargesEnabled'] == true ? 'enabled' : 'disabled'),
              _KV(k: 'payouts',
                  v: d['stripePayoutsEnabled'] == true ? 'enabled' : 'disabled'),
              if (hasAccount) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => onOpenDashboard(accountId),
                  icon: const Icon(Icons.open_in_new_rounded, size: 14),
                  label: const Text('Stripe-Dashboard öffnen'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.text,
                    side: const BorderSide(color: AppColors.accentBorder),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ── Parties-Sektion ───────────────────────────────────────────────────

class _PartiesCard extends StatelessWidget {
  const _PartiesCard({required this.stream});
  final Stream<QuerySnapshot<Map<String, dynamic>>> stream;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Parties',
      icon: Icons.event_rounded,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snap) {
          if (snap.hasError) {
            return _ErrorBlock(
                msg: 'Fehler beim Laden: ${snap.error}\n'
                    '(Falls FAILED_PRECONDITION: Index für '
                    'Party(hostUid, createdAt DESC) fehlt — siehe '
                    'firestore.indexes.json + firebase deploy --only firestore:indexes.)');
          }
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Text('Keine Parties.',
                style: TextStyle(color: AppColors.muted));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${docs.length} Parties (max 10 angezeigt)',
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 12)),
              ),
              ...docs.map((d) => _PartyRow(doc: d)),
            ],
          );
        },
      ),
    );
  }
}

class _PartyRow extends StatelessWidget {
  const _PartyRow({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final name = (d['name'] ?? '').toString();
    final created = _fmtTs(d['createdAt']);
    final isClosed = d['isClosed'] == true;

    return InkWell(
      onTap: () => _showPartyInfo(context),
      borderRadius: AppRadius.smBr,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.bgTop,
          borderRadius: AppRadius.smBr,
          border: Border.all(color: AppColors.accentBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? doc.id : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('$created  ·  ${doc.id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11)),
                ],
              ),
            ),
            if (isClosed)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.lock_outline,
                    size: 14, color: AppColors.muted),
              ),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppColors.muted),
          ],
        ),
      ),
    );
  }

  void _showPartyInfo(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final d = doc.data();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text((d['name'] ?? '').toString(),
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                _KV(k: 'partyId', v: doc.id, mono: true,
                    copyAction: () async {
                      await Clipboard.setData(ClipboardData(text: doc.id));
                      if (ctx.mounted) Navigator.pop(ctx);
                    }),
                _KV(k: 'created', v: _fmtTs(d['createdAt'])),
                _KV(k: 'date',    v: _fmtTs(d['date'])),
                _KV(k: 'time',    v: (d['time'] ?? '').toString()),
                _KV(k: 'address', v: (d['address'] ?? '').toString()),
                _KV(k: 'visibility', v: (d['visibility'] ?? '').toString()),
                _KV(k: 'tickets',
                    v: d['ticketsEnabled'] == true ? 'aktiv' : 'inaktiv'),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Moderation-Sektion ────────────────────────────────────────────────

class _ModerationCard extends StatelessWidget {
  const _ModerationCard({
    required this.uid,
    required this.userStream,
    required this.busy,
    required this.actionError,
    required this.onBan,
    required this.onUnban,
    required this.onDelete,
  });

  final String uid;
  final Stream<DocumentSnapshot<Map<String, dynamic>>> userStream;
  final bool busy;
  final String? actionError;
  final VoidCallback onBan;
  final VoidCallback onUnban;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Moderation',
      icon: Icons.shield_rounded,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userStream,
        builder: (context, snap) {
          final d = snap.data?.data() ?? const <String, dynamic>{};
          final banned = d['banned'] == true;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (banned)
                ElevatedButton.icon(
                  onPressed: busy ? null : onUnban,
                  icon: const Icon(Icons.lock_open_rounded, size: 16),
                  label: const Text('Ban entfernen'),
                  style: _btnStyle(AppColors.success),
                )
              else
                ElevatedButton.icon(
                  onPressed: busy ? null : onBan,
                  icon: const Icon(Icons.block_rounded, size: 16),
                  label: const Text('User bannen'),
                  style: _btnStyle(AppColors.accent),
                ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_forever_rounded, size: 16),
                label: const Text('User löschen'),
                style: _btnStyle(Colors.redAccent),
              ),
              if (actionError != null) ...[
                const SizedBox(height: 10),
                Text(actionError!,
                    style: const TextStyle(
                        color: Colors.redAccent, fontSize: 12)),
              ],
            ],
          );
        },
      ),
    );
  }

  ButtonStyle _btnStyle(Color color) => ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
      );
}
