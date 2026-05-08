import 'package:cloud_firestore/cloud_firestore.dart';

class AgeSyncResult {
  final int? age;
  final bool isBirthdayToday;

  AgeSyncResult({required this.age, required this.isBirthdayToday});
}

class AgeService {
  static int calcAge(DateTime birthday, DateTime now) {
    var age = now.year - birthday.year;
    final hadBirthdayThisYear =
        (now.month > birthday.month) ||
            (now.month == birthday.month && now.day >= birthday.day);
    if (!hadBirthdayThisYear) age--;
    return age;
  }

  static bool isBirthday(DateTime birthday, DateTime now) {
    return now.month == birthday.month && now.day == birthday.day;
  }

  /// Defensive Parsing eines Firestore-Geburtstag-Werts.
  /// Akzeptiert: Timestamp, ISO-Datum, "DD.MM.YYYY", "YYYY-MM-DD".
  /// Liefert null bei null/leerem Wert oder unparsbarem Format —
  /// niemals eine Exception, auch nicht bei kaputten Daten.
  static DateTime? parseBirthday(dynamic raw) {
    if (raw == null) return null;
    try {
      if (raw is Timestamp) return raw.toDate();
      if (raw is DateTime) return raw;
      final s = raw.toString().trim();
      if (s.isEmpty) return null;

      // ISO ("2007-04-28" oder "2007-04-28T..."): tryParse reicht.
      final iso = DateTime.tryParse(s);
      if (iso != null) return iso;

      // Deutsches Format "DD.MM.YYYY".
      final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(s);
      if (m != null) {
        final d = int.parse(m.group(1)!);
        final mo = int.parse(m.group(2)!);
        final y = int.parse(m.group(3)!);
        if (d >= 1 && d <= 31 && mo >= 1 && mo <= 12 && y > 1900) {
          return DateTime(y, mo, d);
        }
      }
    } catch (_) {
      // Bewusst leer — wir wollen nie crashen, sondern null zurückgeben.
    }
    return null;
  }

  /// Formatiert ein Datum als "DD.MM.YYYY" — ohne Zeitzonen-Surprise.
  static String formatBirthdayDDMMYYYY(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd.$mm.${d.year}';
  }

  /// Updatet users/{docId}.age falls nötig und gibt zurück ob heute Geburtstag ist.
  static Future<AgeSyncResult> syncAgeAndCheckBirthday({
    required String docId,
  }) async {
    final ref = FirebaseFirestore.instance.collection('users').doc(docId);
    final snap = await ref.get();
    if (!snap.exists) return AgeSyncResult(age: null, isBirthdayToday: false);

    final data = snap.data()!;
    final birthdayRaw = data['birthday'];
    if (birthdayRaw == null) {
      return AgeSyncResult(age: data['age'] is int ? data['age'] as int : null, isBirthdayToday: false);
    }

    DateTime birthday;
    if (birthdayRaw is Timestamp) {
      birthday = birthdayRaw.toDate();
    } else {
      birthday = DateTime.tryParse(birthdayRaw.toString()) ?? DateTime(2000, 1, 1);
    }

    final now = DateTime.now();
    final newAge = calcAge(birthday, now);
    final bdayToday = isBirthday(birthday, now);

    final currentAge = data['age'];
    if (currentAge is int && currentAge == newAge) {
      return AgeSyncResult(age: newAge, isBirthdayToday: bdayToday);
    }

    await ref.set({
      'age': newAge,
      'ageUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    return AgeSyncResult(age: newAge, isBirthdayToday: bdayToday);
  }
}
