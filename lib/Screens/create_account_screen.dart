import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'selection_screen.dart';
import 'party_map_screen.dart';
import 'login_screen.dart';
import 'nutzungsbedinungen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({Key? key}) : super(key: key);

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final TextEditingController _vornameController = TextEditingController();
  final TextEditingController _nachnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isSaving = false;

  int _selectedDay = 1;
  int _selectedMonth = 1;
  int _selectedYear = DateTime.now().year;

  bool get _isFormValid {
    return _vornameController.text.trim().isNotEmpty &&
        _nachnameController.text.trim().isNotEmpty &&
        _usernameController.text.trim().isNotEmpty &&
        _passwordController.text.trim().isNotEmpty;
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowRealNameHint());
  }

  Future<void> _maybeShowRealNameHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool('realNameHintDismissed') ?? false;
    if (dismissed || !mounted) return;

    bool dontShowAgain = false;
    await showDialog(
      context: context,
      builder: (context) {
        final accent = Colors.redAccent;
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          // macht den Dialog scrollbar -> kein gelb/schwarzer Overflow
          scrollable: true,
          title: Row(
            children: const [
              Icon(Icons.badge, color: Colors.redAccent),
              SizedBox(width: 8),
              Text(
                "Echten Namen verwenden",
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          content: StatefulBuilder(
            builder: (context, setStateDialog) {
              return ConstrainedBox(
                constraints: BoxConstraints(
                  // Max. 60% der Bildschirmhöhe, damit nix überläuft
                  maxHeight: MediaQuery.of(context).size.height * 0.60,
                  maxWidth: 520,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Text mit hervorgehobenen Schlüsselwörtern
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(color: Colors.white70, height: 1.35),
                          children: [
                            const TextSpan(text: "Bitte gib deinen "),
                            TextSpan(
                              text: "echten Vor- & Nachnamen",
                              style: TextStyle(fontWeight: FontWeight.w700, color: accent),
                            ),
                            const TextSpan(text: " an. "),
                            TextSpan(
                              text: "Hosts prüfen Anfragen",
                              style: TextStyle(fontWeight: FontWeight.w700, color: accent),
                            ),
                            const TextSpan(text: " – mit echtem Namen wirst du eher "),
                            TextSpan(
                              text: "zugelassen",
                              style: TextStyle(fontWeight: FontWeight.w700, color: accent),
                            ),
                            const TextSpan(text: " und bekommst die "),
                            TextSpan(
                              text: "beste Experience",
                              style: TextStyle(fontWeight: FontWeight.w700, color: accent),
                            ),
                            const TextSpan(text: "."),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        value: dontShowAgain,
                        onChanged: (v) => setStateDialog(() => dontShowAgain = v ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: accent,
                        contentPadding: EdgeInsets.zero,
                        title: const Text("Nicht mehr anzeigen", style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Verstanden", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (dontShowAgain) {
      await prefs.setBool('realNameHintDismissed', true);
    }
  }

  Future<void> _checkTermsAndSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final termsAccepted = prefs.getBool('termsAccepted') ?? false;
    final savedLanguage = prefs.getString('language');
    final savedCountry = prefs.getString('country');
    final savedCity = prefs.getString('city');

    if (!termsAccepted) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const TermsScreen()));
      return;
    }

    if (savedLanguage == null || savedCountry == null || savedCity == null) {
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SelectionScreen()));
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const PartyMapScreen()));
  }

  Future<void> _proceed() async {
    final vorname = _vornameController.text.trim();
    final nachname = _nachnameController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (!_isFormValid) return;

    final birthDate = DateTime(_selectedYear, _selectedMonth, _selectedDay);
    final age = _calculateAge(birthDate);

    if (age < 12) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Du musst mindestens 12 Jahre alt sein!")),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection("users")
          .where("username", isEqualTo: username)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Dieser Username ist bereits vergeben!")),
        );
        setState(() => _isSaving = false);
        return;
      }

      final docName = "$vorname$nachname";

      await FirebaseFirestore.instance.collection("users").doc(docName).set({
        "createdAt": FieldValue.serverTimestamp(),
        "vorname": vorname,
        "nachname": nachname,
        "username": username,
        "password": password,
        "age": age,
        "geburtsdatum": {"tag": _selectedDay, "monat": _selectedMonth, "jahr": _selectedYear},
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("vorname", vorname);
      await prefs.setString("nachname", nachname);
      await prefs.setString("username", username);
      await prefs.setString("password", password);

      await _checkTermsAndSelection();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Speichern: $e")),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final int currentYear = DateTime.now().year;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Account erstellen"),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 12,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_add, size: 64, color: Colors.redAccent),
                      const SizedBox(height: 20),

                      TextField(
                        controller: _vornameController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Vorname",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.person, color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        controller: _nachnameController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Nachname",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.person_outline, color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        controller: _usernameController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Username",
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.alternate_email, color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                          prefixIcon: const Icon(Icons.lock, color: Colors.redAccent),
                          filled: true,
                          fillColor: Colors.grey[850],
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 20),

                      const Text(
                        "Geburtsdatum",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                      const SizedBox(height: 10),

                      SizedBox(
                        height: 180,
                        child: Row(
                          children: [
                            Expanded(
                              child: CupertinoPicker(
                                backgroundColor: Colors.grey[850],
                                itemExtent: 32,
                                scrollController:
                                FixedExtentScrollController(initialItem: _selectedDay - 1),
                                onSelectedItemChanged: (index) => setState(() => _selectedDay = index + 1),
                                children: List.generate(
                                  31,
                                      (index) => Center(
                                    child: Text("${index + 1}",
                                        style: const TextStyle(color: Colors.white)),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: CupertinoPicker(
                                backgroundColor: Colors.grey[850],
                                itemExtent: 32,
                                scrollController:
                                FixedExtentScrollController(initialItem: _selectedMonth - 1),
                                onSelectedItemChanged: (index) =>
                                    setState(() => _selectedMonth = index + 1),
                                children: List.generate(
                                  12,
                                      (index) => Center(
                                    child: Text("${index + 1}",
                                        style: const TextStyle(color: Colors.white)),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: CupertinoPicker(
                                backgroundColor: Colors.grey[850],
                                itemExtent: 32,
                                scrollController:
                                FixedExtentScrollController(initialItem: currentYear - _selectedYear),
                                onSelectedItemChanged: (index) =>
                                    setState(() => _selectedYear = currentYear - index),
                                children: List.generate(
                                  currentYear - 1900 + 1,
                                      (index) => Center(
                                    child: Text("${currentYear - index}",
                                        style: const TextStyle(color: Colors.white)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 25),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_isFormValid && !_isSaving) ? _proceed : null,
                          style: ElevatedButton.styleFrom(
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ).copyWith(
                            backgroundColor: MaterialStateProperty.resolveWith<Color>(
                                  (states) =>
                              states.contains(MaterialState.disabled)
                                  ? Colors.redAccent.withOpacity(0.4)
                                  : Colors.redAccent,
                            ),
                          ),
                          child: _isSaving
                              ? const CircularProgressIndicator(color: Colors.white)
                              : const Text("Account erstellen",
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(height: 8),

                      TextButton(
                        onPressed: () {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(builder: (_) => const LoginScreen()),
                          );
                        },
                        child: const Text("Ich habe schon einen Account",
                            style: TextStyle(color: Colors.white54)),
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
