// lib/Screens/auth/bar_signup_wizard.dart
//
// 3-Schritt-Wizard für Bar-Selbstregistrierung.
//
// SECURITY_HARDENING (Pre-Launch Audit C2, Session 2026-05-17):
// Bar-Account-Erstellung läuft jetzt server-seitig über
// AuthService.signupBar → signupCallable. Vorher schrieb der Client
// `passwordHash` direkt nach /bars, was den Hash für jeden authed
// Client lesbar machte.
//
// Zusätzlich gefixt: der Wizard nutzte vorher `SHA-256("user:pass")`
// für Bar-Hashes, während der Login-Pfad `HMAC-SHA256(lower, pw)`
// verwendete — d.h. via Wizard registrierte Bars konnten sich nie
// einloggen (latenter Bug). signupCallable nutzt jetzt einheitlich
// denselben HMAC-Hash wie loginCallable.
//
// Logo-Upload bleibt clientseitig (Firebase Storage), die URL wird
// als Teil des Payloads an die CF übergeben.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../Services/auth_service.dart';
import '../../Theme/app_theme.dart';
import 'login_screen.dart';

class BarSignupWizard extends StatefulWidget {
  const BarSignupWizard({
    super.key,
    this.initialBarName,
    this.initialUsername,
    this.initialPassword,
    this.initialEmail,
    this.initialPhone,
  });

  /// Vorausgefüllte Werte aus dem CreateAccountScreen (optional).
  final String? initialBarName;
  final String? initialUsername;
  final String? initialPassword;
  final String? initialEmail;
  final String? initialPhone;

  @override
  State<BarSignupWizard> createState() => _BarSignupWizardState();
}

class _BarSignupWizardState extends State<BarSignupWizard> {
  static const _totalSteps = 3;

  int _step = 0;
  bool _submitting = false;

  // Step 1
  final _step1Key = GlobalKey<FormState>();
  late final TextEditingController _barNameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  final _passwordConfirmCtrl = TextEditingController();
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;

