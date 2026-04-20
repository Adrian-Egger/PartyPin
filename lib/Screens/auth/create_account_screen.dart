// lib/Screens/create_account_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../home/selection_screen.dart';
import 'login_screen.dart';
import 'nutzungsbedinungen.dart';
import '../home/home_shell.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

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
  final TextEditingController _barNameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _availabilityController = TextEditingController();

  final _vornameNode = FocusNode();
  final _nachnameNode = FocusNode();
  final _usernameNode = FocusNode();
  final _passwordNode = FocusNode();

  bool _isSaving = false;
  bool _pwVisible = false;
  bool _usernameTaken = false;
  bool _usernameChecked = false;

  // false = Privat, true = Unternehmen/Lokal
  bool _isBar = false;

  int _selectedDay = 1;
  int _selectedMonth = 1;
  int _selectedYear = DateTime.now().year;

  static const _bg = AppColors.bgTop;
  static const _gradTop = AppColors.bgTop;
  static const _gradBottom = AppColors.bgBottom;
  static const _panel = Color(0xFF15171C);
  static const _card = AppColors.panel;
  static const _textPrimary = AppColors.text;
  static const _textSecondary = AppColors.muted;
  static const _accent = AppColors.accent;
  static const _secondary = AppColors.teal;

  bool get _usernameHasUppercase =>
      RegExp(r'[A-Z]').hasMatch(_usernameController.text);

  bool get _isFormFilled {
    if (_isBar) {
      return _barNameController.text.trim().isNotEmpty &&
          _usernameController.text.trim().isNotEmpty &&
          _passwordController.text.trim().isNotEmpty &&
          _emailController.text.trim().isNotEmpty &&
          _phoneController.text.trim().isNotEmpty &&
          _availabilityController.text.trim().isNotEmpty;
    } else {
      return _vornameController.text.trim().isNotEmpty &&
          _nachnameController.text.trim().isNotEmpty &&
          _usernameController.text.trim().isNotEmpty &&
          _passwordController.text.trim().isNotEmpty;
    }
  }

  bool get _canSubmit => _isFormFilled && !_usernameTaken && !_isSaving;

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
    final trimmed = username.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _usernameTaken = false;
        _usernameChecked = false;
      });
      return;
    }

    try {
      final collectionName = _isBar ? "bars" : "users";
      final query = await FirebaseFirestore.instance
          .collection(collectionName)
          .where("username", isEqualTo: trimmed)
          .limit(1)
          .get();

      setState(() {
        _usernameTaken = query.docs.isNotEmpty;
        _usernameChecked = true;
      });
    } catch (_) {
      setState(() {
        _usernameTaken = false;
        _usernameChecked = true;
      });
    }
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
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

      _onFieldChanged();
    });

    _passwordController.addListener(_onFieldChanged);
    _vornameController.addListener(_onFieldChanged);
    _nachnameController.addListener(_onFieldChanged);
    _barNameController.addListener(_onFieldChanged);
    _emailController.addListener(_onFieldChanged);
    _phoneController.addListener(_onFieldChanged);
    _availabilityController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _vornameController.dispose();
    _nachnameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _barNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _availabilityController.dispose();

    _vornameNode.dispose();
    _nachnameNode.dispose();
    _usernameNode.dispose();
    _passwordNode.dispose();
    super.dispose();
  }

  Future<void> _maybeShowRealNameHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool('realNameHintDismissed') ?? false;
    if (dismissed || !mounted || _isBar) return;

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
            children: [
              const Icon(Icons.badge, color: _accent),
              const SizedBox(width: 8),
              Text(
                Lang.t('reg_real_name_title'),
                style: const TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          content: Text(
            Lang.t('reg_real_name_body'),
            style: const TextStyle(color: _textSecondary, height: 1.35),
          ),
          actions: [
            StatefulBuilder(
              builder: (context, setStateDialog) {
                return Row(
                  children: [
                    Checkbox(
                      value: dontShowAgain,
                      onChanged: (v) =>
                          setStateDialog(() => dontShowAgain = v ?? false),
                      activeColor: _accent,
                    ),
                    Expanded(
                      child: Text(
                        Lang.t('reg_dont_show_again'),
                        style: const TextStyle(color: _textSecondary),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        Lang.t('reg_understood'),
                        style: const TextStyle(color: _textPrimary),
                      ),
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
      // TermsScreen may have navigated away itself (pushReplacement).
      // If this widget is no longer mounted, do nothing.
      if (!mounted) return;
      // If terms still not accepted (user pressed back), stop here.
      final prefsCheck = await SharedPreferences.getInstance();
      if (!(prefsCheck.getBool('termsAccepted') ?? false)) return;
    }

    if (!mounted) return;

    final prefsAfterTerms = await SharedPreferences.getInstance();
    final savedLanguage = prefsAfterTerms.getString('language');
    final savedCountry = prefsAfterTerms.getString('country');
    final savedCity = prefsAfterTerms.getString('city');

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
      MaterialPageRoute(builder: (_) => const HomeShell(initialIndex: 2)),
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
    if (s <= 0.2) return Lang.t('pw_very_weak');
    if (s <= 0.4) return Lang.t('pw_weak');
    if (s <= 0.6) return Lang.t('pw_ok');
    if (s <= 0.8) return Lang.t('pw_good');
    return Lang.t('pw_strong');
  }

  String? _nameValidator(String? v) {
    if (v == null || v.trim().isEmpty) return Lang.t('val_required');
    if (v.trim().length < 2) return Lang.t('val_too_short');
    return null;
  }

  String? _usernameValidator(String? v) {
    final val = v?.trim() ?? '';
    if (val.isEmpty) return Lang.t('val_required');
    if (RegExp(r'[A-Z]').hasMatch(val)) return Lang.t('val_lowercase_only');
    if (!RegExp(r'^[a-z0-9_.-]{3,20}$').hasMatch(val)) {
      return Lang.t('val_username_format');
    }
    if (_usernameChecked && _usernameTaken) return Lang.t('val_username_taken');
    return null;
  }

  String? _passwordValidator(String? v) {
    final pw = v ?? '';
    if (pw.isEmpty) return Lang.t('val_required');
    if (pw.length < 6) return Lang.t('val_min_6_chars');
    return null;
  }

  String? _emailValidator(String? v) {
    final val = v?.trim() ?? '';
    if (_isBar) {
      if (val.isEmpty) return Lang.t('val_required');
      if (!val.contains("@")) return Lang.t('val_invalid_email');
    }
    return null;
  }

  String? _phoneValidator(String? v) {
    final val = v?.trim() ?? '';
    if (_isBar) {
      if (val.isEmpty) return Lang.t('val_required');
      if (val.length < 6) return Lang.t('val_too_short');
    }
    return null;
  }

  String? _availabilityValidator(String? v) {
    final val = v?.trim() ?? '';
    if (_isBar) {
      if (val.isEmpty) return Lang.t('val_required');
      if (val.length < 4) return Lang.t('val_too_short');
    }
    return null;
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
            color: s < .4 ? _accent : (s < .7 ? Colors.orangeAccent : _secondary),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          "${Lang.t('pw_strength_label')}: ${_passwordLabel(s)}",
          style: const TextStyle(
            color: _textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _birthRow() {
    final int currentYear = DateTime.now().year;

    Widget _columnLabel(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        t,
        style: const TextStyle(
          color: _textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Lang.t('reg_birthdate'),
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 180,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _columnLabel(Lang.t('reg_day')),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController: FixedExtentScrollController(
                            initialItem: _selectedDay - 1,
                          ),
                          onSelectedItemChanged: (index) =>
                              setState(() => _selectedDay = index + 1),
                          children: List.generate(
                            31,
                                (index) => Center(
                              child: Text(
                                "${index + 1}",
                                style: const TextStyle(color: _textPrimary),
                              ),
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
                      _columnLabel(Lang.t('reg_month')),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController: FixedExtentScrollController(
                            initialItem: _selectedMonth - 1,
                          ),
                          onSelectedItemChanged: (index) =>
                              setState(() => _selectedMonth = index + 1),
                          children: List.generate(
                            12,
                                (index) => Center(
                              child: Text(
                                "${index + 1}",
                                style: const TextStyle(color: _textPrimary),
                              ),
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
                      _columnLabel(Lang.t('reg_year')),
                      Expanded(
                        child: CupertinoPicker(
                          backgroundColor: _card,
                          itemExtent: 32,
                          scrollController: FixedExtentScrollController(
                            initialItem: DateTime.now().year - _selectedYear,
                          ),
                          onSelectedItemChanged: (index) => setState(
                                () => _selectedYear = DateTime.now().year - index,
                          ),
                          children: List.generate(
                            currentYear - 1900 + 1,
                                (index) => Center(
                              child: Text(
                                "${DateTime.now().year - index}",
                                style: const TextStyle(color: _textPrimary),
                              ),
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

  Future<void> _onSubmit() async {
    if (_isSaving) return;
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) return;
    await _proceed();
  }

  Future<void> _proceed() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    setState(() => _isSaving = true);

    try {
      final collectionName = _isBar ? "bars" : "users";
      final query = await FirebaseFirestore.instance
          .collection(collectionName)
          .where("username", isEqualTo: username)
          .limit(1)
          .get();

      if (query.docs.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(Lang.t('reg_err_username_taken')),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
        setState(() {
          _isSaving = false;
          _usernameTaken = true;
          _usernameChecked = true;
        });
        return;
      }

      if (_isBar) {
        final barName = _barNameController.text.trim();
        final email = _emailController.text.trim();
        final phone = _phoneController.text.trim();
        final availability = _availabilityController.text.trim();

        await FirebaseFirestore.instance.collection("barAnfragen").add({
          "createdAt": FieldValue.serverTimestamp(),
          "barName": barName,
          "username": username,
          "username_lower": username.toLowerCase(),
          "email": email,
          "phoneNumber": phone,
          "availabilityNote": availability,
          "requestedPassword": password,
          "status": "open",
        });

        if (!mounted) return;

        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: _panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              Lang.t('reg_dialog_title'),
              style: const TextStyle(color: _textPrimary),
            ),
            content: Text(
              Lang.t('reg_dialog_body'),
              style: const TextStyle(color: _textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(Lang.t('ok'), style: const TextStyle(color: _textPrimary)),
              )
            ],
          ),
        );

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
      } else {
        final prefs = await SharedPreferences.getInstance();

        final vorname = _vornameController.text.trim();
        final nachname = _nachnameController.text.trim();
        final birthDate = DateTime(_selectedYear, _selectedMonth, _selectedDay);
        final age = _calculateAge(birthDate);

        if (age < 12) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(Lang.t('reg_err_age')),
              backgroundColor: AppColors.accent,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          );
          setState(() => _isSaving = false);
          return;
        }

        final docId = "$vorname $nachname".trim();

        await FirebaseFirestore.instance.collection("users").doc(docId).set({
          "createdAt": FieldValue.serverTimestamp(),
          "vorname": vorname,
          "nachname": nachname,
          "fullName": docId,
          "username": username,
          "password": password,
          "username_lower": username.toLowerCase(),
          "age": age,
          "geburtsdatum": {
            "tag": _selectedDay,
            "monat": _selectedMonth,
            "jahr": _selectedYear,
          },
          "phoneNumber": null,
          "phoneVerified": false,
          "authVersion": 1,
        });

        await prefs.setString("vorname", vorname);
        await prefs.setString("nachname", nachname);
        await prefs.setString("username", username);
        await prefs.setBool("isBarAccount", false); // ✅ wichtig
        await prefs.setBool("isLoggedIn", true);
        await prefs.setString("currentUsername", username);
        await prefs.setInt("authVersion", 1);
        await prefs.setBool("phoneVerified", false);
        await prefs.remove("phoneNumber");

        await _checkTermsAndSelection();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${Lang.t('reg_err_save')}: $e"),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildAccountTypeToggle() {
    final bool isPrivat = !_isBar;
    final bool isUnternehmen = _isBar;

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
            setState(() {
              _isBar = !_isBar;
              _checkUsernameAvailability(_usernameController.text.trim());
            });
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
                  onTap: () {
                    setState(() {
                      _isBar = false;
                      _checkUsernameAvailability(_usernameController.text.trim());
                    });
                  },
                ),
                _buildToggleSegment(
                  label: Lang.t('login_type_company'),
                  selected: isUnternehmen,
                  onTap: () {
                    setState(() {
                      _isBar = true;
                      _checkUsernameAvailability(_usernameController.text.trim());
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isBar
              ? Lang.t('reg_type_company_hint')
              : Lang.t('reg_type_private_hint'),
          style: const TextStyle(
            color: _textSecondary,
            fontSize: 12,
          ),
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

  Widget _cardForm() {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
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
            children: [
              const LangToggleWidget(),
              const SizedBox(height: 16),
              const Icon(Icons.person_add, size: 52, color: _accent),
              const SizedBox(height: 8),
              Text(
                _isBar ? Lang.t('reg_title_company') : Lang.t('create_account_title'),
                style: const TextStyle(
                  color: _textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _isBar
                    ? Lang.t('reg_subtitle_company')
                    : Lang.t('reg_subtitle_private'),
                style: const TextStyle(
                  color: _textSecondary,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              _buildAccountTypeToggle(),
              const SizedBox(height: 16),

              if (_isBar) ...[
                TextFormField(
                  controller: _barNameController,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'^\s')),
                  ],
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_bar_name'),
                    icon: Icons.storefront,
                    hint: Lang.t('reg_bar_name_hint'),
                  ),
                  validator: _nameValidator,
                ),
                const SizedBox(height: 12),
              ] else ...[
                TextFormField(
                  controller: _vornameController,
                  focusNode: _vornameNode,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _nachnameNode.requestFocus(),
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'^\s')),
                  ],
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_first_name'),
                    icon: Icons.person,
                    hint: Lang.t('reg_first_name_hint'),
                  ),
                  validator: _nameValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _nachnameController,
                  focusNode: _nachnameNode,
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) => _usernameNode.requestFocus(),
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'^\s')),
                  ],
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_last_name'),
                    icon: Icons.person_outline,
                    hint: Lang.t('reg_last_name_hint'),
                  ),
                  validator: _nameValidator,
                ),
                const SizedBox(height: 12),
              ],

              TextFormField(
                controller: _usernameController,
                focusNode: _usernameNode,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _passwordNode.requestFocus(),
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                  label: Lang.t('login_username'),
                  icon: Icons.alternate_email,
                  hint: Lang.t('reg_username_hint'),
                  suffix: _usernameController.text.isEmpty
                      ? null
                      : (_usernameChecked
                      ? (_usernameTaken
                      ? const Icon(Icons.close_rounded, color: _accent)
                      : const Icon(Icons.check_circle, color: _secondary))
                      : const SizedBox(
                    width: 18,
                    height: 18,
                    child: Padding(
                      padding: EdgeInsets.all(2.0),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )),
                ),
                validator: _usernameValidator,
              ),

              if (_usernameHasUppercase) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    Lang.t('reg_username_lowercase'),
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 12),

              TextFormField(
                controller: _passwordController,
                focusNode: _passwordNode,
                textInputAction: TextInputAction.next,
                obscureText: !_pwVisible,
                style: const TextStyle(color: _textPrimary),
                decoration: _dec(
                  label: Lang.t('login_password'),
                  icon: Icons.lock,
                  hint: Lang.t('reg_password_hint'),
                  suffix: IconButton(
                    tooltip: _pwVisible ? Lang.t('reg_pw_hide') : Lang.t('reg_pw_show'),
                    onPressed: () => setState(() => _pwVisible = !_pwVisible),
                    icon: Icon(
                      _pwVisible ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white70,
                    ),
                  ),
                ),
                validator: _passwordValidator,
              ),
              _passwordMeter(),
              const SizedBox(height: 12),

              if (_isBar) ...[
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_business_email'),
                    icon: Icons.email,
                    hint: "kontakt@mustermann.at",
                  ),
                  validator: _emailValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_phone'),
                    icon: Icons.phone,
                    hint: "+43 660 123456",
                  ),
                  validator: _phoneValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _availabilityController,
                  keyboardType: TextInputType.text,
                  maxLines: 2,
                  style: const TextStyle(color: _textPrimary),
                  decoration: _dec(
                    label: Lang.t('reg_availability'),
                    icon: Icons.access_time,
                    hint: Lang.t('reg_availability_hint'),
                  ),
                  validator: _availabilityValidator,
                ),
                const SizedBox(height: 16),
              ] else ...[
                const SizedBox(height: 8),
                _birthRow(),
                const SizedBox(height: 18),
              ],

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _canSubmit ? _onSubmit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    disabledBackgroundColor: _accent.withOpacity(0.4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isSaving
                      ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                      : Text(
                    _isBar ? Lang.t('reg_btn_apply') : Lang.t('create_account_title'),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (_isBar)
                Text(
                  Lang.t('reg_bar_info'),
                  style: const TextStyle(
                    color: _textSecondary,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isSaving
                    ? null
                    : () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  );
                },
                child: Text(
                  Lang.t('reg_have_account'),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 4,
        centerTitle: true,
        title: Text(
          Lang.t('create_account_title'),
          style: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _cardForm(),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
