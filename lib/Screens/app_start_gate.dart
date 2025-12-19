import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Services/age_services.dart';
import 'birthday_screen.dart';
import 'create_account_screen.dart';
import 'selection_screen.dart';
import 'nutzungsbedinungen.dart';
import 'home_shell.dart'; // ✅ NEU

class AppStartGate extends StatefulWidget {
  const AppStartGate({super.key});

  @override
  State<AppStartGate> createState() => _AppStartGateState();
}

class _AppStartGateState extends State<AppStartGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _fade = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _scale = Tween<double>(begin: 0.96, end: 1.03).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    _boot();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final prefs = await SharedPreferences.getInstance()
          .timeout(const Duration(seconds: 5));

      // 1) Login-Status
      final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
      if (!isLoggedIn) {
        _go(const CreateAccountScreen());
        return;
      }

      // 2) Terms
      final termsAccepted = prefs.getBool('termsAccepted') ?? false;
      if (!termsAccepted) {
        _go(const TermsScreen());
        return;
      }

      // 3) Age Sync + Birthday (darf NIE blockieren)
      final username = (prefs.getString('currentUsername') ?? '').trim();
      if (username.isNotEmpty) {
        try {
          final result = await AgeService.syncAgeAndCheckBirthday(docId: username)
              .timeout(const Duration(seconds: 6));

          if (!mounted) return;

          if (result.isBirthdayToday) {
            final now = DateTime.now();
            final todayKey = '${now.year}-${now.month}-${now.day}';
            final lastShown = prefs.getString('birthdayShownOn');

            if (lastShown != todayKey) {
              await prefs.setString('birthdayShownOn', todayKey);
              _go(BirthdayScreen(username: username));
              return;
            }
          }
        } catch (_) {
          // Firestore/Network/DocId falsch → ignorieren
        }
      }

      // 4) Location
      final savedCity = prefs.getString('city');
      final savedCountry = prefs.getString('country');
      final savedLat = prefs.getDouble('selectedLat');
      final savedLng = prefs.getDouble('selectedLng');

      final hasLocationData =
          savedCity != null && savedCountry != null && savedLat != null && savedLng != null;

      if (!hasLocationData) {
        _go(const SelectionScreen());
        return;
      }

      // 5) Alles erfüllt → ✅ HomeShell (BottomNav bleibt permanent)
      _go(const HomeShell());
    } catch (_) {
      if (!mounted) return;
      _go(const SelectionScreen());
    }
  }

  void _go(Widget screen) {
    if (_navigated || !mounted) return;
    _navigated = true;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFF0E0F12);
    const bgBottom = Color(0xFF141A22);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [bgTop, bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (_, __) {
              return Transform.scale(
                scale: _scale.value,
                child: Opacity(
                  opacity: _fade.value,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'lib/Pics/PartyPinLogo.png',
                        width: 140,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'PartyPin wird gestartet…',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
