// lib/Social/city_mood.dart
//
// City Mood Layer — pure helper.
//
// Aggregiert bereits geladene Party-Daten zu einem kompakten
// City-Mood-Signal. KEINE Firestore-Reads, KEINE Streams, KEIN async.
// O(n) über die übergebenen Party-Docs.
//
// Konsumer:
//   - party_map_screen ruft das nach _refreshMap auf
//   - access_parties_screen (optional) — würde das auch profitieren
//
// Mood-Levels (eskalierend):
//   quiet     → nichts wird angezeigt (Strip versteckt sich)
//   active    → "X gehen heute aus"
//   alive     → mehrere Signale gleichzeitig
//   electric  → ungewöhnlich aktiv
//
// Thresholds bewusst niedrig für Linz Early-Stage: ein paar Hosts
// + ~10 Going sollen schon ein sichtbares Mood-Level triggern.

import 'linz_districts.dart';
import 'map_social_layer.dart';
import 'party_activity.dart';

enum CityMoodLevel { quiet, active, alive, electric }

class DistrictPulse {
  const DistrictPulse({
    required this.name,
    required this.partyCount,
    required this.surgingCount,
  });
  final String name;
  final int partyCount;
  final int surgingCount;

  /// True wenn "X zieht an" — surging-Aktivität im District.
  bool get isSurging => surgingCount > 0;
}

class CityMood {
  const CityMood({
    required this.level,
    required this.surgingPartiesCount,
    required this.totalGoingTonight,
    required this.friendsGoingTonight,
    required this.activeDistricts,
    required this.surgingHostnames,
  });

  /// Aggregat-Score.
  final CityMoodLevel level;

  /// Anzahl Parties mit goingDelta60m >= 5 (& momentum-fresh).
  final int surgingPartiesCount;

  /// Summe goingCount über alle Parties, die heute starten oder
  /// gerade laufen (Start in [-3h, +∞] heute).
  final int totalGoingTonight;

  /// Anzahl unique Freunde, die in goingRecent irgendeiner Tonight-Party
  /// auftauchen.
  final int friendsGoingTonight;

  /// Bis zu 3 District-Pulse (sortiert nach Aktivität).
  final List<DistrictPulse> activeDistricts;

  /// Hosts (Usernames) mit ≥1 surging Party heute — wird vom
  /// TrendingHostsStrip als Sort-Boost verwendet.
  final Set<String> surgingHostnames;

  static const CityMood empty = CityMood(
    level: CityMoodLevel.quiet,
    surgingPartiesCount: 0,
    totalGoingTonight: 0,
    friendsGoingTonight: 0,
    activeDistricts: <DistrictPulse>[],
    surgingHostnames: <String>{},
  );

  bool get isVisible => level != CityMoodLevel.quiet;
}

/// Bewusst tief gesetzt für Linz Early-Stage. Wenn die App größer
/// wird, einfach hochziehen.
const int _kElectricSurging = 4;
const int _kElectricGoing = 60;
const int _kElectricFriends = 10;

const int _kAliveSurging = 2;
const int _kAliveGoing = 30;
const int _kAliveFriends = 5;
const int _kAliveDistricts = 2;

const int _kActiveGoing = 10;
const int _kActiveFriends = 2;
const int _kActiveDistricts = 1;

