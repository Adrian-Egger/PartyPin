import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'friends_model.dart';

// ✅ NEU: BottomNav Targets
import '../Screens/party_map_screen.dart';
import '../Screens/feedback_screen.dart';
import '../Screens/new_party.dart';

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
  // ✅ Farbschema: wie PartyMapScreen
  static const _bgTop = Color(0xFF0E0F12);
  static const _bgBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF1C1F26);
  static const _text = Colors.white;
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);

  // ✅ wie Feedback: clean rot im Header
  static const _accentSoft = Color(0x26FF3B30); // ~15% rot
  static const _accentLine = Color(0x66FF3B30); // ~40% rot

  // passend dazu
  static const _border = Color(0xFF2A2F3A);
  static const _ok = Color(0xFF2ECC71);
  static const _warn = Color(0xFFFFB020);
  static const _err = Color(0xFFFF3B30);
  static const _info = Color(0xFF3AA0FF);

  final FriendsModel _model = FriendsModel();

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  final TextEditingController _friendsFilterCtrl = TextEditingController();
  String _friendsFilter = '';
  Timer? _friendsDebounce;

  // ✅ Cache: damit „Freunde durchsuchen“ auch nach Vorname/Nachname/Voller Name/Username geht
  final Map<String, _FriendVM> _friendVmCache = {};

  // ✅ NEU: BottomNav Index (0=Feedback, 1=Map, 2=Freunde, 3=Neue Party)
  int _currentIndex = 2;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _friendsFilterCtrl.addListener(_onFriendsFilterChanged);
    _model.loadMyDocId(widget.currentUsername.trim()).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _friendsDebounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _friendsFilterCtrl.removeListener(_onFriendsFilterChanged);
    _searchCtrl.dispose();
    _friendsFilterCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  void _onFriendsFilterChanged() {
    _friendsDebounce?.cancel();
    _friendsDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _friendsFilter = _friendsFilterCtrl.text.trim().toLowerCase());
    });
  }

  Stream<List<String>>? _searchStream() {
    if (_query.isEmpty) return null;
    return _model.users
        .orderBy('username_lower')
        .startAt([_query])
        .endAt(['${_query}\uf8ff'])
        .limit(20)
        .snapshots()
        .map((qs) => qs.docs
        .map((d) {
      final data = d.data();
      return (data['username'] ?? '').toString();
    })
        .where((uname) =>
    uname.isNotEmpty &&
        uname.toLowerCase() != widget.currentUsername.trim().toLowerCase())
        .toList());
  }

  void _showSnack(
      String msg, {
        Color color = _info,
        IconData icon = Icons.info_rounded,
      }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: color,
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
      ),
    );
  }

  Future<({String docId, String username})?> _resolveTarget(String input) async {
    final n = input.trim();
    if (n.isEmpty) return null;
    final nLower = n.toLowerCase();
    try {
      final qsLower =
      await _model.users.where('username_lower', isEqualTo: nLower).limit(1).get();
      if (qsLower.docs.isNotEmpty) {
        final d = qsLower.docs.first;
        final data = d.data();
        final uname = (data['username'] ?? '').toString();
        if (uname.isNotEmpty) return (docId: d.id, username: uname);
      }
      final qs = await _model.users.where('username', isEqualTo: n).limit(1).get();
      if (qs.docs.isNotEmpty) {
        final d = qs.docs.first;
        final data = d.data();
        final uname = (data['username'] ?? '').toString();
        if (uname.isNotEmpty) return (docId: d.id, username: uname);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _sendFriendRequest(String targetRaw) async {
    final me = widget.currentUsername.trim();
    if (me.isEmpty) {
      _showSnack('Kein aktueller Benutzer.', color: _err, icon: Icons.error);
      return;
    }
    final target = await _resolveTarget(targetRaw);
    if (target == null) {
      _showSnack('User nicht gefunden', color: _warn, icon: Icons.warning_amber_rounded);
      return;
    }
    final toDoc = target.docId;
    final toUsername = target.username;

    if (toUsername.toLowerCase() == me.toLowerCase()) {
      _showSnack('Du kannst dich nicht selbst adden.',
          color: _warn, icon: Icons.warning_amber);
      return;
    }
    if (await _model.areFriends(me, toUsername)) {
      _showSnack('Ihr seid bereits Freunde.',
          color: _warn, icon: Icons.check_circle_outline);
      return;
    }
    final ex =
        await _model.requestStatus(me, toUsername) ?? await _model.requestStatus(toUsername, me);
    if (ex != null) {
      if (ex == 'pending') {
        _showSnack('Anfrage existiert bereits.',
            color: _warn, icon: Icons.hourglass_top_rounded);
      } else {
        _showSnack('Anfrage ist $ex.', color: _info, icon: Icons.info_outline);
      }
      return;
    }

    final err = await _model.sendRequest(
      me: me,
      target: toUsername,
      targetDoc: toDoc,
    );

    if (err == null) {
      _showSnack('Anfrage gesendet', color: _ok, icon: Icons.check_circle_rounded);
      _searchCtrl.clear();
      if (mounted) setState(() => _query = '');
    } else {
      _showSnack('Fehler: $err', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _accept(String fromUsername, String toUsername) async {
    final err = await _model.accept(fromUsername, toUsername);
    if (err == null) {
      _showSnack('Anfrage angenommen', color: _ok, icon: Icons.check_circle);
    } else {
      _showSnack('Fehler: $err', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _decline(String fromUsername, String toUsername) async {
    final err = await _model.decline(fromUsername, toUsername);
    if (err == null) {
      _showSnack('Anfrage abgelehnt', color: _warn, icon: Icons.cancel_outlined);
    } else {
      _showSnack('Fehler: $err', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _confirmAndUnfriend(String otherUsername) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'Freund entfernen',
          style: TextStyle(color: _text, fontWeight: FontWeight.w800),
        ),
        content: Text(
          '„$otherUsername“ wirklich entfernen?',
          style: const TextStyle(color: _muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen', style: TextStyle(color: _muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _err,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final me = widget.currentUsername.trim();
    final err = await _model.removeFriend(me, otherUsername);
    if (err == null) {
      _showSnack('Entfernt', color: _ok, icon: Icons.check_circle_outline);
    } else {
      _showSnack('Fehler: $err', color: _err, icon: Icons.error_outline);
    }
  }

  // ✅ Such-Blob: Username + @username + Vorname + Nachname + voller Name (alles lower)
  String _buildSearchBlob({
    required String username,
    required String first,
    required String last,
  }) {
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
        final user = await _model.getUser(username: other);
        final m = user ?? <String, dynamic>{};

        final first = (m['vorname'] ?? '').toString().trim();
        final last = (m['nachname'] ?? '').toString().trim();
        final full = (first + ' ' + last).trim();
        final name = full.isEmpty ? other : full;

        final photo = (m['photoUrl'] ?? '').toString().trim();
        final blob = _buildSearchBlob(username: other, first: first, last: last);

        final vm = _FriendVM(
          username: other,
          displayName: name,
          photoUrl: photo,
          searchBlob: blob,
        );

        _friendVmCache[other.toLowerCase()] = vm;
        return vm;
      }));

      // Reihenfolge wie `others` behalten:
      final map = {for (final x in fetched) x.username.toLowerCase(): x};
      for (final u in missing) {
        final vm = map[u.toLowerCase()];
        if (vm != null) vms.add(vm);
      }
    }

    // vms ist jetzt nicht zwingend exakt in others-Reihenfolge, daher sauber sortieren:
    final order = <String, int>{};
    for (int i = 0; i < others.length; i++) {
      order[others[i].toLowerCase()] = i;
    }
    vms.sort((a, b) =>
        (order[a.username.toLowerCase()] ?? 0).compareTo(order[b.username.toLowerCase()] ?? 0));

    return vms;
  }

  // ✅ NEU: BottomNav Navigation
  Future<void> _onBottomNavTapped(int index) async {
    if (index == _currentIndex) return;

    setState(() => _currentIndex = index);

    if (index == 2) return;

    if (index == 1) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
      );
      return;
    }

    if (index == 0) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const FeedbackScreen()),
      );
      return;
    }

    if (index == 3) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const NewPartyScreen()),
      );
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.currentUsername.trim();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgTop, _bgBottom],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ✅ Header: wie Feedback (Chip + Emojis + rot umrandet) + ✅ Zurückbutton entfernt
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: Row(
                  children: [
                    const SizedBox(width: 48), // Platzhalter statt Back-Button
                    Expanded(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _accentSoft,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: _accentLine, width: 1),
                          ),
                          child: const Text(
                            "👥 Freunde 🔥",
                            style: TextStyle(
                              color: _text,
                              fontWeight: FontWeight.w900,
                              fontSize: 24,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _model.reqs.where('status', isEqualTo: 'pending').snapshots(),
                      builder: (ctx, snap) {
                        int count = 0;
                        if (snap.hasData) {
                          final all = snap.data!.docs;
                          count = all.where((d) {
                            final m = d.data();
                            final toU = (m['to'] ?? m['toUsername'] ?? '').toString().trim();
                            final toD = (m['toDocId'] ?? '').toString().trim();
                            return toU == me ||
                                (_model.myDocId != null && toD == _model.myDocId);
                          }).length;
                        }
                        final label = count == 0 ? null : (count > 9 ? '9+' : '$count');

                        return Stack(
                          alignment: Alignment.center,
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              tooltip: 'Mich geaddet',
                              icon: const Icon(Icons.person_add, color: _text),
                              onPressed: _openIncomingSheet,
                            ),
                            if (label != null)
                              Positioned(
                                right: 6,
                                top: 10,
                                child: Container(
                                  padding:
                                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: _accent,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.white, width: 1),
                                  ),
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),

              // Search Add
              Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(.45),
                      blurRadius: 16,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search_rounded, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        style: const TextStyle(color: _text),
                        decoration: const InputDecoration(
                          hintText: 'Neue Freunde finden',
                          hintStyle: TextStyle(color: _muted),
                          border: InputBorder.none,
                        ),
                        textInputAction: TextInputAction.search,
                        onSubmitted: _sendFriendRequest,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _sendFriendRequest(_searchCtrl.text),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Add'),
                    ),
                  ],
                ),
              ),

              // Friends Filter
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _border),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.filter_list, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _friendsFilterCtrl,
                        style: const TextStyle(color: _text),
                        decoration: const InputDecoration(
                          hintText: 'Freunde durchsuchen (Name oder Username)',
                          hintStyle: TextStyle(color: _muted),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    if (_friendsFilter.isNotEmpty)
                      IconButton(
                        tooltip: 'Filter löschen',
                        onPressed: () {
                          _friendsFilterCtrl.clear();
                          setState(() => _friendsFilter = '');
                        },
                        icon: const Icon(Icons.close, color: _muted),
                      ),
                  ],
                ),
              ),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: _query.isEmpty
                      ? _buildFriendsList(me, filter: _friendsFilter)
                      : _buildSearchResults(me),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFriendsList(String me, {String filter = ''}) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _model.ships.where('members', arrayContains: me).snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) return _ErrorHint(err: snap.error.toString());

        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const _EmptyHint(text: 'Noch keine Freunde', emoji: '🫤');
        }

        final sorted = [...docs]
          ..sort((a, b) {
            final at = a.data()['since'];
            final bt = b.data()['since'];
            final an = at is Timestamp ? at.toDate() : DateTime(0);
            final bn = bt is Timestamp ? bt.toDate() : DateTime(0);
            return bn.compareTo(an);
          });

        final others = sorted.map((doc) {
          final members = (doc.data()['members'] as List).cast<String>();
          return members.first == me ? members.last : members.first;
        }).toList();

        return FutureBuilder<List<_FriendVM>>(
          future: _getFriendVMs(others),
          builder: (ctx2, fSnap) {
            if (fSnap.hasError) return _ErrorHint(err: fSnap.error.toString());
            if (!fSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final all = fSnap.data!;
            final q = filter.trim().toLowerCase();

            final filtered = q.isEmpty ? all : all.where((vm) => vm.searchBlob.contains(q)).toList();

            if (filtered.isEmpty) {
              return const _EmptyHint(text: 'Kein Freund gefunden', emoji: '😶');
            }

            return ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final vm = filtered[i];
                return _FriendCard(
                  photoUrl: vm.photoUrl,
                  title: vm.displayName,
                  subtitle: '@${vm.username}',
                  onRemove: () => _confirmAndUnfriend(vm.username),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSearchResults(String me) {
    final stream = _searchStream();
    if (stream == null) {
      return const _EmptyHint(text: 'Username eingeben', emoji: '🔍');
    }

    return StreamBuilder<List<String>>(
      stream: stream,
      builder: (ctx, snap) {
        if (snap.hasError) return _ErrorHint(err: snap.error.toString());
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final users = snap.data!;
        if (users.isEmpty) {
          return const _EmptyHint(text: 'Keine User gefunden', emoji: '😶');
        }

        return ListView.separated(
          itemCount: users.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (ctx, i) {
            final uname = users[i];

            return FutureBuilder<RelStatus>(
              future: _model.relationWith(me, uname),
              builder: (ctx2, rSnap) {
                final rel = rSnap.data;

                Widget shell(Widget child) => Card(
                  color: _panel,
                  elevation: 6,
                  shadowColor: Colors.black54,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: _accent.withOpacity(0.22), width: 1),
                  ),
                  child: child,
                );

                final titleText = Text(
                  uname,
                  softWrap: true,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                    height: 1.15,
                  ),
                );

                final subtitleText = Text(
                  '@$uname',
                  softWrap: true,
                  maxLines: null,
                  overflow: TextOverflow.visible,
                  style: const TextStyle(
                    color: _muted,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                );

                if (rel == null) {
                  return shell(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.person, color: _text),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                titleText,
                                const SizedBox(height: 4),
                                subtitleText,
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                if (rel == RelStatus.friends) {
                  return const SizedBox.shrink();
                }

                if (rel == RelStatus.incomingPending) {
                  return shell(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.person, color: _text),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                titleText,
                                const SizedBox(height: 4),
                                subtitleText,
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ElevatedButton(
                                onPressed: () => _accept(uname, me),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _ok,
                                  foregroundColor: Colors.white,
                                  padding:
                                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                ),
                                child: const Text(
                                  'AKZEPTIEREN',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                              const SizedBox(height: 6),
                              IconButton(
                                tooltip: 'Ablehnen',
                                onPressed: () => _decline(uname, me),
                                icon: const Icon(Icons.close_rounded, color: _err, size: 26),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }

                if (rel == RelStatus.outgoingPending) {
                  return shell(
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.person, color: _text),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                titleText,
                                const SizedBox(height: 4),
                                subtitleText,
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'pending',
                            style: TextStyle(
                              color: _muted,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return shell(
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.person, color: _text),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleText,
                              const SizedBox(height: 4),
                              subtitleText,
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(
                          onPressed: () => _sendFriendRequest(uname),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _openIncomingSheet() {
    final me = widget.currentUsername.trim();
    final myDoc = _model.myDocId;
    final stream = _model.reqs.where('status', isEqualTo: 'pending').snapshots();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.35,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Mich geaddet',
                      style: TextStyle(
                        color: _text,
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: stream,
                        builder: (ctx2, s2) {
                          if (s2.hasError) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: _ErrorHint(err: s2.error.toString()),
                            );
                          }

                          final all = s2.data?.docs ?? const [];
                          final docs = all.where((d) {
                            final m = d.data();
                            final toU = (m['to'] ?? m['toUsername'] ?? '').toString().trim();
                            final toD = (m['toDocId'] ?? '').toString().trim();
                            return toU == me || (myDoc != null && toD == myDoc);
                          }).toList();

                          if (docs.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: _EmptyHint(
                                text: 'Niemand hat dich geaddet',
                                emoji: '😶',
                              ),
                            );
                          }

                          docs.sort((a, b) {
                            final at = a.data()['ts'];
                            final bt = b.data()['ts'];
                            final an = at is Timestamp ? at.toDate() : DateTime(0);
                            final bn = bt is Timestamp ? bt.toDate() : DateTime(0);
                            return bn.compareTo(an);
                          });

                          return ListView.separated(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: docs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final m = docs[i].data();
                              final fromU = (m['from'] ?? '').toString();
                              final fromDoc = (m['fromDocId'] ?? '').toString();
                              final toU = (m['to'] ?? '').toString();

                              return FutureBuilder<Map<String, dynamic>?>(
                                future: _model.getUser(
                                  docId: fromDoc.isNotEmpty ? fromDoc : null,
                                  username: fromU,
                                ),
                                builder: (ctx, uSnap) {
                                  final user = uSnap.data ?? {};
                                  final first = (user['vorname'] ?? '').toString().trim();
                                  final last = (user['nachname'] ?? '').toString().trim();
                                  final full = (first + ' ' + last).trim().isEmpty
                                      ? fromU
                                      : ('$first $last').trim();
                                  final photo = (user['photoUrl'] ?? '').toString().trim();

                                  return _RequestCard(
                                    photoUrl: photo,
                                    title: full,
                                    subtitle: 'möchte dich adden',
                                    onAccept: () => _accept(fromU, toU),
                                    onDecline: () => _decline(fromU, toU),
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

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

class _FriendCard extends StatelessWidget {
  final String photoUrl;
  final String title;
  final String subtitle;
  final VoidCallback onRemove;

  const _FriendCard({
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _FriendsScreenState._panel,
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _FriendsScreenState._accent.withOpacity(0.35), // ✅ minimal rot
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    softWrap: true,
                    maxLines: null,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      color: _FriendsScreenState._text,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    softWrap: true,
                    maxLines: null,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      color: _FriendsScreenState._muted,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Entfernen',
              onPressed: onRemove,
              icon: const Icon(Icons.person_remove, color: _FriendsScreenState._accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final String photoUrl;
  final String title;
  final String subtitle;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _RequestCard({
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _FriendsScreenState._panel,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: _FriendsScreenState._accent.withOpacity(0.35), // ✅ minimal rot
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    softWrap: true,
                    maxLines: null,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      color: _FriendsScreenState._text,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    softWrap: true,
                    maxLines: null,
                    overflow: TextOverflow.visible,
                    style: const TextStyle(
                      color: _FriendsScreenState._muted,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: onAccept,
              style: ElevatedButton.styleFrom(
                backgroundColor: _FriendsScreenState._ok,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text(
                'AKZEPTIEREN',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Ablehnen',
              onPressed: onDecline,
              icon: const Icon(Icons.close_rounded,
                  color: _FriendsScreenState._accent, size: 26),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? photoUrl;
  const _Avatar({this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final url = (photoUrl ?? '').trim();
    const radius = 26.0;
    if (url.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(url));
    }
    return const CircleAvatar(
      radius: radius,
      backgroundColor: Color(0xFF2A2F3A),
      child: Icon(Icons.person, color: Colors.white, size: 26),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  final String emoji;
  const _EmptyHint({required this.text, required this.emoji});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      alignment: Alignment.center,
      child: Text(
        '$text $emoji',
        style: const TextStyle(
          color: _FriendsScreenState._muted,
          fontWeight: FontWeight.w800,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _ErrorHint extends StatelessWidget {
  final String err;
  const _ErrorHint({required this.err});

  @override
  Widget build(BuildContext context) {
    return Text(
      'Fehler: $err',
      style: const TextStyle(color: _FriendsScreenState._accent),
    );
  }
}
