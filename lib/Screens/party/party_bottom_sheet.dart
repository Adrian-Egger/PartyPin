// lib/Screens/party/party_bottom_sheet.dart

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'new_party.dart';
import 'ticket_purchase_section.dart';
import 'ticket_scanner_screen.dart';
import '../../Services/app_draggable_sheet.dart';
import '../profile/user_profile_screen.dart';
import '../../Theme/app_theme.dart';

typedef VoidAsync     = Future<void> Function();
typedef StringAsync   = Future<void> Function(String value);
typedef UserStatusAsync = Future<void> Function(String user, String status);
typedef VerifyFn      = Future<bool> Function(String username);
typedef DocStream     = Stream<DocumentSnapshot<Map<String, dynamic>>>?;
typedef QStream       = Stream<QuerySnapshot<Map<String, dynamic>>>?;

String safeDocId(String input) =>
    input.trim().replaceAll('/', '_').replaceAll('#', '_').replaceAll('?', '_');

void showStatusSnack(BuildContext context, String message, {required bool positive}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: positive ? AppColors.success : AppColors.accent,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PartyBottomSheet
// ─────────────────────────────────────────────────────────────────────────────

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
    required this.onSetRating,
    required this.onReport,
    required this.rsvpStream,
    required this.comingStream,
    required this.maybeStream,
    required this.ratingsStream,
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

  final StringAsync    onSetRsvp;
  final VoidAsync      onClearRsvp;
  final VoidAsync      onSendJoinRequest;
  final UserStatusAsync onUpdateRequestStatus;
  final StringAsync    onSetRating;
  final VoidAsync      onReport;

  final DocStream Function() rsvpStream;
  final QStream   Function() comingStream;
  final QStream   Function() maybeStream;
  final QStream   Function() ratingsStream;
  final VerifyFn  isUserVerified;

  final void Function(String? status) recolorOpenMarker;
  final void Function(String? status) setClosedLockIcon;
  final VoidAsync onEditedParty;
  final bool isBarAccount;

  // ── Firebase helpers ────────────────────────────────────────────────────────

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

  /// Cascading RSVP status lookup: uid → username → coming → maybe
  Widget _rsvpStatusBuilder(
    BuildContext context, {
    required Widget Function(String? status) builder,
  }) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _myRsvpUidStream(),
      builder: (context, uidSnap) {
        final s1 = uidSnap.data?.data()?['status'] as String?;
        if (uidSnap.data?.exists == true && s1 != null) return builder(s1);

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: _myRsvpUsernameStream(),
          builder: (context, userSnap) {
            final s2 = userSnap.data?.data()?['status'] as String?;
            if (userSnap.data?.exists == true && s2 != null) return builder(s2);

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

  void _showHostProfile(BuildContext context, String hostUsername, {String? displayName}) {
    if (hostUsername.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          username: hostUsername,
          myUsername: currentUsername,
          displayName: displayName,
        ),
      ),
    );
  }

  // ── Friends ─────────────────────────────────────────────────────────────────

  Future<Set<String>> _loadFriendUsernames() async {
    final me = (currentUsername ?? '').trim();
    if (me.isEmpty) return {};
    final qs = await FirebaseFirestore.instance
        .collection('friendships')
        .where('members', arrayContains: me)
        .get();
    final out = <String>{};
    for (final d in qs.docs) {
      for (final m in (d.data()['members'] as List?)?.cast<String>() ?? <String>[]) {
        final s = m.trim();
        if (s.isNotEmpty && s != me) out.add(s);
      }
    }
    return out;
  }

  Widget _friendsGoingSection(BuildContext context) {
    if ((currentUsername ?? '').trim().isEmpty) return const SizedBox.shrink();

    return FutureBuilder<Set<String>>(
      future: _loadFriendUsernames(),
      builder: (context, friendSnap) {
        if (friendSnap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }

        final friends = friendSnap.data ?? {};

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: comingStream(),
          builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: maybeStream(),
            builder: (context, ms) {
              final goingFriends = (cs.data?.docs ?? [])
                  .map((d) => d.id.trim())
                  .where(friends.contains)
                  .toList()..sort();
              final maybeFriends = (ms.data?.docs ?? [])
                  .map((d) => d.id.trim())
                  .where(friends.contains)
                  .toList()..sort();

              if (goingFriends.isEmpty && maybeFriends.isEmpty) return const SizedBox.shrink();

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel("Freunde hier"),
                    const SizedBox(height: 10),
                    if (goingFriends.isNotEmpty)
                      Wrap(
                        spacing: 6, runSpacing: 6,
                        children: goingFriends
                            .map((u) => _friendChip(u, AppColors.success))
                            .toList(),
                      ),
                    if (maybeFriends.isNotEmpty) ...[
                      if (goingFriends.isNotEmpty) const SizedBox(height: 8),
                      Wrap(
                        spacing: 6, runSpacing: 6,
                        children: maybeFriends
                            .map((u) => _friendChip(u, Colors.orangeAccent))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  static Widget _friendChip(String username, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: c.withAlpha(20),
      borderRadius: AppRadius.fullBr,
      border: Border.all(color: c.withAlpha(80)),
    ),
    child: Text(username, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 13)),
  );

  // ── Rating ──────────────────────────────────────────────────────────────────

  Future<void> _setRatingViaFunction(BuildContext context, String value) async {
    if (_uid() == null || (currentUsername ?? '').trim().isEmpty || !inRatingWindow) {
      showStatusSnack(context, "Bewertung nicht möglich.", positive: false);
      return;
    }
    try {
      final fn = FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(
        'setPartyRating',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 20)),
      );
      await fn.call({'partyId': partyId, 'value': value});
      if (!context.mounted) return;
      showStatusSnack(
        context,
        value == 'good' ? "Danke! Positive Bewertung gespeichert." : "Danke! Negative Bewertung gespeichert.",
        positive: value == 'good',
      );
    } on FirebaseFunctionsException catch (e) {
      final msg = (e.message ?? '').toLowerCase();
      String userMsg;
      if (msg.contains('outside 24h window')) {
        userMsg = "Bewertungsfenster ist geschlossen (24h ab Partybeginn).";
      } else if (msg.contains('not approved')) {
        userMsg = "Du musst freigegeben sein, um zu bewerten.";
      } else if (msg.contains('only going/maybe')) {
        userMsg = "Nur Zusagen oder Vielleicht können bewerten.";
      } else if (msg.contains('host cannot rate')) {
        userMsg = "Hosts können ihre eigene Party nicht bewerten.";
      } else if (e.code == 'unauthenticated') {
        userMsg = "Nicht eingeloggt.";
      } else {
        userMsg = "Fehler: ${e.message ?? e.code}";
      }
      if (context.mounted) showStatusSnack(context, userMsg, positive: false);
    } catch (e) {
      if (context.mounted) showStatusSnack(context, "Fehler: $e", positive: false);
    }
  }

  /// Liefert true, sobald der eingeloggte Nutzer mindestens ein bezahltes
  /// Ticket für diese Party hat. Nutzt einen Live-Stream, damit der
  /// Bewertungsbereich automatisch erscheint, sobald Stripe die Buchung
  /// bestätigt.
  Stream<bool> _hasPaidTicketStream() {
    final uid = _uid();
    if (uid == null) return Stream.value(false);
    return FirebaseFirestore.instance
        .collection('tickets')
        .where('buyerUid', isEqualTo: uid)
        .where('partyId', isEqualTo: partyId)
        .where('status', isEqualTo: 'paid')
        .limit(1)
        .snapshots()
        .map((s) => s.docs.isNotEmpty);
  }

  Widget _ratingGate(BuildContext context) {
    if (currentUsername == null || isHost || !inRatingWindow) {
      return const SizedBox.shrink();
    }
    return _rsvpStatusBuilder(
      context,
      builder: (status) {
        final isComing = status == 'going';
        return StreamBuilder<bool>(
          stream: _hasPaidTicketStream(),
          builder: (context, ticketSnap) {
            final hasPaidTicket = ticketSnap.data == true;
            // Nur "Ich komme" oder zahlende Gäste dürfen bewerten.
            // "Vielleicht" reicht ausdrücklich NICHT mehr.
            if (isComing || hasPaidTicket) return _ratingButtons(context);
            return const SizedBox.shrink();
          },
        );
      },
    );
  }

  Widget _ratingButtons(BuildContext context) {
    final canRate = currentUsername != null && _uid() != null;
    final myUid = _uid();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: ratingsStream(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        final good = docs.where((d) => d.data()['value'] == 'good').length;
        final bad  = docs.where((d) => d.data()['value'] == 'bad').length;

        QueryDocumentSnapshot<Map<String, dynamic>>? myDoc;
        if (myUid != null) {
          for (final d in docs) {
            if (d.id == myUid) { myDoc = d; break; }
          }
        }
        final hasRated = myDoc != null;
        final myValue  = myDoc?.data()['value']?.toString();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionLabel("Bewertung (24h ab Partybeginn)"),
            const SizedBox(height: 10),
            if (hasRated)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.success.withAlpha(22),
                  borderRadius: AppRadius.smBr,
                  border: Border.all(color: AppColors.success.withAlpha(90)),
                ),
                child: Row(
                  children: [
                    Icon(
                      myValue == 'good'
                          ? Icons.thumb_up_rounded
                          : Icons.thumb_down_rounded,
                      color: AppColors.success,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        "Danke für deine Bewertung!",
                        style: TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                      elevation: 0,
                    ),
                    onPressed: canRate ? () => _setRatingViaFunction(context, 'good') : null,
                    icon: const Icon(Icons.thumb_up_outlined, size: 16),
                    label: const Text("Gut", style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                      elevation: 0,
                    ),
                    onPressed: canRate ? () => _setRatingViaFunction(context, 'bad') : null,
                    icon: const Icon(Icons.thumb_down_outlined, size: 16),
                    label: const Text("Schlecht", style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            const SizedBox(height: 8),
            Text(
              "$good positiv · $bad negativ",
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
        );
      },
    );
  }

  // ── Kick user ───────────────────────────────────────────────────────────────

  Future<void> _confirmKickUser(BuildContext context, String username) async {
    final cleanUser = username.trim();
    if (cleanUser.isEmpty || cleanUser == 'Unbekannt') return;

    final isFriendsOnly = (data['type'] ?? '').toString() == 'Only4Friends';

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.panel,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.lgBr,
              side: const BorderSide(color: AppColors.accentBorder),
            ),
            title: const Text("Person ausladen?", style: TextStyle(color: AppColors.text)),
            content: Text(
              "Möchtest du \"$cleanUser\" wirklich ausladen?",
              style: const TextStyle(color: AppColors.muted),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text("Abbrechen", style: TextStyle(color: AppColors.muted)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text("Ausladen", style: TextStyle(color: AppColors.accent)),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    try {
      final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        for (final sub in ['rsvps', 'coming', 'maybe', 'approved']) {
          tx.delete(partyRef.collection(sub).doc(cleanUser));
        }
        final reqRef1 = partyRef.collection('requests').doc(cleanUser);
        final reqRef2 = partyRef.collection('requests').doc(safeDocId(cleanUser));
        tx.delete(reqRef1);
        if (reqRef2.id != reqRef1.id) tx.delete(reqRef2);

        tx.set(partyRef, {'approvedUsers': FieldValue.arrayRemove([cleanUser])}, SetOptions(merge: true));
        if (isFriendsOnly) {
          tx.set(partyRef, {'excludedFriends': FieldValue.arrayUnion([cleanUser])}, SetOptions(merge: true));
        }
      });
      showStatusSnack(context, "\"$cleanUser\" wurde ausgeladen.", positive: true);
    } catch (e) {
      showStatusSnack(context, "Fehler: $e", positive: false);
    }
  }

  // ── Images ──────────────────────────────────────────────────────────────────

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
            } else if (it is String && it.trim().isNotEmpty) {
              imgs.add(it.trim());
            }
          }
        }
        if (caption.isNotEmpty || imgs.isNotEmpty) blocks.add(_UiImageBlock(caption: caption, urls: imgs));
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
          } else if (it is String && it.trim().isNotEmpty) {
            urls.add(it.trim());
          }
        }
        if (caption.isNotEmpty || urls.isNotEmpty) blocks.add(_UiImageBlock(caption: caption, urls: urls));
      }
    }
    return blocks;
  }

  Widget _imagesSection(Map<String, dynamic> partyData) {
    final blocks = _extractImageBlocks(partyData);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel("Bilder"),
          const SizedBox(height: 10),
          ...List.generate(blocks.length, (i) {
            final b = blocks[i];
            return Padding(
              padding: EdgeInsets.only(bottom: i < blocks.length - 1 ? 12 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (b.caption.isNotEmpty) ...[
                    Text(b.caption, style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                  ],
                  if (b.urls.isNotEmpty)
                    SizedBox(
                      height: 120,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: b.urls.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (ctx, idx) => _imageThumb(ctx, b.urls[idx]),
                      ),
                    ),
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
        borderRadius: AppRadius.mdBr,
        child: Container(
          width: 160,
          height: 120,
          color: AppColors.panelAlt,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            // Thumb ist 160 × 120 — bei DPR 3 reichen 480 px → spart bis zu 90 % RAM
            memCacheWidth: 480,
            memCacheHeight: 360,
            maxWidthDiskCache: 800,
            placeholder: (_, __) => const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted))),
            errorWidget: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, color: AppColors.subtle)),
          ),
        ),
      ),
    );
  }

  void _openImageViewer(BuildContext context, String url) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withAlpha(235),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(14),
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4,
            child: ClipRRect(
              borderRadius: AppRadius.mdBr,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, __, ___) => Container(
                  color: AppColors.panel,
                  padding: const EdgeInsets.all(18),
                  child: const Center(child: Icon(Icons.broken_image_outlined, color: AppColors.muted, size: 36)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── BUILD ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final typeStr    = (data['type'] ?? (isClosed ? 'Closed' : 'Open')).toString();
    final isFriendsOnly = typeStr == 'Only4Friends';
    final canSeeFull = isFriendsOnly ? true : (!isClosed || baseCanSeeFull);

    final hostNameStr = (data['hostName'] ?? '').toString();
    final hostIdStr   = (data['hostId']   ?? '').toString();
    final hostLabel   = isHost ? "$hostNameStr (du)" : hostNameStr;

    // Type badge
    final Color badgeColor, badgeFg;
    final IconData badgeIcon;
    final String badgeLabel;
    if (isFriendsOnly) {
      badgeColor = AppColors.teal.withAlpha(30);
      badgeFg    = AppColors.teal;
      badgeIcon  = Icons.group_rounded;
      badgeLabel = "Only4Friends";
    } else if (isClosed) {
      badgeColor = AppColors.accent.withAlpha(25);
      badgeFg    = AppColors.accent;
      badgeIcon  = Icons.lock_rounded;
      badgeLabel = "Closed";
    } else {
      badgeColor = AppColors.success.withAlpha(25);
      badgeFg    = AppColors.success;
      badgeIcon  = Icons.public_rounded;
      badgeLabel = "Open";
    }

    // ── Info chip ──────────────────────────────────────────────────────────
    Widget infoChip(IconData icon, String label, String value) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: AppRadius.mdBr,
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(icon, color: AppColors.accent, size: 13),
              const SizedBox(width: 4),
              Expanded(
                child: Text(value,
                    style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ],
        ),
      ),
    );

    final minAge     = (data['minAge']?.toString() ?? '').trim();
    final guestLimit = (data['guestLimit']?.toString() ?? '').trim();
    final price      = data['price'];
    final address    = (data['address'] ?? '—').toString();
    final description = (data['description'] ?? '').toString().trim();

    // ── Full details ───────────────────────────────────────────────────────
    final fullDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          infoChip(Icons.calendar_today_rounded, "Datum", formattedDate),
          const SizedBox(width: 8),
          infoChip(Icons.schedule_rounded, "Uhrzeit", (data['time'] ?? '—').toString()),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          infoChip(Icons.euro_rounded, "Eintritt", (price == null || price == 0) ? "Gratis" : "${price}€"),
          const SizedBox(width: 8),
          infoChip(Icons.cake_outlined, "Alter", minAge.isEmpty ? '—' : '${minAge}+'),
          const SizedBox(width: 8),
          infoChip(Icons.group_rounded, "Limit", guestLimit.isEmpty ? '∞' : guestLimit),
        ]),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: AppRadius.mdBr,
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Beschreibung', style: TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
                const SizedBox(height: 4),
                Text(description, style: const TextStyle(color: AppColors.text, fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.mdBr,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Adresse', style: TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.location_on_rounded, color: AppColors.accent, size: 13),
                const SizedBox(width: 4),
                Expanded(child: Text(address, style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 13))),
              ]),
            ],
          ),
        ),
      ],
    );

    // ── Partial (locked) — alles außer Adresse sichtbar ──────────────────
    final closedPartial = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          infoChip(Icons.calendar_today_rounded, "Datum", formattedDate),
          const SizedBox(width: 8),
          infoChip(Icons.schedule_rounded, "Uhrzeit", (data['time'] ?? '—').toString()),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          infoChip(Icons.euro_rounded, "Eintritt", (price == null || price == 0) ? "Gratis" : "${price}€"),
          const SizedBox(width: 8),
          infoChip(Icons.cake_outlined, "Alter", minAge.isEmpty ? '—' : '${minAge}+'),
          const SizedBox(width: 8),
          infoChip(Icons.group_rounded, "Limit", guestLimit.isEmpty ? '∞' : guestLimit),
        ]),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: AppRadius.mdBr,
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Beschreibung', style: TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
                const SizedBox(height: 4),
                Text(description, style: const TextStyle(color: AppColors.text, fontSize: 13, height: 1.5)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.mdBr,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Adresse', style: TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              const SizedBox(height: 4),
              const Row(children: [
                Text('🔒', style: TextStyle(fontSize: 13)),
                SizedBox(width: 6),
                Expanded(child: Text("Erst nach Freigabe sichtbar.", style: TextStyle(color: AppColors.subtle, fontSize: 13))),
              ]),
            ],
          ),
        ),
      ],
    );

    // ── Delete dialog ──────────────────────────────────────────────────────
    Future<void> confirmDelete() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.panel,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.lgBr, side: const BorderSide(color: AppColors.accentBorder)),
          title: const Text("Party löschen?", style: TextStyle(color: AppColors.text)),
          content: const Text("Alle Zusagen, Anfragen und Bewertungen gehen verloren.", style: TextStyle(color: AppColors.muted)),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text("Abbrechen", style: TextStyle(color: AppColors.muted))),
            TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text("Löschen", style: TextStyle(color: AppColors.accent))),
          ],
        ),
      ) ?? false;

      if (!ok) return;
      try {
        final partyRef = FirebaseFirestore.instance.collection('Party').doc(partyId);
        final batch = FirebaseFirestore.instance.batch();
        for (final sub in ['rsvps', 'coming', 'maybe', 'requests', 'approved', 'ratings']) {
          final qs = await partyRef.collection(sub).get();
          for (final doc in qs.docs) batch.delete(doc.reference);
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

    return AppDraggableSheet(
      panelColor: AppColors.bgTop,
      borderColor: AppColors.border,
      childBuilder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [

            // ── Party name ───────────────────────────────────────────────
            Text(
              (data['name'] ?? (isClosed ? "Geschlossene Party" : "Party")).toString(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.text, letterSpacing: -0.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),

            // ── Type badge + host chip ───────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Type badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: AppRadius.fullBr,
                    border: Border.all(color: badgeFg.withAlpha(60)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(badgeIcon, color: badgeFg, size: 13),
                    const SizedBox(width: 5),
                    Text(badgeLabel, style: TextStyle(color: badgeFg, fontWeight: FontWeight.w700, fontSize: 12)),
                  ]),
                ),
                const SizedBox(width: 8),
                // Host chip — tappable → profile
                GestureDetector(
                  onTap: () => _showHostProfile(context, hostIdStr.isNotEmpty ? hostIdStr : hostNameStr, displayName: hostNameStr),
                  child: FutureBuilder<bool>(
                    future: isUserVerified(hostNameStr),
                    builder: (context, snap) {
                      final verified = snap.data == true;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.accentBorder,
                          borderRadius: AppRadius.fullBr,
                          border: Border.all(color: AppColors.accentBorder2),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            verified ? Icons.verified_rounded : Icons.mic_rounded,
                            color: AppColors.accent,
                            size: 13,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            hostLabel,
                            style: const TextStyle(color: AppColors.muted, fontWeight: FontWeight.w600, fontSize: 12),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // ── Status pill ──────────────────────────────────────────────
            if (isFriendsOnly)
              _pill("Nur für Freunde sichtbar.", AppColors.teal)
            else if (isClosed && canSeeFull)
              _pill("Zugang freigegeben – alle Details sichtbar.", AppColors.success),
            if (isFriendsOnly || isClosed) const SizedBox(height: 14),

            // ── Details ──────────────────────────────────────────────────
            if (canSeeFull) fullDetails else closedPartial,

            // ── Images ───────────────────────────────────────────────────
            if (canSeeFull) _imagesSection(data),

            const SizedBox(height: 16),

            // ── Friends ──────────────────────────────────────────────────
            _friendsGoingSection(context),

            // ── Divider ──────────────────────────────────────────────────
            const Divider(color: AppColors.border),
            const SizedBox(height: 16),

            // ── Host view ────────────────────────────────────────────────
            if (isHost) ...[
              if (isClosed && !isFriendsOnly)
                _hostClosedLists(context)
              else
                _hostOpenLists(context),
              const SizedBox(height: 16),
              if (data['ticketsEnabled'] == true) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: const Text(
                      "Tickets scannen",
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TicketScannerScreen(
                            partyId: partyId,
                            partyName: (data['name'] ?? 'Party').toString(),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                    elevation: 0,
                  ),
                  icon: const Icon(Icons.edit_rounded, size: 17),
                  label: const Text("Party bearbeiten", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => NewPartyScreen(existingData: data, docId: partyId)),
                    );
                    await onEditedParty();
                  },
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: AppColors.accent, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16)),
                  onPressed: confirmDelete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text("Party löschen", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),

            // ── Guest view ───────────────────────────────────────────────
            ] else ...[
              // Bezahlte Party: ausschließlich Ticketkauf — kein RSVP.
              // Gratis Party: ausschließlich RSVP — keine Ticket-Option.
              if (data['ticketsEnabled'] == true) ...[
                if (canSeeFull && isActive)
                  TicketPurchaseSection(partyId: partyId, partyData: data)
                else if (!isClosed || isFriendsOnly)
                  // Closed-Party-Hinweis (Anfrage stellen) bleibt erhalten,
                  // damit der User überhaupt Zugang bekommt.
                  _guestClosedActions(context),
              ] else ...[
                if (!isClosed || isFriendsOnly)
                  _guestOpenActions(context)
                else if (canSeeFull)
                  const SizedBox.shrink()
                else
                  _guestClosedActions(context),
              ],

              // Rating
              const SizedBox(height: 12),
              _ratingGate(context),

              // Report
              if (isActive) ...[
                const SizedBox(height: 4),
                Center(
                  child: TextButton.icon(
                    onPressed: onReport,
                    icon: const Icon(Icons.flag_outlined, size: 14, color: AppColors.subtle),
                    label: const Text("Melden", style: TextStyle(color: AppColors.subtle, fontSize: 12)),
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 8)),
                  ),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  // ── Guest Open ──────────────────────────────────────────────────────────────

  Widget _guestOpenActions(BuildContext context) {
    if (isBarAccount && !isHost) {
      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: comingStream(),
        builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: maybeStream(),
          builder: (context, ms) {
            final cCount = (cs.data?.docs ?? []).length;
            final mCount = (ms.data?.docs ?? []).length;
            return _attendanceCounter(cCount, mCount);
          },
        ),
      );
    }

    if (currentUsername == null) {
      return _pill("Bitte Username setzen, um zuzusagen.", AppColors.accent);
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
              icon: Icons.check_circle_outline_rounded,
              active: isGoing,
              activeColor: AppColors.success,
              onTap: () async {
                try {
                  if (isGoing) {
                    await onClearRsvp();
                    if (!context.mounted) return;
                    showStatusSnack(context, "Zusage zurückgezogen.", positive: true);
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('going');
                    if (!context.mounted) return;
                    showStatusSnack(context, "Ich komme!", positive: true);
                    recolorOpenMarker('going');
                  }
                } catch (e) {
                  if (context.mounted) showStatusSnack(context, "Fehler: $e", positive: false);
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
                try {
                  if (isMaybe) {
                    await onClearRsvp();
                    if (!context.mounted) return;
                    showStatusSnack(context, "Vielleicht zurückgezogen.", positive: true);
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('maybe');
                    if (!context.mounted) return;
                    showStatusSnack(context, "Ich komme eventuell.", positive: true);
                    recolorOpenMarker('maybe');
                  }
                } catch (e) {
                  if (context.mounted) showStatusSnack(context, "Fehler: $e", positive: false);
                }
              },
            ),
          ),
        ]),
        const SizedBox(height: 10),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: comingStream(),
          builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: maybeStream(),
            builder: (context, ms) => _attendanceCounter(
              (cs.data?.docs ?? []).length,
              (ms.data?.docs ?? []).length,
            ),
          ),
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
          color: active ? activeColor.withAlpha(35) : AppColors.panelAlt,
          borderRadius: AppRadius.smBr,
          border: Border.all(color: active ? activeColor.withAlpha(160) : AppColors.border),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: active ? activeColor : AppColors.subtle, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? activeColor : AppColors.muted,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _attendanceCounter(int coming, int maybe) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.panelAlt,
      borderRadius: AppRadius.smBr,
      border: Border.all(color: AppColors.border),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.people_rounded, color: AppColors.subtle, size: 14),
      const SizedBox(width: 6),
      Text(
        "$coming kommen  ·  $maybe vielleicht",
        style: const TextStyle(color: AppColors.muted, fontSize: 13),
      ),
    ]),
  );

  // ── Guest Closed ────────────────────────────────────────────────────────────

  Widget _guestClosedActions(BuildContext context) {
    if (currentUsername == null) {
      return _pill("Bitte Username setzen, um eine Anfrage zu senden.", AppColors.accent);
    }

    final uid      = _uid();
    final uname    = currentUsername!.trim();
    final safeUname = safeDocId(uname);

    Stream<DocumentSnapshot<Map<String, dynamic>>> reqStream(String docId) {
      if (docId.trim().isEmpty) return const Stream.empty();
      return FirebaseFirestore.instance
          .collection('Party').doc(partyId)
          .collection('requests').doc(docId)
          .snapshots();
    }

    Widget requestStatusBuilder({required Widget Function(String? status) builder}) {
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: uid == null ? const Stream.empty() : reqStream(uid),
        builder: (context, s1) {
          final st1 = s1.data?.data()?['status'] as String?;
          if (s1.data?.exists == true && st1 != null) return builder(st1);

          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: reqStream(uname),
            builder: (context, s2) {
              final st2 = s2.data?.data()?['status'] as String?;
              if (s2.data?.exists == true && st2 != null) return builder(st2);

              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: reqStream(safeUname),
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
      builder: (context, setState) => requestStatusBuilder(
        builder: (statusFromDb) {
          final status = statusFromDb ?? (localPending ? 'pending' : null);

          if (status == 'pending') {
            SchedulerBinding.instance.addPostFrameCallback((_) => setClosedLockIcon('pending'));
            return _statusCard(
              icon: Icons.hourglass_top_rounded,
              iconColor: Colors.orangeAccent,
              title: "Anfrage gesendet",
              subtitle: "Warte auf Antwort des Hosts.",
              bgColor: Colors.orangeAccent.withAlpha(20),
              borderColor: Colors.orangeAccent.withAlpha(60),
            );
          }

          if (status == 'approved') {
            SchedulerBinding.instance.addPostFrameCallback((_) => setClosedLockIcon('approved'));
            return _statusCard(
              icon: Icons.check_circle_rounded,
              iconColor: AppColors.success,
              title: "Zugang genehmigt",
              subtitle: "Du kannst jetzt alle Party-Details sehen.",
              bgColor: AppColors.success.withAlpha(20),
              borderColor: AppColors.success.withAlpha(60),
            );
          }

          if (status == 'declined') {
            SchedulerBinding.instance.addPostFrameCallback((_) => setClosedLockIcon('declined'));
            return _statusCard(
              icon: Icons.cancel_rounded,
              iconColor: AppColors.accent,
              title: "Anfrage abgelehnt",
              subtitle: "Du kannst den Host direkt kontaktieren.",
              bgColor: AppColors.accent.withAlpha(18),
              borderColor: AppColors.accent.withAlpha(60),
            );
          }

          // null — send request
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
              onPressed: () async {
                try {
                  setState(() => localPending = true);
                  await onSendJoinRequest();
                  if (!context.mounted) return;
                  showStatusSnack(context, "Anfrage gesendet – warte auf Antwort.", positive: true);
                  setClosedLockIcon('pending');
                } catch (e) {
                  setState(() => localPending = false);
                  if (context.mounted) showStatusSnack(context, "Fehler: $e", positive: false);
                }
              },
              icon: const Icon(Icons.lock_open_rounded, size: 17),
              label: const Text("Anfrage senden", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          );
        },
      ),
    );
  }

  static Widget _statusCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Color bgColor,
    required Color borderColor,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: AppRadius.mdBr,
          border: Border.all(color: borderColor),
        ),
        child: Row(children: [
          Icon(icon, color: iconColor, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: iconColor, fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 3),
              Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            ]),
          ),
        ]),
      );

  // ── Host closed lists ───────────────────────────────────────────────────────

  Widget _hostClosedLists(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pending requests
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party').doc(partyId)
              .collection('requests')
              .where('status', isEqualTo: 'pending')
              .snapshots(),
          builder: (context, reqsSnap) {
            final docs = (reqsSnap.data?.docs ?? [])
              ..sort((a, b) {
                final ta = a.data()['timestamp'];
                final tb = b.data()['timestamp'];
                return (ta is Timestamp && tb is Timestamp) ? tb.compareTo(ta) : 0;
              });

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel("Anfragen (${docs.length})"),
                const SizedBox(height: 10),
                if (docs.isEmpty)
                  _emptyLabel("Keine offenen Anfragen.")
                else
                  ...docs.map((d) {
                    final user = d.data()['username']?.toString() ?? 'Unbekannt';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.panelAlt,
                        borderRadius: AppRadius.mdBr,
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.person_outline_rounded, color: AppColors.muted, size: 16),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(user,
                                  style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 14),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.success,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                                  elevation: 0,
                                ),
                                onPressed: () => onUpdateRequestStatus(user, 'approved'),
                                child: const Text("Zulassen", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.accent,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                                  elevation: 0,
                                ),
                                onPressed: () => onUpdateRequestStatus(user, 'declined'),
                                child: const Text("Ablehnen", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    );
                  }),
              ],
            );
          },
        ),

        const SizedBox(height: 20),

        // Approved list
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party').doc(partyId)
              .collection('approved')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, apprSnap) {
            final names = (apprSnap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel("Zugelassen (${names.length})"),
                const SizedBox(height: 10),
                if (names.isEmpty)
                  _emptyLabel("Noch niemand zugelassen.")
                else
                  ...names.map((u) => Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.panelAlt,
                      borderRadius: AppRadius.smBr,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(children: [
                      const Icon(Icons.verified_user_rounded, color: AppColors.success, size: 15),
                      const SizedBox(width: 8),
                      Expanded(child: Text(u,
                          style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 14),
                          overflow: TextOverflow.ellipsis)),
                      GestureDetector(
                        onTap: () => _confirmKickUser(context, u),
                        child: const Icon(Icons.close_rounded, color: AppColors.accent, size: 18),
                      ),
                    ]),
                  )),
              ],
            );
          },
        ),
      ],
    );
  }

  // ── Host open lists ─────────────────────────────────────────────────────────

  Widget _hostOpenLists(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party').doc(partyId)
              .collection('coming')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, snap) {
            final names = (snap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();
            return _userList(
              context: context,
              label: "Kommen (${names.length})",
              dotColor: AppColors.success,
              names: names,
            );
          },
        ),
        const SizedBox(height: 20),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party').doc(partyId)
              .collection('maybe')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, snap) {
            final names = (snap.data?.docs ?? [])
                .map((d) => d.data()['username']?.toString() ?? 'Unbekannt')
                .toList();
            return _userList(
              context: context,
              label: "Vielleicht (${names.length})",
              dotColor: Colors.orangeAccent,
              names: names,
            );
          },
        ),
      ],
    );
  }

  Widget _userList({
    required BuildContext context,
    required String label,
    required Color dotColor,
    required List<String> names,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(label),
        const SizedBox(height: 10),
        if (names.isEmpty)
          _emptyLabel("Noch niemand.")
        else
          ...names.map((u) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.panelAlt,
              borderRadius: AppRadius.smBr,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(u,
                  style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 14),
                  overflow: TextOverflow.ellipsis)),
              GestureDetector(
                onTap: () => _confirmKickUser(context, u),
                child: const Icon(Icons.close_rounded, color: AppColors.accent, size: 18),
              ),
            ]),
          )),
      ],
    );
  }

  // ── Static helpers ──────────────────────────────────────────────────────────

  static Widget _sectionLabel(String label) => Text(
    label.toUpperCase(),
    style: const TextStyle(color: AppColors.subtle, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8),
  );

  static Widget _emptyLabel(String text) => Text(
    text,
    style: const TextStyle(color: AppColors.subtle, fontSize: 13),
  );

  static Widget _pill(String text, Color c) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: c.withAlpha(20),
      borderRadius: AppRadius.smBr,
      border: Border.all(color: c.withAlpha(70)),
    ),
    child: Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w500, fontSize: 13)),
  );

}

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

class _UiImageBlock {
  final String caption;
  final List<String> urls;
  const _UiImageBlock({required this.caption, required this.urls});
}
