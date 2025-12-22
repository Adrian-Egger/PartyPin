// lib/Screens/home_shell.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feedback_screen.dart';
import 'party_map_screen.dart';
import 'new_party.dart';
import '../Social/friends_view.dart';
import 'profil_settings_screen.dart';

// Gate Screens
import 'create_account_screen.dart';
import 'nutzungsbedinungen.dart';
import 'selection_screen.dart';

// Bar Tabs
import 'bar_event_screen.dart';
import 'bar_feedback_screen.dart';

enum _GateState { loading, login, terms, selection, ready }

class HomeShell extends StatefulWidget {
  final int initialIndex;
  const HomeShell({super.key, this.initialIndex = 2});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _panel = Color(0xFF1C1F26);
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);

  _GateState _gate = _GateState.loading;

  int _currentIndex = 2;
  String _username = "";
  bool _isBarAccount = false;
  String _barId = "";

  List<Widget> _pages = const [SizedBox.shrink()];
  bool get _isTabsReady => _pages.isNotEmpty && _pages.first is! SizedBox;

  @override
  void initState() {
    super.initState();
    _bootGate();
  }

  int _clampIndex(int i, int max) {
    if (i < 0) return 0;
    if (i > max) return max;
    return i;
  }

  Future<void> _bootGate() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
      if (!isLoggedIn) {
        if (!mounted) return;
        setState(() => _gate = _GateState.login);
        return;
      }

      final termsAccepted = prefs.getBool('termsAccepted') ?? false;
      if (!termsAccepted) {
        if (!mounted) return;
        setState(() => _gate = _GateState.terms);
        return;
      }

      final savedCity = prefs.getString('city');
      final savedCountry = prefs.getString('country');
      final savedLat = prefs.getDouble('selectedLat');
      final savedLng = prefs.getDouble('selectedLng');

      final hasLocation =
          savedCity != null && savedCountry != null && savedLat != null && savedLng != null;

      if (!hasLocation) {
        if (!mounted) return;
        setState(() => _gate = _GateState.selection);
        return;
      }

      // ✅ Alles ok → Tabs bauen
      await _loadUserAndBuildPages();
      if (!mounted) return;
      setState(() => _gate = _GateState.ready);
    } catch (_) {
      if (!mounted) return;
      // Fallback: lieber Selection statt “kaputt”
      setState(() => _gate = _GateState.selection);
    }
  }

  Future<void> _loadUserAndBuildPages() async {
    final prefs = await SharedPreferences.getInstance();

    final u = (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '').trim();
    final isBar = prefs.getBool('isBarAccount') ?? false;
    final barId = (prefs.getString('barId') ?? '').trim();

    if (!mounted) return;

    setState(() {
      _username = u;
      _isBarAccount = isBar;
      _barId = barId;

      if (_isBarAccount) {
        _pages = <Widget>[
          BarEventScreen(barId: _barId), // 0
          const PartyMapScreen(),        // 1
          const BarFeedbackScreen(),     // 2
        ];
        _currentIndex = _clampIndex(widget.initialIndex, _pages.length - 1);
      } else {
        _pages = <Widget>[
          const FeedbackScreen(), // 0
          _username.isEmpty
              ? const _UsernameMissingScreen()
              : FriendsScreen(currentUsername: _username), // 1
          const PartyMapScreen(), // 2
          const NewPartyScreen(), // 3
          const ProfileSettingsScreen(), // 4
        ];
        _currentIndex = _clampIndex(widget.initialIndex, _pages.length - 1);
      }
    });
  }

  void _onBottomNavTapped(int i) {
    if (!_isTabsReady) return;
    if (i == _currentIndex) return;
    setState(() => _currentIndex = i);
  }

  @override
  Widget build(BuildContext context) {
    // Gate-Screens: HomeShell bleibt Root, BottomNav wird ausgeblendet.
    if (_gate != _GateState.ready) {
      return Scaffold(
        body: _buildGateBody(),
      );
    }

    if (!_isTabsReady) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: _panel,
        selectedItemColor: _accent,
        unselectedItemColor: _muted,
        currentIndex: _currentIndex,
        onTap: _onBottomNavTapped,
        type: BottomNavigationBarType.fixed,
        items: _isBarAccount
            ? const [
          BottomNavigationBarItem(icon: Icon(Icons.celebration), label: "Event"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(icon: Icon(Icons.feedback), label: "Feedback"),
        ]
            : const [
          BottomNavigationBarItem(icon: Icon(Icons.feedback), label: "Feedback"),
          BottomNavigationBarItem(icon: Icon(Icons.people), label: "Freunde"),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: "Map"),
          BottomNavigationBarItem(icon: Icon(Icons.add), label: "Neu"),
        ],
      ),
    );
  }

  Widget _buildGateBody() {
    switch (_gate) {
      case _GateState.loading:
        return const Center(child: CircularProgressIndicator(color: _accent));
      case _GateState.login:
        return const CreateAccountScreen();
      case _GateState.terms:
        return const TermsScreen();
      case _GateState.selection:
        return const SelectionScreen();
      case _GateState.ready:
        return const SizedBox.shrink();
    }
  }
}

class _UsernameMissingScreen extends StatelessWidget {
  const _UsernameMissingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            "Username fehlt. Bitte in den Einstellungen setzen.",
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
