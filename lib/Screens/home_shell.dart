// lib/Screens/home_shell.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'feedback_screen.dart';
import 'party_map_screen.dart';
import 'new_party.dart';
import '../Social/friends_view.dart';

// optional, aber sinnvoll (5. Tab für "Map mittig" ohne Dummy)
import 'profil_settings_screen.dart';

// Bar Tabs
import 'bar_event_screen.dart';
import 'bar_feedback_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Farben wie PartyMap
  static const _panel = Color(0xFF1C1F26);
  static const _muted = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);

  int _currentIndex = 2; // default: Map (mittig)
  String _username = "";
  bool _isBarAccount = false;
  String _barId = "";

  // Caches für Pages (kosteneffizient + State bleibt erhalten)
  List<Widget> _pages = const [SizedBox.shrink()];

  // Normal: 0 Feedback, 1 Freunde, 2 Map, 3 Neu, 4 Profil
  // Bar:    0 Event,    1 Map,     2 Feedback
  bool get _isReady => _pages.isNotEmpty && _pages.first is! SizedBox;

  @override
  void initState() {
    super.initState();
    _loadUserAndBuildPages();
  }

  Future<void> _loadUserAndBuildPages() async {
    final prefs = await SharedPreferences.getInstance();

    final u = (prefs.getString('currentUsername') ??
        prefs.getString('username') ??
        '')
        .trim();

    final isBar = prefs.getBool('isBarAccount') ?? false;
    final barId = (prefs.getString('barId') ?? '').trim();

    if (!mounted) return;

    setState(() {
      _username = u;
      _isBarAccount = isBar;
      _barId = barId;

      if (_isBarAccount) {
        // Bar: Event - Map - Feedback (Map mittig)
        _currentIndex = 1;

        _pages = <Widget>[
          // 0 Event
          BarEventScreen(barId: _barId),
          // 1 Map
          const PartyMapScreen(),
          // 2 Feedback
          const BarFeedbackScreen(),
        ];
      } else {
        // Normal: Feedback - Freunde - Map - NewParty - Profil (Map mittig)
        _currentIndex = 2;

        _pages = <Widget>[
          // 0 Feedback
          const FeedbackScreen(),
          // 1 Freunde
          _username.isEmpty
              ? const _UsernameMissingScreen()
              : FriendsScreen(currentUsername: _username),
          // 2 Map
          const PartyMapScreen(),
          // 3 Neue Party
          const NewPartyScreen(),
          // 4 Profil
          const ProfileSettingsScreen(),
        ];
      }
    });
  }

  void _onBottomNavTapped(int i) {
    if (!_isReady) return;
    if (i == _currentIndex) return;
    setState(() => _currentIndex = i);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: _accent),
        ),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.celebration),
            label: "Event",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: "Map",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.feedback),
            label: "Feedback",
          ),
        ]
            : const [
          BottomNavigationBarItem(
            icon: Icon(Icons.feedback),
            label: "Feedback",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people),
            label: "Freunde",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: "Map",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.add),
            label: "Neu",
          ),
        ],
      ),
    );
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
