import 'package:cloud_firestore/cloud_firestore.dart';

enum RelStatus { none, friends, incomingPending, outgoingPending }

class FriendsModel {
  final CollectionReference<Map<String, dynamic>> users =
  FirebaseFirestore.instance.collection('users');
  final CollectionReference<Map<String, dynamic>> reqs =
  FirebaseFirestore.instance.collection('friendRequests');
  final CollectionReference<Map<String, dynamic>> ships =
  FirebaseFirestore.instance.collection('friendships');

  final Map<String, Map<String, dynamic>> _userCache = {};
  String? myDocId;

  Future<void> loadMyDocId(String username) async {
    final qs =
    await users.where('username', isEqualTo: username).limit(1).get();
    if (qs.docs.isNotEmpty) {
      myDocId = qs.docs.first.id;
    }
  }

  Future<Map<String, dynamic>?> getUser(
      {String? docId, String? username}) async {
    if (username != null && _userCache.containsKey(username)) {
      return _userCache[username];
    }

    if (docId != null && docId.isNotEmpty) {
      final snap = await users.doc(docId).get();
      if (snap.exists) {
        final data = snap.data()!;
        final uname = data['username'];
        if (uname != null) _userCache[uname] = data;
        return data;
      }
    }

    if (username != null) {
      final q =
      await users.where('username', isEqualTo: username).limit(1).get();
      if (q.docs.isNotEmpty) {
        final d = q.docs.first.data();
        final uname = d['username'];
        if (uname != null) _userCache[uname] = d;
        return d;
      }
    }
    return null;
  }

  String _shipId(String a, String b) {
    final s = [a, b]..sort();
    return '${s[0]}__${s[1]}';
  }

  Future<bool> areFriends(String a, String b) async {
    final id = _shipId(a, b);
    final snap = await ships.doc(id).get();
    return snap.exists;
  }

  Future<String?> requestStatus(String from, String to) async {
    final id = '${from}__${to}';
    final snap = await reqs.doc(id).get();
    if (!snap.exists) return null;
    return snap.data()?['status'];
  }

  Future<RelStatus> relationWith(String me, String other) async {
    if (await areFriends(me, other)) return RelStatus.friends;
    final incoming = await requestStatus(other, me);
    if (incoming == 'pending') return RelStatus.incomingPending;
    final outgoing = await requestStatus(me, other);
    if (outgoing == 'pending') return RelStatus.outgoingPending;
    return RelStatus.none;
  }

  Future<String?> sendRequest({
    required String me,
    required String target,
    required String targetDoc,
  }) async {
    final rid = '${me}__${target}';
    try {
      await reqs.doc(rid).set({
        'from': me,
        'fromDocId': myDocId,
        'to': target,
        'toDocId': targetDoc,
        'status': 'pending',
        'ts': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> accept(String from, String to) async {
    final sid = _shipId(from, to);
    final rid = '${from}__${to}';
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        tx.set(reqs.doc(rid), {
          'status': 'accepted',
          'handledAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        tx.set(ships.doc(sid), {
          'members': [from, to],
          'since': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      });
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> decline(String from, String to) async {
    final rid = '${from}__${to}';
    try {
      await reqs.doc(rid).set({
        'status': 'declined',
        'handledAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> removeFriend(String me, String other) async {
    final sid = _shipId(me, other);
    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        tx.delete(ships.doc(sid));
        tx.delete(reqs.doc('${me}__${other}'));
        tx.delete(reqs.doc('${other}__${me}'));
      });
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // =========================================================
  // NEU: Freunde holen + Freunde minus Ausschlüsse
  // =========================================================

  /// Alle Freunde von `me` (Usernames).
  /// Liest alle friendships, wo `me` in members steckt,
  /// und gibt den jeweils anderen Username zurück.
  Future<List<String>> myFriends(String me) async {
    final qs = await ships.where('members', arrayContains: me).get();
    final out = <String>[];

    for (final d in qs.docs) {
      final members = List<String>.from(d.data()['members'] ?? const []);
      final other =
      members.firstWhere((u) => u != me, orElse: () => '');
      if (other.isNotEmpty) out.add(other);
    }

    return out;
  }

  /// Freunde von `me`, die eine Party sehen dürfen (Ausschlüsse rausfiltern).
  Future<List<String>> visibleFriendsForParty({
    required String me,
    required List<dynamic>? excludedFriends,
  }) async {
    final friends = await myFriends(me);
    final excluded = (excludedFriends ?? const []).cast<String>().toSet();
    return friends.where((f) => !excluded.contains(f)).toList();
  }
}