  // Step 2
  final _step2Key = GlobalKey<FormState>();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'Austria');
  File? _logoFile;
  bool _uploadingLogo = false;

  // Step 3
  final _descCtrl = TextEditingController();

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _barNameCtrl = TextEditingController(text: widget.initialBarName ?? '');
    _usernameCtrl = TextEditingController(text: widget.initialUsername ?? '');
    _passwordCtrl = TextEditingController(text: widget.initialPassword ?? '');
    _emailCtrl = TextEditingController(text: widget.initialEmail ?? '');
    _phoneCtrl = TextEditingController(text: widget.initialPhone ?? '');
    if (widget.initialPassword != null && widget.initialPassword!.isNotEmpty) {
      _passwordConfirmCtrl.text = widget.initialPassword!;
    }
  }

  @override
  void dispose() {
    _barNameCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordConfirmCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _countryCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ── Step navigation ───────────────────────────────────────────────────

  Future<void> _next() async {
    HapticFeedback.lightImpact();
    if (_step == 0) {
      if (!(_step1Key.currentState?.validate() ?? false)) return;
      // Username-Verfügbarkeit prüfen (auf bars + users)
      final taken = await _isUsernameTaken(_usernameCtrl.text.trim());
      if (taken) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(_snack(
            'Benutzername ist bereits vergeben.', AppColors.accent));
        return;
      }
    } else if (_step == 1) {
      if (!(_step2Key.currentState?.validate() ?? false)) return;
    }

    if (_step < _totalSteps - 1) {
      setState(() => _step++);
    } else {
      await _submit();
    }
  }

  void _back() {
    HapticFeedback.selectionClick();
    if (_step > 0) {
      setState(() => _step--);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// UX-Pre-Check: blockiert nicht den finalen Submit (das macht
  /// signupCallable transaktional), zeigt aber bereits in Step 1 an
  /// dass der Username vergeben ist — damit der Nutzer nicht 3 Steps
  /// ausfüllt bevor er die schlechte Nachricht bekommt.
  /// SECURITY_HARDENING: die finale Eindeutigkeitsprüfung passiert
  /// IMMER server-seitig in signupCallable. Dieser Check ist nur UX.
  Future<bool> _isUsernameTaken(String username) async {
    final lower = username.toLowerCase();
    for (final col in ['users', 'bars']) {
      try {
        final q = await FirebaseFirestore.instance
            .collection(col)
            .where('username_lower', isEqualTo: lower)
            .limit(1)
            .get();
        if (q.docs.isNotEmpty) return true;
      } catch (_) {}
    }
    try {
      final byDoc = await FirebaseFirestore.instance
          .collection('bars')
          .doc(username)
          .get();
      if (byDoc.exists) return true;
    } catch (_) {}
    return false;
  }

  // ── Logo upload ───────────────────────────────────────────────────────

  Future<void> _pickLogo() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1080,
      );
      if (picked == null) return;
      setState(() => _logoFile = File(picked.path));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          _snack('Bild konnte nicht geladen werden.', AppColors.accent));
    }
  }

  Future<String?> _uploadLogoIfPresent(String docId) async {
    if (_logoFile == null) return null;
    setState(() => _uploadingLogo = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref()
          .child('bar_avatars')
          .child('$docId-$ts.jpg');
      await ref.putFile(_logoFile!,
          SettableMetadata(contentType: 'image/jpeg'));
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  // ── Submit ────────────────────────────────────────────────────────────
  //
  // SECURITY_HARDENING: Bar-Erstellung läuft jetzt komplett über
  // signupCallable. Client lädt nur das Logo nach Storage hoch und
  // schickt die URL als Teil des Payloads. KEIN Direct-Write nach
  // /bars, KEIN Client-Hashing, KEIN passwordHash sichtbar.

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);

    try {
      final username = _usernameCtrl.text.trim();
      final barName = _barNameCtrl.text.trim();
      final email = _emailCtrl.text.trim();
      final phone = _phoneCtrl.text.trim();
      final password = _passwordCtrl.text.trim();
      final address = _addressCtrl.text.trim();
      final city = _cityCtrl.text.trim();
      final country = _countryCtrl.text.trim();
      final desc = _descCtrl.text.trim();

      // Logo: clientseitiger Upload nach Firebase Storage. URL wird
      // dann an die CF gegeben. Wenn Upload fehlschlägt → null,
      // Account wird trotzdem erstellt (Logo kann später nachgereicht
      // werden).
      final logoUrl = await _uploadLogoIfPresent(username);

      final result = await AuthService.signupBar(
        username: username,
        password: password,
        barName: barName,
        email: email,
        phoneNumber: phone,
        address: address,
        city: city,
        country: country,
        description: desc,
        profileImageUrl: logoUrl,
      );

      if (!result.isOk) {
        if (!mounted) return;
        if (result.error == SignupError.usernameTaken) {
          ScaffoldMessenger.of(context).showSnackBar(
              _snack('Username inzwischen vergeben.', AppColors.accent));
          setState(() {
            _submitting = false;
            _step = 0;
          });
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
            _snack(result.message ?? 'Anfrage fehlgeschlagen.', AppColors.accent));
        setState(() => _submitting = false);
        return;
      }

      if (!mounted) return;
      await _showDoneDialog(barName);

      if (!mounted) return;
      // Bar-Accounts sind pending → Auto-Login wäre sinnlos. Nutzer
      // landet im LoginScreen und kann nach Admin-Freischaltung
      // einloggen.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(_snack('Fehler: $e', AppColors.accent));
      setState(() => _submitting = false);
    }
  }

  Future<void> _showDoneDialog(String barName) async {
    return showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBr),
        title: Row(
          children: const [
            Icon(Icons.check_circle_rounded, color: AppColors.success),
            SizedBox(width: 10),
            Text('Anfrage gesendet',
                style: TextStyle(
                    color: AppColors.text, fontWeight: FontWeight.w800)),
          ],
        ),
        content: Text(
          'Danke! Wir prüfen deine Bar „$barName" und melden uns per E-Mail, '
          'sobald der Account freigeschaltet ist. Bis dahin kannst du dich '
          'noch nicht einloggen.',
          style: const TextStyle(color: AppColors.muted, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Verstanden'),
          ),
        ],
      ),
    );
  }

  SnackBar _snack(String msg, Color color) => SnackBar(
        content: Text(msg),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
      );

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _back,
        ),
        title: Text('Bar registrieren · Schritt ${_step + 1} / $_totalSteps'),
      ),
      body: Column(
        children: [
          _buildProgress(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0.05, 0), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              child: _stepBody(),
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: List.generate(_totalSteps, (i) {
          final done = i <= _step;
          return Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i < _totalSteps - 1 ? 6 : 0),
              decoration: BoxDecoration(
                color: done ? AppColors.accent : AppColors.panelAlt,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _Step1Basics(
          key: const ValueKey('step1'),
          formKey: _step1Key,
          barName: _barNameCtrl,
          username: _usernameCtrl,
          password: _passwordCtrl,
          passwordConfirm: _passwordConfirmCtrl,
          email: _emailCtrl,
          phone: _phoneCtrl,
        );
      case 1:
        return _Step2Address(
          key: const ValueKey('step2'),
          formKey: _step2Key,
          address: _addressCtrl,
          city: _cityCtrl,
          country: _countryCtrl,
          logoFile: _logoFile,
          onPickLogo: _pickLogo,
          onClearLogo: () => setState(() => _logoFile = null),
        );
      case 2:
      default:
        return _Step3Description(
          key: const ValueKey('step3'),
          desc: _descCtrl,
          summaryName: _barNameCtrl.text,
          summaryAddress:
              '${_addressCtrl.text}, ${_cityCtrl.text}, ${_countryCtrl.text}',
        );
    }
  }

  Widget _buildBottomBar() {
    final isLast = _step == _totalSteps - 1;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Row(
          children: [
            if (_step > 0)
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : _back,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.text,
                    side: const BorderSide(color: AppColors.accentBorder2),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape:
                        RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                  ),
                  child: const Text('Zurück'),
                ),
              ),
            if (_step > 0) const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                onPressed: (_submitting || _uploadingLogo) ? null : _next,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
                ),
                child: _submitting || _uploadingLogo
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text(isLast ? 'Anfrage senden' : 'Weiter →',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Step widgets ───────────────────────────────────────────────────────

class _Step1Basics extends StatelessWidget {
  const _Step1Basics({
    super.key,
    required this.formKey,
    required this.barName,
    required this.username,
    required this.password,
    required this.passwordConfirm,
    required this.email,
    required this.phone,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController barName;
  final TextEditingController username;
  final TextEditingController password;
  final TextEditingController passwordConfirm;
  final TextEditingController email;
  final TextEditingController phone;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          const _StepHeader(
            icon: Icons.local_bar_rounded,
            title: 'Basis-Daten',
            subtitle:
                'Mit diesem Account loggst du dich später als Bar in PartyPin ein.',
          ),
          _Field(
            controller: barName,
            label: 'Bar-Name',
            icon: Icons.storefront_rounded,
            validator: _required('Bar-Name fehlt'),
          ),
          _Field(
            controller: username,
            label: 'Benutzername',
            icon: Icons.alternate_email_rounded,
            validator: (v) {
              final t = (v ?? '').trim();
              if (t.length < 3) return 'Mind. 3 Zeichen';
              if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(t)) {
                return 'Nur a-z, 0-9, _ . -';
              }
              return null;
            },
          ),
          _Field(
            controller: password,
            label: 'Passwort',
            icon: Icons.lock_outline_rounded,
            obscure: true,
            validator: (v) {
              if ((v ?? '').length < 6) return 'Mind. 6 Zeichen';
              return null;
            },
          ),
          _Field(
            controller: passwordConfirm,
            label: 'Passwort bestätigen',
            icon: Icons.lock_outline_rounded,
            obscure: true,
            validator: (v) {
              if (v != password.text) return 'Passwörter stimmen nicht überein';
              return null;
            },
          ),
          _Field(
            controller: email,
            label: 'Kontakt-E-Mail',
            icon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              final t = (v ?? '').trim();
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) {
                return 'Gültige E-Mail eingeben';
              }
              return null;
            },
          ),
          _Field(
            controller: phone,
            label: 'Telefon (optional)',
            icon: Icons.phone_outlined,
            keyboardType: TextInputType.phone,
          ),
        ],
      ),
    );
  }

  static FormFieldValidator<String> _required(String msg) =>
      (v) => (v ?? '').trim().isEmpty ? msg : null;
}

