// lib/Screens/phone_upgrade_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:party_pin/Screens/home/home_shell.dart';

class PhoneUpgradeScreen extends StatefulWidget {
  const PhoneUpgradeScreen({Key? key}) : super(key: key);

  @override
  State<PhoneUpgradeScreen> createState() => _PhoneUpgradeScreenState();
}

class _PhoneUpgradeScreenState extends State<PhoneUpgradeScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  bool _isLoading = false;
  bool _codeSent = false;

  String? _username;
  bool _isBar = false;

  String? _verificationId;
  int? _resendToken;

  @override
  void initState() {
    super.initState();
    _loadUserFromPrefs();
  }

  Future<void> _loadUserFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final uname = prefs.getString("currentUsername");
    final isBar = prefs.getBool("isBar") ?? false;
    final savedPhone =
        prefs.getString("phoneNumber") ?? prefs.getString("phone");

    setState(() {
      _username = uname;
      _isBar = isBar;
      if (savedPhone != null && savedPhone.isNotEmpty) {
        _phoneController.text = savedPhone;
      }
    });

    if (uname == null || uname.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Kein eingeloggter User gefunden.")),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String? _phoneValidator(String? v) {
    final val = v?.trim() ?? '';
    if (val.isEmpty) return "Telefonnummer ist Pflicht";
    if (!RegExp(r'^\+?[0-9 ]{6,}$').hasMatch(val)) {
      return "Ungültige Telefonnummer";
    }
    return null;
  }

  Future<void> _sendCode() async {
    if (_isLoading) return;
    final uname = _username?.trim();
    if (uname == null || uname.isEmpty) return;

    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) return;

    final phone = _phoneController.text.trim();

    setState(() => _isLoading = true);

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Android kann manchmal automatisch verifizieren
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
          } catch (_) {}
          await _onVerified(phone);
        },
        verificationFailed: (FirebaseAuthException e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Verifizierung fehlgeschlagen: ${e.message}")),
          );
        },
        codeSent: (String verificationId, int? resendToken) {
          setState(() {
            _verificationId = verificationId;
            _resendToken = resendToken;
            _codeSent = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("SMS-Code gesendet.")),
          );
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Senden des Codes: $e")),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_isLoading) return;
    final uname = _username?.trim();
    if (uname == null || uname.isEmpty) return;

    final code = _codeController.text.trim();
    if (code.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bitte gültigen SMS-Code eingeben.")),
      );
      return;
    }
    if (_verificationId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Kein Verifizierungscode vorhanden.")),
      );
      return;
    }

    final phone = _phoneController.text.trim();

    setState(() => _isLoading = true);

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: code,
      );

      // FirebaseAuth-User anmelden (wird nur für Verifizierung genutzt)
      await FirebaseAuth.instance.signInWithCredential(credential);

      // Wenn das ohne Fehler klappt → Nummer als verifiziert speichern
      await _onVerified(phone);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Falscher Code: ${e.message}")),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler bei der Codeprüfung: $e")),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Wird aufgerufen, wenn SMS-Verifizierung erfolgreich war.
  Future<void> _onVerified(String phone) async {
    final uname = _username?.trim();
    if (uname == null || uname.isEmpty) return;

    try {
      final collectionName = _isBar ? "bars" : "users";
      final col = FirebaseFirestore.instance.collection(collectionName);

      // Bei users ist die Doc-ID != username → immer über Feld "username"
      final query =
      await col.where("username", isEqualTo: uname).limit(1).get();

      if (query.docs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                "Kein ${_isBar ? 'Bar-' : ''}Account für $uname gefunden."),
          ),
        );
        return;
      }

      final docRef = query.docs.first.reference;

      await docRef.set({
        "phoneNumber": phone,
        "phone": phone,
        "authVersion": 2,
        "phoneVerified": true,
        "phoneUpdatedAt": FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("phoneNumber", phone);
      await prefs.setInt("authVersion", 2);
      await prefs.setBool("phoneVerified", true);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Telefonnummer verifiziert.")),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomeShell()),
            (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Speichern: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReady = _username != null && _username!.trim().isNotEmpty;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text("Telefon-Upgrade"),
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
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.phone_iphone,
                            size: 64, color: Colors.redAccent),
                        const SizedBox(height: 16),
                        const Text(
                          "Telefonnummer verifizieren",
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isBar
                              ? "Damit wir deinen Bar-Account besser schützen, bestätige bitte deine Telefonnummer."
                              : "Wir stellen auf Login mit Telefonnummer um. Bitte bestätige deine Nummer mit einem SMS-Code.",
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 20),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            "Eingeloggt als: ${_username ?? '-'}",
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          readOnly: _codeSent, // nach Code-Senden nicht mehr ändern
                          style: const TextStyle(color: Colors.white),
                          validator: _phoneValidator,
                          decoration: InputDecoration(
                            labelText: "Telefonnummer",
                            hintText: "+43 660 ...",
                            labelStyle:
                            const TextStyle(color: Colors.white70),
                            hintStyle:
                            const TextStyle(color: Colors.white38),
                            prefixIcon: const Icon(Icons.phone,
                                color: Colors.redAccent),
                            filled: true,
                            fillColor: Colors.grey[850],
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_codeSent) ...[
                          TextFormField(
                            controller: _codeController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: "SMS-Code",
                              hintText: "z. B. 123456",
                              labelStyle:
                              const TextStyle(color: Colors.white70),
                              hintStyle:
                              const TextStyle(color: Colors.white38),
                              prefixIcon: const Icon(Icons.sms,
                                  color: Colors.redAccent),
                              filled: true,
                              fillColor: Colors.grey[850],
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: (!_isLoading && isReady)
                                ? (_codeSent ? _verifyCode : _sendCode)
                                : null,
                            style: ElevatedButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding:
                              const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ).copyWith(
                              backgroundColor:
                              MaterialStateProperty.resolveWith<Color>(
                                      (states) {
                                    if (states
                                        .contains(MaterialState.disabled)) {
                                      return Colors.redAccent.withOpacity(0.4);
                                    }
                                    return Colors.redAccent;
                                  }),
                            ),
                            child: _isLoading
                                ? const CircularProgressIndicator(
                              color: Colors.white,
                            )
                                : Text(
                              _codeSent
                                  ? "Code bestätigen"
                                  : "SMS-Code senden",
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        if (_codeSent) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed:
                            _isLoading ? null : _sendCode, // erneut senden
                            child: const Text(
                              "Code erneut senden",
                              style: TextStyle(color: Colors.white54),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        const Text(
                          "Für Tests kannst du in Firebase eine Test-Telefonnummer mit festem Code anlegen.",
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
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
