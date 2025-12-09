// lib/Screens/login_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'party_map_screen.dart';
import 'selection_screen.dart';
import 'create_account_screen.dart';
import 'nutzungsbedinungen.dart';
import 'package:party_pin/Upgrade/phone_upgrade_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _loginAsBar = false; // NEU: Auswahl, ob als Bar-Account eingeloggt werden soll

  bool get _isFormValid {
    return _usernameController.text.trim().isNotEmpty &&
        _passwordController.text.trim().isNotEmpty;
  }

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

    // 1) Terms / AGB
    if (!termsAccepted) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const TermsScreen()),
      );
      return;
    }

    // 2) Location-Auswahl
    if (!hasLocationData) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SelectionScreen()),
      );
      return;
    }

    // 3) Alles gesetzt → Map
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const PartyMapScreen()),
    );
  }

  Future<void> _login() async {
    final usernameInput = _usernameController.text.trim();
    final passwordInput = _passwordController.text.trim();

    if (!_isFormValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bitte Username und Passwort eingeben!")),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      Map<String, dynamic>? userData;
      String? userType;   // "user" oder "bar"
      String? barDocId;   // tatsächliche Bar-Doc-ID in Firestore

      // 1) In users suchen (über Feld "username")
      final userQuery = await FirebaseFirestore.instance
          .collection("users")
          .where("username", isEqualTo: usernameInput)
          .limit(1)
          .get();

      if (userQuery.docs.isNotEmpty) {
        userData = userQuery.docs.first.data();
        userType = "user";
      } else {
        // 2) In bars suchen (zuerst docId = username, dann Feld "username")
        final barsCol = FirebaseFirestore.instance.collection("bars");

        final barDocById = await barsCol.doc(usernameInput).get();
        if (barDocById.data() != null) {
          userData = barDocById.data();
          userType = "bar";
          barDocId = barDocById.id;
        } else {
          final barQuery = await barsCol
              .where("username", isEqualTo: usernameInput)
              .limit(1)
              .get();
          if (barQuery.docs.isNotEmpty) {
            final barDoc = barQuery.docs.first;
            userData = barDoc.data();
            userType = "bar";
            barDocId = barDoc.id;
          }
        }
      }

      if (userData == null || userType == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Username nicht gefunden!")),
        );
        return;
      }

      // Passwort prüfen
      final storedPw = (userData["password"] ?? "").toString();
      if (storedPw != passwordInput) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Falsches Passwort!")),
        );
        return;
      }

      // Harter Check: Auswahl (User/Bar) muss zum Account-Typ passen
      if (_loginAsBar && userType != "bar") {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Dieser Account ist kein Bar-Account.")),
        );
        return;
      }
      if (!_loginAsBar && userType != "user") {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
              Text("Dieser Account ist ein Bar-Account. Bitte als Bar einloggen.")),
        );
        return;
      }

      // auth / phone
      final authVersion = (userData["authVersion"] ?? 1) as int;
      final phoneNumber = userData["phoneNumber"] as String?;
      final phoneVerified = userData["phoneVerified"] == true;

      // Terms / Location aus Firestore lesen
      final firestoreTermsAccepted = userData["termsAccepted"] == true;
      final firestoreLanguage = (userData["language"] ?? "") as String;
      final firestoreCountry = (userData["country"] ?? "") as String;
      final firestoreCity = (userData["city"] ?? "") as String;

      final latRaw = userData["selectedLat"];
      final lngRaw = userData["selectedLng"];
      final double? firestoreLat =
      latRaw is num ? latRaw.toDouble() : null;
      final double? firestoreLng =
      lngRaw is num ? lngRaw.toDouble() : null;

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

      // Terms aus Firestore in Local spiegeln
      await prefs.setBool("termsAccepted", firestoreTermsAccepted);

      // Location aus Firestore in Local spiegeln (falls vorhanden)
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

      // User vs Bar-spezifische Infos + Flags für PartyMapScreen
      if (userType == "user") {
        // normaler User
        await prefs.setBool("isBar", false);         // dein altes Flag
        await prefs.setBool("isBarAccount", false);  // NEU: von PartyMapScreen verwendet
        await prefs.remove("barId");                 // keine Bar verknüpft

        await prefs.setString(
            "vorname", (userData["vorname"] ?? "").toString());
        await prefs.setString(
            "nachname", (userData["nachname"] ?? "").toString());
      } else {
        // Bar-Account
        await prefs.setBool("isBar", true);          // dein altes Flag
        await prefs.setBool("isBarAccount", true);   // NEU: von PartyMapScreen verwendet

        if (barDocId != null) {
          await prefs.setString("barId", barDocId);
        } else {
          // sollte eigentlich nicht passieren, zur Sicherheit:
          await prefs.remove("barId");
        }

        await prefs.setString(
            "barName", (userData["barName"] ?? "").toString());
      }

      // Phone-Upgrade (wenn du es wieder aktivieren willst, hier sauber einbauen) !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
      // final mustUpgradePhone =
      //     phoneNumber == null || phoneNumber.trim().isEmpty;
      // if (mustUpgradePhone) {
      //   if (!mounted) return;
      //   Navigator.pushReplacement(
      //     context,
      //     MaterialPageRoute(
      //       builder: (_) => const PhoneUpgradeScreen(),
      //     ),
      //   );
      //   return;
      // }

      // Wenn Telefonnummer vorhanden bzw. Phone-Upgrade deaktiviert -> normale Navigation
      await _checkNavigation();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Login: $e")),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Login'),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0f0f0f), Color(0xFF1f1f1f)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                color: Colors.grey[900]!.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 12,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.nightlife,
                          size: 64, color: Colors.redAccent),
                      const SizedBox(height: 16),
                      const Text(
                        'Login',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Bitte melde dich mit deinem Account an',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _usernameController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Username",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.person,
                              color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        onChanged: (_) => setState(() {}),
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Passwort",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.lock,
                              color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // NEU: Auswahl, ob als Bar einloggen
                      CheckboxListTile(
                        value: _loginAsBar,
                        onChanged: (v) {
                          setState(() {
                            _loginAsBar = v ?? false;
                          });
                        },
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        activeColor: Colors.redAccent,
                        title: const Text(
                          "Als Bar-Account einloggen",
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),

                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                          (_isFormValid && !_isLoading) ? _login : null,
                          style: ElevatedButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ).copyWith(
                            backgroundColor:
                            MaterialStateProperty.resolveWith<Color>(
                                    (states) {
                                  if (states.contains(MaterialState.disabled)) {
                                    return Colors.redAccent.withOpacity(0.4);
                                  }
                                  return Colors.redAccent;
                                }),
                          ),
                          child: _isLoading
                              ? const CircularProgressIndicator(
                              color: Colors.white)
                              : const Text(
                            'Login',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                const CreateAccountScreen()),
                          );
                        },
                        child: const Text(
                          "Noch keinen Account? Jetzt registrieren",
                          style: TextStyle(color: Colors.white54),
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
    );
  }
}
