// lib/Screens/login_screen.dart
//
// SECURITY_HARDENING (Pre-Launch Audit C1, Session 2026-05-16):
// Login läuft NICHT mehr client-seitig (passwordHash-Vergleich aus
// Firestore-Read). Stattdessen:
//   AuthService.login() → loginCallable CF → signInWithCustomToken
//
// Die alte _hashPassword + manuelle Firestore-Reads sind entfernt.
// Die UX (Form, Toggle, Navigation) ist unverändert geblieben.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../home/selection_screen.dart';
import 'create_account_screen.dart';
import 'nutzungsbedinungen.dart';
import 'password_reset_request_screen.dart';
import '../home/home_shell.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';
import '../../Services/auth_service.dart';
import '../../Services/notification_service.dart';
import '../../Services/platform_info.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;

  // false = Privat, true = Unternehmen
  bool _loginAsCompany = false;

  // Farben wie im CreateAccountScreen
  static const _bg = AppColors.bgTop;
  static const _gradTop = AppColors.bgTop;
  static const _gradBottom = AppColors.bgBottom;
  static const _panel = Color(0xFF15171C);
  static const _card = AppColors.panel;
  static const _textPrimary = AppColors.text;
  static const _textSecondary = AppColors.muted;
  static const _accent = AppColors.accent;

  // SECURITY_HARDENING: _hashPassword wurde entfernt — Passwort-
  // Verifikation läuft jetzt server-seitig in functions/auth/
  // loginCallable.js. Falls für Signup-Migration ein Client-Hash
  // gebraucht wird, lebt der weiter in create_account_screen.dart
  // (separate Iteration für Signup-Refactor).

  bool get _isFormValid =>
      _usernameController.text.trim().isNotEmpty &&
          _passwordController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Entscheidet nach Login wohin:
  /// - TermsScreen wenn nicht akzeptiert
  /// - SelectionScreen wenn Location fehlt
  /// - sonst IMMER HomeShell (BottomNav bleibt)
  Future<void> _checkNavigation() async {
    final prefs = await SharedPreferences.getInstance();

    final savedLanguage = prefs.getString('language');
    final savedCountry = prefs.getString('country');
    final savedCity = prefs.getString('city');
    final savedLat = prefs.getDouble('selectedLat');
    final savedLng = prefs.getDouble('selectedLng');

    final termsAccepted = prefs.getBool("termsAccepted") ?? false;

    final hasLocationData =
        savedCity != null &&
            savedCountry != null &&
            savedLat != null &&
            savedLng != null &&
            savedLanguage != null;

    if (!mounted) return;

    // 1) AGB / Nutzungsbedingungen
    if (!termsAccepted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const TermsScreen()),
            (route) => false,
      );
      return;
    }

    // 2) Standort-Auswahl
    if (!hasLocationData) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SelectionScreen()),
            (route) => false,
      );
      return;
    }

    // 3) Alles vorhanden -> IMMER HomeShell (Tab Map)
    final isBar = prefs.getBool('isBarAccount') ?? false;
    final mapTab = isBar ? 1 : 2; // Bar: Event/Map/Feedback -> Map=1, Normal -> Map=2

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomeShell(initialIndex: mapTab)),
          (route) => false,
    );
  }

  void _showError(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _login() async {
    final usernameInput = _usernameController.text.trim();
    final passwordInput = _passwordController.text.trim();

    if (!_isFormValid) {
      _showError(Lang.t('login_err_empty'));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // SECURITY_HARDENING: server-seitige Verifikation. CF prüft Hash
      // gegen users_secrets/{docId} (mit lazy migration aus users.
      // passwordHash). Bei Erfolg: Custom Token + signInWithCustomToken.
      final result = await AuthService.login(
        username: usernameInput,
        password: passwordInput,
      );

      if (!result.isOk) {
        // Server-Mapping in AuthService liefert konsistente Messages.
        final fallback = result.error == LoginError.invalidCredentials
            ? Lang.t('login_err_wrong_pw')
            : result.error == LoginError.network
                ? 'Keine Verbindung zum Server.'
                : Lang.t('login_err_generic');
        _showError(result.message ?? fallback);
        return;
      }

      final profile = result.profile!;
      final userType = profile.userType; // 'user' | 'bar'

      // Bar-Status-Check: pending/rejected verhindert App-Nutzung.
      // Wir lassen den Custom-Token signed-in, weisen aber das
      // Weiterleiten ab — User sieht klare Meldung und kommt nicht in
      // die App. Beim nächsten Login-Versuch wird wieder geprüft.
      if (userType == 'bar') {
        final status = (profile.barStatus ?? '').toLowerCase();
        if (status == 'pending') {
          await AuthService.signOut(); // verhindere bestehende Session
          _showError(
            'Dein Bar-Account wartet noch auf Freischaltung durch das Admin-Team.',
          );
          return;
        }
        if (status == 'rejected' || status == 'declined') {
          await AuthService.signOut();
          _showError(
            'Dein Bar-Account wurde abgelehnt. Bitte kontaktiere den Support.',
          );
          return;
        }
      }

      // Typ-Toggle-Check: ein User darf sich nicht als Unternehmen
      // einloggen und umgekehrt. Auch hier: bei Mismatch signOut, damit
      // keine inkonsistente Session zurückbleibt.
      if (_loginAsCompany && userType != 'bar') {
        await AuthService.signOut();
        _showError(Lang.t('login_err_not_company'));
        return;
      }
      if (!_loginAsCompany && userType != 'user') {
        await AuthService.signOut();
        _showError(Lang.t('login_err_is_company'));
        return;
      }

      // ── Profil-Daten in prefs spiegeln (aus CF-Response, KEIN
      //    weiterer Firestore-Read) ────────────────────────────
      final prefs = await SharedPreferences.getInstance();
      final storedUsername =
          profile.username.isNotEmpty ? profile.username : usernameInput;

      await prefs.setString('username', storedUsername);
      await prefs.setString('currentUsername', storedUsername);
      await prefs.setBool('isLoggedIn', true);
      await prefs.setInt('authVersion', profile.authVersion);
      await prefs.setBool('phoneVerified', profile.phoneVerified);

      if ((profile.phoneNumber ?? '').isNotEmpty) {
        await prefs.setString('phoneNumber', profile.phoneNumber!);
      } else {
        await prefs.remove('phoneNumber');
      }

      await prefs.setBool('termsAccepted', profile.termsAccepted);

      final hasFirestoreLocation = (profile.city ?? '').isNotEmpty &&
          (profile.country ?? '').isNotEmpty &&
          profile.selectedLat != null &&
          profile.selectedLng != null &&
          (profile.language ?? '').isNotEmpty;

      if (hasFirestoreLocation) {
        await prefs.setString('city', profile.city!);
        await prefs.setString('country', profile.country!);
        await prefs.setString('language', profile.language!);
        await prefs.setDouble('selectedLat', profile.selectedLat!);
        await prefs.setDouble('selectedLng', profile.selectedLng!);
      } else {
        await prefs.remove('city');
        await prefs.remove('country');
        await prefs.remove('language');
        await prefs.remove('selectedLat');
        await prefs.remove('selectedLng');
      }

      if (userType == 'user') {
        await prefs.setBool('isBar', false);
        await prefs.setBool('isBarAccount', false);
        await prefs.remove('barId');
        await prefs.setString('vorname', profile.vorname ?? '');
        await prefs.setString('nachname', profile.nachname ?? '');
      } else {
        await prefs.setBool('isBar', true);
        await prefs.setBool('isBarAccount', true);
        // bar uid == docId per loginCallable.
        if ((result.uid ?? '').isNotEmpty) {
          await prefs.setString('barId', result.uid!);
        } else {
          await prefs.remove('barId');
        }
        await prefs.setString('barName', profile.barName ?? '');
      }

      // FCM-Token persistieren — nicht-fatal.
      try {
        await NotificationService.saveCurrentToken();
      } catch (_) {}

      // Platform-Telemetrie (lastActive setzt der CF schon). Best-effort.
      // Läuft jetzt unter dem Custom-Token-User — Rules erlauben es via
      // isAuthed(). Wenn strikte Owner-Rules später aktiviert werden,
      // greift uid == docId weiterhin.
      try {
        final col = userType == 'user' ? 'users' : 'bars';
        // Doc-ID ist IMMER die Auth-UID (== docId aus loginCallable), NIE der
        // Username. Für users war hier fälschlich storedUsername gesetzt →
        // Write auf users/<username> (z. B. users/admin_pp) scheiterte an den
        // Rules (isOwnerByCustomToken: auth.uid == userId).
        final docId = result.uid ?? '';
        if (docId.isNotEmpty) {
          await FirebaseFirestore.instance.collection(col).doc(docId).set(
            {'platform': PlatformInfo.detectName()},
            SetOptions(merge: true),
          );
        }
      } catch (_) {}

      await _checkNavigation();
    } catch (e) {
      _showError("${Lang.t('login_err_generic')}: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _dec({
    required String label,
    String? hint,
    IconData? icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textSecondary),
      hintText: hint,
      hintStyle: const TextStyle(color: _textSecondary),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      filled: true,
      fillColor: _card,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
      errorStyle: const TextStyle(color: _accent),
    );
  }

  Widget _buildAccountTypeToggle() {
    final bool isPrivat = !_loginAsCompany;
    final bool isUnternehmen = _loginAsCompany;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          Lang.t('login_account_type'),
          style: const TextStyle(
            color: _textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onHorizontalDragEnd: (_) {
            setState(() => _loginAsCompany = !_loginAsCompany);
          },
          child: Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.accentBorder),
            ),
            child: Row(
              children: [
                _buildToggleSegment(
                  label: Lang.t('login_type_private'),
                  selected: isPrivat,
                  onTap: () => setState(() => _loginAsCompany = false),
                ),
                _buildToggleSegment(
                  label: Lang.t('login_type_company'),
                  selected: isUnternehmen,
                  onTap: () => setState(() => _loginAsCompany = true),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _loginAsCompany
              ? Lang.t('login_as_company')
              : Lang.t('login_as_private'),
          style: const TextStyle(color: _textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildToggleSegment({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected ? _accent : Colors.transparent,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _textPrimary : _textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.4),
        elevation: 0,
        title: const Text('Login', style: TextStyle(color: _textPrimary)),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_gradTop, _gradBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accentBorder),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 14,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LangToggleWidget(),
                      const SizedBox(height: 16),
                      const Icon(Icons.nightlife, size: 52, color: _accent),
                      const SizedBox(height: 8),
                      Text(
                        Lang.t('login_title'),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: _textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        Lang.t('login_subtitle'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _usernameController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: _textPrimary),
                        decoration: _dec(
                          label: Lang.t('login_username'),
                          hint: Lang.t('login_username_hint'),
                          icon: Icons.person,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        onChanged: (_) => setState(() {}),
                        obscureText: true,
                        style: const TextStyle(color: _textPrimary),
                        decoration: _dec(
                          label: Lang.t('login_password'),
                          hint: "•••••••",
                          icon: Icons.lock,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildAccountTypeToggle(),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_isFormValid && !_isLoading) ? _login : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            disabledBackgroundColor: _accent.withOpacity(0.4),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                              : Text(
                            Lang.t('login_btn'),
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => const CreateAccountScreen(),
                            ),
                          );
                        },
                        child: Text(
                          Lang.t('login_no_account'),
                          style: const TextStyle(
                            color: _textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _isLoading
                            ? null
                            : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const PasswordResetRequestScreen(),
                                  ),
                                );
                              },
                        child: const Text(
                          'Passwort vergessen?',
                          style: TextStyle(
                            color: _textSecondary,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