/// Berechnet die City-Mood aus bereits geladenen Party-Docs.
///
/// `parties`: rohe Map<String,dynamic> wie sie aus `snapshot.docs`
/// rauskommen — die Funktion parst selbst was sie braucht. Bewusst
/// keine Domain-Klasse als Input, damit beide Surfaces (Map, Discovery)
/// ihre native Datenform durchreichen können.
CityMood computeCityMood({
  required Iterable<Map<String, dynamic>> parties,
  required Set<String> myFriends,
  DateTime? nowOverride,
}) {
  final now = nowOverride ?? DateTime.now();
  // "Tonight" = ab 14 Uhr heute bis 6 Uhr morgens nächster Tag.
  // Wenn aktuell vor 14 Uhr: Fenster ist heute 14 Uhr → morgen früh.
  // Wenn aktuell nach 14 Uhr: Fenster ist jetzt → morgen früh.
  // Wenn aktuell zwischen 0–6 Uhr: Fenster war gestern Abend → heute früh.
  final DateTime tonightStart, tonightEnd;
  if (now.hour < 6) {
    final yesterday = now.subtract(const Duration(days: 1));
    tonightStart = DateTime(yesterday.year, yesterday.month, yesterday.day, 14);
    tonightEnd = DateTime(now.year, now.month, now.day, 6);
  } else {
    tonightStart = DateTime(now.year, now.month, now.day, 14);
    final tomorrow = now.add(const Duration(days: 1));
    tonightEnd = DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 6);
  }

  int surgingPartiesCount = 0;
  int totalGoingTonight = 0;
  final friendsSet = <String>{};
  final surgingHostnames = <String>{};
  final districtAcc = <String, _DistrictAcc>{};

  for (final data in parties) {
    final start = _parseStart(data);
    if (start == null) continue;
    if (start.isBefore(tonightStart) || start.isAfter(tonightEnd)) continue;

    final activity = PartyActivity.fromPartyData(data);
    final lat = (data['lat'] is num) ? (data['lat'] as num).toDouble() : null;
    final lng = (data['lng'] is num) ? (data['lng'] as num).toDouble() : null;

    totalGoingTonight += activity.goingCount;

    final isSurging = activity.isMomentumFresh &&
        activity.goingDelta60m >= kSurgingDelta60m;
    if (isSurging) {
      surgingPartiesCount += 1;
      final host = (data['hostId'] ?? data['hostUid'] ?? '').toString().trim();
      if (host.isNotEmpty) surgingHostnames.add(host);
    }

    if (myFriends.isNotEmpty) {
      for (final a in activity.goingRecent) {
        if (myFriends.contains(a.username)) friendsSet.add(a.username);
      }
    }

    if (lat != null && lng != null) {
      final district = districtFor(lat: lat, lng: lng);
      if (district != null) {
        final acc = districtAcc.putIfAbsent(
            district, () => _DistrictAcc(district));
        acc.partyCount += 1;
        if (isSurging) acc.surgingCount += 1;
      }
    }
  }

  // Active = ≥2 Parties ODER ≥1 surging. Sortiert nach
  // (surgingCount desc, partyCount desc, name asc) → top 3.
  final activeDistricts = districtAcc.values
      .where((d) => d.partyCount >= 2 || d.surgingCount > 0)
      .map((d) => DistrictPulse(
            name: d.name,
            partyCount: d.partyCount,
            surgingCount: d.surgingCount,
          ))
      .toList()
    ..sort((a, b) {
      final c1 = b.surgingCount.compareTo(a.surgingCount);
      if (c1 != 0) return c1;
      final c2 = b.partyCount.compareTo(a.partyCount);
      if (c2 != 0) return c2;
      return a.name.compareTo(b.name);
    });
  final topDistricts = activeDistricts.take(3).toList();

  final level = _classifyLevel(
    surgingPartiesCount: surgingPartiesCount,
    totalGoingTonight: totalGoingTonight,
    friendsGoingTonight: friendsSet.length,
    activeDistrictsCount: topDistricts.length,
  );

  return CityMood(
    level: level,
    surgingPartiesCount: surgingPartiesCount,
    totalGoingTonight: totalGoingTonight,
    friendsGoingTonight: friendsSet.length,
    activeDistricts: topDistricts,
    surgingHostnames: surgingHostnames,
  );
}

CityMoodLevel _classifyLevel({
  required int surgingPartiesCount,
  required int totalGoingTonight,
  required int friendsGoingTonight,
  required int activeDistrictsCount,
}) {
  if (surgingPartiesCount >= _kElectricSurging ||
      totalGoingTonight >= _kElectricGoing ||
      friendsGoingTonight >= _kElectricFriends) {
    return CityMoodLevel.electric;
  }
  if (surgingPartiesCount >= _kAliveSurging ||
      totalGoingTonight >= _kAliveGoing ||
      friendsGoingTonight >= _kAliveFriends ||
      activeDistrictsCount >= _kAliveDistricts) {
    return CityMoodLevel.alive;
  }
  if (totalGoingTonight >= _kActiveGoing ||
      friendsGoingTonight >= _kActiveFriends ||
      activeDistrictsCount >= _kActiveDistricts) {
    return CityMoodLevel.active;
  }
  return CityMoodLevel.quiet;
}

class _DistrictAcc {
  _DistrictAcc(this.name);
  final String name;
  int partyCount = 0;
  int surgingCount = 0;
}

DateTime? _parseStart(Map<String, dynamic> d) {
  final st = d['startTime'];
  if (st is DateTime) return st.toLocal();
  // Cloud Firestore Timestamps haben `.toDate()` — wir können hier
  // nicht direkt `Timestamp` importieren (würde dieses Modul an
  // cloud_firestore koppeln). Stattdessen Duck-Typing per dynamic.
  try {
    final dyn = st as dynamic;
    if (dyn != null && dyn.toDate is Function) {
      final dt = dyn.toDate();
      if (dt is DateTime) return dt.toLocal();
    }
  } catch (_) {}
  if (st is String) {
    final parsed = DateTime.tryParse(st);
    if (parsed != null) return parsed.toLocal();
  }

  DateTime? base;
  final v = d['date'];
  if (v is DateTime) base = v.toLocal();
  if (base == null) {
    try {
      final dyn = v as dynamic;
      if (dyn != null && dyn.toDate is Function) {
        final dt = dyn.toDate();
        if (dt is DateTime) base = dt.toLocal();
      }
    } catch (_) {}
  }
  if (base == null && v is String) base = DateTime.tryParse(v);
  if (base == null) return null;

  final timeStr = (d['time'] ?? '').toString().trim();
  int hh = 0, mm = 0;
  if (timeStr.contains(':')) {
    final parts = timeStr.split(':');
    if (parts.isNotEmpty) hh = int.tryParse(parts[0]) ?? 0;
    if (parts.length > 1) mm = int.tryParse(parts[1]) ?? 0;
  }
  return DateTime(base.year, base.month, base.day, hh, mm);
}
