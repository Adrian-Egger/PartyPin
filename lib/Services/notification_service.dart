import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final _messaging = FirebaseMessaging.instance;

  static Future<void> init() async {
    try {
      await _messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await _messaging.getToken();
      if (token != null) await _saveToken(token);
      _messaging.onTokenRefresh.listen(_saveToken);
    } catch (_) {}
  }

  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '').trim();
    if (username.isEmpty) return;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(username)
        .set({'fcmToken': token}, SetOptions(merge: true));
  }
}
