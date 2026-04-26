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

    // Also persist location so Cloud Functions can do proximity checks
    final lat = prefs.getDouble('selectedLat');
    final lng = prefs.getDouble('selectedLng');
    if (lat != null) data['selectedLat'] = lat;
    if (lng != null) data['selectedLng'] = lng;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(username)
        .set(data, SetOptions(merge: true));
  }
}
