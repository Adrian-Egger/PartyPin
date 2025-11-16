// lib/Screens/create_account_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _vornameController = TextEditingController();
  final TextEditingController _nachnameController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final _vornameNode = FocusNode();
  final _nachnameNode = FocusNode();
  final _usernameNode = FocusNode();
  final _passwordNode = FocusNode();

  bool _isSaving = false;
  bool _pwVisible = false;
  bool _usernameTaken = false;
  bool _usernameChecked = false;

  int _selectedDay = 1;
  int _selectedMonth = 1;
  int _selectedYear = DateTime.now().year;

  static const _bg = Color(0xFF0E0F12);
  static const _gradTop = Color(0xFF0E0F12);
  static const _gradBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF15171C);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _card = Color(0xFF1C1F26);
  static const _textPrimary = Colors.white;
  static const _textSecondary = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);
  static const _secondary = Color(0xFF00C2A8);

  bool get _isFormFilled =>
      _vornameController.text.trim().isNotEmpty &&
          _nachnameController.text.trim().isNotEmpty &&
          _usernameController.text.trim().isNotEmpty &&
          _passwordController.text.trim().isNotEmpty;

  bool get _isFormValid =>
      _isFormFilled &&
          (_formKey.currentState?.validate() ?? false) &&
          !_usernameTaken;

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  Future<void> _checkUsernameAvailability(String username) async {
    if (username.trim().isEmpty) {
      setState(() {
        _usernameTaken = false;
        _usernameChecked = false;
      });
      return;
    }
    try {
      final query = await FirebaseFirestore.instance
          .collection("users")
          .where("username", isEqualTo: username.trim())
          .limit(1)
          .get();

      setState(() {
        _usernameTaken = query.docs.isNotEmpty;
        _usernameChecked = true;
      });
    } catch (_) {
      setState(() {
        _usernameTaken = false;
        _usernameChecked = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowRealNameHint());

    _usernameController.addListener(() {
      final v = _usernameController.text;
      final normalized = v.replaceAll(' ', '_');

      if (v != normalized) {
        final sel = _usernameController.selection;
        _usernameController.value = TextEditingValue(
          text: normalized,
          selection: sel.copyWith(
            baseOffset: normalized.length,
            extentOffset: normalized.length,
          ),
        );
      }

      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted && _usernameController.text == normalized) {
          _checkUsernameAvailability(normalized);
        }
      });

      setState(() {});
    });

    _passwordController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _vornameController.dispose();
    _nachnameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _vornameNode.dispose();
    _nachnameNode.dispose();
    _usernameNode.dispose();
    _passwordNode.dispose();
    super.dispose();
  }

  Future<void> _maybeShowRealNameHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool('realNameHintDismissed') ?? false;
    if (dismissed || !mounted) return;

    bool dontShowAgain = false;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          scrollable: true,
          title: Row(
            children: const [
              Icon(Icons.badge, color: _accent),
              SizedBox(width: 8),
              Text(
                "Echten Namen verwenden",
                style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          content: const Text(
            "Bitte gib deinen echten Vor- & Nachnamen an. Hosts prüfen Anfragen – "
                "mit echtem Namen wirst du eher zugelassen und bekommst die beste Experience.",
            style: TextStyle(color: _textSecondary, height: 1.35),
          ),
          actions: [
            StatefulBuilder(
              builder: (context, setStateDialog) {
                return Row(
                  children: [
                    Checkbox(
                      value: dontShowAgain,
                      onChanged: (v) => setStateDialog(() => dontShowAgain = v ?? false),
                      activeColor: _accent,
                    ),
                    const Expanded(
                      child: Text("Nicht mehr anzeigen",
                          style: TextStyle(color: _textSecondary)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Verstanden",
                          style: TextStyle(color: _textPrimary)),
                    ),
                  ],
                );
              },
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
    if (!termsAccepted) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TermsScreen()),
      );
    }

    final prefsAfterTerms = await SharedPreferences.getInstance();
    String? savedLanguage = prefsAfterTerms.getString('language');
    String? savedCountry = prefsAfterTerms.getString('country');
    String? savedCity = prefsAfterTerms.getString('city');

    if (savedLanguage == null || savedCountry == null || savedCity == null) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SelectionScreen()),
      );
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const PartyMapScreen()),
    );
  }

  double _passwordStrength(String pw) {
    if (pw.isEmpty) return 0;
    int score = 0;
    if (pw.length >= 8) score++;
    if (RegExp(r'[A-Z]').hasMatch(pw)) score++;
    if (RegExp(r'[a-z]').hasMatch(pw)) score++;
    if (RegExp(r'\d').hasMatch(pw)) score++;
    if (RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=]').hasMatch(pw)) score++;
    return (score / 5).clamp(0, 1).toDouble();
  }

  String _passwordLabel(double s) {
    if (s <= 0.2) return "sehr schwach";
    if (s <= 0.4) return "schwach";
    if (s <= 0.6) return "ok";
    if (s <= 0.8) return "gut";
    return "stark";
  }

  // ----------------------
  // WICHTIG: HIER DER FIX
  // ----------------------
  Future<void> _proceed() async {
    if (!_isFormValid) return;

    final vorname = _vornameController.text.trim();
    final nachname = _nachnameController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

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
          .limit(1)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Dieser Username ist bereits vergeben!")),
        );
        setState(() {
          _isSaving = false;
          _usernameTaken = true;
          _usernameChecked = true;
        });
        return;
      }

      // Username als Doc-ID → eindeutig
      await FirebaseFirestore.instance
          .collection("users")
          .doc(username)
          .set({
        "createdAt": FieldValue.serverTimestamp(),
        "vorname": vorname,
        "nachname": nachname,
        "username": username,
        "password": password,
        "age": age,
        "geburtsdatum": {
          "tag": _selectedDay,
          "monat": _selectedMonth,
          "jahr": _selectedYear,
        },
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("vorname", vorname);
      await prefs.setString("nachname", nachname);
      await prefs.setString("username", username);

      // LOGIN STATUS SPEICHERN
      await prefs.setBool("isLoggedIn", true);
      await prefs.setString("currentUsername", username);

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

  InputDecoration _dec({
    required String label,
    String? hint,
    IconData? icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textSecondary),
      hintText: hint,
      hintStyle: const TextStyle(color: _textSecondary),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      suffixIcon: suffix,
      filled: true,
      fillColor: _card,
      contentPadding:
      const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
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

  String? _nameValidator(String? v) {
    if (v == null || v.trim().isEmpty) return "Pflichtfeld";
    if (v.trim().length < 2) return "Zu kurz";
    return null;
  }

  String? _usernameValidator(String? v) {
    final val = v?.trim() ?? '';
    if (val.isEmpty) return "Pflichtfeld";
    if (!RegExp(r'^[a-z0-9_.-]{3,20}$').hasMatch(val)) {
      return "3–20 Zeichen, a–z, 0–9, _ . -";
    }
    if (_usernameChecked && _usernameTaken) return "Bereits vergeben";
    return null;
  }

  String? _passwordValidator(String? v) {
    final pw = v ?? '';
    if (pw.isEmpty) return "Pflichtfeld";
    if (pw.length < 6) return "Mind. 6 Zeichen";
    return null;
  }

  Widget _passwordMeter() {
    final s = _passwordStrength(_passwordController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: s,
            minHeight: 6,
            backgroundColor: Colors.white12,
            color: s < .4
                ? _accent
                : (s < .7 ? Colors.orangeAccent : _secondary),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "Passwort: ${_passwordLabel(s)}",
          style: const TextStyle(
              color: _textSecondary, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _birthRow() {
    final int currentYear = DateTime.now().year;

    Widget _columnLabel(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(t,
          style: const TextStyle(
              color: _textSecondary, fontWeight: FontWeight.w600)),
    );

    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Geburtsdatum",
              style: TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16)),
          const SizedBox(height: 10),
          SizedBox(
            height: 180,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _columnLabel("Tag"),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController: FixedExtentScrollController(
                              initialItem: _selectedDay - 1),
                          onSelectedItemChanged: (index) =>
                              setState(() => _selectedDay = index + 1),
                          children: List.generate(
                            31,
                                (index) => Center(
                              child: Text("${index + 1}",
                                  style: const TextStyle(
                                      color: _textPrimary)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      _columnLabel("Monat"),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController:
                          FixedExtentScrollController(
                              initialItem: _selectedMonth - 1),
                          onSelectedItemChanged: (index) =>
                              setState(() =>
                              _selectedMonth = index + 1),
                          children: List.generate(
                            12,
                                (index) => Center(
                              child: Text("${index + 1}",
                                  style: const TextStyle(
                                      color: _textPrimary)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      _columnLabel("Jahr"),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController:
                          FixedExtentScrollController(
                              initialItem:
                              DateTime.now().year -
                                  _selectedYear),
                          onSelectedItemChanged: (index) =>
                              setState(() => _selectedYear =
                                  DateTime.now().year - index),
                          children: List.generate(
                            currentYear - 1900 + 1,
                                (index) => Center(
                              child: Text(
                                  "${DateTime.now().year - index}",
                                  style: const TextStyle(
                                      color: _textPrimary)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardForm() {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Container(
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _panelBorder),
          boxShadow: const [
            BoxShadow(
                color: Color(0x33000000),
                blurRadius: 14,
                offset: Offset(0, 10)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Icon(Icons.person_add,
                  size: 56, color: _accent),
              const SizedBox(height: 18),

              TextFormField(
                controller: _vornameController,
                focusNode: _vornameNode,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) =>
                    _nachnameNode.requestFocus(),
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'^\s'))
                ],
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                    label: "Vorname",
                    icon: Icons.person,
                    hint: "z. B. Adrian"),
                validator: _nameValidator,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _nachnameController,
                focusNode: _nachnameNode,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) =>
                    _usernameNode.requestFocus(),
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'^\s'))
                ],
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                    label: "Nachname",
                    icon: Icons.person_outline,
                    hint: "z. B. Egger"),
                validator: _nameValidator,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _usernameController,
                focusNode: _usernameNode,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) =>
                    _passwordNode.requestFocus(),
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                  label: "Username",
                  icon: Icons.alternate_email,
                  hint: "3–20 Zeichen, a–z, 0–9, _.-",
                  suffix: _usernameController.text.isEmpty
                      ? null
                      : (_usernameChecked
                      ? (_usernameTaken
                      ? const Icon(Icons.close_rounded,
                      color: _accent)
                      : const Icon(Icons.check_circle,
                      color: _secondary))
                      : const SizedBox(
                    width: 18,
                    height: 18,
                    child: Padding(
                      padding: EdgeInsets.all(2.0),
                      child: CircularProgressIndicator(
                          strokeWidth: 2),
                    ),
                  )),
                ),
                validator: _usernameValidator,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _passwordController,
                focusNode: _passwordNode,
                textInputAction: TextInputAction.done,
                obscureText: !_pwVisible,
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                  label: "Passwort",
                  icon: Icons.lock,
                  hint: "mind. 6 Zeichen",
                  suffix: IconButton(
                    tooltip:
                    _pwVisible ? "Verbergen" : "Anzeigen",
                    onPressed: () =>
                        setState(() => _pwVisible = !_pwVisible),
                    icon: Icon(
                        _pwVisible
                            ? Icons.visibility_off
                            : Icons.visibility,
                        color: Colors.white70),
                  ),
                ),
                validator: _passwordValidator,
              ),
              _passwordMeter(),
              const SizedBox(height: 16),

              _birthRow(),
              const SizedBox(height: 22),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isFormValid && !_isSaving)
                      ? _proceed
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    disabledBackgroundColor:
                    Colors.redAccent.withOpacity(0.4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                        BorderRadius.circular(12)),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2),
                  )
                      : const Text("Account erstellen",
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),

              TextButton(
                onPressed: _isSaving
                    ? null
                    : () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                        const LoginScreen()),
                  );
                },
                child: const Text(
                  "Ich habe schon einen Account",
                  style: TextStyle(
                      color: _textSecondary,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Account erstellen",
          style: TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700),
        ),
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
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                  maxWidth: 560),
              child: _cardForm(),
            ),
          ),
        ),
      ),
    );
  }
}
