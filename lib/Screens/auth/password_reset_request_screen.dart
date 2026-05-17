// lib/Screens/auth/password_reset_request_screen.dart
//
// Operational Readiness Sprint (2026-05-17):
// Minimaler "Passwort vergessen?"-Screen. Eine Eingabe (Username oder
// Email), ein Button. CF schickt Mail mit Link auf web-basierte
// Confirm-Page → Confirm passiert NICHT in der App.
//
// UX:
//   - Nach Klick auf "Reset-Mail schicken" sehen wir IMMER dieselbe
//     Bestätigung — auch wenn der Account nicht existiert. Das ist
//     Enumeration-Schutz, der CF deckt das bereits ab.
//   - Loading-Spinner während Anfrage, dann pop-back zu LoginScreen.

import 'package:flutter/material.dart';

import '../../Services/auth_service.dart';
import '../../Theme/app_theme.dart';

class PasswordResetRequestScreen extends StatefulWidget {
  const PasswordResetRequestScreen({super.key});

  @override
  State<PasswordResetRequestScreen> createState() =>
      _PasswordResetRequestScreenState();
}

class _PasswordResetRequestScreenState
    extends State<PasswordResetRequestScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _ctrl.text.trim();
    if (id.isEmpty || _loading) return;
    setState(() => _loading = true);
    final err = await AuthService.requestPasswordReset(identifier: id);
    if (!mounted) return;
    setState(() => _loading = false);

    if (err != null) {
      // Nur Netzwerk-/Server-Fehler werden differenziert gezeigt.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    // Erfolgs-Sheet — auch wenn Account nicht existiert (Enumeration-Schutz).
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Mail unterwegs',
          style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w800),
        ),
        content: const Text(
          'Wenn ein Account zu diesen Angaben existiert und eine '
          'bestätigte E-Mail hinterlegt ist, schicken wir dir gleich '
          'einen Reset-Link. Schau auch in den Spam-Ordner.',
          style: TextStyle(color: AppColors.muted, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop(); // zurück zum LoginScreen
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.4),
        elevation: 0,
        title: const Text(
          'Passwort vergessen',
          style: TextStyle(color: AppColors.text),
        ),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.bgTop, AppColors.bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF15171C),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accentBorder),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.lock_reset_rounded,
                        size: 52, color: AppColors.accent),
                    const SizedBox(height: 12),
                    const Text(
                      'Passwort zurücksetzen',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Gib deinen Username oder die hinterlegte '
                      'E-Mail-Adresse ein. Wir schicken dir einen Link '
                      'zum Setzen eines neuen Passworts.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.muted, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _ctrl,
                      style: const TextStyle(color: AppColors.text),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Username oder E-Mail',
                        labelStyle: const TextStyle(color: AppColors.muted),
                        prefixIcon:
                            const Icon(Icons.person, color: AppColors.accent),
                        filled: true,
                        fillColor: AppColors.panel,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 14),
                    ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        disabledBackgroundColor:
                            AppColors.accent.withOpacity(0.4),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Reset-Mail schicken',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
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
    );
  }
}
