import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'friends_model.dart';
import '../Theme/app_theme.dart';
import '../l10n/lang.dart';
import '../Screens/profile/chat_detail_screen.dart';

class FriendsScreen extends StatefulWidget {
  final String currentUsername;

  const FriendsScreen({
    super.key,
    required this.currentUsername,
  });

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final FriendsModel _model = FriendsModel();

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  final Map<String, _FriendVM> _friendVmCache = {};
  Set<String> _blockedIds = <String>{};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _blockedSub;
  final Map<String, bool> _blockedByOtherCache = {};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chatSub;
  Map<String, Timestamp?> _chatLastTs = {};
  Map<String, int> _chatUnread = {};

  String get _me => widget.currentUsername.trim();

  void _dismissKeyboard() => FocusManager.instance.primaryFocus?.unfocus();

  void _openChat(BuildContext context, String other) {
    final s = [_me, other]..sort();
    final chatId = '${s[0]}__${s[1]}';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(
          chatId: chatId,
          currentUsername: _me,
          otherUsername: other,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _model.loadMyDocId(widget.currentUsername.trim()).then((_) {
      if (mounted) setState(() {});
    });
    _bindBlocked();
    _bindChats();
  }

  @override
  void dispose() {
    _chatSub?.cancel();
    _blockedSub?.cancel();
    _debounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _bindChats() {
    _chatSub?.cancel();
    final me = _me;
    if (me.isEmpty) return;
    _chatSub = FirebaseFirestore.instance
        .collection('chats')
        .where('members', arrayContains: me)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final tsMap = <String, Timestamp?>{};
      final unreadMap = <String, int>{};
      for (final doc in snap.docs) {
        final d = doc.data();
        final members = List<String>.from(d['members'] ?? []);
        final other = members.firstWhere((m) => m != me, orElse: () => '');
        if (other.isNotEmpty) {
          tsMap[other] = d['lastTs'] as Timestamp?;
          unreadMap[other] = ((d['unread_$me'] ?? 0) as num).toInt();
        }
      }
      setState(() {
        _chatLastTs = tsMap;
        _chatUnread = unreadMap;
      });
    });
  }

