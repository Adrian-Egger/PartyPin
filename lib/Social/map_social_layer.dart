// lib/Social/map_social_layer.dart
//
// Live Social Map Layer — pure helper.
//
// Berechnet aus Party-Doc-Daten + cached Friend-Set die kompakten
// Social-Flags, die der Map-Layer für Aura/Dot-Entscheidungen
// braucht. Keine I/O. Wird im Render-Pfad von party_map_screen.dart
// aufgerufen — muss billig bleiben.
//
// Phase-3-Layer:
//   - momentum: rising / surging — aus goingDelta60m (TTL-geschützt)
//   - startingSoon: Party beginnt in [-15min, +60min]
//   - atmosphericLabel(): kombinierte Atmosphären-Pille für UI
//
// Rule of thumb (Map-Visual):
//   - hasFriend       → grüne Aura + Friend-Dot oben rechts am Marker
//   - isHot           → rote (accent) Aura, kein extra Dot
//   - beides          → grüne Aura gewinnt (Freunde > Crowd-Volumen)
//   - momentum:rising → Aura-Radius +4m, Stroke +0.10 opacity
//   - momentum:surging → Aura-Radius +8m, Stroke +0.20 opacity

import 'party_activity.dart';

enum PartyMomentum { none, rising, surging }

class MapSocialFlags {
  const MapSocialFlags({
    required this.goingCount,
    required this.friendCount,
    required this.isHot,
    this.momentum = PartyMomentum.none,
    this.startingSoon = false,
  });

  /// Total going (self-join bereits server-seitig entfernt).
  final int goingCount;

  /// Anzahl meiner Freunde unter `goingRecent` (max 20).
  final int friendCount;

  /// `goingCount >= kHotThreshold`. Soft-Threshold, Linz Early-Stage:
  /// 5 Gäste = Mini-Hot, deutlich genug für visuelle Aura ohne dass
  /// jede Mini-Party glüht.
  final bool isHot;

  /// Crowd-Wachstumsrate: none / rising (≥2 neue/h) / surging (≥5 neue/h).
  /// Nur gesetzt wenn der Aggregator-Stand frisch ist (TTL via
  /// `PartyActivity.isMomentumFresh`).
  final PartyMomentum momentum;

  /// Party beginnt in [-15min, +60min] relativ zu DeviceClock.
  /// Pure client-side Ableitung. Bei Zeitzonen-Drift visuell unfein,
  /// aber kein Crash-Risiko.
  final bool startingSoon;

  bool get hasFriend => friendCount > 0;

  /// True wenn ≥2 Freunde dort sind (für Doppel-Dot-Icon).
  bool get hasManyFriends => friendCount >= 2;

  /// True wenn irgendein Social-Signal angezeigt werden soll.
  bool get hasAnySignal =>
      hasFriend || isHot || momentum != PartyMomentum.none;

  static const MapSocialFlags none =
      MapSocialFlags(goingCount: 0, friendCount: 0, isHot: false);
}

/// Schwellenwerte. Bewusst niedrig für Linz Early-Stage.
const int kHotThreshold = 5;
const int kRisingDelta60m = 2;
const int kSurgingDelta60m = 5;

/// Berechnet alle Map-Social-Flags aus einem rohen Party-Doc-Map.
/// Convenience-Wrapper für den Map-Pfad. UI-Caller mit bereits
/// geparster `PartyActivity` sollten `computeMapSocialFlagsFromActivity`
/// nehmen — vermeidet ein redundantes Parsen.
MapSocialFlags computeMapSocialFlags({
  required Map<String, dynamic>? partyData,
  required Set<String> myFriends,
  DateTime? startTime,
  DateTime? nowOverride,
}) {
  if (partyData == null) return MapSocialFlags.none;
  return computeMapSocialFlagsFromActivity(
    activity: PartyActivity.fromPartyData(partyData),
    myFriends: myFriends,
    startTime: startTime,
    nowOverride: nowOverride,
  );
}

/// Direkter Pfad ohne Re-Parse. UI-Caller mit `PartyActivity`-Instanz
/// (z.B. Cards, Bottom-Sheet) verwenden diesen.
MapSocialFlags computeMapSocialFlagsFromActivity({
  required PartyActivity activity,
  required Set<String> myFriends,
  DateTime? startTime,
  DateTime? nowOverride,
}) {
  if (activity.goingCount <= 0 && startTime == null) {
    return MapSocialFlags.none;
  }

  int friendCount = 0;
  if (myFriends.isNotEmpty) {
    for (final a in activity.goingRecent) {
      if (myFriends.contains(a.username)) friendCount++;
    }
  }

  // Momentum nur wenn Aggregat-Stand frisch (≤90min alt). Sonst ist
  // delta60m eingefroren und nicht aussagekräftig.
  PartyMomentum momentum = PartyMomentum.none;
  if (activity.isMomentumFresh) {
    if (activity.goingDelta60m >= kSurgingDelta60m) {
      momentum = PartyMomentum.surging;
    } else if (activity.goingDelta60m >= kRisingDelta60m) {
      momentum = PartyMomentum.rising;
    }
  }

  bool startingSoon = false;
  if (startTime != null) {
    final now = nowOverride ?? DateTime.now();
    final mins = startTime.difference(now).inMinutes;
    startingSoon = mins >= -15 && mins <= 60;
  }

  return MapSocialFlags(
    goingCount: activity.goingCount,
    friendCount: friendCount,
    isHot: activity.goingCount >= kHotThreshold,
    momentum: momentum,
    startingSoon: startingSoon,
  );
}

/// Kurze Atmosphären-Pille (≤14 Zeichen) für Party-Cards und
/// Bottom-Sheet. Priorität:
///   1. „startet gleich" / „in X Min"     (start in [0, 60])
///   2. „läuft gerade" / „voller Action"   (started < 2h ago + momentum)
///   3. „füllt sich gerade" / „füllt sich" (momentum without start-context)
///   4. null                                (kein Hinweis nötig)
///
/// Bewusst minimal: keine Emoji-Spam, keine langen Texte.
String? atmosphericLabel({
  required MapSocialFlags flags,
  DateTime? startTime,
  DateTime? nowOverride,
}) {
  final now = nowOverride ?? DateTime.now();

  if (startTime != null) {
    final diff = startTime.difference(now);
    final mins = diff.inMinutes;

    // Pre-start: max-prio Time-Hint
    if (mins > 5 && mins <= 60) return 'in $mins Min';
    if (mins >= 0 && mins <= 5) return 'startet gleich';

    // Already running (last 2h)
    if (mins >= -120 && mins < 0) {
      if (flags.momentum == PartyMomentum.surging) return 'voller Action';
      if (flags.momentum == PartyMomentum.rising) return 'läuft';
      return null;
    }
  }

  if (flags.momentum == PartyMomentum.surging) return 'füllt sich gerade';
  if (flags.momentum == PartyMomentum.rising) return 'füllt sich';
  return null;
}
