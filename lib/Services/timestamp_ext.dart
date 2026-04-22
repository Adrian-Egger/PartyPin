import 'package:cloud_firestore/cloud_firestore.dart';

extension TimestampLocalTime on Timestamp {
  /// Firestore Timestamps are always UTC. This SDK version's toDate() omits
  /// isUtc:true, so Dart treats the result as local and .toLocal() becomes a
  /// no-op. This extension forces the correct UTC interpretation first.
  DateTime toLocalDateTime() =>
      DateTime.fromMicrosecondsSinceEpoch(microsecondsSinceEpoch, isUtc: true)
          .toLocal();
}
