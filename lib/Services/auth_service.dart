// lib/Services/auth_service.dart
//
// SECURITY_HARDENING (Pre-Launch Audit C1): zentraler Login-Service.
//
// Ruft die `loginCallable` Cloud Function auf, bekommt einen Custom
// Token, und macht `signInWithCustomToken`. KEIN client-seitiger
// Hash-Vergleich mehr, KEIN Lesen von passwordHash aus Firestore.
//
// Konsumer: lib/Screens/auth/login_screen.dart
//
// Public API:
//   - AuthService.login(username, password)
//       → LoginResult (ok/typed-error/profile)
//   - AuthService.signOut()
//       → kompletter Logout: FirebaseAuth + lokale prefs (currentUsername etc.)
//
// Fehler-Mapping ist konservativ: für jeden Pfad ein menschenlesbarer
// Grund. Unbekannte Fehler werden auf `LoginError.unknown` gemappt,
// niemals geworfen.

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LoginError {
  none,
  emptyInput,
  invalidCredentials,
  banned,
  network,
  timeout,
  serverInternal,
  appCheckFailed,
  unknown,
}

enum SignupError {
  none,
  invalidArgument,    // Format-Fehler, zu kurz etc.
  usernameTaken,
  ageTooLow,
  rateLimited,
  network,
  timeout,
  serverInternal,
  unknown,
}

/// User-Profile-Echo vom CF — bekannte Felder. Optional (null wenn CF
/// keinen Wert geliefert hat).
class LoginProfile {
  const LoginProfile({
    required this.username,
    required this.userType,
    this.vorname,
    this.nachname,
    this.phoneNumber,
    this.phoneVerified = false,
    this.authVersion = 1,
    this.termsAccepted = false,
    this.language,
    this.country,
    this.city,
    this.selectedLat,
    this.selectedLng,
    this.barName,
    this.barStatus,
  });

  final String username;

  /// 'user' oder 'bar'
  final String userType;

  final String? vorname;
  final String? nachname;
  final String? phoneNumber;
  final bool phoneVerified;
  final int authVersion;
  final bool termsAccepted;
  final String? language;
  final String? country;
  final String? city;
  final double? selectedLat;
  final double? selectedLng;
  final String? barName;

  /// Nur für userType=='bar': pending/approved/rejected/...
  final String? barStatus;

  bool get isBar => userType == 'bar';

  factory LoginProfile.fromMap(String userType, Map<String, dynamic> m) {
    String? s(String k) {
      final v = m[k];
      if (v == null) return null;
      final t = v.toString().trim();
      return t.isEmpty ? null : t;
    }

    double? d(String k) {
      final v = m[k];
      if (v is num) return v.toDouble();
      return null;
    }

    return LoginProfile(
      username: (m['username'] ?? '').toString(),
      userType: userType,
      vorname: s('vorname'),
      nachname: s('nachname'),
      phoneNumber: s('phoneNumber'),
      phoneVerified: m['phoneVerified'] == true,
      authVersion: m['authVersion'] is int ? m['authVersion'] as int : 1,
      termsAccepted: m['termsAccepted'] == true,
      language: s('language'),
      country: s('country'),
      city: s('city'),
      selectedLat: d('selectedLat'),
      selectedLng: d('selectedLng'),
      barName: s('barName'),
      barStatus: s('status'),
    );
  }
}

class LoginResult {
  const LoginResult.ok({required this.profile, required this.uid})
      : error = LoginError.none,
        message = null;
  const LoginResult.fail(this.error, this.message)
      : profile = null,
        uid = null;

  final LoginError error;
  final String? message;
  final LoginProfile? profile;
  final String? uid;

  bool get isOk => error == LoginError.none && profile != null;
}

class SignupResult {
  const SignupResult.ok({
    required this.profile,
    required this.uid,
    this.requiresApproval = false,
  })  : error = SignupError.none,
        message = null;
  const SignupResult.fail(this.error, this.message)
      : profile = null,
        uid = null,
        requiresApproval = false;

  final SignupError error;
  final String? message;
  final LoginProfile? profile;
  final String? uid;

  /// True für Bar-Signups: Account ist erstellt aber status==pending,
  /// kein Auto-Login. Caller muss auf Login-Screen leiten.
  final bool requiresApproval;

  bool get isOk => error == SignupError.none && profile != null;
}

class AuthService {
  AuthService._();

  static const _region = 'europe-west1';
  static const _timeout = Duration(seconds: 20);