class _Step2Address extends StatelessWidget {
  const _Step2Address({
    super.key,
    required this.formKey,
    required this.address,
    required this.city,
    required this.country,
    required this.logoFile,
    required this.onPickLogo,
    required this.onClearLogo,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController address;
  final TextEditingController city;
  final TextEditingController country;
  final File? logoFile;
  final VoidCallback onPickLogo;
  final VoidCallback onClearLogo;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          const _StepHeader(
            icon: Icons.location_on_outlined,
            title: 'Adresse & Logo',
            subtitle:
                'Hilft uns, deine Bar auf der Karte zu platzieren. Logo ist optional.',
          ),
          _Field(
            controller: address,
            label: 'Straße + Nr.',
            icon: Icons.home_outlined,
            validator: (v) =>
                (v ?? '').trim().length < 3 ? 'Adresse fehlt' : null,
          ),
          _Field(
            controller: city,
            label: 'Stadt',
            icon: Icons.location_city_outlined,
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Stadt fehlt' : null,
          ),
          _Field(
            controller: country,
            label: 'Land',
            icon: Icons.flag_outlined,
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Land fehlt' : null,
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onPickLogo,
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                color: AppColors.panelAlt,
                borderRadius: AppRadius.mdBr,
                border: Border.all(color: AppColors.accentBorder),
              ),
              child: logoFile == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.add_photo_alternate_outlined,
                              color: AppColors.muted, size: 32),
                          SizedBox(height: 8),
                          Text('Bar-Logo hinzufügen (optional)',
                              style: TextStyle(color: AppColors.muted)),
                        ],
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: AppRadius.mdBr,
                          child: Image.file(logoFile!, fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: GestureDetector(
                            onTap: onClearLogo,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close_rounded,
                                  color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step3Description extends StatelessWidget {
  const _Step3Description({
    super.key,
    required this.desc,
    required this.summaryName,
    required this.summaryAddress,
  });

  final TextEditingController desc;
  final String summaryName;
  final String summaryAddress;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        const _StepHeader(
          icon: Icons.description_outlined,
          title: 'Letzte Schritte',
          subtitle:
              'Eine kurze Beschreibung erscheint später auf der Bar-Detailseite.',
        ),
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: AppColors.panelAlt,
            borderRadius: AppRadius.mdBr,
            border: Border.all(color: AppColors.accentBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Zusammenfassung',
                  style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4)),
              const SizedBox(height: 6),
              Text(summaryName,
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(summaryAddress,
                  style:
                      const TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
          ),
        ),
        TextFormField(
          controller: desc,
          maxLines: 5,
          maxLength: 300,
          style: const TextStyle(color: AppColors.text),
          decoration: InputDecoration(
            labelText: 'Kurzbeschreibung (optional)',
            hintText: 'Was macht deine Bar besonders?',
            hintStyle: const TextStyle(color: AppColors.subtle),
            filled: true,
            fillColor: AppColors.panelAlt,
            border: OutlineInputBorder(
              borderRadius: AppRadius.smBr,
              borderSide: const BorderSide(color: AppColors.accentBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: AppRadius.smBr,
              borderSide: const BorderSide(color: AppColors.accentBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: AppRadius.smBr,
              borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Mit „Anfrage senden" bestätigst du, dass du berechtigt bist, '
          'diese Bar zu vertreten. Wir prüfen die Angaben und schalten den '
          'Account frei.',
          style: TextStyle(color: AppColors.subtle, fontSize: 12, height: 1.4),
        ),
      ],
    );
  }
}

// ─── Reusable bits ──────────────────────────────────────────────────────

class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 13, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: const TextStyle(color: AppColors.text),
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: AppColors.muted, size: 20),
          filled: true,
          fillColor: AppColors.panelAlt,
          border: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide: const BorderSide(color: AppColors.accentBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide: const BorderSide(color: AppColors.accentBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.smBr,
            borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
          ),
        ),
      ),
    );
  }
}
