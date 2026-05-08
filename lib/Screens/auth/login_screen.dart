// lib/Screens/login_screen.dart
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../home/selection_screen.dart';
import 'create_account_screen.dart';
import 'nutzungsbedinungen.dart';
import '../home/home_shell.dart';
import 'package:party_pin/Upgrade/phone_upgrade_screen.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';
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

  static String _hashPassword(String username, String password) {
    final key = utf8.encode(username.toLowerCase());
    final bytes = utf8.encode(password);
    return Hmac(sha256, key).convert(bytes).toString();
  }

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

  Future<void> _login() async {
    final usernameInput = _usernameController.text.trim();
    final passwordInput = _passwordController.text.trim();

    if (!_isFormValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Lang.t('login_err_empty')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      Map<String, dynamic>? userData;
      String? userType; // "user" oder "bar"
      String? barDocId;
      DocumentReference<Map<String, dynamic>>? foundDocRef;

      // 1) Privatkonten in "users" suchen (Feld username)
      final userQuery = await FirebaseFirestore.instance
          .collection("users")
          .where("username", isEqualTo: usernameInput)
          .limit(1)
          .get();

      if (userQuery.docs.isNotEmpty) {
        userData = userQuery.docs.first.data();
        userType = "user";
        foundDocRef = userQuery.docs.first.reference;
      } else {
        // 2) Unternehmens-Accounts in "bars" suchen
        final barsCol = FirebaseFirestore.instance.collection("bars");

        // Variante 1: DocID == username
        final barDocById = await barsCol.doc(usernameInput).get();
        if (barDocById.data() != null) {
          userData = barDocById.data();
          userType = "bar";
          barDocId = barDocById.id;
          foundDocRef = barDocById.reference;
        } else {
          // Variante 2: Feld username
          final barQuery = await barsCol
              .where("username", isEqualTo: usernameInput)
              .limit(1)
              .get();
          if (barQuery.docs.isNotEmpty) {
            final barDoc = barQuery.docs.first;
            userData = barDoc.data();
            userType = "bar";
            barDocId = barDoc.id;
            foundDocRef = barDoc.reference;
          }
        }
      }

      if (userData == null || userType == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Lang.t('login_err_not_found')),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        return;
      }

      // ── Passwort prüfen (Hash-Vergleich + Migrations-Fallback) ────────────
      final inputHash = _hashPassword(usernameInput, passwordInput);
      final storedHash = (userData['passwordHash'] ?? '').toString();
      final storedPlain = (userData['password'] ?? '').toString();

      bool passwordOk = false;

      if (storedHash.isNotEmpty && storedHash == inputHash) {
        // Moderner Account: Hash stimmt
        passwordOk = true;
      } else if (storedPlain.isNotEmpty && storedPlain == passwordInput) {
        // Alter Account (Klartext): stimmt → migrieren
        passwordOk = true;
        try {
          await foundDocRef?.update({
            'passwordHash': inputHash,
            'password': FieldValue.delete(),
          });
        } catch (_) {}
      }

      if (!passwordOk) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(Lang.t('login_err_wrong_pw')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        return;
      }

      // Bar-Account muss freigeschaltet sein. status: "pending" / "rejected"
      // landet hier — Login wird abgewiesen mit verstaendlichem Hinweis.
      if (userType == "bar") {
        final status = (userData["status"] ?? "").toString();
        if (status == "pending") {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text(
                'Dein Bar-Account wartet noch auf Freischaltung durch das Admin-Team.'),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ));
          return;
        }
        if (status == "rejected" || status == "declined") {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text(
                'Dein Bar-Account wurde abgelehnt. Bitte kontaktiere den Support.'),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ));
          return;
        }
      }

      // Typ-Kontrolle: Auswahl muss zum Account-Typ passen
      if (_loginAsCompany && userType != "bar") {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Lang.t('login_err_not_company')),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        return;
      }
      if (!_loginAsCompany && userType != "user") {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Lang.t('login_err_is_company')),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        return;
      }

      // Auth / Phone
      final authVersion = (userData["authVersion"] ?? 1) as int;
      final phoneNumber = userData["phoneNumber"] as String?;
      final phoneVerified = userData["phoneVerified"] == true;

      // Terms / Location aus Firestore
      final firestoreTermsAccepted = userData["termsAccepted"] == true;
      final firestoreLanguage = (userData["language"] ?? "") as String;
      final firestoreCountry = (userData["country"] ?? "") as String;
      final firestoreCity = (userData["city"] ?? "") as String;
      final latRaw = userData["selectedLat"];
      final lngRaw = userData["selectedLng"];
      final double? firestoreLat = latRaw is num ? latRaw.toDouble() : null;
      final double? firestoreLng = lngRaw is num ? lngRaw.toDouble() : null;

      final prefs = await SharedPreferences.getInstance();

      // Gemeinsame Infos
      final storedUsername = (userData["username"] ?? usernameInput).toString();
      await prefs.setString("username", storedUsername);
      await prefs.setString("currentUsername", storedUsername);
      await prefs.setBool("isLoggedIn", true);

      await prefs.setInt("authVersion", authVersion);
      await prefs.setBool("phoneVerified", phoneVerified);

      if (phoneNumber != null && phoneNumber.isNotEmpty) {
        await prefs.setString("phoneNumber", phoneNumber);
      } else {
        await prefs.remove("phoneNumber");
      }

      // Terms spiegeln
      await prefs.setBool("termsAccepted", firestoreTermsAccepted);

      // Location spiegeln (falls vorhanden)
      final hasFirestoreLocation =
          firestoreCity.isNotEmpty &&
              firestoreCountry.isNotEmpty &&
              firestoreLat != null &&
              firestoreLng != null &&
              firestoreLanguage.isNotEmpty;

      if (hasFirestoreLocation) {
        await prefs.setString("city", firestoreCity);
        await prefs.setString("country", firestoreCountry);
        await prefs.setString("language", firestoreLanguage);
        await prefs.setDouble("selectedLat", firestoreLat);
        await prefs.setDouble("selectedLng", firestoreLng);
      } else {
        await prefs.remove("city");
        await prefs.remove("country");
        await prefs.remove("language");
        await prefs.remove("selectedLat");
        await prefs.remove("selectedLng");
      }

      // Privat vs Unternehmen
      if (userType == "user") {
        await prefs.setBool("isBar", false); // legacy
        await prefs.setBool("isBarAccount", false);
        await prefs.remove("barId");

        await prefs.setString("vorname", (userData["vorname"] ?? "").toString());
        await prefs.setString("nachname", (userData["nachname"] ?? "").toString());
      } else {
        await prefs.setBool("isBar", true); // legacy
        await prefs.setBool("isBarAccount", true);

        if (barDocId != null && barDocId.isNotEmpty) {
          await prefs.setString("barId", barDocId);
        } else {
          await prefs.remove("barId");
        }

        await prefs.setString("barName", (userData["barName"] ?? "").toString());
      }

      // Optional Phone-Upgrade (derzeit auskommentiert im Original)
      // final mustUpgradePhone = phoneNumber == null || phoneNumber.trim().isEmpty;
      // if (mustUpgradePhone) {
      //   if (!mounted) return;
      //   Navigator.of(context).pushAndRemoveUntil(
      //     MaterialPageRoute(builder: (_) => const PhoneUpgradeScreen()),
      //     (route) => false,
      //   );
      //   return;
      // }

      // Save FCM token now that username is known
      try { await NotificationService.saveCurrentToken(); } catch (_) {}

      // lastActive + platform fürs Admin-Dashboard nachziehen.
      // Telemetrie — Login-Flow fällt NICHT, wenn das hier scheitert.
      try {
        await foundDocRef?.update({
          'lastActive': FieldValue.serverTimestamp(),
          'platform': PlatformInfo.detectName(),
        });
      } catch (_) {}

      await _checkNavigation();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${Lang.t('login_err_generic')}: $e"),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
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