  /// Vollständiger Login. Macht intern:
  ///   1. loginCallable (CF) — Hash-Verifikation server-seitig
  ///   2. signInWithCustomToken
  ///   3. Validiert dass FirebaseAuth.currentUser danach existiert
  ///
  /// Bei jedem Fehler ist FirebaseAuth.currentUser NICHT gesetzt
  /// (bei Fehler in Schritt 3 wird explizit ausgeloggt).
  static Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    final u = username.trim();
    final p = password.trim();
    if (u.isEmpty || p.isEmpty) {
      return const LoginResult.fail(
        LoginError.emptyInput,
        'Benutzername und Passwort dürfen nicht leer sein.',
      );
    }

    final fn = FirebaseFunctions.instanceFor(region: _region).httpsCallable(
      'loginCallable',
      options: HttpsCallableOptions(timeout: _timeout),
    );

    Map<String, dynamic> data;
    try {
      final res = await fn.call(<String, dynamic>{
        'username': u,
        'password': p,
      });
      final raw = res.data;
      if (raw is! Map) {
        return const LoginResult.fail(
          LoginError.serverInternal,
          'Unerwartete Antwort vom Server.',
        );
      }
      data = Map<String, dynamic>.from(raw);
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] FF error: ${e.code} ${e.message}');
      }
      switch (e.code) {
        case 'unauthenticated':
          return const LoginResult.fail(
            LoginError.invalidCredentials,
            'Benutzername oder Passwort falsch.',
          );
        case 'permission-denied':
          return LoginResult.fail(
            LoginError.banned,
            (e.message ?? 'Account ist gesperrt.').toString(),
          );
        case 'invalid-argument':
          return LoginResult.fail(
            LoginError.invalidCredentials,
            'Eingabe ungültig.',
          );
        case 'deadline-exceeded':
        case 'cancelled':
          return const LoginResult.fail(
            LoginError.timeout,
            'Login dauert zu lange. Bitte erneut versuchen.',
          );
        case 'unavailable':
          return const LoginResult.fail(
            LoginError.network,
            'Keine Verbindung zum Server.',
          );
        case 'failed-precondition':
        case 'internal':
          return const LoginResult.fail(
            LoginError.serverInternal,
            'Server-Fehler. Bitte später erneut versuchen.',
          );
        default:
          return LoginResult.fail(
            LoginError.unknown,
            'Login fehlgeschlagen: ${e.code}',
          );
      }
    } catch (e) {
      // Netzwerk-, Plattform- oder unbekannte Exceptions
      if (kDebugMode) debugPrint('[AuthService] unknown error: $e');
      final msg = e.toString().toLowerCase();
      if (msg.contains('network') || msg.contains('socket') || msg.contains('connection')) {
        return const LoginResult.fail(
          LoginError.network,
          'Keine Verbindung zum Server.',
        );
      }
      return const LoginResult.fail(
        LoginError.unknown,
        'Login fehlgeschlagen.',
      );
    }

    if (data['ok'] != true || data['token'] == null) {
      return const LoginResult.fail(
        LoginError.serverInternal,
        'Server hat keinen Token geliefert.',
      );
    }

    final token = data['token'].toString();
    final userType = (data['userType'] ?? 'user').toString();
    final uid = (data['uid'] ?? '').toString();
    final profileRaw = data['profile'];
    final profileMap = profileRaw is Map
        ? Map<String, dynamic>.from(profileRaw)
        : <String, dynamic>{};
    final profile = LoginProfile.fromMap(userType, profileMap);

    // signInWithCustomToken — ersetzt jede bestehende Auth-Session
    // (anonyme inkl.). Bei Fehlern: kein currentUser, Fehlerpfad zurück.
    try {
      await FirebaseAuth.instance.signInWithCustomToken(token);
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] signIn error: ${e.code} ${e.message}');
      }
      // Sicherheitshalber: wenn signIn fehlschlägt, alten Auth-Stand kappen.
      try { await FirebaseAuth.instance.signOut(); } catch (_) {}
      return LoginResult.fail(
        LoginError.serverInternal,
        'Auth-Token ungültig: ${e.code}',
      );
    } catch (e) {
      try { await FirebaseAuth.instance.signOut(); } catch (_) {}
      return const LoginResult.fail(
        LoginError.serverInternal,
        'Auth-Token konnte nicht verwendet werden.',
      );
    }

    if (FirebaseAuth.instance.currentUser == null) {
      return const LoginResult.fail(
        LoginError.serverInternal,
        'Auth-Status nach Login leer.',
      );
    }

    return LoginResult.ok(profile: profile, uid: uid);
  }

  // ─────────────────────────────────────────────────────────
  // SIGNUP — User
  // ─────────────────────────────────────────────────────────

  /// User-Signup über signupCallable + Auto-Login per Custom Token.
  /// Bei Erfolg ist FirebaseAuth.currentUser != null nach Rückkehr.
  ///
  /// Bewusst KEINE doc-Schreiboperationen client-seitig — alles
  /// passiert in der CF. PasswordHash verlässt nie den Server.
  static Future<SignupResult> signupUser({
    required String username,
    required String password,
    required String vorname,
    required String nachname,
    required int tag,
    required int monat,
    required int jahr,
  }) async {
    return _signup(
      payload: <String, dynamic>{
        'userType': 'user',
        'username': username.trim(),
        'password': password.trim(),
        'vorname': vorname.trim(),
        'nachname': nachname.trim(),
        'geburtstag': {'tag': tag, 'monat': monat, 'jahr': jahr},
      },
      autoLogin: true,
    );
  }

  /// Bar-Signup. Liefert KEIN Custom Token zurück (status: pending,
  /// muss zuerst von Admin freigeschaltet werden). Der Aufrufer muss
  /// den User nach Erfolg auf den Login-Screen leiten.
  static Future<SignupResult> signupBar({
    required String username,
    required String password,
    required String barName,
    required String email,
    required String phoneNumber,
    required String address,
    required String city,
    required String country,
    String description = '',
    String? profileImageUrl,
  }) async {
    return _signup(
      payload: <String, dynamic>{
        'userType': 'bar',
        'username': username.trim(),
        'password': password.trim(),
        'barName': barName.trim(),
        'email': email.trim(),
        'phoneNumber': phoneNumber.trim(),
        'address': address.trim(),
        'city': city.trim(),
        'country': country.trim(),
        'description': description.trim(),
        if (profileImageUrl != null && profileImageUrl.trim().isNotEmpty)
          'profileImageUrl': profileImageUrl.trim(),
      },
      autoLogin: false,
    );
  }

  static Future<SignupResult> _signup({
    required Map<String, dynamic> payload,
    required bool autoLogin,
  }) async {
    final fn = FirebaseFunctions.instanceFor(region: _region).httpsCallable(
      'signupCallable',
      options: HttpsCallableOptions(timeout: _timeout),
    );

    Map<String, dynamic> data;
    try {
      final res = await fn.call(payload);
      final raw = res.data;
      if (raw is! Map) {
        return const SignupResult.fail(
          SignupError.serverInternal,
          'Unerwartete Antwort vom Server.',
        );
      }
      data = Map<String, dynamic>.from(raw);
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] signup FF error: ${e.code} ${e.message}');
      }
      switch (e.code) {
        case 'already-exists':
          return const SignupResult.fail(
            SignupError.usernameTaken,
            'Username ist bereits vergeben.',
          );
        case 'failed-precondition':
          // CF wirft das z.B. bei age<12
          return SignupResult.fail(
            SignupError.ageTooLow,
            (e.message ?? 'Voraussetzung nicht erfüllt.').toString(),
          );
        case 'invalid-argument':
          return SignupResult.fail(
            SignupError.invalidArgument,
            (e.message ?? 'Eingabe ungültig.').toString(),
          );
        case 'resource-exhausted':
          return const SignupResult.fail(
            SignupError.rateLimited,
            'Zu viele Versuche. Bitte später erneut.',
          );
        case 'deadline-exceeded':
        case 'cancelled':
          return const SignupResult.fail(
            SignupError.timeout,
            'Server-Antwort dauert zu lange.',
          );
        case 'unavailable':
          return const SignupResult.fail(
            SignupError.network,
            'Keine Verbindung zum Server.',
          );
        default:
          return SignupResult.fail(
            SignupError.unknown,
            'Signup fehlgeschlagen: ${e.code}',
          );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] signup unknown: $e');
      final msg = e.toString().toLowerCase();
      if (msg.contains('network') || msg.contains('socket') || msg.contains('connection')) {
        return const SignupResult.fail(
          SignupError.network,
          'Keine Verbindung zum Server.',
        );
      }
      return const SignupResult.fail(
        SignupError.unknown,
        'Signup fehlgeschlagen.',
      );
    }

    if (data['ok'] != true) {
      return const SignupResult.fail(
        SignupError.serverInternal,
        'Server: Signup nicht bestätigt.',
      );
    }

    final uid = (data['uid'] ?? '').toString();
    final userType = (data['userType'] ?? 'user').toString();
    final profileRaw = data['profile'];
    final profileMap = profileRaw is Map
        ? Map<String, dynamic>.from(profileRaw)
        : <String, dynamic>{};
    final profile = LoginProfile.fromMap(userType, profileMap);

    if (autoLogin) {
      final token = (data['token'] ?? '').toString();
      if (token.isEmpty) {
        return const SignupResult.fail(
          SignupError.serverInternal,
          'Server hat keinen Token geliefert.',
        );
      }
      try {
        await FirebaseAuth.instance.signInWithCustomToken(token);
      } catch (e) {
        try { await FirebaseAuth.instance.signOut(); } catch (_) {}
        return const SignupResult.fail(
          SignupError.serverInternal,
          'Auto-Login nach Signup fehlgeschlagen.',
        );
      }
    }

    return SignupResult.ok(
      profile: profile,
      uid: uid,
      requiresApproval: data['requiresApproval'] == true,
    );
  }

  // ─────────────────────────────────────────────────────────
  // PASSWORD RESET (request only — confirm passiert auf web page)
  // ─────────────────────────────────────────────────────────

  /// Triggert den server-seitigen Reset-Flow. CF schickt Mail mit
  /// Web-Link. CF antwortet IMMER ok (Enumeration-Schutz) — der
  /// Caller darf daraus KEINE Info ableiten ob die Account existiert.
  ///
  /// Returns:
  ///   null bei Erfolg (Mail wurde versucht — wahrscheinlich
  ///                    unterwegs falls Account/Email existieren)
  ///   non-null: human-lesbarer Fehler (z.B. Netzwerk).
  static Future<String?> requestPasswordReset({
    required String identifier,
  }) async {
    final id = identifier.trim();
    if (id.isEmpty) return 'Bitte Username oder E-Mail eingeben.';
    if (id.length > 254) return 'Eingabe zu lang.';

    final fn = FirebaseFunctions.instanceFor(region: _region).httpsCallable(
      'requestPasswordReset',
      options: HttpsCallableOptions(timeout: _timeout),
    );
    try {
      await fn.call(<String, dynamic>{'identifier': id});
      return null;
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] pwReset FF error: ${e.code} ${e.message}');
      }
      if (e.code == 'unavailable' || e.code == 'deadline-exceeded') {
        return 'Keine Verbindung zum Server.';
      }
      // Wir verschlucken bewusst differenzierte Fehler (Enumeration-Schutz)
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] pwReset unknown: $e');
      final msg = e.toString().toLowerCase();
      if (msg.contains('network') || msg.contains('socket') || msg.contains('connection')) {
        return 'Keine Verbindung zum Server.';
      }
      return null;
    }
  }

  // ─────────────────────────────────────────────────────────
  // CHANGE PASSWORD
  // ─────────────────────────────────────────────────────────

  /// Wechselt das Passwort des aktuell eingeloggten Accounts.
  /// Voraussetzung: User ist per Custom Token authentifiziert
  /// (legacy anonymous Sessions kommen serverseitig nicht durch).
  ///
  /// Returns null bei Erfolg, sonst eine menschenlesbare Fehlermeldung.
  static Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final fn = FirebaseFunctions.instanceFor(region: _region).httpsCallable(
      'changePasswordCallable',
      options: HttpsCallableOptions(timeout: _timeout),
    );
    try {
      final res = await fn.call(<String, dynamic>{
        'currentPassword': currentPassword.trim(),
        'newPassword': newPassword.trim(),
      });
      if (res.data is Map && (res.data as Map)['ok'] == true) return null;
      return 'Server hat den Wechsel nicht bestätigt.';
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] changePw FF error: ${e.code} ${e.message}');
      }
      switch (e.code) {
        case 'permission-denied':
          return e.message ?? 'Aktuelles Passwort falsch.';
        case 'invalid-argument':
          return e.message ?? 'Eingabe ungültig.';
        case 'failed-precondition':
          return e.message ?? 'Account-Status verhindert Wechsel.';
        case 'unauthenticated':
          return 'Bitte erst einloggen.';
        case 'unavailable':
        case 'deadline-exceeded':
          return 'Keine Verbindung zum Server.';
        default:
          return 'Wechsel fehlgeschlagen: ${e.code}';
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AuthService] changePw unknown: $e');
      return 'Wechsel fehlgeschlagen.';
    }
  }

  /// Kompletter Logout: FirebaseAuth abmelden + lokale Auth-Prefs leeren.
  /// Lässt App-Daten wie city/language unverändert (User-Convenience).
  static Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('isLoggedIn');
    await prefs.remove('currentUsername');
    await prefs.remove('username');
    await prefs.remove('isBar');
    await prefs.remove('isBarAccount');
    await prefs.remove('barId');
    await prefs.remove('barName');
    await prefs.remove('vorname');
    await prefs.remove('nachname');
    await prefs.remove('phoneNumber');
    await prefs.remove('phoneVerified');
    await prefs.remove('authVersion');
  }
}
