// lib/Social/friends.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../Screens/party_map_screen.dart';

class FriendsScreen extends StatefulWidget {
  final String currentUsername; // Username aus SharedPreferences
  final String mapRoute;        // Optional: Named Route der Map
  const FriendsScreen({
    super.key,
    required this.currentUsername,
    this.mapRoute = '/map',
  });

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  // Farben
  static const Color _bg     = Color(0xFF0B1220);
  static const Color _panel  = Color(0xFF111A2E);
  static const Color _border = Color(0xFF2C3B63);
  static const Color _accent = Color(0xFF7C4DFF);

  // Snack-Farben
  static const Color _ok   = Color(0xFF2E7D32);   // grün
  static const Color _warn = Color(0xFFFFA000);   // gelb
  static const Color _err  = Color(0xFFD32F2F);   // rot
  static const Color _info = Color(0xFF1976D2);   // blau

  // Suche
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  // Firestore
  CollectionReference<Map<String, dynamic>> get _users =>
      FirebaseFirestore.instance.collection('users');
  CollectionReference<Map<String, dynamic>> get _reqs =>
      FirebaseFirestore.instance.collection('friendRequests');
  CollectionReference<Map<String, dynamic>> get _ships =>
      FirebaseFirestore.instance.collection('friendships');

  // eigene Doc-ID (kann vom Username abweichen -> jetzt "Vorname Nachname")
  String? _myDocId;

