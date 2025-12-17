import 'package:cloud_firestore/cloud_firestore.dart';
import '../Screens/bar_event.dart';

class EventRepository {
  final FirebaseFirestore _db;

  EventRepository({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _eventsRef(String barId) {
    return _db.collection('bars').doc(barId).collection('events');
  }

  Stream<List<BarEvent>> streamUpcomingEvents(String barId) {
    final now = DateTime.now();
    // Wir zeigen Events, die noch nicht endgültig vorbei sind.
    // (EndAt >= now - 1h) als Toleranz.
    final threshold = now.subtract(const Duration(hours: 1));

    return _eventsRef(barId)
        .where('isActive', isEqualTo: true)
        .where('endAt', isGreaterThanOrEqualTo: Timestamp.fromDate(threshold))
        .orderBy('endAt')
        .orderBy('startAt')
        .snapshots()
        .map((qs) => qs.docs.map((d) => BarEvent.fromDoc(barId: barId, doc: d)).toList());
  }

  Stream<BarEvent?> streamEventById(String barId, String eventId) {
    return _eventsRef(barId)
        .doc(eventId)
        .snapshots()
        .map((snap) => snap.exists ? BarEvent.fromDoc(barId: barId, doc: snap) : null);
  }

  Future<void> upsertEvent({
    required String barId,
    required String eventId,
    required Map<String, dynamic> data,
  }) async {
    await _eventsRef(barId).doc(eventId).set(
      {
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}
