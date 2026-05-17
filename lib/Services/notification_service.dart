import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final _messaging = FirebaseMessaging.instance;

  // SECURITY_HARDENING (Audit M3): Token-Refresh-Listener wurde vorher
  // ohne Cancel-Handling registriert. Bei zweitem init() (z.B. nach
  // logout/login) lebten beide Listener parallel und schrieben Token
  // doppelt. Jetzt: gespeicherte Subscription, vor jedem Re-Init
  // gecancelt.
  static StreamSubscription<String>? _tokenRefreshSub;

  static void _log(String msg) {
    if (kDebugMode) {
      // ignore: avoid_print
      print(msg);
    }
  }

  static Future<void> init() async {
    try {
      final settings = await _messaging.requestPermission(
          alert: true, badge: true, sound: true);
      _log('[FCM] Permission: ${settings.authorizationStatus}');

      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      final token = await _messaging.getToken();
      _log('[FCM] Token: $token');
      if (token != null) await _saveToken(token);
      // Re-subscribe sauber.
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = _messaging.onTokenRefresh.listen((t) {
        _log('[FCM] Token refreshed: $t');
        _saveToken(t);
      });
    } catch (e) {
      _log('[FCM] init error: $e');
    }
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
    if (username.isEmpty) {
      _log('[FCM] _saveToken: no username in prefs, skipping');
      return;
    }

    final data = <String, dynamic>{'fcmToken': token};

    final lat = prefs.getDouble('selectedLat');
    final lng = prefs.getDouble('selectedLng');
    if (lat != null) data['selectedLat'] = lat;
    if (lng != null) data['selectedLng'] = lng;

    final isBar = prefs.getBool('isBar') ?? false;

    for (final col in [if (!isBar) 'users', 'bars']) {
      for (final field in ['username', 'username_lower']) {
        final val = field == 'username' ? username : username.toLowerCase();
        try {
          final q = await FirebaseFirestore.instance
              .collection(col)
              .where(field, isEqualTo: val)
              .limit(1)
              .get();
          if (q.docs.isNotEmpty) {
            await q.docs.first.reference.set(data, SetOptions(merge: true));
            _log('[FCM] Token saved to $col/${q.docs.first.id}');
            return;
          }
        } catch (e) {
          _log('[FCM] _saveToken query error ($col.$field): $e');
        }
      }
    }
    _log('[FCM] _saveToken: no matching document found for username="$username"');
  }
}
