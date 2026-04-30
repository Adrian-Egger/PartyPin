import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../../Theme/app_theme.dart';
import '../../Social/friends_model.dart';
import 'chat_detail_screen.dart';

class UserProfileScreen extends StatefulWidget {
  final String username;
  final String? myUsername;
  final String? initialAvatarUrl;
  final String? initialBio;
  final String? displayName;

  const UserProfileScreen({
    super.key,
    required this.username,
    this.myUsername,
    this.initialAvatarUrl,
    this.initialBio,
    this.displayName,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;

  RelStatus? _rel;
  bool _relLoading = true;
  bool _actioning = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    if (widget.myUsername != null && widget.myUsername != widget.username) {
      _loadRel();
    } else {
      _relLoading = false;
    }
  }

  Future<void> _loadProfile() async {
    final name  = widget.username.trim();
    final lower = name.toLowerCase();
    // Run the two most likely queries in parallel first
    try {
      final results = await Future.wait([
        FirebaseFirestore.instance.collection('users').where('username_lower', isEqualTo: lower).limit(1).get(),
        FirebaseFirestore.instance.collection('users').where('username', isEqualTo: name).limit(1).get(),
      ], eagerError: false);
      for (final q in results) {
        if (q.docs.isNotEmpty) {
          if (mounted) setState(() { _data = q.docs.first.data(); _loading = false; });
          return;
        }
      }
    } catch (_) {}
    // Fallback: bars collection + lowercase username variant
    for (final query in [
      FirebaseFirestore.instance.collection('bars').where('username_lower', isEqualTo: lower).limit(1),
      FirebaseFirestore.instance.collection('bars').where('username', isEqualTo: name).limit(1),
      FirebaseFirestore.instance.collection('users').where('username', isEqualTo: lower).limit(1),
    ]) {
      try {
        final q = await query.get();
        if (q.docs.isNotEmpty) {
          if (mounted) setState(() { _data = q.docs.first.data(); _loading = false; });
          return;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadRel() async {
    try {
      final m = FriendsModel();
      try { await m.loadMyDocId(widget.myUsername!); } catch (_) {}
      final s = await m.relationWith(widget.myUsername!, widget.username.trim());
      if (mounted) setState(() { _rel = s; _relLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _relLoading = false);
    }
  }

  Future<void> _sendRequest() async {
    setState(() => _actioning = true);
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('sendFriendRequest',
              options: HttpsCallableOptions(timeout: const Duration(seconds: 15)));
      final result = await fn.call({'to': widget.username});
      final status = (result.data as Map?)?['status'] as String? ?? '';
      if (!mounted) return;
      if (status == 'sent' || status == 'already_sent') {
        setState(() => _rel = RelStatus.outgoingPending);
      } else if (status == 'already_friends') {
        setState(() => _rel = RelStatus.friends);
      }
    } catch (_) {}
    if (mounted) setState(() => _actioning = false);
  }

  void _openAvatar(String url) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, __, ___) => _FullscreenAvatar(url: url),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  void _openChat() {
    final me = widget.myUsername!;
    final parts = [me, widget.username]..sort();
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ChatDetailScreen(
        chatId: '${parts[0]}__${parts[1]}',
        currentUsername: me,
        otherUsername: widget.username,
      ),
    ));
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF5C6BC0), Color(0xFF7B52AB), Color(0xFF00897B),
      Color(0xFF1565C0), Color(0xFF6D4C41), Color(0xFF2E7D32),
      Color(0xFF37474F), Color(0xFF6A1B9A),
    ];
    if (name.isEmpty) return AppColors.panelAlt;
    return colors[name.codeUnitAt(0) % colors.length];
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final avatarUrl = (_data?['avatarUrl'] ?? widget.initialAvatarUrl ?? '').toString().trim();
    final bio       = (_data?['bio']       ?? widget.initialBio       ?? '').toString().trim();
    final createdAt = _data?['createdAt'] as Timestamp?;
    final isBar     = (_data?['accountType'] ?? '').toString().toLowerCase().contains('bar');
    final isSelf    = widget.myUsername == widget.username.trim();

    final vorname   = (_data?['vorname'] ?? '').toString().trim();
    final nachname  = (_data?['nachname'] ?? '').toString().trim();
    final realName  = [vorname, nachname].where((s) => s.isNotEmpty).join(' ').trim();
    final displayName = realName.isNotEmpty ? realName : (widget.displayName ?? '');

    String? memberSince;
    if (createdAt != null) {
      final dt = createdAt.toDate();
      memberSince = '${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    }

    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.fullBr,
            border: Border.all(color: AppColors.accentBorder2),
          ),
          child: const Text(
            'Profil',
            style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: -0.2),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [

                  // ── Avatar ─────────────────────────────────────────────
                  GestureDetector(
                    onTap: avatarUrl.isNotEmpty ? () => _openAvatar(avatarUrl) : null,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [AppColors.accent, Color(0xFF7B2FF7)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: CircleAvatar(
                            radius: 54,
                            backgroundColor: AppColors.panelAlt,
                            // Avatar 108 px breit → Decode auf 256 px reicht für Retina,
                            // spart aber den Decode eines 1080+ px Originals.
                            backgroundImage: avatarUrl.isNotEmpty
                                ? ResizeImage(
                                    CachedNetworkImageProvider(avatarUrl),
                                    width: 256,
                                  )
                                : null,
                            child: avatarUrl.isEmpty
                                ? Text(
                                    widget.username.isNotEmpty ? widget.username[0].toUpperCase() : '?',
                                    style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w700),
                                  )
                                : null,
                          ),
                        ),
                        if (avatarUrl.isNotEmpty)
                          Positioned(
                            bottom: 2, right: 2,
                            child: Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(
                                color: AppColors.panel,
                                shape: BoxShape.circle,
                                border: Border.all(color: AppColors.border),
                              ),
                              child: const Icon(Icons.zoom_in_rounded, color: AppColors.muted, size: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Name + username + bar badge ───────────────────────
                  if (displayName.isNotEmpty) ...[
                    Text(
                      displayName,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 2),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          '@${widget.username}',
                          style: TextStyle(
                            color: displayName.isNotEmpty ? AppColors.subtle : AppColors.text,
                            fontSize: displayName.isNotEmpty ? 13 : 22,
                            fontWeight: displayName.isNotEmpty ? FontWeight.w400 : FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      if (isBar) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.teal.withAlpha(25),
                            borderRadius: AppRadius.fullBr,
                            border: Border.all(color: AppColors.teal.withAlpha(70)),
                          ),
                          child: const Text('Bar', style: TextStyle(color: AppColors.teal, fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ],
                  ),

                  // ── Info cards ────────────────────────────────────────
                  const SizedBox(height: 20),
                  _infoCard(
                    icon: Icons.person_outline_rounded,
                    label: 'Bio',
                    value: bio.isNotEmpty ? bio : 'Keine Bio angegeben.',
                    muted: bio.isEmpty,
                  ),
                  if (memberSince != null) ...[
                    const SizedBox(height: 10),
                    _infoCard(
                      icon: Icons.calendar_today_rounded,
                      label: 'Dabei seit',
                      value: memberSince!,
                    ),
                  ],
                  const SizedBox(height: 10),
                  _infoCard(
                    icon: isBar ? Icons.local_bar_rounded : Icons.person_rounded,
                    label: 'Account-Typ',
                    value: isBar ? 'Bar-Account' : 'Nutzer',
                  ),

                  const SizedBox(height: 28),
                  const Divider(color: AppColors.border),
                  const SizedBox(height: 24),

                  // ── Actions ───────────────────────────────────────────
                  if (!isSelf && widget.myUsername != null)
                    _buildActions(),

                ],
              ),
            ),
    );
  }

