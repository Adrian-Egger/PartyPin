import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final _messaging = FirebaseMessaging.instance;

  static Future<void> init() async {
    try {
      await _messaging.requestPermission(
          alert: true, badge: true, sound: true);

      // iOS: show banner/sound/badge even while the app is open
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);
      _messaging.onTokenRefresh.listen(_saveToken);
    } catch (_) {}
  }

  /// Call this right after login, once the username is in SharedPreferences.
  static Future<void> saveCurrentToken() async {
    try {
      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);
    } catch (_) {}
  }

  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final username =
        (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '')
            .trim();
    if (username.isEmpty) return;

    final data = <String, dynamic>{'fcmToken': token};

    final lat = prefs.getDouble('selectedLat');
    final lng = prefs.getDouble('selectedLng');
    if (lat != null) data['selectedLat'] = lat;
    if (lng != null) data['selectedLng'] = lng;

    final isBar = prefs.getBool('isBar') ?? false;

    // Find the real document by username field (doc ID is "Vorname Nachname", not username)
    for (final col in [if (!isBar) 'users', 'bars']) {
      for (final field in ['username', 'username_lower']) {
        final val = field == 'username' ? username : username.toLowerCase();
        final q = await FirebaseFirestore.instance
            .collection(col)
            .where(field, isEqualTo: val)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) {
          await q.docs.first.reference.set(data, SetOptions(merge: true));
          return;
        }
      }
    }
  }
}
