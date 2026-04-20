// lib/Screens/home_shell.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../profile/feedback_screen.dart';
import '../party/party_map_screen.dart';
import '../party/new_party.dart';
import '../../Social/friends_view.dart';

// Gate Screens
import '../auth/create_account_screen.dart';
import '../auth/nutzungsbedinungen.dart';
import 'selection_screen.dart';

// Bar Tabs
import '../bar/bar_event_screen.dart';
import '../bar/bar_feedback_screen.dart';

// ✅ MyBarTab
import '../bar/my_bar_tab.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

enum _GateState { loading, login, terms, selection, ready }

class HomeShell extends StatefulWidget {
  final int initialIndex;

  // ✅ NEU: Party, die beim Öffnen der Map automatisch als BottomSheet aufgeht
  final String? initialOpenPartyId;

  const HomeShell({
    super.key,
    this.initialIndex = 2,
    this.initialOpenPartyId,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _accent = AppColors.accent;

  _GateState _gate = _GateState.loading;

  int _currentIndex = 2;

  /// ✅ Wichtig: IndexedStack baut alle Tabs sofort.
  /// MyBarTab öffnet nur, wenn _tabIndex wirklich auf 3 wechselt.
  final ValueNotifier<int> _tabIndex = ValueNotifier<int>(2);

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

  @override
  void dispose() {
    _tabIndex.dispose();
    super.dispose();
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

      final hasLocation = savedCity != null &&
          savedCountry != null &&
          savedLat != null &&
          savedLng != null;

      if (!hasLocation) {
        if (!mounted) return;
        setState(() => _gate = _GateState.selection);
        return;
      }

      await _loadUserAndBuildPages();
      if (!mounted) return;
      setState(() => _gate = _GateState.ready);
    } catch (_) {
      if (!mounted) return;
      setState(() => _gate = _GateState.selection);
    }
  }

  Future<void> _loadUserAndBuildPages() async {
    final prefs = await SharedPreferences.getInstance();

    final u =
    (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '')
        .trim();
    final isBar = prefs.getBool('isBarAccount') ?? false;
    final barId = (prefs.getString('barId') ?? '').trim();

    if (!mounted) return;

    setState(() {
      _username = u;
      _isBarAccount = isBar;
      _barId = barId;

      if (_isBarAccount) {
        // ✅ Bar account: 4 Tabs
        _pages = <Widget>[
          BarEventScreen(barId: _barId), // 0
          // ✅ Map (Bar) -> initialOpenPartyId auch hier durchreichen (schadet nicht)
          PartyMapScreen(initialOpenPartyId: widget.initialOpenPartyId), // 1
          const BarFeedbackScreen(), // 2
          MyBarTab(
            barId: _barId,
            myIndex: 3,
            tabIndex: _tabIndex,
          ), // 3
        ];

        // ✅ Bar startet IMMER auf Map (Index 1)
        _currentIndex = 1;
        _tabIndex.value = 1;
      } else {
        // ✅ Normal Account: 4 Tabs
        _pages = <Widget>[
          const FeedbackScreen(), // 0
          _username.isEmpty
              ? const _UsernameMissingScreen()
              : FriendsScreen(currentUsername: _username), // 1
          // ✅ Map -> hier MUSS initialOpenPartyId rein
          PartyMapScreen(initialOpenPartyId: widget.initialOpenPartyId), // 2
          const NewPartyScreen(), // 3
        ];

        // ✅ Wenn initialOpenPartyId gesetzt ist, soll IMMER die Map geöffnet werden
        if (widget.initialOpenPartyId != null &&
            widget.initialOpenPartyId!.trim().isNotEmpty) {
          _currentIndex = 2;
          _tabIndex.value = 2;
        } else {
          _currentIndex = _clampIndex(widget.initialIndex, _pages.length - 1);
          _tabIndex.value = _currentIndex;
        }
      }
    });
  }

  void _onBottomNavTapped(int i) {
    if (!_isTabsReady) return;

    HapticFeedback.lightImpact();

    // ✅ Für "Meine Bar" soll bei erneutem Tap wieder öffnen
    if (_isBarAccount && i == 3) {
      if (_tabIndex.value == 3) {
        final fallback = _currentIndex == 3 ? 1 : _currentIndex;
        _tabIndex.value = fallback;
      }
      setState(() => _currentIndex = 3);
      _tabIndex.value = 3;
      return;
    }

    if (i == _currentIndex) return;

    setState(() => _currentIndex = i);
    _tabIndex.value = i;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_gate != _GateState.ready) {
      return Scaffold(body: _buildGateBody());
    }

    if (!_isTabsReady) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onBottomNavTapped,
        destinations: _isBarAccount
            ? [
                NavigationDestination(
                  icon: const Icon(Icons.celebration_outlined),
                  selectedIcon: const Icon(Icons.celebration),
                  label: Lang.t('nav_event'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.map_outlined),
                  selectedIcon: const Icon(Icons.map),
                  label: Lang.t('nav_map'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.star_outline),
                  selectedIcon: const Icon(Icons.star),
                  label: Lang.t('nav_bar_feedback'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.store_outlined),
                  selectedIcon: const Icon(Icons.store),
                  label: Lang.t('nav_my_bar'),
                ),
              ]
            : [
                NavigationDestination(
                  icon: const Icon(Icons.chat_bubble_outline),
                  selectedIcon: const Icon(Icons.chat_bubble),
                  label: Lang.t('nav_feedback'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.people_outline),
                  selectedIcon: const Icon(Icons.people),
                  label: Lang.t('nav_friends'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.map_outlined),
                  selectedIcon: const Icon(Icons.map),
                  label: Lang.t('nav_map'),
                ),
                NavigationDestination(
                  icon: const Icon(Icons.add_circle_outline),
                  selectedIcon: const Icon(Icons.add_circle),
                  label: Lang.t('nav_new'),
                ),
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

