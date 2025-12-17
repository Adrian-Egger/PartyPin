import 'package:cloud_firestore/cloud_firestore.dart';

class BarEvent {
  final String id;
  final String barId;

  final bool isActive;

  final String title;
  final String tagline;
  final String description;

  final DateTime startAt;
  final DateTime endAt;
  final DateTime visibleFrom;

  final bool entryEnabled;
  final bool ageEnabled;
  final bool musicEnabled;
  final bool dresscodeEnabled;

  final String entry;
  final String age;
  final String music;
  final String dresscode;

  final List<Map<String, dynamic>> sections;

  BarEvent({
    required this.id,
    required this.barId,
    required this.isActive,
    required this.title,
    required this.tagline,
    required this.description,
    required this.startAt,
    required this.endAt,
    required this.visibleFrom,
    required this.entryEnabled,
    required this.ageEnabled,
    required this.musicEnabled,
    required this.dresscodeEnabled,
    required this.entry,
    required this.age,
    required this.music,
    required this.dresscode,
    required this.sections,
  });

  static DateTime _readDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is String) return DateTime.parse(v);
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static List<Map<String, dynamic>> _readSections(dynamic raw) {
    if (raw is List) {
      return raw
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  factory BarEvent.fromDoc({
    required String barId,
    required DocumentSnapshot<Map<String, dynamic>> doc,
  }) {
    final data = doc.data() ?? <String, dynamic>{};

    return BarEvent(
      id: doc.id,
      barId: barId,
      isActive: data['isActive'] == true,

      title: (data['title'] ?? '').toString().trim(),
      tagline: (data['tagline'] ?? '').toString().trim(),
      description: (data['description'] ?? '').toString().trim(),

      startAt: _readDate(data['startAt']),
      endAt: _readDate(data['endAt']),
      visibleFrom: _readDate(data['visibleFrom']),

      entryEnabled: data['entryEnabled'] != false,
      ageEnabled: data['ageEnabled'] != false,
      musicEnabled: data['musicEnabled'] != false,
      dresscodeEnabled: data['dresscodeEnabled'] != false,

      entry: (data['entry'] ?? '').toString().trim(),
      age: (data['age'] ?? '').toString().trim(),
      music: (data['music'] ?? '').toString().trim(),
      dresscode: (data['dresscode'] ?? '').toString().trim(),

      sections: _readSections(data['sections']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'isActive': isActive,
      'title': title,
      'tagline': tagline,
      'description': description,
      'startAt': Timestamp.fromDate(startAt),
      'endAt': Timestamp.fromDate(endAt),
      'visibleFrom': Timestamp.fromDate(visibleFrom),
      'entryEnabled': entryEnabled,
      'ageEnabled': ageEnabled,
      'musicEnabled': musicEnabled,
      'dresscodeEnabled': dresscodeEnabled,
      'entry': entry,
      'age': age,
      'music': music,
      'dresscode': dresscode,
      'sections': sections,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
