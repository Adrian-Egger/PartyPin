// lib/Social/party_activity.dart
//
// Friends & Social Activity Layer — Client-Datenmodell.
//
// Liest die vom Backend (functions/partyActivity/aggregate.js) auf jedem
// Party-Doc geschriebenen Felder:
//   - goingCount        : int
//   - goingRecent       : List<{username, avatarUrl?}>  (max 20)
//   - goingUpdatedAt    : Timestamp
//
// Konsumer (Map/Discovery/Bottom-Sheet) lesen 1 Party-Doc → bekommen
// Anzahl + Avatare. Friend-Intersection passiert client-seitig aus
// einem gecacheten Friend-Set.

import 'package:cloud_firestore/cloud_firestore.dart';

class PartyAttendee {
  const PartyAttendee({
    required this.username,
    this.avatarUrl,
    this.joinedAt,
  });

  final String username;
  final String? avatarUrl;

  /// Wann der User auf "going" geswitcht ist (server-aggregator capture-
  /// time). Optional — legacy Aggregat-Doks haben das Feld nicht.
  /// Wird für client-seitige Momentum-Recomputation gebraucht
  /// (z.B. wenn goingDelta60m als veraltet eingestuft wird, kann der
  /// Client direkt aus den joinedAt-Timestamps neu rechnen).
  final DateTime? joinedAt;

  factory PartyAttendee.fromMap(Map<String, dynamic> m) {
    final av = (m['avatarUrl'] ?? '').toString().trim();
    final ja = m['joinedAt'];
    DateTime? joinedAtDt;
    if (ja is Timestamp) joinedAtDt = ja.toDate();
    return PartyAttendee(
      username: (m['username'] ?? '').toString().trim(),
      avatarUrl: av.isEmpty ? null : av,
      joinedAt: joinedAtDt,
    );
  }
}

class PartyActivity {
  const PartyActivity({
    required this.goingCount,
    required this.goingRecent,
    this.goingDelta60m = 0,
    this.updatedAt,
  });

  /// Anzahl going-RSVPs (Self-Join bereits server-seitig gefiltert).
  final int goingCount;

  /// Bis zu 20 jüngste going-RSVPs mit Username + Avatar.
  final List<PartyAttendee> goingRecent;

  /// Anzahl neuer going-RSVPs in den letzten 60min (server-aggregiert).
  /// 0 wenn nicht vorhanden (legacy). Wird vom Client für Momentum-
  /// Detection genutzt — mit TTL-Schutz via [updatedAt].
  final int goingDelta60m;

  /// Server-Timestamp der letzten Aggregator-Berechnung. Wird genutzt
  /// um abzuschätzen ob `goingDelta60m` noch frisch ist — wenn älter
  /// als 90min, sollte Client den Wert ignorieren (kein neuer Trigger
  /// = stale).
  final DateTime? updatedAt;

  static const PartyActivity empty =
      PartyActivity(goingCount: 0, goingRecent: <PartyAttendee>[]);

  /// Liest die Activity-Felder aus einem Party-Doc-Map. Wenn der
  /// Aggregator noch nicht gelaufen ist (legacy Partys), wird empty
  /// zurückgegeben — UI rendert dann gar nichts statt 0.
  factory PartyActivity.fromPartyData(Map<String, dynamic>? data) {
    if (data == null) return empty;
    final raw = data['goingRecent'];
    final list = (raw is List)
        ? raw
            .whereType<Map>()
            .map((m) => PartyAttendee.fromMap(Map<String, dynamic>.from(m)))
            .where((a) => a.username.isNotEmpty)
            .toList()
        : const <PartyAttendee>[];
    final ua = data['goingUpdatedAt'];
    return PartyActivity(
      goingCount: (data['goingCount'] is num)
          ? (data['goingCount'] as num).toInt()
          : 0,
      goingRecent: list,
      goingDelta60m: (data['goingDelta60m'] is num)
          ? (data['goingDelta60m'] as num).toInt()
          : 0,
      updatedAt: ua is Timestamp ? ua.toDate() : null,
    );
  }

  /// True wenn der Aggregator-Stand frisch genug ist, um Momentum-
  /// Aussagen zu treffen. Wenn `updatedAt` > 90min alt, sollte Client
  /// `goingDelta60m` ignorieren (keine neuen RSVPs heißt Wert eingefroren).
  bool get isMomentumFresh {
    if (updatedAt == null) return false;
    return DateTime.now().difference(updatedAt!) < const Duration(minutes: 90);
  }

  /// Schnittmenge mit einem cached Friend-Set (Usernames). Verwendet
  /// die in goingRecent enthaltenen Usernames — wenn ein Freund unter
  /// den letzten 20 ist, wird er hier gefunden.
  List<PartyAttendee> friendsAmongGoing(Set<String> friendUsernames) {
    if (friendUsernames.isEmpty) return const [];
    return goingRecent.where((a) => friendUsernames.contains(a.username)).toList();
  }

  /// True wenn ≥1 Freund unter den letzten 20 going-RSVPs.
  bool hasFriendsGoing(Set<String> friendUsernames) =>
      friendsAmongGoing(friendUsernames).isNotEmpty;
}

/// Hilfs-Service. Bewusst dünn — die Activity-Felder leben auf dem
/// Party-Doc selbst, also reicht ein einzelner Doc-Read/Stream.
class PartyActivityService {
  PartyActivityService._();

  /// One-shot Read aus einem Party-Doc-Map.
  static PartyActivity fromPartyData(Map<String, dynamic>? data) =>
      PartyActivity.fromPartyData(data);

  /// Stream einzelner Party-Activity (Doc-Snapshots). Wenn der Caller
  /// schon den Party-Doc-Stream hat, sollte er `fromPartyData` darauf
  /// mappen statt diesen Stream zu öffnen — vermeidet zweiten Stream.
  static Stream<PartyActivity> watch(String partyId) {
    if (partyId.isEmpty) return Stream.value(PartyActivity.empty);
    return FirebaseFirestore.instance
        .collection('Party')
        .doc(partyId)
        .snapshots()
        .map((snap) => PartyActivity.fromPartyData(snap.data()));
  }
}
