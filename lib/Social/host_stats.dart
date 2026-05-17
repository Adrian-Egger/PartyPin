// lib/Social/host_stats.dart
//
// Datenklasse für users/{username}/hostStats/current (v2).

import 'package:cloud_firestore/cloud_firestore.dart';

import 'host_level.dart';

class HostStats {
  const HostStats({
    required this.username,
    required this.hostLevel,
    required this.previousLevel,
    required this.reputationScore,
    required this.successfulEvents,
    required this.attendedEvents,
    required this.eventScore,
    required this.attendeeCount,
    required this.uniqueAttendees,
    required this.repeatAttendees,
    required this.repeatRate,
    required this.bestSinglePartyAttendees,
    required this.ghostEventCount,
    required this.ratingsGood,
    required this.ratingsBad,
    required this.ratingPositiveRate,
    required this.reportCount,
    required this.trendingScore,
    required this.growthDelta,
    required this.newcomerBoost,
    required this.partyCount,
    required this.recentEvents7d,
    required this.recentAttendees7d,
    required this.prevEvents7d,
    required this.prevAttendees7d,
    required this.recentRatingsGood7d,
    required this.auditFlags,
    required this.lastComputedAt,
    required this.lastLevelUpAt,
  });

  final String username;
  final HostLevel hostLevel;
  final HostLevel previousLevel;
  final int reputationScore;

  /// Events mit ≥2 echten Gästen (Self-Join entfernt). Wird für Level-
  /// Thresholds verwendet (siehe [kHostLevelThresholds]).
  final int successfulEvents;

  /// Events mit ≥1 echtem Gast — "es ist überhaupt etwas passiert".
  final int attendedEvents;

  /// Gewichteter Event-Score (1 Gast = 0.4, 2 = 0.8, 3-4 = 1.0,
  /// 5-7 = 1.2, 8+ = 1.5). Geht in reputationScore ein.
  final double eventScore;

  /// Gesamtsumme der going-RSVPs über alle Parties (mit Mehrfachzählung,
  /// d.h. derselbe UID in mehreren Parties = mehrfach gezählt).
  final int attendeeCount;

  /// Anzahl unique UIDs, die je als Gast aufgetaucht sind.
  final int uniqueAttendees;

  /// Davon kamen ≥2 Mal — Stammgäste.
  final int repeatAttendees;

  /// repeatAttendees / uniqueAttendees, 0..1.
  final double repeatRate;

  /// Beste Einzel-Party-Besucherzahl. Für Milestone-Display.
  final int bestSinglePartyAttendees;

  final int ghostEventCount;
  final int ratingsGood;
  final int ratingsBad;
  final double ratingPositiveRate;
  final int reportCount;

  /// Trending-Score (Momentum-aware, growth-weighted).
  final int trendingScore;

  /// Wachstum letzte 7 Tage vs Vorwoche (Attendee-Delta, ≥0).
  final int growthDelta;

  /// 30 wenn Host weniger als 5 Parties insgesamt hat — UI kann das als
  /// "🚀 Newcomer"-Indikator nutzen.
  final int newcomerBoost;

  final int partyCount;
  final int recentEvents7d;
  final int recentAttendees7d;
  final int prevEvents7d;
  final int prevAttendees7d;
  final int recentRatingsGood7d;

  /// Placeholder für spätere Anti-Spam/Sybil-Detection. Frontend kann sich
  /// daran orientieren ("⚠ markiert für Review"), wir setzen aktuell nichts.
  final List<String> auditFlags;

  final DateTime? lastComputedAt;
  final DateTime? lastLevelUpAt;

  factory HostStats.empty(String username) => HostStats(
        username: username,
        hostLevel: HostLevel.rookie,
        previousLevel: HostLevel.rookie,
        reputationScore: 0,
        successfulEvents: 0,
        attendedEvents: 0,
        eventScore: 0,
        attendeeCount: 0,
        uniqueAttendees: 0,
        repeatAttendees: 0,
        repeatRate: 0,
        bestSinglePartyAttendees: 0,
        ghostEventCount: 0,
        ratingsGood: 0,
        ratingsBad: 0,
        ratingPositiveRate: 0,
        reportCount: 0,
        trendingScore: 0,
        growthDelta: 0,
        newcomerBoost: 0,
        partyCount: 0,
        recentEvents7d: 0,
        recentAttendees7d: 0,
        prevEvents7d: 0,
        prevAttendees7d: 0,
        recentRatingsGood7d: 0,
        auditFlags: const [],
        lastComputedAt: null,
        lastLevelUpAt: null,
      );