  // kleiner User-Cache (username -> userData)
  final Map<String, Map<String, dynamic>> _userCache = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _resolveMyDocId();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---------- Helpers ----------

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  /// Case-insensitive Suche über username_lower (Feld in users).
  Stream<List<String>>? _searchStream() {
    if (_query.isEmpty) return null;

    return _users
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

  void _showSnack(String msg,
      {Color color = _info, IconData icon = Icons.info_rounded}) {
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

  String _shipId(String a, String b) {
    final s = [a, b]..sort();
    return '${s[0]}__${s[1]}';
  }

  /// eigene Doc-ID aus users holen (über Feld username, NICHT über docId).
  Future<void> _resolveMyDocId() async {
    final me = widget.currentUsername.trim();
    if (me.isEmpty) return;
    try {
      final qs = await _users
          .where('username', isEqualTo: me)
          .limit(1)
          .get();
      if (qs.docs.isNotEmpty) {
        _myDocId = qs.docs.first.id; // das ist jetzt "Vorname Nachname"
      }
    } catch (_) {
      _myDocId = null;
    } finally {
      if (mounted) setState(() {});
    }
  }

  /// Benutzer per docId ODER username holen (mit Cache).
  Future<Map<String, dynamic>?> _getUserData({
    String? docId,
    String? username,
  }) async {
    try {
      if (username != null && _userCache.containsKey(username)) {
        return _userCache[username];
      }

      // 1) docId direkt
      if (docId != null && docId.isNotEmpty) {
        final snap = await _users.doc(docId).get();
        if (snap.exists) {
          final data = snap.data() ?? {};
          final uname = (data['username'] ?? '').toString();
          if (uname.isNotEmpty) _userCache[uname] = data;
          return data;
        }
      }

      // 2) Suche über Feld username
      if (username != null && username.isNotEmpty) {
        final qs = await _users
            .where('username', isEqualTo: username)
            .limit(1)
            .get();
        if (qs.docs.isNotEmpty) {
          final d = qs.docs.first;
          final data = d.data();
          final uname = (data['username'] ?? '').toString();
          if (uname.isNotEmpty) _userCache[uname] = data;
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Ziel-User ermitteln: Eingabe ist der USERNAME (nicht der volle Name).
  /// Rückgabe: docId (Vorname Nachname) + username.
  Future<({String docId, String username})?> _resolveTarget(
      String input) async {
    final n = input.trim();
    if (n.isEmpty) return null;
    final nLower = n.toLowerCase();

    try {
      // 1) exakte Suche über username_lower
      final qsLower = await _users
          .where('username_lower', isEqualTo: nLower)
          .limit(1)
          .get();
      if (qsLower.docs.isNotEmpty) {
        final d = qsLower.docs.first;
        final data = d.data();
        final uname = (data['username'] ?? '').toString();
        if (uname.isNotEmpty) {
          return (docId: d.id, username: uname);
        }
      }

      // 2) Fallback: exakte Suche über username (falls username_lower fehlt)
      final qs = await _users
          .where('username', isEqualTo: n)
          .limit(1)
          .get();
      if (qs.docs.isNotEmpty) {
        final d = qs.docs.first;
        final data = d.data();
        final uname = (data['username'] ?? '').toString();
        if (uname.isNotEmpty) {
          return (docId: d.id, username: uname);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _isAlreadyFriends(String a, String b) async {
    final id = _shipId(a, b);
    final snap = await _ships.doc(id).get();
    return snap.exists;
  }

  Future<String?> _existingRequestStatus(String from, String toUsername) async {
    final id = '${from}__${toUsername}';
    final snap = await _reqs.doc(id).get();
    if (!snap.exists) return null;
    return (snap.data()?['status'] ?? '').toString();
  }

  // ---------- Aktionen ----------

  Future<void> _sendFriendRequest(String targetRaw) async {
    final me = widget.currentUsername.trim();
    if (me.isEmpty) {
      _showSnack('Kein aktueller Benutzer.', color: _err, icon: Icons.error);
      return;
    }

    final target = await _resolveTarget(targetRaw);

    if (target == null) {
      _showSnack('User nicht gefunden',
          color: _warn, icon: Icons.warning_amber_rounded);
      return;
    }
    final toDoc = target.docId;       // "Vorname Nachname"
    final toUsername = target.username; // echter Username

    if (toUsername.toLowerCase() == me.toLowerCase()) {
      _showSnack('Du kannst dich nicht selbst adden.',
          color: _warn, icon: Icons.warning_amber);
      return;
    }
    if (await _isAlreadyFriends(me, toUsername)) {
      _showSnack('Ihr seid bereits Freunde.',
          color: _warn, icon: Icons.check_circle_outline);
      return;
    }

    final ex = await _existingRequestStatus(me, toUsername) ??
        await _existingRequestStatus(toUsername, me);

    if (ex != null) {
      if (ex == 'pending') {
        _showSnack('Anfrage existiert bereits.',
            color: _warn, icon: Icons.hourglass_top_rounded);
      } else {
        _showSnack('Anfrage ist $ex.', color: _info, icon: Icons.info_outline);
      }
      return;
    }

    final rid = '${me}__${toUsername}';
    try {
      await _reqs.doc(rid).set({
        'from': me,         // Username
        'fromDocId': _myDocId, // "Vorname Nachname"
        'to': toUsername,   // Username
        'toDocId': toDoc,   // "Vorname Nachname"
        'status': 'pending',
        'ts': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _showSnack('Anfrage gesendet',
          color: _ok, icon: Icons.check_circle_rounded);
      _searchCtrl.clear();
      if (mounted) setState(() => _query = '');
    } on FirebaseException catch (e) {
      _showSnack('Fehler: ${e.message ?? e.code}',
          color: _err, icon: Icons.error_outline);
    } catch (e) {
      _showSnack('Fehler: $e', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _accept(String fromUsername, String toUsername) async {
    final sid = _shipId(fromUsername, toUsername);
    final rid = '${fromUsername}__${toUsername}';
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        tx.set(_reqs.doc(rid), {
          'status': 'accepted',
          'handledAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        tx.set(_ships.doc(sid), {
          'members': [fromUsername, toUsername], // beide: USERNAME
          'since': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
      _showSnack('Anfrage angenommen', color: _ok, icon: Icons.check_circle);
    } on FirebaseException catch (e) {
      _showSnack('Fehler: ${e.message ?? e.code}',
          color: _err, icon: Icons.error_outline);
    } catch (e) {
      _showSnack('Fehler: $e', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _decline(String fromUsername, String toUsername) async {
    final rid = '${fromUsername}__${toUsername}';
    try {
      await _reqs.doc(rid).set({
        'status': 'declined',
        'handledAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _showSnack('Anfrage abgelehnt',
          color: _warn, icon: Icons.cancel_outlined);
    } on FirebaseException catch (e) {
      _showSnack('Fehler: ${e.message ?? e.code}',
          color: _err, icon: Icons.error_outline);
    } catch (e) {
      _showSnack('Fehler: $e', color: _err, icon: Icons.error_outline);
    }
  }

  Future<void> _confirmAndUnfriend(String otherUsername) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Freund entfernen',
            style:
            TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        content: Text('„$otherUsername“ wirklich entfernen?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _err, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final me = widget.currentUsername.trim();
    final sid = _shipId(me, otherUsername);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        tx.delete(_ships.doc(sid));
        tx.delete(_reqs.doc('${me}__${otherUsername}'));
        tx.delete(_reqs.doc('${otherUsername}__${me}'));
      });
      _showSnack('Entfernt', color: _ok, icon: Icons.check_circle_outline);
    } on FirebaseException catch (e) {
      _showSnack('Fehler: ${e.message ?? e.code}',
          color: _err, icon: Icons.error_outline);
    } catch (e) {
      _showSnack('Fehler: $e', color: _err, icon: Icons.error_outline);
    }
  }

  // ---------- Navigation ----------

  void _backToMap() {
    bool pushed = false;
    try {
      Navigator.of(context)
          .pushNamedAndRemoveUntil(widget.mapRoute, (_) => false);
      pushed = true;
    } catch (_) {}
    if (!pushed) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
            (_) => false,
      );
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final me = widget.currentUsername.trim();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Zurück zur Karte',
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: _backToMap,
        ),
        title: const Text('Freunde',
            style:
            TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        actions: [
          // Badge-Zähler
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _reqs.where('status', isEqualTo: 'pending').snapshots(),
            builder: (ctx, snap) {
              int count = 0;
              if (snap.hasData) {
                final all = snap.data!.docs;
                count = all.where((d) {
                  final m = d.data();
                  final toU =
                  (m['to'] ?? m['toUsername'] ?? '').toString().trim();
                  final toD = (m['toDocId'] ?? '').toString().trim();
                  return toU == me || (_myDocId != null && toD == _myDocId);
                }).length;
              }
              final label = count == 0 ? null : (count > 9 ? '9+' : '$count');
              return Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    tooltip: 'Mich geaddet',
                    icon: const Icon(Icons.person_add, color: Colors.white),
                    onPressed: _openIncomingSheet,
                  ),
                  if (label != null)
                    Positioned(
                      right: 6,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _err,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white, width: 1),
                        ),
                        child: Text(label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          // Suche + Add
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _border),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(.35),
                    blurRadius: 14,
                    offset: const Offset(0, 8))
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.search, color: _accent),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Username suchen',
                      hintStyle: TextStyle(color: Colors.white54),
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

          // Entweder Suche oder Freundesliste
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _query.isEmpty
                  ? _buildFriendsList(me)
                  : _buildSearchResults(),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- UI-Teile ----------

  Widget _buildFriendsList(String me) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _ships.where('members', arrayContains: me).snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return _ErrorHint(err: snap.error.toString());
        }
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const _EmptyHint(text: 'Noch keine Freunde', emoji: '🫤');
        }

        final sorted = [...docs]..sort((a, b) {
          final at = a.data()['since'];
          final bt = b.data()['since'];
          final an = at is Timestamp ? at.toDate() : DateTime(0);
          final bn = bt is Timestamp ? bt.toDate() : DateTime(0);
          return bn.compareTo(an);
        });

        return ListView.separated(
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final d = sorted[i].data();
            final members = (d['members'] as List).cast<String>();
            final other = members.first == me ? members.last : members.first;

            return FutureBuilder<Map<String, dynamic>?>(
              future: _getUserData(username: other),
              builder: (ctx, uSnap) {
                final user = uSnap.data ?? {};
                final first =
                (user['vorname'] ?? '').toString().trim();
                final last =
                (user['nachname'] ?? '').toString().trim();
                final name = (first + ' ' + last).trim().isEmpty
                    ? other
                    : ('$first $last').trim();
                final photo =
                (user['photoUrl'] ?? '').toString().trim();

                return _FriendCard(
                  photoUrl: photo,
                  title: name,
                  subtitle: '@$other',
                  onChat: () => _showSnack(
                      'Chat mit „$other“ öffnen',
                      color: _info,
                      icon: Icons.chat_bubble_outline),
                  onRemove: () => _confirmAndUnfriend(other),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSearchResults() {
    final stream = _searchStream();
    if (stream == null) {
      return const _EmptyHint(text: 'Username eingeben', emoji: '🔍');
    }

    return StreamBuilder<List<String>>(
      stream: stream,
      builder: (ctx, snap) {
        if (snap.hasError) {
          return _ErrorHint(err: snap.error.toString());
        }
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
            return Card(
              color: _panel,
              elevation: 4,
              shadowColor: Colors.black54,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              child: ListTile(
                leading: const Icon(Icons.person, color: Colors.white),
                title: Text(
                  uname,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
                subtitle: Text(
                  '@$uname',
                  style: const TextStyle(
                      color: Colors.white54, fontWeight: FontWeight.w500),
                ),
                trailing: FilledButton.tonalIcon(
                  onPressed: () => _sendFriendRequest(uname),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add'),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ---------- Eingehende Anfragen (Sheet) ----------

  void _openIncomingSheet() {
    final me = widget.currentUsername.trim();
    final myDoc = _myDocId;

    final stream =
    _reqs.where('status', isEqualTo: 'pending').snapshots();

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
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18),
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
                            final toU = (m['to'] ?? m['toUsername'] ?? '')
                                .toString()
                                .trim();
                            final toD =
                            (m['toDocId'] ?? '').toString().trim();
                            return toU == me ||
                                (myDoc != null && toD == myDoc);
                          }).toList();

                          if (docs.isEmpty) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: _EmptyHint(
                                  text: 'Niemand hat dich geaddet',
                                  emoji: '😶'),
                            );
                          }

                          docs.sort((a, b) {
                            final at = a.data()['ts'];
                            final bt = b.data()['ts'];
                            final an =
                            at is Timestamp ? at.toDate() : DateTime(0);
                            final bn =
                            bt is Timestamp ? bt.toDate() : DateTime(0);
                            return bn.compareTo(an);
                          });

                          return ListView.separated(
                            controller: scrollController,
                            padding:
                            const EdgeInsets.symmetric(vertical: 6),
                            itemCount: docs.length,
                            separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final m = docs[i].data();
                              final fromU =
                              (m['from'] ?? '').toString(); // Username
                              final fromDoc =
                              (m['fromDocId'] ?? '').toString(); // fullName
                              final toU = (m['to'] ?? '').toString();

                              return FutureBuilder<Map<String, dynamic>?>(
                                future: _getUserData(
                                  docId: fromDoc.isNotEmpty ? fromDoc : null,
                                  username: fromU,
                                ),
                                builder: (ctx, uSnap) {
                                  final user = uSnap.data ?? {};
                                  final first = (user['vorname'] ?? '')
                                      .toString()
                                      .trim();
                                  final last = (user['nachname'] ?? '')
                                      .toString()
                                      .trim();
                                  final full = (first + ' ' + last)
                                      .trim()
                                      .isEmpty
                                      ? fromU
                                      : ('$first $last').trim();
                                  final photo =
                                  (user['photoUrl'] ?? '')
                                      .toString()
                                      .trim();

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

// ---------- Reusable UI: Clean Cards ----------

class _FriendCard extends StatelessWidget {
  final String photoUrl;
  final String title;
  final String subtitle;
  final VoidCallback onChat;
  final VoidCallback onRemove;

  const _FriendCard({
    required this.photoUrl,
    required this.title,
    required this.subtitle,
    required this.onChat,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _FriendsScreenState._panel,
      elevation: 8,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            _Avatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white60,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: onChat,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Chat',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onRemove,
              style: OutlinedButton.styleFrom(
                foregroundColor: _FriendsScreenState._err,
                side: BorderSide(
                    color: _FriendsScreenState._err.withOpacity(.6)),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.person_remove, size: 18),
              label: const Text('Entfernen',
                  style: TextStyle(fontWeight: FontWeight.w700)),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            _Avatar(photoUrl: photoUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white60,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton(
              onPressed: onAccept,
              style: ElevatedButton.styleFrom(
                backgroundColor: _FriendsScreenState._ok,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('AKZEPTIEREN',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Ablehnen',
              onPressed: onDecline,
              icon: const Icon(Icons.close_rounded,
                  color: _FriendsScreenState._err, size: 26),
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
      backgroundColor: Color(0xFF2C3B63),
      child: Icon(Icons.person, color: Colors.white, size: 26),
    );
  }
}

// ---------- generische Hints/Errors ----------

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
      child: Text('$text $emoji',
          style: const TextStyle(
              color: Colors.white54, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center),
    );
  }
}

class _ErrorHint extends StatelessWidget {
  final String err;
  const _ErrorHint({required this.err});
  @override
  Widget build(BuildContext context) {
    return Text('Fehler: $err',
        style: const TextStyle(color: Colors.redAccent));
  }
}