  Widget _buildActions() {
    if (_relLoading) {
      return const SizedBox(
        height: 46,
        child: Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2)),
      );
    }

    final isFriends  = _rel == RelStatus.friends;
    final isPending  = _rel == RelStatus.outgoingPending;
    final isIncoming = _rel == RelStatus.incomingPending;

    if (isFriends) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusRow(
            icon: Icons.check_circle_rounded,
            color: AppColors.success,
            label: 'Befreundet',
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                elevation: 0,
              ),
              onPressed: _openChat,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 17),
              label: const Text('Nachricht schreiben', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      );
    }

    if (isPending) {
      return _statusRow(
        icon: Icons.hourglass_top_rounded,
        color: Colors.orangeAccent,
        label: 'Anfrage gesendet',
      );
    }

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
          elevation: 0,
        ),
        onPressed: _actioning ? null : _sendRequest,
        icon: _actioning
            ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Icon(isIncoming ? Icons.person_add_rounded : Icons.person_add_outlined, size: 17),
        label: Text(
          isIncoming ? 'Ebenfalls hinzufügen' : 'Hinzufügen',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
    );
  }

  static Widget _statusRow({required IconData icon, required Color color, required String label}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: AppRadius.smBr,
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 14)),
          ],
        ),
      );

  static Widget _infoCard({
    required IconData icon,
    required String label,
    required String value,
    bool muted = false,
  }) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: AppRadius.smBr,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.subtle, size: 15),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                  const SizedBox(height: 3),
                  Text(value, style: TextStyle(color: muted ? AppColors.subtle : AppColors.text, fontSize: 14, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      );
}

// ── Fullscreen avatar ──────────────────────────────────────────────────────────

class _FullscreenAvatar extends StatefulWidget {
  final String url;
  const _FullscreenAvatar({required this.url});

  @override
  State<_FullscreenAvatar> createState() => _FullscreenAvatarState();
}

class _FullscreenAvatarState extends State<_FullscreenAvatar> {
  double _dy = 0;
  double get _opacity => (1.0 - (_dy.abs() / 300)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        onVerticalDragUpdate: (d) => setState(() => _dy += d.delta.dy),
        onVerticalDragEnd: (d) {
          if (_dy.abs() > 100 || (d.primaryVelocity ?? 0).abs() > 500) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dy = 0);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          color: Colors.black.withOpacity(_opacity),
          child: Transform.translate(
            offset: Offset(0, _dy),
            child: Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: CachedNetworkImage(
                  imageUrl: widget.url,
                  fit: BoxFit.contain,
                  errorWidget: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: Colors.white38, size: 60),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