  void _bindBlocked() {
    _blockedSub?.cancel();
    final me = _me;
    if (me.isEmpty) return;
    _blockedSub = FirebaseFirestore.instance
        .collection('users')
        .doc(me)
        .collection('blocked')
        .snapshots()
        .listen((qs) {
      if (!mounted) return;
      setState(() {
        _blockedIds = qs.docs.map((d) => d.id).toSet();
        _blockedByOtherCache.clear();
      });
    });
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  Stream<List<String>>? _searchStream() {
    if (_query.isEmpty) return null;
    return _model.users
        .orderBy('username_lower')
        .startAt([_query])
        .endAt(['$_query\uf8ff'])
        .limit(20)
        .snapshots()
        .map((qs) => qs.docs
            .map((d) => (d.data()['username'] ?? '').toString())
            .where((u) =>
                u.isNotEmpty &&
                u.toLowerCase() != widget.currentUsername.trim().toLowerCase())
            .toList());
  }

  void _showSnack(String msg, {Color color = const Color(0xFF3AA0FF), IconData icon = Icons.info_rounded}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: color,
      content: Row(children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(child: Text(msg)),
      ]),
    ));
  }

  Future<({String docId, String username})?> _resolveTarget(String input) async {
    final n = input.trim();
    if (n.isEmpty) return null;
    final nLower = n.toLowerCase();
    try {
      final qs = await _model.users.where('username_lower', isEqualTo: nLower).limit(1).get();
      if (qs.docs.isNotEmpty) {
        final d = qs.docs.first;
        final uname = (d.data()['username'] ?? '').toString();
        if (uname.isNotEmpty) return (docId: d.id, username: uname);
      }
      final qs2 = await _model.users.where('username', isEqualTo: n).limit(1).get();
      if (qs2.docs.isNotEmpty) {
        final d = qs2.docs.first;
        final uname = (d.data()['username'] ?? '').toString();
        if (uname.isNotEmpty) return (docId: d.id, username: uname);
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _isBlockedByOther(String otherUsername) async {
    final me = _me;
    final other = otherUsername.trim();
    if (me.isEmpty || other.isEmpty) return false;
    final key = other.toLowerCase();
    final cached = _blockedByOtherCache[key];
    if (cached != null) return cached;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(other).collection('blocked').doc(me).get();
      return _blockedByOtherCache[key] = snap.exists;
    } catch (_) {
      return _blockedByOtherCache[key] = false;
    }
  }

  Future<void> _sendFriendRequest(String targetRaw) async {
    final me = widget.currentUsername.trim();
    if (me.isEmpty) {
      _showSnack(Lang.t('friends_no_user'), color: AppColors.accent, icon: Icons.error);
      return;
    }
    final target = await _resolveTarget(targetRaw);
    if (target == null) {
      _showSnack(Lang.t('friends_not_found'), color: const Color(0xFFFFB020), icon: Icons.warning_amber_rounded);
      return;
    }
    if (target.username.toLowerCase() == me.toLowerCase()) {
      _showSnack(Lang.t('friends_self_add'), color: const Color(0xFFFFB020), icon: Icons.warning_amber);
      return;
    }
    if (_blockedIds.contains(target.username)) {
      _showSnack(Lang.t('friends_you_blocked'), color: const Color(0xFFFFB020), icon: Icons.block);
      return;
    }
    if (await _isBlockedByOther(target.username)) {
      _showSnack(Lang.t('friends_they_blocked'), color: const Color(0xFFFFB020), icon: Icons.block);
      return;
    }
    if (await _model.areFriends(me, target.username)) {
      _showSnack(Lang.t('friends_already_friends'), color: const Color(0xFFFFB020), icon: Icons.check_circle_outline);
      return;
    }
    final ex = await _model.requestStatus(me, target.username) ??
        await _model.requestStatus(target.username, me);
    if (ex == 'pending') {
      _showSnack(Lang.t('friends_request_exists'), color: const Color(0xFFFFB020), icon: Icons.hourglass_top_rounded);
      return;
    }
    final err = await _model.sendRequest(me: me, target: target.username, targetDoc: target.docId);
    if (err == null) {
      _showSnack(Lang.t('friends_request_sent'), color: AppColors.success, icon: Icons.check_circle_rounded);
      _searchCtrl.clear();
      if (mounted) setState(() => _query = '');
      _dismissKeyboard();
    } else {
      _showSnack('Fehler: $err', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _accept(String fromUsername, String toUsername) async {
    if (_blockedIds.contains(fromUsername)) {
      _showSnack(Lang.t('friends_you_blocked'), color: const Color(0xFFFFB020), icon: Icons.block);
      return;
    }
    if (await _isBlockedByOther(fromUsername)) {
      _showSnack(Lang.t('friends_they_blocked'), color: const Color(0xFFFFB020), icon: Icons.block);
      return;
    }
    final err = await _model.accept(fromUsername, toUsername);
    if (err == null) {
      _showSnack(Lang.t('friends_accepted'), color: AppColors.success, icon: Icons.check_circle);
    } else {
      _showSnack('Fehler: $err', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _decline(String fromUsername, String toUsername) async {
    final err = await _model.decline(fromUsername, toUsername);
    if (err == null) {
      _showSnack(Lang.t('friends_declined'), color: const Color(0xFFFFB020), icon: Icons.cancel_outlined);
    } else {
      _showSnack('Fehler: $err', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _confirmAndUnfriend(String otherUsername) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Lang.t('friends_confirm_remove_title')),
        content: Text('"$otherUsername" ${Lang.t('friends_confirm_remove_body')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Lang.t('cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Lang.t('friends_remove')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = await _model.removeFriend(_me, otherUsername);
    if (err == null) {
      _showSnack(Lang.t('friends_removed'), color: AppColors.success, icon: Icons.check_circle_outline);
    } else {
      _showSnack('Fehler: $err', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _reportUser(String reportedUsername) async {
    final reason = await _pickReasonBottomSheet();
    if (reason == null) return;
    final details = await _optionalDetailsDialog();
    if (!mounted) return;
    try {
      await FirebaseFirestore.instance.collection('reports').add({
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'open',
        'reporterUsername': _me,
        'reportedUsername': reportedUsername,
        'targetType': 'user',
        'targetId': reportedUsername,
        'reason': reason,
        'details': details,
      });
      _showSnack(Lang.t('friends_reported_ok'), color: AppColors.success, icon: Icons.check_circle_rounded);
    } catch (e) {
      _showSnack('Melden fehlgeschlagen: $e', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _blockUser(String otherUsername) async {
    final other = otherUsername.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Lang.t('friends_confirm_block_title')),
        content: Text('"$other" ${Lang.t('friends_confirm_block_body')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(Lang.t('cancel'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(Lang.t('friends_block'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(_me).collection('blocked').doc(other)
          .set({'blockedUsername': other, 'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      _showSnack(Lang.t('friends_blocked_ok'), color: AppColors.success, icon: Icons.check_circle_rounded);
    } catch (e) {
      _showSnack('Fehler: $e', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<void> _unblockUser(String otherUsername) async {
    final other = otherUsername.trim();
    try {
      await FirebaseFirestore.instance
          .collection('users').doc(_me).collection('blocked').doc(other).delete();
      _showSnack(Lang.t('friends_unblocked_ok'), color: AppColors.success, icon: Icons.lock_open_rounded);
    } catch (e) {
      _showSnack('Fehler: $e', color: AppColors.accent, icon: Icons.error_outline);
    }
  }

  Future<String?> _pickReasonBottomSheet() {
    final reasons = [
      Lang.t('report_hate'), Lang.t('report_harassment'), Lang.t('report_nudity'),
      Lang.t('report_violence'), Lang.t('report_spam'), Lang.t('report_other'),
    ];
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: reasons.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => ListTile(
            title: Text(reasons[i]),
            onTap: () => Navigator.of(ctx).pop(reasons[i]),
          ),
        ),
      ),
    );
  }

  Future<String> _optionalDetailsDialog() async {
    final ctrl = TextEditingController();
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(Lang.t('friends_report_details_title')),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: InputDecoration(hintText: Lang.t('friends_report_details_hint')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(''), child: Text(Lang.t('skip'))),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: Text(Lang.t('ok'))),
        ],
      ),
    );
    return (res ?? '').trim();
  }

  Widget _userMenu({required String username, required bool isBlockedByMe}) {
    return PopupMenuButton<String>(
      color: AppColors.panelAlt,
      icon: const Icon(Icons.more_vert, color: AppColors.muted, size: 20),
      onSelected: (v) {
        if (v == 'report') _reportUser(username);
        if (v == 'block') _blockUser(username);
        if (v == 'unblock') _unblockUser(username);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'report',
          child: Row(children: [
            const Icon(Icons.flag_outlined, size: 17, color: AppColors.accent),
            const SizedBox(width: 10),
            Text(Lang.t('friends_report'), style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
        PopupMenuItem(
          value: isBlockedByMe ? 'unblock' : 'block',
          child: Row(children: [
            Icon(isBlockedByMe ? Icons.lock_open_rounded : Icons.block, size: 17, color: AppColors.accent),
            const SizedBox(width: 10),
            Text(isBlockedByMe ? Lang.t('friends_unblock') : Lang.t('friends_block'),
                style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
          ]),
        ),
      ],
    );
  }

  String _buildSearchBlob({required String username, required String first, required String last}) {
    final u = username.trim();
    final f = first.trim();
    final l = last.trim();
    final full = ('$f $l').trim();
    return [u, '@$u', f, l, full].where((s) => s.trim().isNotEmpty).join(' ').toLowerCase();
  }

  Future<List<_FriendVM>> _getFriendVMs(List<String> others) async {
    final vms = <_FriendVM>[];
    final missing = <String>[];

    for (final u in others) {
      final key = u.trim();
      if (key.isEmpty) continue;
      final cached = _friendVmCache[key.toLowerCase()];
      if (cached != null) {
        vms.add(cached);
      } else {
        missing.add(key);
      }
    }

    if (missing.isNotEmpty) {
      final fetched = await Future.wait(missing.map((other) async {
        final user = await _model.getUser(username: other) ?? {};
        final first = (user['vorname'] ?? '').toString().trim();
        final last = (user['nachname'] ?? '').toString().trim();
        final full = ('$first $last').trim();
        final vm = _FriendVM(
          username: other,
          displayName: full.isEmpty ? other : full,
          photoUrl: (user['photoUrl'] ?? '').toString().trim(),
          searchBlob: _buildSearchBlob(username: other, first: first, last: last),
        );
        _friendVmCache[other.toLowerCase()] = vm;
        return vm;
      }));
      final map = {for (final x in fetched) x.username.toLowerCase(): x};
      for (final u in missing) {
        final vm = map[u.toLowerCase()];
        if (vm != null) vms.add(vm);
      }
    }

    final order = {for (int i = 0; i < others.length; i++) others[i].toLowerCase(): i};
    vms.sort((a, b) =>
        (order[a.username.toLowerCase()] ?? 0).compareTo(order[b.username.toLowerCase()] ?? 0));
    return vms;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final me = widget.currentUsername.trim();

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _dismissKeyboard,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.bgTop, AppColors.bgBottom],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _buildHeader(me),
                _buildSearchBar(),
                Expanded(child: _buildBody(me)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Header ──────────────────────────────────────────────────────────────────

  Widget _buildHeader(String me) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: AppRadius.fullBr,
                  border: Border.all(color: AppColors.accentBorder2, width: 1),
                ),
                child: Text(
                  Lang.t('friends_header'),
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }

  // ─── Search bar ──────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: AppColors.panelAlt,
          borderRadius: AppRadius.smBr,
          border: Border.all(
            color: _query.isNotEmpty ? AppColors.accentBorder3 : AppColors.accentBorder,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Icon(Icons.search_rounded, color: AppColors.subtle, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: AppColors.text, fontSize: 14),
                decoration: InputDecoration(
                  hintText: Lang.t('friends_search_hint'),
                  hintStyle: const TextStyle(color: AppColors.subtle, fontSize: 14),
                  border: InputBorder.none,
                  isDense: true,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (v) {
                  _dismissKeyboard();
                  if (v.trim().isNotEmpty) _sendFriendRequest(v);
                },
              ),
            ),
            if (_query.isNotEmpty) ...[
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                  _dismissKeyboard();
                },
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(Icons.close_rounded, color: AppColors.subtle, size: 18),
                ),
              ),
            ] else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  // ─── Body ────────────────────────────────────────────────────────────────────

  Widget _buildBody(String me) {
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        // Incoming requests — always shown when non-empty
        _buildRequestsSliver(me),

        _buildFriendsSliver(me),
        if (_query.isNotEmpty) _buildSearchResultsSliver(me),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  // ─── Anfragen ────────────────────────────────────────────────────────────────

  Widget _buildRequestsSliver(String me) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _model.reqs.where('status', isEqualTo: 'pending').snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());

        final myDoc = _model.myDocId;
        final docs = snap.data!.docs.where((d) {
          final m = d.data();
          final toU = (m['to'] ?? m['toUsername'] ?? '').toString().trim();
          final toD = (m['toDocId'] ?? '').toString().trim();
          return toU == me || (myDoc != null && toD == myDoc);
        }).toList();

        // Sort by timestamp desc
        docs.sort((a, b) {
          final at = a.data()['ts'];
          final bt = b.data()['ts'];
          final an = at is Timestamp ? at.toDate() : DateTime(0);
          final bn = bt is Timestamp ? bt.toDate() : DateTime(0);
          return bn.compareTo(an);
        });

        final visible = docs.where((d) {
          final fromU = (d.data()['from'] ?? '').toString();
          return !_blockedIds.contains(fromU);
        }).toList();

        if (visible.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  title: Lang.t('friends_section_requests'),
                  count: visible.length,
                  icon: Icons.person_add_outlined,
                ),
                const SizedBox(height: 8),
                ...visible.asMap().entries.map((entry) {
                  final i = entry.key;
                  final d = entry.value;
                  final m = d.data();
                  final fromU = (m['from'] ?? '').toString();
                  final fromDoc = (m['fromDocId'] ?? '').toString();
                  final toU = (m['to'] ?? '').toString();

                  return Padding(
                    padding: EdgeInsets.only(bottom: i < visible.length - 1 ? 8 : 0),
                    child: FutureBuilder<Map<String, dynamic>?>(
                      future: _model.getUser(
                        docId: fromDoc.isNotEmpty ? fromDoc : null,
                        username: fromU,
                      ),
                      builder: (ctx, uSnap) {
                        final user = uSnap.data ?? {};
                        final first = (user['vorname'] ?? '').toString().trim();
                        final last = (user['nachname'] ?? '').toString().trim();
                        final full = ('$first $last').trim();
                        final name = full.isEmpty ? fromU : full;
                        final photo = (user['photoUrl'] ?? '').toString().trim();

                        return _RequestCard(
                          photoUrl: photo,
                          displayName: name,
                          username: fromU,
                          onAccept: () {
                            _dismissKeyboard();
                            _accept(fromU, toU);
                          },
                          onDecline: () {
                            _dismissKeyboard();
                            _decline(fromU, toU);
                          },
                          menu: _userMenu(username: fromU, isBlockedByMe: _blockedIds.contains(fromU)),
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  // ─── Suchergebnisse ──────────────────────────────────────────────────────────

  Widget _buildSearchResultsSliver(String me) {
    final stream = _searchStream();
    if (stream == null) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: StreamBuilder<List<String>>(
          stream: stream,
          builder: (ctx, snap) {
            if (snap.hasError) {
              return _ErrorHint(err: snap.error.toString());
            }
            if (!snap.hasData) {
              return const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2)),
              );
            }

            final users = snap.data!;
            if (users.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(title: Lang.t('friends_section_results'), icon: Icons.search_rounded),
                  const SizedBox(height: 16),
                  _EmptyHint(text: Lang.t('friends_no_results')),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      onPressed: () => _sendFriendRequest(_searchCtrl.text),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: Text('"${_searchCtrl.text}" ${Lang.t('friends_add_suffix')}'),
                    ),
                  ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(title: Lang.t('friends_section_results'), count: users.length, icon: Icons.search_rounded),
                const SizedBox(height: 8),
                ...users.asMap().entries.map((entry) {
                  final i = entry.key;
                  final uname = users[i];
                  final isBlockedByMe = _blockedIds.contains(uname);

                  return Padding(
                    padding: EdgeInsets.only(bottom: i < users.length - 1 ? 8 : 0),
                    child: FutureBuilder<bool>(
                      future: _isBlockedByOther(uname),
                      builder: (_, bSnap) {
                        final blockedByOther = bSnap.data == true;
                        return FutureBuilder<RelStatus>(
                          future: _model.relationWith(me, uname),
                          builder: (_, rSnap) {
                            final rel = rSnap.data;
                            if (rel == RelStatus.friends) return const SizedBox.shrink();
                            return _SearchUserCard(
                              username: uname,
                              rel: rel,
                              isBlockedByMe: isBlockedByMe,
                              blockedByOther: blockedByOther,
                              onAdd: () {
                                _dismissKeyboard();
                                _sendFriendRequest(uname);
                              },
                              onAccept: () {
                                _dismissKeyboard();
                                _accept(uname, me);
                              },
                              onDecline: () {
                                _dismissKeyboard();
                                _decline(uname, me);
                              },
                              onUnblock: () {
                                _dismissKeyboard();
                                _unblockUser(uname);
                              },
                              menu: _userMenu(username: uname, isBlockedByMe: isBlockedByMe),
                            );
                          },
                        );
                      },
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }

  // ─── Meine Freunde ───────────────────────────────────────────────────────────

  Widget _buildFriendsSliver(String me) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _model.ships.where('members', arrayContains: me).snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: _ErrorHint(err: snap.error.toString()),
            ),
          );
        }

        final docs = snap.data?.docs ?? const [];

        final sorted = [...docs]..sort((a, b) {
            final at = a.data()['since'];
            final bt = b.data()['since'];
            final an = at is Timestamp ? at.toDate() : DateTime(0);
            final bn = bt is Timestamp ? bt.toDate() : DateTime(0);
            return bn.compareTo(an);
          });

        final others = sorted.map((doc) {
          final members = (doc.data()['members'] as List).cast<String>();
          return members.first == me ? members.last : members.first;
        }).where((u) => !_blockedIds.contains(u)).toList();

        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionHeader(
                  title: Lang.t('friends_section_my_friends'),
                  count: others.isEmpty ? null : others.length,
                  icon: Icons.people_outline,
                ),
                const SizedBox(height: 8),
                if (docs.isEmpty)
                  _EmptyHint(text: Lang.t('friends_empty'))
                else
                  FutureBuilder<List<_FriendVM>>(
                    future: _getFriendVMs(others),
                    builder: (ctx2, fSnap) {
                      if (fSnap.hasError) return _ErrorHint(err: fSnap.error.toString());
                      if (!fSnap.hasData) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2)),
                        );
                      }

                      // Filter by current query
                      final all = fSnap.data!;
                      final q = _query;
                      var filtered = q.isEmpty ? all : all.where((vm) => vm.searchBlob.contains(q)).toList();

                      // Sort by chat activity: unread first, then by lastTs desc
                      filtered = filtered.toList()..sort((a, b) {
                        final aU = _chatUnread[a.username] ?? 0;
                        final bU = _chatUnread[b.username] ?? 0;
                        if (aU > 0 && bU == 0) return -1;
                        if (bU > 0 && aU == 0) return 1;
                        final aTs = _chatLastTs[a.username];
                        final bTs = _chatLastTs[b.username];
                        if (aTs != null && bTs != null) return bTs.compareTo(aTs);
                        if (aTs != null) return -1;
                        if (bTs != null) return 1;
                        return 0;
                      });

                      if (filtered.isEmpty) {
                        return _EmptyHint(text: Lang.t('friends_no_match'));
                      }

                      return Column(
                        children: filtered.asMap().entries.map((entry) {
                          final i = entry.key;
                          final vm = filtered[i];
                          return Padding(
                            padding: EdgeInsets.only(bottom: i < filtered.length - 1 ? 8 : 0),
                            child: _FriendCard(
                              photoUrl: vm.photoUrl,
                              displayName: vm.displayName,
                              username: vm.username,
                              unreadChat: _chatUnread[vm.username] ?? 0,
                              onRemove: () => _confirmAndUnfriend(vm.username),
                              onChat: () => _openChat(context, vm.username),
                              menu: _userMenu(username: vm.username, isBlockedByMe: _blockedIds.contains(vm.username)),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final IconData? icon;

  const _SectionHeader({required this.title, this.count, this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, color: AppColors.subtle, size: 14),
          const SizedBox(width: 5),
        ],
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: AppColors.subtle,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.panelAlt,
              borderRadius: AppRadius.fullBr,
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: Text(
              '$count',
              style: const TextStyle(color: AppColors.muted, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Friend Card ──────────────────────────────────────────────────────────────

class _FriendCard extends StatelessWidget {
  final String photoUrl;
  final String displayName;
  final String username;
  final int unreadChat;
  final VoidCallback onRemove;
  final VoidCallback onChat;
  final Widget menu;

  const _FriendCard({
    required this.photoUrl,
    required this.displayName,
    required this.username,
    required this.unreadChat,
    required this.onRemove,
    required this.onChat,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChat,
      borderRadius: AppRadius.mdBr,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: AppRadius.mdBr,
          border: Border.all(
            color: unreadChat > 0 ? AppColors.accentBorder3 : AppColors.accentBorder,
            width: unreadChat > 0 ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Badge(
                isLabelVisible: unreadChat > 0,
                label: Text('$unreadChat'),
                child: _Avatar(photoUrl: photoUrl),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 15)),
                    const SizedBox(height: 2),
                    Text('@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  ],
                ),
              ),
              menu,
              IconButton(
                tooltip: 'Entfernen',
                onPressed: onRemove,
                icon: const Icon(Icons.person_remove_outlined, color: AppColors.muted, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Request Card ─────────────────────────────────────────────────────────────

class _RequestCard extends StatelessWidget {
  final String photoUrl;
  final String displayName;
  final String username;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final Widget menu;

  const _RequestCard({
    required this.photoUrl,
    required this.displayName,
    required this.username,
    required this.onAccept,
    required this.onDecline,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.mdBr,
        border: Border.all(color: AppColors.accentBorder2, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _Avatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text('@$username',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Decline
            GestureDetector(
              onTap: onDecline,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.panelAlt,
                  borderRadius: AppRadius.smBr,
                  border: Border.all(color: AppColors.border),
                ),
                child: const Icon(Icons.close_rounded, color: AppColors.muted, size: 18),
              ),
            ),
            const SizedBox(width: 8),
            // Accept
            GestureDetector(
              onTap: onAccept,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.12),
                  borderRadius: AppRadius.smBr,
                  border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
                ),
                child: Text(Lang.t('friends_accept'),
                    style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 4),
            menu,
          ],
        ),
      ),
    );
  }
}

// ─── Search User Card ─────────────────────────────────────────────────────────

class _SearchUserCard extends StatelessWidget {
  final String username;
  final RelStatus? rel;
  final bool isBlockedByMe;
  final bool blockedByOther;
  final VoidCallback onAdd;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onUnblock;
  final Widget menu;

  const _SearchUserCard({
    required this.username,
    required this.rel,
    required this.isBlockedByMe,
    required this.blockedByOther,
    required this.onAdd,
    required this.onAccept,
    required this.onDecline,
    required this.onUnblock,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    Widget trailing;

    if (isBlockedByMe || blockedByOther) {
      trailing = isBlockedByMe
          ? GestureDetector(
              onTap: onUnblock,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.panelAlt,
                  borderRadius: AppRadius.smBr,
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(Lang.t('friends_unblock'),
                    style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            )
          : const SizedBox.shrink();
    } else if (rel == null) {
      trailing = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
      );
    } else if (rel == RelStatus.outgoingPending) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.panelAlt,
          borderRadius: AppRadius.smBr,
          border: Border.all(color: AppColors.border),
        ),
        child: Text(Lang.t('friends_pending'),
            style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w500, fontSize: 13)),
      );
    } else if (rel == RelStatus.incomingPending) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onDecline,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: AppRadius.smBr,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Icons.close_rounded, color: AppColors.muted, size: 18),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onAccept,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                borderRadius: AppRadius.smBr,
                border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
              ),
              child: Text(Lang.t('friends_accept'),
                  style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
        ],
      );
    } else {
      trailing = GestureDetector(
        onTap: onAdd,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.1),
            borderRadius: AppRadius.smBr,
            border: Border.all(color: AppColors.accentBorder2),
          ),
          child: Text(Lang.t('friends_add'),
              style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      );
    }

    return Opacity(
      opacity: (isBlockedByMe || blockedByOther) ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: AppRadius.mdBr,
          border: Border.all(
            color: (isBlockedByMe || blockedByOther) ? AppColors.border : AppColors.accentBorder,
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.person_outline, color: AppColors.muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              const SizedBox(width: 8),
              trailing,
              const SizedBox(width: 4),
              menu,
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String? photoUrl;
  const _Avatar({this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final url = (photoUrl ?? '').trim();
    const radius = 22.0;
    if (url.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(url));
    }
    return const CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.panelAlt,
      child: Icon(Icons.person, color: AppColors.muted, size: 22),
    );
  }
}

// ─── Empty / Error hints ──────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(text,
          style: const TextStyle(color: AppColors.subtle, fontSize: 14),
          textAlign: TextAlign.center),
    );
  }
}

class _ErrorHint extends StatelessWidget {
  final String err;
  const _ErrorHint({required this.err});

  @override
  Widget build(BuildContext context) {
    return Text('Fehler: $err', style: const TextStyle(color: AppColors.accent));
  }
}

// ─── ViewModel ───────────────────────────────────────────────────────────────

class _FriendVM {
  final String username;
  final String displayName;
  final String photoUrl;
  final String searchBlob;

  const _FriendVM({
    required this.username,
    required this.displayName,
    required this.photoUrl,
    required this.searchBlob,
  });
}
