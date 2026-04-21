// lib/Widgets/party_bottom_sheet.dart
//
// ✅ Änderungen:
// - RSVP-Status-FIX (Button wird grün):
//      Priorität:
//        1) rsvps/{uid}
//        2) rsvps/{username}
//        3) coming/{username} -> going
//        4) maybe/{username}  -> maybe
// - SnackBars: positiv = grün, negativ = rot (floating + rounded)
// - Closed Party: Wenn Anfrage gesendet (pending) -> Button wird ORANGE (deaktiviert)
// - ✅ Timer unten entfernt (kein "Wird automatisch gelöscht in ...")
// - ✅ FIX: Wenn Closed Party freigegeben (canSeeFull == true) -> "Anfrage senden" verschwindet
// - ✅ FIX PREMIUM: Premium-Check stabil & kompatibel (UID -> username-doc -> username-query)
// - ✅ FIX CLOSED REQUEST UI: "Anfrage gesendet" wird sofort angezeigt + Request-Status wird robust gefunden
//      Priorität:
//        1) requests/{uid}
//        2) requests/{username}
//        3) requests/{safeDocId(username)}

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'new_party.dart';
import '../../Services/app_draggable_sheet.dart';
import '../profile/premium_screen.dart';

typedef VoidAsync = Future<void> Function();
typedef StringAsync = Future<void> Function(String value);
typedef UserStatusAsync = Future<void> Function(String user, String status);
typedef VerifyFn = Future<bool> Function(String username);
typedef DocStream = Stream<DocumentSnapshot<Map<String, dynamic>>>?;
typedef QStream = Stream<QuerySnapshot<Map<String, dynamic>>>?;

String safeDocId(String input) =>
    input.trim().replaceAll('/', '_').replaceAll('#', '_').replaceAll('?', '_');