  factory HostStats.fromSnapshot(
    String username,
    Map<String, dynamic>? data,
  ) {
    if (data == null) return HostStats.empty(username);
    return HostStats(
      username: username,
      hostLevel: parseHostLevel(data['hostLevel']),
      previousLevel: parseHostLevel(data['previousLevel']),
      reputationScore: _toInt(data['reputationScore']),
      successfulEvents: _toInt(data['successfulEvents']),
      attendedEvents: _toInt(data['attendedEvents']),
      eventScore: _toDouble(data['eventScore']),
      attendeeCount: _toInt(data['attendeeCount']),
      uniqueAttendees: _toInt(data['uniqueAttendees']),
      repeatAttendees: _toInt(data['repeatAttendees']),
      repeatRate: _toDouble(data['repeatRate']),
      bestSinglePartyAttendees: _toInt(data['bestSinglePartyAttendees']),
      ghostEventCount: _toInt(data['ghostEventCount']),
      ratingsGood: _toInt(data['ratingsGood']),
      ratingsBad: _toInt(data['ratingsBad']),
      ratingPositiveRate: _toDouble(data['ratingPositiveRate']),
      reportCount: _toInt(data['reportCount']),
      trendingScore: _toInt(data['trendingScore']),
      growthDelta: _toInt(data['growthDelta']),
      newcomerBoost: _toInt(data['newcomerBoost']),
      partyCount: _toInt(data['partyCount']),
      recentEvents7d: _toInt(data['recentEvents7d']),
      recentAttendees7d: _toInt(data['recentAttendees7d']),
      prevEvents7d: _toInt(data['prevEvents7d']),
      prevAttendees7d: _toInt(data['prevAttendees7d']),
      recentRatingsGood7d: _toInt(data['recentRatingsGood7d']),
      auditFlags: _toStringList(data['auditFlags']),
      lastComputedAt: _toDate(data['lastComputedAt']),
      lastLevelUpAt: _toDate(data['lastLevelUpAt']),
    );
  }

  bool isFresh({DateTime? since}) {
    if (lastLevelUpAt == null) return false;
    if (since == null) return true;
    return lastLevelUpAt!.isAfter(since);
  }

  int eventsToNextLevel() {
    final next = hostLevel.next;
    if (next == null) return 0;
    final t = thresholdOf(next);
    return (t.minEvents - successfulEvents).clamp(0, t.minEvents);
  }

  int scoreToNextLevel() {
    final next = hostLevel.next;
    if (next == null) return 0;
    final t = thresholdOf(next);
    return (t.minScore - reputationScore).clamp(0, t.minScore);
  }

  double progressToNextLevel() {
    final next = hostLevel.next;
    if (next == null) return 1;
    final t = thresholdOf(next);
    final tPrev = thresholdOf(hostLevel);
    final range = (t.minEvents - tPrev.minEvents).clamp(1, 1 << 30);
    final done = (successfulEvents - tPrev.minEvents).clamp(0, range);
    return done / range;
  }

  /// Wird der Host als Newcomer im Trending markiert?
  bool get isNewcomer => newcomerBoost > 0;

  /// Wird der Host als wachsend markiert? (Growth-Delta > 0)
  bool get isGrowing => growthDelta > 0;
}

int _toInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

DateTime? _toDate(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

List<String> _toStringList(Object? v) {
  if (v is List) return v.map((e) => e.toString()).toList();
  return const [];
}

/// Eintrag aus trendingHosts/global.entries — Kompaktformat (v2).
class TrendingHost {
  const TrendingHost({
    required this.username,
    required this.hostLevel,
    required this.trendingScore,
    required this.recentEvents7d,
    required this.recentAttendees7d,
    required this.growthDelta,
    required this.newcomerBoost,
  });

  final String username;
  final HostLevel hostLevel;
  final int trendingScore;
  final int recentEvents7d;
  final int recentAttendees7d;
  final int growthDelta;
  final int newcomerBoost;

  bool get isNewcomer => newcomerBoost > 0;
  bool get isGrowing => growthDelta > 0;

  factory TrendingHost.fromMap(Map<String, dynamic> m) => TrendingHost(
        username: (m['username'] ?? '').toString(),
        hostLevel: parseHostLevel(m['hostLevel']),
        trendingScore: _toInt(m['trendingScore']),
        recentEvents7d: _toInt(m['recentEvents7d']),
        recentAttendees7d: _toInt(m['recentAttendees7d']),
        growthDelta: _toInt(m['growthDelta']),
        newcomerBoost: _toInt(m['newcomerBoost']),
      );
}
