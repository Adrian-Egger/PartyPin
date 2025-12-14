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