/// ✅ Einheitliche SnackBars: positiv = grün, negativ = rot
void showStatusSnack(
    BuildContext context,
    String message, {
      required bool positive,
    }) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: positive ? Colors.green : Colors.redAccent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class PartyBottomSheet extends StatelessWidget {
  const PartyBottomSheet({
    super.key,
    required this.partyId,
    required this.data,
    required this.isClosed,
    required this.isHost,
    required this.baseCanSeeFull,
    required this.formattedDate,
    required this.currentUsername,
    required this.inRatingWindow,
    required this.isActive,
    required this.onSetRsvp,
    required this.onClearRsvp,
    required this.onSendJoinRequest,
    required this.onUpdateRequestStatus,
    required this.onSetRating, // bleibt nur für Kompatibilität (nicht genutzt)
    required this.onReport,
    required this.rsvpStream, // wird NICHT verwendet (wir nutzen UID/Username-stream fix)
    required this.comingStream,
    required this.maybeStream,
    required this.ratingsStream, // Anzeige: Party/{partyId}/ratings listen (Docs enthalten value)
    required this.isUserVerified,
    required this.recolorOpenMarker,
    required this.setClosedLockIcon,
    required this.onEditedParty,
    this.isBarAccount = false,
  });

  final String partyId;
  final Map<String, dynamic> data;
  final bool isClosed;
  final bool isHost;
  final bool baseCanSeeFull;
  final String formattedDate;
  final String? currentUsername;
  final bool inRatingWindow;
  final bool isActive;

  final StringAsync onSetRsvp;
  final VoidAsync onClearRsvp;
  final VoidAsync onSendJoinRequest;
  final UserStatusAsync onUpdateRequestStatus;

  final StringAsync onSetRating;
  final VoidAsync onReport;

  final DocStream Function() rsvpStream;
  final QStream Function() comingStream;
  final QStream Function() maybeStream;
  final QStream Function() ratingsStream;
  final VerifyFn isUserVerified;

  final void Function(String? status) recolorOpenMarker;
  final void Function(String? status) setClosedLockIcon;

  final VoidAsync onEditedParty;

  final bool isBarAccount;

  // ------------------ Helpers ------------------
  String? _uid() => FirebaseAuth.instance.currentUser?.uid;

  DocumentReference<Map<String, dynamic>> _partyRef() =>
      FirebaseFirestore.instance.collection('Party').doc(partyId);

  Stream<DocumentSnapshot<Map<String, dynamic>>> _myRsvpUidStream() {
    final uid = _uid();
    if (uid == null) return const Stream.empty();
    return _partyRef().collection('rsvps').doc(uid).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _myRsvpUsernameStream() {
    final u = (currentUsername ?? '').trim();
    if (u.isEmpty) return const Stream.empty();
    return _partyRef().collection('rsvps').doc(u).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _myComingUsernameStream() {
    final u = (currentUsername ?? '').trim();
    if (u.isEmpty) return const Stream.empty();
    return _partyRef().collection('coming').doc(u).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _myMaybeUsernameStream() {
    final u = (currentUsername ?? '').trim();
    if (u.isEmpty) return const Stream.empty();
    return _partyRef().collection('maybe').doc(u).snapshots();
  }

  /// ✅ Status lesen:
  /// 1) rsvps/{uid}
  /// 2) rsvps/{username}
  /// 3) coming/{username} => going
  /// 4) maybe/{username}  => maybe
  Widget _rsvpStatusBuilder(
      BuildContext context, {
        required Widget Function(String? status) builder,
      }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _myRsvpUidStream(),
      builder: (context, uidSnap) {
        final uidExists = uidSnap.data?.exists == true;
        final s1 = uidSnap.data?.data()?['status'] as String?;
        if (uidExists && s1 != null) return builder(s1);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _myRsvpUsernameStream(),
          builder: (context, userSnap) {
            final userExists = userSnap.data?.exists == true;
            final s2 = userSnap.data?.data()?['status'] as String?;
            if (userExists && s2 != null) return builder(s2);

            return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: _myComingUsernameStream(),
              builder: (context, comingSnap) {
                if (comingSnap.data?.exists == true) return builder('going');

                return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: _myMaybeUsernameStream(),
                  builder: (context, maybeSnap) {
                    if (maybeSnap.data?.exists == true) return builder('maybe');
                    return builder(null);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ------------------ PREMIUM helpers ------------------

  bool _parsePremium(dynamic v) {
    if (v == true) return true;
    if (v is String) return v.trim().toLowerCase() == 'true';
    if (v is num) return v == 1;
    return false;
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _userDocByUidStream() {
    final uid = _uid();
    if (uid == null || uid.trim().isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').doc(uid).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _userDocByUsernameStream() {
    final u = (currentUsername ?? '').trim();
    if (u.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance.collection('users').doc(u).snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _userByUsernameQueryStream() {
    final u = (currentUsername ?? '').trim();
    if (u.isEmpty) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: u)
        .limit(1)
        .snapshots();
  }

  Future<Set<String>> _loadFriendUsernames() async {
    final me = (currentUsername ?? '').trim();
    if (me.isEmpty) return <String>{};

    final qs = await FirebaseFirestore.instance
        .collection('friendships')
        .where('members', arrayContains: me)
        .get();

    final out = <String>{};
    for (final d in qs.docs) {
      final members = (d.data()['members'] as List?)?.cast<String>() ?? const [];
      for (final m in members) {
        final s = m.trim();
        if (s.isNotEmpty && s != me) out.add(s);
      }
    }
    return out;
  }

  /// ✅ Premium-Section:
  /// 1) users/{uid}
  /// 2) users/{username}
  /// 3) users where username == me (limit 1)
  Widget _friendsGoingPremiumSection(BuildContext context) {
    if ((currentUsername ?? '').trim().isEmpty) return const SizedBox.shrink();

    // ✅ Premium-Gate entfernt: immer "freigeschaltet"
    return FutureBuilder<Set<String>>(
      future: _loadFriendUsernames(),
      builder: (context, friendSnap) {
        final friends = friendSnap.data ?? <String>{};

        if (friendSnap.connectionState == ConnectionState.waiting) {
          return _boxed(
            Row(
              children: const [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text("Lade Freunde…", style: TextStyle(color: Colors.white70)),
              ],
            ),
          );
        }

        if (friends.isEmpty) {
          return _boxed(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  "👀 Freunde bei dieser Party",
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 8),
                Text(
                  "Du hast aktuell keine Freunde, die angezeigt werden können.",
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          );
        }

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: comingStream(),
          builder: (context, comingSnap) {
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: maybeStream(),
              builder: (context, maybeSnap) {
                final comingDocs = comingSnap.data?.docs ?? const [];
                final maybeDocs = maybeSnap.data?.docs ?? const [];

                final comingFriends = <String>[];
                for (final d in comingDocs) {
                  final u = d.id.trim();
                  if (friends.contains(u)) comingFriends.add(u);
                }

                final maybeFriends = <String>[];
                for (final d in maybeDocs) {
                  final u = d.id.trim();
                  if (friends.contains(u)) maybeFriends.add(u);
                }

                comingFriends.sort();
                maybeFriends.sort();

                return _boxed(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.groups_rounded,
                              color: Colors.redAccent, size: 20),
                          SizedBox(width: 8),
                          Text(
                            "👀 Freunde bei dieser Party",
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (comingFriends.isEmpty && maybeFriends.isEmpty)
                        const Text(
                          "Keine deiner Freunde sind hier aktuell in 'Ich komme' oder 'Vielleicht'.",
                          style: TextStyle(color: Colors.white70),
                        )
                      else ...[
                        if (comingFriends.isNotEmpty) ...[
                          const Text("✅ Kommen",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: comingFriends
                                .map((u) => _friendChip(u, Colors.greenAccent))
                                .toList(),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (maybeFriends.isNotEmpty) ...[
                          const Text("🤔 Vielleicht",
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: maybeFriends
                                .map((u) =>
                                _friendChip(u, Colors.orangeAccent))
                                .toList(),
                          ),
                        ],
                      ],
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }


  static Widget _friendChip(String username, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withOpacity(.6)),
      ),
      child: Text(username,
          style: TextStyle(color: c, fontWeight: FontWeight.w800)),
    );
  }

  // ------------------ RATING (Cloud Function CALLABLE) ------------------
  Future<void> _setRatingViaFunction(BuildContext context, String value) async {
    final uid = _uid();
    final meName = (currentUsername ?? '').trim();

    if (uid == null) {
      showStatusSnack(context, "Nicht eingeloggt (auth.uid fehlt).",
          positive: false);
      return;
    }
    if (meName.isEmpty) {
      showStatusSnack(context, "Username fehlt.", positive: false);
      return;
    }
    if (!inRatingWindow) {
      showStatusSnack(context, "Bewertung ist noch nicht möglich.",
          positive: false);
      return;
    }

    try {
      final functions = FirebaseFunctions.instanceFor(region: 'europe-west1');

      final fn = functions.httpsCallable(
        'setPartyRating',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
      );

      await fn.call(<String, dynamic>{
        'partyId': partyId,
        'value': value, // good|bad
      });

      if (!context.mounted) return;

      showStatusSnack(
        context,
        value == 'good'
            ? "Danke! Positive Bewertung gespeichert."
            : "Danke! Negative Bewertung gespeichert.",
        positive: value == 'good',
      );
    } on FirebaseFunctionsException catch (e) {
      if (!context.mounted) return;
      showStatusSnack(context,
          "Function-Fehler: ${e.code} (${e.message ?? ''})",
          positive: false);
    } on FirebaseException catch (e) {
      if (!context.mounted) return;
      showStatusSnack(context,
          "Firebase-Fehler: ${e.code} (${e.message ?? ''})",
          positive: false);
    } catch (e) {
      if (!context.mounted) return;
      showStatusSnack(context, "Fehler beim Bewerten: $e", positive: false);
    }
  }

  // -------- User ausladen --------
  Future<void> _confirmKickUser(BuildContext context, String username) async {
    final cleanUser = username.trim();
    if (cleanUser.isEmpty || cleanUser == 'Unbekannt') return;

    final typeStr = (data['type'] ?? (isClosed ? 'Closed' : 'Open')).toString();
    final bool isFriendsOnly = typeStr == 'Only4Friends';

    final bool confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
        const Text("Person ausladen?", style: TextStyle(color: Colors.white)),
        content: Text(
          isFriendsOnly
              ? "Möchtest du \"$cleanUser\" wirklich ausladen? Die Person wird aus allen Listen entfernt und bei dieser Only4Friends-Party ausgeschlossen."
              : "Möchtest du \"$cleanUser\" wirklich ausladen? Die Person wird aus allen Zusagen/Listen dieser Party entfernt.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
            const Text("Abbrechen", style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("Ausladen",
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    ) ??
        false;

    if (!confirmed) return;

    try {
      final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);

      await FirebaseFirestore.instance.runTransaction((tx) async {
        final rsvpRef = partyRef.collection('rsvps').doc(cleanUser);
        final comingRef = partyRef.collection('coming').doc(cleanUser);
        final maybeRef = partyRef.collection('maybe').doc(cleanUser);
        final apprRef = partyRef.collection('approved').doc(cleanUser);

        final reqRef1 = partyRef.collection('requests').doc(cleanUser);
        final reqRef2 = partyRef.collection('requests').doc(safeDocId(cleanUser));

        tx.delete(rsvpRef);
        tx.delete(comingRef);
        tx.delete(maybeRef);
        tx.delete(apprRef);
        tx.delete(reqRef1);
        if (reqRef2.id != reqRef1.id) tx.delete(reqRef2);

        tx.set(
          partyRef,
          {'approvedUsers': FieldValue.arrayRemove([cleanUser])},
          SetOptions(merge: true),
        );

        if (isFriendsOnly) {
          tx.set(
            partyRef,
            {'excludedFriends': FieldValue.arrayUnion([cleanUser])},
            SetOptions(merge: true),
          );
        }
      });

      showStatusSnack(context, "\"$cleanUser\" wurde ausgeladen.", positive: true);
    } catch (e) {
      showStatusSnack(context, "Fehler beim Ausladen: $e", positive: false);
    }
  }

  // ✅ Timer unten entfernt -> immer shrink
  Widget _buildExpiryInfo() => const SizedBox.shrink();

  // ✅ Rating-Gate
  Widget _ratingGate(BuildContext context) {
    if (currentUsername == null) return const SizedBox.shrink();

    if (isHost) {
      return _pill("Hosts können ihre eigene Party nicht bewerten.", Colors.white70);
    }

    if (!inRatingWindow) {
      return _pill("Bewertung ist noch nicht freigeschaltet.", Colors.white70);
    }

    return _rsvpStatusBuilder(
      context,
      builder: (status) {
        final canRate = status == 'going' || status == 'maybe';
        if (!canRate) {
          return _pill(
            "Bewerten erst möglich, wenn du \"Ich komme\" oder \"Ich komme eventuell\" gesetzt hast.",
            Colors.white70,
          );
        }
        return _ratingButtons(context);
      },
    );
  }

  // ===========================
  // ✅ Bilder anzeigen
  // ===========================
  List<_UiImageBlock> _extractImageBlocks(Map<String, dynamic> partyData) {
    final blocks = <_UiImageBlock>[];

    final rawBlocks = partyData['imageBlocks'];
    if (rawBlocks is List) {
      for (final b in rawBlocks) {
        if (b is! Map) continue;
        final caption = (b['caption'] ?? '').toString().trim();
        final imgs = <String>[];

        final rawImgs = b['images'];
        if (rawImgs is List) {
          for (final it in rawImgs) {
            if (it is Map) {
              final url = (it['url'] ?? '').toString().trim();
              if (url.isNotEmpty) imgs.add(url);
            } else if (it is String) {
              final url = it.trim();
              if (url.isNotEmpty) imgs.add(url);
            }
          }
        }

        if (caption.isEmpty && imgs.isEmpty) continue;
        blocks.add(_UiImageBlock(caption: caption, urls: imgs));
      }
    }

    if (blocks.isEmpty) {
      final rawImages = partyData['images'];
      if (rawImages is List) {
        final urls = <String>[];
        String caption = '';

        for (final it in rawImages) {
          if (it is Map) {
            final url = (it['url'] ?? '').toString().trim();
            if (url.isNotEmpty) urls.add(url);
            final c = (it['caption'] ?? '').toString().trim();
            if (caption.isEmpty && c.isNotEmpty) caption = c;
          } else if (it is String) {
            final url = it.trim();
            if (url.isNotEmpty) urls.add(url);
          }
        }

        if (caption.isNotEmpty || urls.isNotEmpty) {
          blocks.add(_UiImageBlock(caption: caption, urls: urls));
        }
      }
    }

    return blocks;
  }

  Widget _imagesSection(Map<String, dynamic> partyData) {
    final blocks = _extractImageBlocks(partyData);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return _boxed(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.photo_library_outlined, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                "📸 Bilder",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...List.generate(blocks.length, (i) {
            final b = blocks[i];

            return Container(
              margin: EdgeInsets.only(bottom: i == blocks.length - 1 ? 0 : 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey[700]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (b.caption.isNotEmpty) ...[
                    Text(
                      b.caption,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          height: 1.25),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (b.urls.isNotEmpty)
                    SizedBox(
                      height: 120,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: b.urls.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, idx) {
                          final url = b.urls[idx];
                          return _imageThumb(context, url);
                        },
                      ),
                    )
                  else
                    const Text("Keine Bilder in diesem Block.",
                        style: TextStyle(color: Colors.white70)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _imageThumb(BuildContext context, String url) {
    return GestureDetector(
      onTap: () => _openImageViewer(context, url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 160,
          height: 120,
          color: Colors.black12,
          child: Image.network(
            url,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (context, _, __) => const Center(
                child: Icon(Icons.broken_image_outlined, color: Colors.white54)),
          ),
        ),
      ),
    );
  }

  void _openImageViewer(BuildContext context, String url) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.92),
      builder: (ctx) {
        return GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(14),
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (context, _, __) => Container(
                    color: Colors.grey[900],
                    padding: const EdgeInsets.all(18),
                    child: const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white70, size: 36),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------ BUILD ------------------
  @override
  Widget build(BuildContext context) {
    final typeStr = (data['type'] ?? (isClosed ? 'Closed' : 'Open')).toString();
    final isFriendsOnly = typeStr == 'Only4Friends';
    final canSeeFull = isFriendsOnly ? true : (!isClosed || baseCanSeeFull);

    final hostNameStr = (data['hostName'] ?? '').toString();
    final hostLabel = isHost ? "$hostNameStr (du)" : hostNameStr;

    final Color badgeColor = isFriendsOnly
        ? Colors.deepPurple[700]!
        : (isClosed ? Colors.blueGrey[800]! : Colors.green[800]!);
    final IconData badgeIcon =
    isFriendsOnly ? Icons.group_rounded : (isClosed ? Icons.lock : Icons.public);
    final String badgeLabel =
    isFriendsOnly ? "👥 Only4Friends" : (isClosed ? "🔒 Closed" : "🌍 Open");

    Future<void> _confirmAndDeleteParty() async {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text("Party löschen?",
              style: TextStyle(color: Colors.white)),
          content: const Text(
            "Willst du diese Party wirklich löschen? Alle Zusagen, Anfragen und Bewertungen gehen verloren.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text("Abbrechen",
                  style: TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text("Löschen",
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ) ??
          false;

      if (!confirm) return;

      try {
        final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
        final batch = FirebaseFirestore.instance.batch();

        const subCollections = [
          'rsvps',
          'coming',
          'maybe',
          'requests',
          'approved',
          'ratings'
        ];

        for (final sub in subCollections) {
          final qs = await partyRef.collection(sub).get();
          for (final doc in qs.docs) {
            batch.delete(doc.reference);
          }
        }

        batch.delete(partyRef);
        await batch.commit();

        if (!context.mounted) return;
        showStatusSnack(context, "Party gelöscht.", positive: true);

        await onEditedParty();
      } catch (e) {
        if (!context.mounted) return;
        showStatusSnack(context, "Fehler beim Löschen: $e", positive: false);
      }
    }

    const _redIcon = Color(0xAAFF3B30);
    const _redBorder = Color(0x22FF3B30);

    Widget _chip(IconData icon, String label, String value) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1215),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _redBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(icon, color: _redIcon, size: 13),
              const SizedBox(width: 4),
              Expanded(child: Text(value,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ),
      ),
    );

    final minAge = (data['minAge']?.toString() ?? '').trim();
    final price = data['price'];
    final guestLimit = (data['guestLimit']?.toString() ?? '').trim();
    final address = (data['address'] ?? '—').toString();
    final description = (data['description'] ?? '').toString().trim();

    final Widget fullDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _chip(Icons.calendar_today_rounded, "📅  Datum", formattedDate),
          const SizedBox(width: 8),
          _chip(Icons.schedule_rounded, "🕐  Uhrzeit", (data['time'] ?? '—').toString()),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _chip(Icons.euro_rounded, "💶  Eintritt",
              price == null || price == 0 ? "Gratis" : "${price}€"),
          const SizedBox(width: 8),
          _chip(Icons.cake_outlined, "🎂  Alter", minAge.isEmpty ? '—' : '${minAge}+'),
          const SizedBox(width: 8),
          _chip(Icons.group_rounded, "👥  Limit", guestLimit.isEmpty ? '∞' : guestLimit),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1215),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _redBorder),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.location_on_rounded, color: _redIcon, size: 14),
            const SizedBox(width: 6),
            Expanded(child: Text(address,
                style: const TextStyle(color: Colors.white70, fontSize: 13))),
          ]),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1215),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _redBorder),
            ),
            child: Text(description,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
          ),
        ],
      ],
    );

    final Widget closedPartial = Column(
      children: [
        Row(children: [
          _chip(Icons.calendar_today_rounded, "📅  Datum", formattedDate),
          const SizedBox(width: 8),
          _chip(Icons.cake_outlined, "🎂  Alter", minAge.isEmpty ? '—' : '${minAge}+'),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1215),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _redBorder),
          ),
          child: const Row(children: [
            Icon(Icons.lock_outline_rounded, color: _redIcon, size: 14),
            SizedBox(width: 8),
            Expanded(child: Text(
              "Weitere Details werden nach Freigabe sichtbar.",
              style: TextStyle(color: Colors.white38, fontSize: 12, fontStyle: FontStyle.italic),
            )),
          ]),
        ),
      ],
    );

    return AppDraggableSheet(
      panelColor: const Color(0xFF120D0F),
      borderColor: const Color(0xFF2E1A1F),
      childBuilder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
          children: [
            // Party name – full width, no competition with badge
            Text(
              (data['name'] ?? (isClosed ? "Geschlossene Party" : "Party")).toString(),
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            // Badge + Host in same row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: badgeColor, borderRadius: BorderRadius.circular(999)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(badgeIcon, color: Colors.white, size: 14),
                      const SizedBox(width: 5),
                      Text(badgeLabel,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FutureBuilder<bool>(
                  future: isUserVerified(hostNameStr),
                  builder: (context, snap) {
                    final isVerified = snap.data == true;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A1018),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: const Color(0x44FF3B30)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isVerified) ...[
                            const Icon(Icons.verified_rounded, color: Color(0xFFFF3B30), size: 14),
                            const SizedBox(width: 5),
                          ] else ...[
                            const Text("🎤", style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 5),
                          ],
                          Text("$hostLabel",
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isFriendsOnly)
              _pill("👥 Nur für Freunde sichtbar.", Colors.deepPurpleAccent)
            else if (isClosed && !canSeeFull)
              _pill("🔒 Geschlossene Party – nur Datum & Mindestalter sichtbar.",
                  Colors.redAccent)
            else if (isClosed && canSeeFull)
              _pill("✅ Zugriff freigegeben – alle Details sichtbar.",
                  Colors.lightGreenAccent),
            const SizedBox(height: 16),
            if (canSeeFull) fullDetails else closedPartial,
            if (canSeeFull) ...[
              const SizedBox(height: 14),
              _imagesSection(data),
            ],
            const SizedBox(height: 14),
            _friendsGoingPremiumSection(context),
            const SizedBox(height: 20),
            const Divider(color: Color(0x33FF3B30)),
            const SizedBox(height: 12),
            if (isHost) ...[
              if (isClosed && !isFriendsOnly)
                _hostClosedLists(context)
              else
                _hostOpenLists(context),
              const SizedBox(height: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orangeAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    label: const Text("Party bearbeiten", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NewPartyScreen(existingData: data, docId: partyId),
                        ),
                      );
                      await onEditedParty();
                    },
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _confirmAndDeleteParty,
                    icon: const Icon(Icons.delete_outline_rounded, size: 16),
                    label: const Text("Party löschen", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ]
            else ...[

              // 🔥 1️⃣ Ticket kaufen Button (nur wenn Preis > 0)
              if ((data['price'] ?? 0) > 0 && (!isClosed || canSeeFull)) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.payment),
                  label: Text("Ticket kaufen – ${(data['price']).toString()}€"),
                  onPressed: () => _buyTicket(context),
                ),
                const SizedBox(height: 14),
              ],

              // 🔥 2️⃣ RSVP / Closed Logik bleibt darunter
              if (!isClosed || isFriendsOnly)
                _guestOpenActions(context)
              else if (canSeeFull)
                const SizedBox.shrink()
              else
                _guestClosedActions(context),

              const SizedBox(height: 12),

              _ratingGate(context),

              if (isActive) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onReport,
                  icon: const Icon(Icons.flag_outlined, size: 15, color: Colors.redAccent),
                  label: const Text("Melden", style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  // ---------- Guest Open ----------
  Widget _guestOpenActions(BuildContext context) {
    if (isBarAccount && !isHost) {
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: comingStream(),
        builder: (context, cs) {
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: maybeStream(),
            builder: (context, ms) {
              final cCount = (cs.data?.docs ?? []).length;
              final mCount = (ms.data?.docs ?? []).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "Bar-Accounts können bei fremden Partys keine Zusage setzen.",
                    style: TextStyle(color: Colors.white60),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  _counter("🔔 $cCount kommen · $mCount vielleicht"),
                ],
              );
            },
          );
        },
      );
    }

    if (currentUsername == null) {
      return const Text(
        "Bitte in den Einstellungen Vor- & Nachname setzen, um zuzusagen.",
        style: TextStyle(color: Colors.redAccent),
      );
    }

    return _rsvpStatusBuilder(
      context,
      builder: (status) => _buildOpenActionsWithStatus(context, status),
    );
  }

  Widget _buildOpenActionsWithStatus(BuildContext context, String? status) {
    final isGoing = status == 'going';
    final isMaybe = status == 'maybe';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(
            child: _rsvpBtn(
              label: "Ich komme",
              icon: Icons.check_circle_rounded,
              active: isGoing,
              activeColor: Colors.green,
              onTap: () async {
                if (currentUsername == null) return;
                try {
                  if (isGoing) {
                    await onClearRsvp();
                    if (!context.mounted) return;
                    showStatusSnack(context, "Zusage zurückgezogen.", positive: true);
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('going');
                    if (!context.mounted) return;
                    showStatusSnack(context, "Ich komme ✅", positive: true);
                    recolorOpenMarker('going');
                  }
                } catch (e) {
                  if (!context.mounted) return;
                  showStatusSnack(context, "Fehler: $e", positive: false);
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _rsvpBtn(
              label: "Vielleicht",
              icon: Icons.help_outline_rounded,
              active: isMaybe,
              activeColor: Colors.orangeAccent,
              onTap: () async {
                if (currentUsername == null) return;
                try {
                  if (isMaybe) {
                    await onClearRsvp();
                    if (!context.mounted) return;
                    showStatusSnack(context, "Vielleicht zurückgezogen.", positive: true);
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('maybe');
                    if (!context.mounted) return;
                    showStatusSnack(context, "Ich komme eventuell 👍", positive: true);
                    recolorOpenMarker('maybe');
                  }
                } catch (e) {
                  if (!context.mounted) return;
                  showStatusSnack(context, "Fehler: $e", positive: false);
                }
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: comingStream(),
          builder: (context, cs) {
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: maybeStream(),
              builder: (context, ms) {
                final cCount = (cs.data?.docs ?? []).length;
                final mCount = (ms.data?.docs ?? []).length;
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[700]!),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.people_rounded, color: Colors.white38, size: 14),
                    const SizedBox(width: 6),
                    Text("$cCount kommen  ·  $mCount vielleicht",
                        style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ]),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Widget _rsvpBtn({
    required String label,
    required IconData icon,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: active ? activeColor.withAlpha(40) : Colors.grey[850],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? activeColor : Colors.grey[700]!),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: active ? activeColor : Colors.white54, size: 16),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(
            color: active ? activeColor : Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          )),
        ]),
      ),
    );
  }

  // ---------- Guest Closed ----------
  // ✅ Robust: zeigt "Anfrage gesendet" sofort + findet Status egal ob DocId uid/username/safeDocId(username)
  Widget _guestClosedActions(BuildContext context) {
    if (currentUsername == null) {
      return const Text(
        "Bitte in den Einstellungen Vor- & Nachname setzen, um eine Anfrage zu senden.",
        style: TextStyle(color: Colors.redAccent),
      );
    }

    final uid = _uid();
    final uname = currentUsername!.trim();
    final safeUname = safeDocId(uname);

    Stream<DocumentSnapshot<Map<String, dynamic>>> _reqStream(String docId) {
      if (docId.trim().isEmpty) return const Stream.empty();
      return FirebaseFirestore.instance
          .collection('Party')
          .doc(partyId)
          .collection('requests')
          .doc(docId)
          .snapshots();
    }

    Widget _requestStatusBuilder({
      required Widget Function(String? status) builder,
    }) {
      // 1) requests/{uid}
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: uid == null ? const Stream.empty() : _reqStream(uid),
        builder: (context, s1) {
          final st1 = s1.data?.data()?['status'] as String?;
          if (s1.data?.exists == true && st1 != null) return builder(st1);

          // 2) requests/{username}
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _reqStream(uname),
            builder: (context, s2) {
              final st2 = s2.data?.data()?['status'] as String?;
              if (s2.data?.exists == true && st2 != null) return builder(st2);

              // 3) requests/{safeDocId(username)}
              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _reqStream(safeUname),
                builder: (context, s3) {
                  final st3 = s3.data?.data()?['status'] as String?;
                  if (s3.data?.exists == true && st3 != null) return builder(st3);

                  return builder(null);
                },
              );
            },
          );
        },
      );
    }

    bool localPending = false;

    return StatefulBuilder(
      builder: (context, setState) {
        return _requestStatusBuilder(
          builder: (statusFromDb) {
            final status = statusFromDb ?? (localPending ? 'pending' : null);

            if (status == 'pending') {
              SchedulerBinding.instance
                  .addPostFrameCallback((_) => setClosedLockIcon('pending'));
              return ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: Colors.orangeAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: null,
                icon: const Icon(Icons.hourglass_top_rounded),
                label: const Text("Anfrage gesendet", style: TextStyle(fontSize: 18)),
              );
            }

            if (status == null) {
              return ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  try {
                    setState(() => localPending = true); // ✅ sofort UI
                    await onSendJoinRequest();
                    if (!context.mounted) return;
                    showStatusSnack(context, "Anfrage gesendet – warte auf Antwort",
                        positive: true);
                    setClosedLockIcon('pending');
                  } catch (e) {
                    setState(() => localPending = false);
                    if (!context.mounted) return;
                    showStatusSnack(context, "Fehler: $e", positive: false);
                  }
                },
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text("Anfrage senden", style: TextStyle(fontSize: 18)),
              );
            }

            if (status == 'approved') {
              SchedulerBinding.instance
                  .addPostFrameCallback((_) => setClosedLockIcon('approved'));
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(20),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.greenAccent.withAlpha(80)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 28),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Zugang genehmigt",
                              style: TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700, fontSize: 15)),
                          SizedBox(height: 3),
                          Text("Du kannst jetzt alle Party-Details sehen.",
                              style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }

            // declined
            SchedulerBinding.instance
                .addPostFrameCallback((_) => setClosedLockIcon('declined'));
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withAlpha(20),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.redAccent.withAlpha(80)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 28),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Anfrage abgelehnt",
                            style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700, fontSize: 15)),
                        SizedBox(height: 3),
                        Text("Du kannst den Host direkt kontaktieren.",
                            style: TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------- Host-Listen ----------
  Widget _hostClosedLists(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Offene Anfragen ──
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party')
              .doc(partyId)
              .collection('requests')
              .where('status', isEqualTo: 'pending')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, reqsSnap) {
            final docs = reqsSnap.data?.docs ?? [];
            return _boxed(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.orangeAccent.withAlpha(30),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.orangeAccent.withAlpha(80)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.pending_actions, color: Colors.orangeAccent, size: 14),
                      const SizedBox(width: 6),
                      Text("Anfragen (${docs.length})",
                          style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w700, fontSize: 13)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                if (docs.isEmpty)
                  const Text("Keine offenen Anfragen.", style: TextStyle(color: Colors.white54, fontSize: 13))
                else
                  ...docs.map((d) {
                    final user = d.data()['username']?.toString() ?? 'Unbekannt';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey[850],
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.grey[700]!),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.person_rounded, color: Colors.white54, size: 16),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  user,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    elevation: 0,
                                  ),
                                  onPressed: () => onUpdateRequestStatus(user, 'approved'),
                                  child: const Text("Zulassen", style: TextStyle(fontWeight: FontWeight.w700)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    elevation: 0,
                                  ),
                                  onPressed: () => onUpdateRequestStatus(user, 'declined'),
                                  child: const Text("Ablehnen", style: TextStyle(fontWeight: FontWeight.w700)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),

        const SizedBox(height: 12),

        // ── Zugelassene ──
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party')
              .doc(partyId)
              .collection('approved')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, apprSnap) {
            final names = (apprSnap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();
            return _boxed(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.greenAccent.withAlpha(30),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.greenAccent.withAlpha(80)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 14),
                      const SizedBox(width: 6),
                      Text("Zugelassen (${names.length})",
                          style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700, fontSize: 13)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                if (names.isEmpty)
                  const Text("Noch niemand zugelassen.", style: TextStyle(color: Colors.white54, fontSize: 13))
                else
                  ...names.map((u) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[700]!),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.verified_user_rounded, color: Colors.greenAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(u,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        IconButton(
                          tooltip: "Ausladen",
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close_rounded, color: Colors.redAccent, size: 18),
                          onPressed: () => _confirmKickUser(context, u),
                        ),
                      ],
                    ),
                  )),
              ],
            ));
          },
        ),
      ],
    );
  }

  Widget _hostOpenLists(BuildContext context) {
    return Column(
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party')
              .doc(partyId)
              .collection('coming')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, comingListSnap) {
            final names = (comingListSnap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();
            return _bigList(
              "✅ Leute, die kommen",
              Icons.check_circle,
              Colors.greenAccent,
              names,
              Icons.check_circle,
              Colors.greenAccent,
                  (user) => _confirmKickUser(context, user),
            );
          },
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party')
              .doc(partyId)
              .collection('maybe')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, maybeListSnap) {
            final names = (maybeListSnap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();
            return _bigList(
              "🤔 Leute, die eventuell kommen",
              Icons.help_outline,
              Colors.orangeAccent,
              names,
              Icons.help_outline,
              Colors.orangeAccent,
                  (user) => _confirmKickUser(context, user),
            );
          },
        ),
      ],
    );
  }

  // ---------- Rating Buttons ----------
  Widget _ratingButtons(BuildContext context) {
    final canRate = currentUsername != null && _uid() != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        const Text(
          "Bewerten (24h ab Partybeginn)",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed:
                canRate ? () async => _setRatingViaFunction(context, 'good') : null,
                icon: const Icon(Icons.thumb_up),
                label: const Text("Gut"),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed:
                canRate ? () async => _setRatingViaFunction(context, 'bad') : null,
                icon: const Icon(Icons.thumb_down),
                label: const Text("Schlecht"),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: ratingsStream(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            final good =
                docs.where((d) => (d.data()['value'] ?? '') == 'good').length;
            final bad =
                docs.where((d) => (d.data()['value'] ?? '') == 'bad').length;
            return Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  "⭐ Bewertungen: $good gut · $bad schlecht",
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
              ),
            );
          },
        ),
      ],
    );
  }


  Future<void> _buyTicket(BuildContext context) async {
    final stripeAccountId = data['stripeAccountId'];

    if (stripeAccountId == null) {
      showStatusSnack(context, "Host hat kein Stripe aktiviert.", positive: false);
      return;
    }

    final response = await http.post(
      Uri.parse("http://192.168.1.5:3000/create-checkout-session"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "stripeAccountId": stripeAccountId,
        "price": data['price'],
        "partyId": partyId,
      }),
    );

    if (response.statusCode != 200) {
      showStatusSnack(context, "Zahlungsfehler.", positive: false);
      return;
    }

    final url = jsonDecode(response.body)["url"];

    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  // ---------- UI Helfer ----------
  static Widget _box({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.grey[850],
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.grey[700]!),
    ),
    child: child,
  );

  static Widget _boxed(Widget child) => Container(
    width: double.infinity,
    margin: const EdgeInsets.symmetric(vertical: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.grey[900],
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.grey[700]!),
    ),
    child: child,
  );

  static Widget _counter(String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.grey[850],
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey[700]!),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
          color: Colors.white70,
          fontSize: 18,
          fontWeight: FontWeight.w700),
    ),
  );

  static Widget _pill(String text, Color c) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: c.withOpacity(.15),
      border: Border.all(color: c.withOpacity(.5)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
  );

  Widget _bigList(
      String title,
      IconData titleIcon,
      Color titleColor,
      List<String> usernames,
      IconData rowIcon,
      Color rowIconColor,
      Future<void> Function(String username) onKick,
      ) {
    return _boxed(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(titleIcon, color: titleColor, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ]),
          const SizedBox(height: 10),
          if (usernames.isEmpty)
            const Text("Noch niemand", style: TextStyle(color: Colors.white70))
          else
            ...List.generate(usernames.length, (i) {
              final u = usernames[i];
              return Column(
                children: [
                  if (i > 0)
                    Divider(color: Colors.grey[800], height: 16, thickness: 1),
                  Row(
                    children: [
                      Icon(rowIcon, color: rowIconColor, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          u,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: "Ausladen",
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.redAccent),
                        onPressed: () => onKick(u),
                      ),
                    ],
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }
}

class _UiImageBlock {
  final String caption;
  final List<String> urls;
  const _UiImageBlock({required this.caption, required this.urls});
}
