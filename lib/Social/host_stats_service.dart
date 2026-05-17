// lib/Social/host_stats_service.dart
//
// Service-Layer für Host Reputation:
//   - watch(username)          → Stream<HostStats> aus Firestore
//   - watchTrending()           → Stream<List<TrendingHost>> aus trendingHosts/global
//   - requestRecompute(...)     → Cloud-Function-Aufruf für On-Demand-Refresh
//
// Reads minimieren: ein einziges Doc pro Host (users/{username}/hostStats/current).
// Caller können die Stats für mehrere Hosts gleichzeitig streamen.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'host_stats.dart';

class HostStatsService {
  HostStatsService._();

  /// Stream der Stats eines Hosts. Liefert immer einen Wert — wenn der
  /// Doc nicht existiert, kommt `HostStats.empty(username)` raus.
  /// Cached intern in Firestore — wiederholte Watches sind günstig.
  static Stream<HostStats> watch(String username) {
    if (username.isEmpty) {
      return Stream.value(HostStats.empty(username));
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(username)
        .collection('hostStats')
        .doc('current')
        .snapshots()
        .map((snap) => HostStats.fromSnapshot(username, snap.data()));
  }

  /// Stream der Top-Trending-Hosts (Top 10). Wird täglich neu geschrieben.
  static Stream<List<TrendingHost>> watchTrending() {
    return FirebaseFirestore.instance
        .collection('trendingHosts')
        .doc('global')
        .snapshots()
        .map((snap) {
      final data = snap.data();
      if (data == null) return const <TrendingHost>[];
      final raw = data['entries'];
      if (raw is! List) return const <TrendingHost>[];
      return raw
          .whereType<Map>()
          .map((m) => TrendingHost.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    });
  }

  /// One-shot read — für UI, die keinen Live-Stream braucht (z.B. Map-Marker).
  static Future<HostStats> get(String username) async {
    if (username.isEmpty) return HostStats.empty(username);
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(username)
        .collection('hostStats')
        .doc('current')
        .get();
    return HostStats.fromSnapshot(username, snap.data());
  }

  /// On-Demand-Recompute via Cloud Function.
  /// Liefert die frischen Stats als HostStats zurück. Bei Fehler:
  /// re-throws lesbare Exception.
  static Future<HostStats> requestRecompute(String username) async {
    if (username.isEmpty) throw Exception('username missing');
    final fn = FirebaseFunctions.instanceFor(region: 'europe-west1')
        .httpsCallable(
      'recomputeHostStats',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 45)),
    );
    try {
      final res = await fn.call(<String, dynamic>{'username': username});
      return HostStats.fromSnapshot(
        username,
        Map<String, dynamic>.from(res.data as Map),
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[HostStatsService] recompute failed: ${e.code} ${e.message}');
      }
      rethrow;
    }
  }
}
