// lib/widgets/party_bottom_sheet.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../Screens/new_party.dart';

typedef VoidAsync = Future<void> Function();
typedef StringAsync = Future<void> Function(String value);
typedef UserStatusAsync = Future<void> Function(String user, String status);
typedef VerifyFn = Future<bool> Function(String username);
typedef DocStream = Stream<DocumentSnapshot<Map<String, dynamic>>>?;
typedef QStream = Stream<QuerySnapshot<Map<String, dynamic>>>?;

String safeDocId(String input) =>
    input.trim().replaceAll('/', '_').replaceAll('#', '_').replaceAll('?', '_');

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

  @override
  Widget build(BuildContext context) {
    final canSeeFull = !isClosed || baseCanSeeFull;

    // -------- Party löschen (nur Host) --------
    Future<void> _confirmAndDeleteParty() async {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            "Party löschen?",
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            "Willst du diese Party wirklich löschen? Alle Zusagen, Anfragen und Bewertungen gehen verloren.",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                "Abbrechen",
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                "Löschen",
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        ),
      ) ??
          false;

      if (!confirm) return;

      try {
        final partyRef =
        FirebaseFirestore.instance.collection('Party').doc(partyId);
        final batch = FirebaseFirestore.instance.batch();

        const subCollections = [
          'rsvps',
          'coming',
          'maybe',
          'requests',
          'approved',
          'ratings',
        ];

        for (final sub in subCollections) {
          final qs = await partyRef.collection(sub).get();
          for (final doc in qs.docs) {
            batch.delete(doc.reference);
          }
        }

        batch.delete(partyRef);
        await batch.commit();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Party gelöscht.")),
        );

        await onEditedParty();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Fehler beim Löschen: $e")),
        );
      }
    }

    Widget infoRow(IconData ic, String label, String value) => Row(
      children: [
        Icon(ic, color: Colors.white70, size: 18),
        const SizedBox(width: 8),
        Text("$label: ",
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w600)),
        Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white70))),
      ],
    );

    final Widget fullDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoRow(Icons.event, "🗓️ Datum", formattedDate),
              const SizedBox(height: 8),
              infoRow(Icons.schedule, "⏰ Uhrzeit",
                  (data['time'] ?? '—').toString()),
              const SizedBox(height: 8),
              infoRow(Icons.people, "👥 Gästelimit",
                  (data['guestLimit'] ?? '—').toString()),
              const SizedBox(height: 8),
              infoRow(Icons.euro, "💶 Preis", "${(data['price'] ?? '—')}€"),
              const SizedBox(height: 8),
              infoRow(
                  Icons.cake_outlined,
                  "🔞 Mindestalter",
                  ((data['minAge']?.toString() ?? '').isEmpty
                      ? '—'
                      : data['minAge'].toString())),
              const SizedBox(height: 8),
              infoRow(Icons.place, "📍 Adresse",
                  (data['address'] ?? '—').toString()),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if ((data['description'] ?? '').toString().trim().isNotEmpty)
          _box(
            child: Text(
              "📝 Beschreibung:\n${data['description']}",
              style: const TextStyle(color: Colors.white70, height: 1.35),
            ),
          ),
      ],
    );

    final Widget closedPartial = _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          infoRow(Icons.event, "🗓️ Datum", formattedDate),
          const SizedBox(height: 8),
          infoRow(
              Icons.cake_outlined,
              "🔞 Mindestalter",
              ((data['minAge']?.toString() ?? '').isEmpty
                  ? '—'
                  : data['minAge'].toString())),
          const SizedBox(height: 12),
          const Text(
            "Weitere Details sind verborgen, bis der Host dich zulässt.",
            style: TextStyle(color: Colors.white54, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );

    final hostNameStr = (data['hostName'] ?? '').toString();
    final hostLabel = isHost ? "$hostNameStr (du)" : hostNameStr;

    return Container(
      width: MediaQuery.of(context).size.width,
      height: MediaQuery.of(context).size.height * 0.80,
      padding: const EdgeInsets.all(22),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                        color: Colors.grey[700],
                        borderRadius: BorderRadius.circular(10)))),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    data['name'] ??
                        (isClosed ? "Geschlossene Party" : "Party"),
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color:
                    isClosed ? Colors.blueGrey[800] : Colors.green[800],
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    children: [
                      Icon(isClosed ? Icons.lock : Icons.public,
                          color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Text(isClosed ? "Closed" : "Open",
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FutureBuilder<bool>(
              future: isUserVerified(hostNameStr),
              builder: (context, snap) {
                final isVerified = snap.data == true;
                return Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: Colors.indigo[700],
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isVerified) ...[
                        const Icon(Icons.verified,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                      ],
                      Text("Host: $hostLabel",
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            if (isClosed && !canSeeFull)
              _pill("🔒 Geschlossene Party – nur Datum & Mindestalter sichtbar.",
                  Colors.redAccent)
            else if (isClosed && canSeeFull)
              _pill("✅ Zugriff freigegeben – alle Details sichtbar.",
                  Colors.lightGreenAccent),
            const SizedBox(height: 16),
            if (canSeeFull) fullDetails else closedPartial,
            const SizedBox(height: 20),
            const Divider(color: Color(0x33FFFFFF)),
            const SizedBox(height: 12),

            // ---------- Host vs Guest UI ----------
            if (isHost) ...[
              if (isClosed)
                _hostClosedLists(context)
              else
                _hostOpenLists(context),
              const SizedBox(height: 16),
              Center(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        backgroundColor: Colors.orangeAccent,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("Bearbeiten",
                          style: TextStyle(fontSize: 18)),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => NewPartyScreen(
                              existingData: data,
                              docId: partyId,
                            ),
                          ),
                        );
                        await onEditedParty();
                      },
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        foregroundColor: Colors.redAccent,
                      ),
                      onPressed: _confirmAndDeleteParty,
                      icon: const Icon(Icons.delete_forever,
                          color: Colors.redAccent),
                      label: const Text(
                        "Party löschen",
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              if (!isClosed)
                _guestOpenActions(context)
              else
                _guestClosedActions(context),
              if (inRatingWindow) ...[
                const SizedBox(height: 12),
                _ratingButtons(context),
              ],
              if (isActive) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onReport,
                  icon: const Icon(Icons.flag, color: Colors.redAccent),
                  label: const Text("Party melden",
                      style: TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      minimumSize: const Size.fromHeight(44)),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // ---------- Guest Open ----------
  Widget _guestOpenActions(BuildContext context) {
    if (currentUsername == null) {
      return const Text(
        "Bitte in den Einstellungen Vor- & Nachname setzen, um zuzusagen.",
        style: TextStyle(color: Colors.redAccent),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: rsvpStream(),
      builder: (context, snap) {
        final map = snap.data?.data();
        final status = map == null ? null : map['status'] as String?;
        final isGoing = status == 'going';
        final isMaybe = status == 'maybe';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor:
                  isGoing ? Colors.green : Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: () async {
                if (currentUsername == null) return;
                try {
                  if (isGoing) {
                    await onClearRsvp();
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Zusage zurückgezogen.")));
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('going');
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text("Status: Ich komme ✅")));
                    recolorOpenMarker('going');
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text("Fehler: $e")));
                }
              },
              icon: const Icon(Icons.check_circle),
              label: const Text("Ich komme"),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor:
                  isMaybe ? Colors.green : Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: () async {
                if (currentUsername == null) return;
                try {
                  if (isMaybe) {
                    await onClearRsvp();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text("„Vielleicht“ zurückgezogen.")));
                    recolorOpenMarker(null);
                  } else {
                    await onSetRsvp('maybe');
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text("Status: Ich komme eventuell 👍")));
                    recolorOpenMarker('maybe');
                  }
                } catch (e) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text("Fehler: $e")));
                }
              },
              icon: const Icon(Icons.help_outline),
              label: const Text("Ich komme eventuell"),
            ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: comingStream(),
              builder: (context, cs) {
                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: maybeStream(),
                  builder: (context, ms) {
                    final cCount = (cs.data?.docs ?? []).length;
                    final mCount = (ms.data?.docs ?? []).length;
                    return _counter("🔔 $cCount kommen · $mCount vielleicht");
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }

  // ---------- Guest Closed ----------
  Widget _guestClosedActions(BuildContext context) {
    if (currentUsername == null) {
      return const Text(
        "Bitte in den Einstellungen Vor- & Nachname setzen, um eine Anfrage zu senden.",
        style: TextStyle(color: Colors.redAccent),
      );
    }
    final reqDocId = safeDocId(currentUsername!);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('Party')
          .doc(partyId)
          .collection('requests')
          .doc(reqDocId)
          .snapshots(),
      builder: (context, myReqSnap) {
        String? status;
        if (myReqSnap.hasData &&
            myReqSnap.data != null &&
            myReqSnap.data!.exists) {
          final map = myReqSnap.data!.data();
          status = map == null ? null : map['status'] as String?;
          if (status == 'approved' ||
              status == 'declined' ||
              status == 'pending') {
            final s = status;
            SchedulerBinding.instance.addPostFrameCallback((_) {
              setClosedLockIcon(s);
            });
          }
        } else {
          status = null;
        }

        if (status == null) {
          return ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            onPressed: () async {
              try {
                await onSendJoinRequest();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("Anfrage gesendet – warte auf Antwort")));
                setClosedLockIcon('pending');
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text("Fehler: $e")));
              }
            },
            icon: const Icon(Icons.lock_open_rounded),
            label:
            const Text("Anfrage senden", style: TextStyle(fontSize: 18)),
          );
        } else if (status == 'pending') {
          return _pill("Anfrage gesendet – warte auf Antwort", Colors.green);
        } else if (status == 'approved') {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const ListTile(
                leading: Icon(Icons.check_circle, color: Colors.greenAccent),
                title: Text("Zugang genehmigt – Details freigeschaltet.",
                    style: TextStyle(color: Colors.white)),
                subtitle: Text("Du kannst jetzt alle Infos sehen.",
                    style: TextStyle(color: Colors.white70)),
              ),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('Party')
                    .doc(partyId)
                    .collection('approved')
                    .snapshots(),
                builder: (context, snap) {
                  final count = snap.data?.docs.length ?? 0;
                  return _counter("🔔 $count zugelassen");
                },
              ),
            ],
          );
        } else {
          return const ListTile(
            leading: Icon(Icons.cancel, color: Colors.redAccent),
            title: Text("Anfrage abgelehnt",
                style: TextStyle(color: Colors.white)),
            subtitle: Text("Du kannst den Host direkt kontaktieren.",
                style: TextStyle(color: Colors.white70)),
          );
        }
      },
    );
  }

  // ---------- Host-Listen ----------
  Widget _hostClosedLists(BuildContext context) {
    return Column(
      children: [
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
            return _bigList(
                "✅ Zugelassen",
                Icons.verified_user,
                Colors.lightGreenAccent,
                names,
                Icons.verified_user,
                Colors.lightGreenAccent);
          },
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('Party')
              .doc(partyId)
              .collection('requests')
              .orderBy('timestamp', descending: true)
              .snapshots(),
          builder: (context, reqsSnap) {
            final docs = reqsSnap.data?.docs ?? [];
            if (docs.isEmpty) {
              return _boxed(const Text("Keine Anfragen.",
                  style: TextStyle(color: Colors.white70)));
            }
            return _boxed(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.pending_actions,
                        color: Colors.orangeAccent, size: 20),
                    SizedBox(width: 8),
                    Text("🛎️ Zugangs-Anfragen",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 10),
                  ...docs.map((d) {
                    final m = d.data();
                    final user =
                        m['username']?.toString() ?? 'Unbekannt';
                    final status = (m['status']?.toString() ?? 'pending');
                    Color statusColor = status == 'approved'
                        ? Colors.lightGreenAccent
                        : status == 'declined'
                        ? Colors.redAccent
                        : Colors.orangeAccent;
                    return Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.grey[850],
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.grey[700]!),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4)
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                Text(user,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 18)),
                                const SizedBox(height: 4),
                                Text("Status: $status",
                                    style: TextStyle(color: statusColor)),
                              ],
                            ),
                          ),
                          if (status == 'pending') ...[
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white),
                              onPressed: () =>
                                  onUpdateRequestStatus(user, 'approved'),
                              child: const Text("Zulassen"),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white),
                              onPressed: () =>
                                  onUpdateRequestStatus(user, 'declined'),
                              child: const Text("Ablehnen"),
                            ),
                          ] else if (status == 'declined') ...[
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white),
                              onPressed: () =>
                                  onUpdateRequestStatus(user, 'approved'),
                              child: const Text("Zulassen"),
                            ),
                          ] else ...[
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white),
                              onPressed: () =>
                                  onUpdateRequestStatus(user, 'declined'),
                              child: const Text("Ablehnen"),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
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
                Colors.greenAccent);
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
                Colors.orangeAccent);
          },
        ),
      ],
    );
  }

  // ---------- Rating ----------
  Widget _ratingButtons(BuildContext context) {
    final canRate = currentUsername != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        const Text("Bewerten (24h ab Partybeginn)",
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44)),
                onPressed:
                canRate ? () async => await onSetRating('good') : null,
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
                    minimumSize: const Size.fromHeight(44)),
                onPressed:
                canRate ? () async => await onSetRating('bad') : null,
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
                child: Text("⭐ Bewertungen: $good gut · $bad schlecht",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
            );
          },
        ),
      ],
    );
  }

  // ---------- kleine UI-Helfer ----------
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
    padding:
    const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.grey[850],
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey[700]!),
    ),
    child: Text(text,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white70,
            fontSize: 18,
            fontWeight: FontWeight.w700)),
  );

  static Widget _pill(String text, Color c) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
        color: c.withOpacity(.15),
        border: Border.all(color: c.withOpacity(.5)),
        borderRadius: BorderRadius.circular(12)),
    child: Text(text,
        style: TextStyle(
            color: c, fontWeight: FontWeight.w600)),
  );

  Widget _bigList(
      String title,
      IconData titleIcon,
      Color titleColor,
      List<String> usernames,
      IconData rowIcon,
      Color rowIconColor) {
    return _boxed(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(titleIcon, color: titleColor, size: 20),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          if (usernames.isEmpty)
            const Text("Noch niemand",
                style: TextStyle(color: Colors.white70))
          else
            ...List.generate(usernames.length, (i) {
              final u = usernames[i];
              return Column(
                children: [
                  if (i > 0)
                    Divider(
                        color: Colors.grey[800],
                        height: 16,
                        thickness: 1),
                  Row(
                    children: [
                      Icon(rowIcon, color: rowIconColor, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(u,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700))),
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
