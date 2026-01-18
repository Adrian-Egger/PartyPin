// lib/Screens/menu_screen.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../Services/language_services.dart';
import '../Screens/selection_screen.dart';
import '../Screens/feedback_screen.dart';
import '../Screens/AdminCreatesBarScreen.dart';
import '../Screens/access_parties_screen.dart';

// WICHTIG: Party Map muss ueber HomeShell geoeffnet werden
// Passe den Importpfad an, falls deine Datei anders heisst:
import '../Screens/home_shell.dart';

// =======================
// APPLE UGC 1.2 SETTINGS
// =======================
const String kRequiredTermsVersion = "2026-01-18";
const String kAdminUsername = "admin_pp";

// =======================
// THEME
// =======================
const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30);

// =======================
// HELPERS
// =======================
Future<String> _currentUsername() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getString('currentUsername') ?? '').trim();
}

Future<Map<String, dynamic>?> _getSavedLocation() async {
  final prefs = await SharedPreferences.getInstance();
  final city = prefs.getString('city');
  final lat = prefs.getDouble('selectedLat');
  final lng = prefs.getDouble('selectedLng');

  if (city != null && lat != null && lng != null) {
    return {'city': city, 'latitude': lat, 'longitude': lng};
  }
  return null;
}

// =======================
// APPLE: BAN WATCHER (global UI eject)
// =======================
class BanWatcher extends StatelessWidget {
  final Widget child;
  const BanWatcher({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _currentUsername(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: _gradTop,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final username = snap.data!.trim();
        if (username.isEmpty) return child;

        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('users').doc(username).snapshots(),
          builder: (context, userSnap) {
            if (!userSnap.hasData) return child;

            final data = userSnap.data!.data() ?? {};
            if (data['banned'] == true) return const BannedScreen();

            return child;
          },
        );
      },
    );
  }
}

// =======================
// APPLE: TERMS GATE (must accept BEFORE any UGC)
// =======================
class RequireTermsAccepted extends StatefulWidget {
  final Widget child;
  const RequireTermsAccepted({super.key, required this.child});

  @override
  State<RequireTermsAccepted> createState() => _RequireTermsAcceptedState();
}

class _RequireTermsAcceptedState extends State<RequireTermsAccepted> {
  bool _checking = true;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final username = await _currentUsername();
    if (username.isEmpty) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _ok = false;
      });
      return;
    }

    final userDoc = await FirebaseFirestore.instance.collection('users').doc(username).get();
    final data = userDoc.data() ?? {};

    if (data['banned'] == true) {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const BannedScreen()),
            (_) => false,
      );
      return;
    }

    final accepted = (data['termsAccepted'] == true);
    final version = (data['termsVersion'] as String?) ?? "";

    if (!(accepted && version == kRequiredTermsVersion)) {
      if (!mounted) return;
      final res = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const TermsGateScreen()),
      );
      _ok = (res == true);
    } else {
      _ok = true;
    }

    if (!mounted) return;
    setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: _gradTop,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_ok) {
      return const Scaffold(
        backgroundColor: _gradTop,
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              "Du musst die Nutzungsbedingungen akzeptieren, um diese Funktion zu nutzen.",
              style: TextStyle(color: _textSecondary, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return widget.child;
  }
}

// =======================
// TERMS GATE SCREEN
// =======================
class TermsGateScreen extends StatefulWidget {
  const TermsGateScreen({super.key});

  @override
  State<TermsGateScreen> createState() => _TermsGateScreenState();
}

class _TermsGateScreenState extends State<TermsGateScreen> {
  bool accepted = false;
  bool saving = false;

  Future<void> _accept() async {
    if (!accepted) return;

    setState(() => saving = true);

    final username = await _currentUsername();
    if (username.isEmpty) {
      setState(() => saving = false);
      return;
    }

    await FirebaseFirestore.instance.collection('users').doc(username).set({
      'termsAccepted': true,
      'termsAcceptedAt': FieldValue.serverTimestamp(),
      'termsVersion': kRequiredTermsVersion,
    }, SetOptions(merge: true));

    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Nutzungsbedingungen",
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: _textPrimary,
          ),
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
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _panelBorder),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Kurzfassung (UGC / Community Regeln)",
                style: TextStyle(
                  color: _accent,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 10),
              const Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    "• Null-Toleranz fuer objectionable content: Hate, Abuse, Belaestigung, Drohungen, Gewalt, sexuelle Ausbeutung "
                        "(insb. Minderjaehrige), nicht-einvernehmliche intime Inhalte, Doxing/Privatdaten, Betrug/Spam.\n\n"
                        "• Inhalte koennen ausgeblendet/entfernt werden (z. B. hidden=true).\n"
                        "• Nutzer koennen blockiert werden; Inhalte blockierter Nutzer werden ausgeblendet.\n"
                        "• Bei Verstoessen koennen Accounts gesperrt/gebanned werden (Eject).\n"
                        "• Meldungen werden in der Regel innerhalb von 24 Stunden moderiert.\n\n"
                        "Vollstaendige Texte findest du im Menue unter „Rechtliches“.",
                    style: TextStyle(color: _textSecondary, height: 1.45),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                value: accepted,
                onChanged: (v) => setState(() => accepted = v ?? false),
                title: const Text(
                  "Ich akzeptiere die Nutzungsbedingungen",
                  style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w600),
                ),
                activeColor: _accent,
                checkColor: Colors.white,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: saving ? null : _accept,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    saving ? "Speichern..." : "Weiter",
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =======================
// BANNED SCREEN
// =======================
class BannedScreen extends StatelessWidget {
  const BannedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_gradTop, _gradBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(18),
        child: Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _panelBorder),
          ),
          padding: const EdgeInsets.all(18),
          child: const Text(
            "Dein Account wurde gesperrt.\n\nWenn du glaubst, dass das ein Fehler ist, kontaktiere den Support.",
            style: TextStyle(color: _textSecondary, height: 1.5),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

// =======================
// ADMIN: REPORTS (24h Moderation) - ONLY admin_pp
// Fix: Query ohne orderBy (keine Index-Probleme) + Fehleranzeige
// =======================
class AdminReportsScreen extends StatelessWidget {
  const AdminReportsScreen({super.key});

  Stream<QuerySnapshot<Map<String, dynamic>>> _openReports() {
    return FirebaseFirestore.instance
        .collection('reports')
        .where('status', isEqualTo: 'open')
        .snapshots();
  }

  Future<void> _hideContent(String contentPath) async {
    await FirebaseFirestore.instance.doc(contentPath).set(
      {'hidden': true},
      SetOptions(merge: true),
    );
  }

  Future<void> _banUser(String username) async {
    await FirebaseFirestore.instance.collection('users').doc(username).set({
      'banned': true,
      'bannedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _closeReport({
    required String reportId,
    required String action,
    required String moderatorUsername,
  }) async {
    await FirebaseFirestore.instance.collection('reports').doc(reportId).set({
      'status': 'closed',
      'action': action,
      'moderatorUsername': moderatorUsername,
      'actionAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Widget _reportCard(BuildContext context, String reportId, Map<String, dynamic> r) {
    final reason = (r['reason'] ?? '').toString();
    final type = (r['type'] ?? '').toString();
    final reporter = (r['reporterUsername'] ?? '').toString();
    final reported = (r['reportedUsername'] ?? '').toString();
    final contentPath = (r['contentPath'] ?? '').toString();

    final createdAt = r['createdAt'];
    DateTime? dt;
    if (createdAt is Timestamp) dt = createdAt.toDate();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Report${type.isEmpty ? "" : " ($type)"}",
            style: const TextStyle(color: _accent, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            "Von: ${reporter.isEmpty ? "-" : reporter}  •  Gegen: ${reported.isEmpty ? "-" : reported}",
            style: const TextStyle(color: _textSecondary),
          ),
          if (dt != null)
            Text(
              "Zeit: ${dt.toLocal()}",
              style: const TextStyle(color: _textSecondary),
            ),
          const SizedBox(height: 8),
          Text(
            reason.isEmpty ? "Kein Grund angegeben" : reason,
            style: const TextStyle(color: _textPrimary, height: 1.3),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: contentPath.isEmpty
                      ? null
                      : () async {
                    await _hideContent(contentPath);
                    await _closeReport(
                      reportId: reportId,
                      action: "hidden",
                      moderatorUsername: kAdminUsername,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Content versteckt + Report geschlossen")),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text("Hide Content"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: reported.isEmpty
                      ? null
                      : () async {
                    await _banUser(reported);
                    await _closeReport(
                      reportId: reportId,
                      action: "banned",
                      moderatorUsername: kAdminUsername,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("User gebannt + Report geschlossen")),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: _accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text("User ban"),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await _closeReport(
                      reportId: reportId,
                      action: "none",
                      moderatorUsername: kAdminUsername,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Report geschlossen")),
                      );
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _textPrimary,
                    side: const BorderSide(color: _panelBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text("Close"),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _currentUsername(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: _gradTop,
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final me = snap.data!.trim();
        if (me != kAdminUsername) {
          return const Scaffold(
            backgroundColor: _gradTop,
            body: Center(
              child: Text("Kein Zugriff.", style: TextStyle(color: _textSecondary)),
            ),
          );
        }

        return Scaffold(
          backgroundColor: _gradTop,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            centerTitle: true,
            title: const Text(
              "Reports (24h Moderation)",
              style: TextStyle(color: _textPrimary, fontWeight: FontWeight.bold),
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
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _openReports(),
              builder: (context, snap2) {
                if (snap2.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        "Firestore Fehler:\n${snap2.error}",
                        style: const TextStyle(color: _textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                if (snap2.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snap2.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text("Keine offenen Reports.", style: TextStyle(color: _textSecondary)),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    return _reportCard(context, d.id, d.data());
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

// =======================
// MENU SCREEN
// =======================
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  static const String _adminUsername = kAdminUsername;

  Future<bool> _isCurrentUserAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('currentUsername') ?? '';
    return username == _adminUsername;
  }

  // BAR CHECK (unveraendert)
  Future<bool> _isBarAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('currentUsername') ?? '').trim();
    if (username.isEmpty) return false;

    try {
      final userSnap = await FirebaseFirestore.instance.collection('users').doc(username).get();
      final isBarFlag = userSnap.data()?['isBarAccount'] == true;
      if (isBarFlag) return true;
    } catch (_) {}

    try {
      final barSnap = await FirebaseFirestore.instance.collection('bars').doc(username).get();
      if (barSnap.exists) return true;
    } catch (_) {}

    return false;
  }

  Widget _menuTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _panelBorder),
      ),
      child: ListTile(
        leading: Icon(icon, color: _accent, size: 28),
        title: Text(
          title,
          style: const TextStyle(
            color: _textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lang = LanguageService.currentLanguage;

    return BanWatcher(
      child: Scaffold(
        backgroundColor: _gradTop,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Text(
            LanguageService.getText('menu_title', lang),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _textPrimary,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            color: _accent,
            onPressed: () => Navigator.pop(context),
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
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              // PARTY MAP (MUSS ueber HomeShell laufen)
              _menuTile(
                icon: Icons.map,
                title: LanguageService.getText('party_map', lang),
                onTap: () {
                  // Menü schließen (falls Drawer/Overlay)
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }

                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RequireTermsAccepted(
                        child: Builder(
                          builder: (ctx) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!ctx.mounted) return;

                              Navigator.of(ctx).pushAndRemoveUntil(
                                MaterialPageRoute(
                                  builder: (_) => const HomeShell(initialIndex: 2),
                                ),
                                    (_) => false,
                              );
                            });

                            return const Scaffold(
                              backgroundColor: _gradTop,
                              body: Center(child: CircularProgressIndicator()),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),



              // UGC: approved parties -> Terms Gate
              _menuTile(
                icon: Icons.verified_rounded,
                title: "Zugelassene Partys",
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RequireTermsAccepted(child: AccessPartiesScreen()),
                    ),
                  );
                },
              ),

              /*
              // Premium (deaktiviert)
              FutureBuilder<bool>(
                future: _isBarAccount(),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const SizedBox.shrink();
                  }
                  final isBar = snap.data == true;
                  if (isBar) return const SizedBox.shrink();

                  return _menuTile(
                    icon: Icons.workspace_premium,
                    title: "Premium ⭐",
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const PremiumScreen()),
                      );
                    },
                  );
                },
              );
              */

              _menuTile(
                icon: Icons.language,
                title: LanguageService.getText('change_language', lang),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SelectionScreen()),
                  );
                },
              ),

              _menuTile(
                icon: Icons.upcoming,
                title: "Coming Soon",
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: _panel,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: const BorderSide(color: _panelBorder),
                      ),
                      title: const Text(
                        "Coming Soon",
                        style: TextStyle(
                          color: _accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      content: const Text(
                        "Bald verfuegbar:\n\n"
                            "- Freunde-Feature ✔\n"
                            "- Benachrichtigungen\n"
                            "- Weitere Premium-Vorteile\n"
                            "- Chatting\n"
                            "- Eure Wuensche\n\n"
                            "Wir bitten um dein Feedback und deine Ideen, um unsere App nach deinen Wuenschen zu gestalten!",
                        style: TextStyle(
                          color: _textSecondary,
                          height: 1.4,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            "Schliessen",
                            style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              // UGC: Feedback -> Terms Gate
              _menuTile(
                icon: Icons.feedback,
                title: "Feedback",
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RequireTermsAccepted(
                        child: FeedbackScreen(openedFromMenu: true),
                      ),
                    ),
                  );
                },
              ),

              _menuTile(
                icon: Icons.info,
                title: "Rechtliches",
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LegalScreen()),
                  );
                },
              ),

              _menuTile(
                icon: Icons.support_agent,
                title: "Support",
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SupportScreen()),
                  );
                },
              ),

              FutureBuilder<bool>(
                future: _isCurrentUserAdmin(),
                builder: (context, snapshot) {
                  if (snapshot.data != true) return const SizedBox.shrink();

                  return Column(
                    children: [
                      _menuTile(
                        icon: Icons.admin_panel_settings,
                        title: "Admin Bereich💻",
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const AdminCreateBarScreen()),
                          );
                        },
                      ),
                      _menuTile(
                        icon: Icons.report,
                        title: "24h Moderation",
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const AdminReportsScreen()),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =======================
// LEGAL SCREEN
// =======================
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  Widget _section(String title, String content) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: const TextStyle(
              fontSize: 15,
              color: _textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Rechtliches",
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: _textPrimary,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: _accent,
          onPressed: () => Navigator.pop(context),
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
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Container(
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _panelBorder),
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section(
                  "Impressum",
                  "PartyPin\n"
                      "E-Mail: mypartypin@gmail.com\n"
                      "Sitz: Österreich\n\n"
                      "Diese App ist eine technische Plattform zur Anzeige und Vermittlung von Veranstaltungen. "
                      "PartyPin tritt zu keinem Zeitpunkt als Veranstalter, Mitveranstalter oder Verantwortlicher fuer Inhalte oder Events auf.",
                ),
                _section(
                  "Datenschutzerklaerung",
                  """1. Allgemeines  
Der Schutz personenbezogener Daten ist uns wichtig. Dennoch weisen wir ausdruecklich darauf hin, dass die Nutzung internetbasierter Dienste stets mit Risiken verbunden ist. Eine vollstaendige Datensicherheit kann nicht garantiert werden.

2. Verarbeitete Daten  
Je nach Nutzung der App koennen folgende Daten verarbeitet werden:
- Registrierungsdaten (z. B. Benutzername, Alter)
- Profildaten (z. B. Profilbild)
- Standortdaten (freiwillig oder geraetebasiert)
- Nutzerinhalte (Texte, Bilder, Partyinformationen)
- Technische Daten (IP-Adresse, Geraeteinformationen)

3. Zweck der Verarbeitung  
- Betrieb und Bereitstellung der App  
- Anzeige und Verwaltung von Partys  
- Kommunikation zwischen Nutzern  
- Missbrauchs- und Sicherheitspraevention  

4. Rechtsgrundlagen  
Die Verarbeitung erfolgt gemaess Art. 6 Abs. 1 lit. b, c und f DSGVO.

5. Haftungsausschluss – Daten  
Wir uebernehmen keine Haftung fuer:
- Datenverluste  
- unbefugten Zugriff Dritter  
- Hackerangriffe  
- technische Stoerungen  
- Fehluebertragungen  
- Ausfaelle externer Dienste (z. B. Server, Cloud, Firebase)

Die Nutzung der App erfolgt diesbezueglich ausdruecklich auf eigenes Risiko.

6. Weitergabe an Dritte  
Eine Weitergabe erfolgt nur, soweit dies technisch erforderlich, gesetzlich vorgeschrieben oder zur Durchsetzung der Nutzungsbedingungen notwendig ist. Fuer die Datenverarbeitung durch Drittanbieter uebernehmen wir keine Haftung.

7. Speicherdauer  
Daten werden grundsaetzlich solange gespeichert, wie ein Nutzerkonto besteht oder gesetzliche Verpflichtungen dies erfordern.

8. Aenderungen  
Diese Datenschutzerklaerung kann jederzeit angepasst werden. Die weitere Nutzung der App gilt als Zustimmung zur aktuellen Version.
""",
                ),
                _section(
                  "AGB / Nutzungsbedingungen",
                  """1. Anbieterrolle  
PartyPin ist eine technische Plattform zur Veroeffentlichung und Anzeige von nutzergenerierten Inhalten (z. B. Party-Infos, Texte, Bilder, Chat- und Kommentar-Inhalte). PartyPin ist weder Veranstalter noch Mitveranstalter und uebernimmt keine Verantwortung fuer die Durchfuehrung von Veranstaltungen oder das Verhalten von Teilnehmern.

2. Nutzung & Pflichten  
Nutzer verpflichten sich, geltendes Recht einzuhalten und keine missbraeuchlichen oder rechtswidrigen Inhalte zu veroeffentlichen.

3. Zero-Tolerance – Verbotene Inhalte  
In PartyPin gilt Null-Toleranz gegenueber missbraeuchlichen oder anstoessigen Inhalten („objectionable content“). Verboten sind insbesondere:
- Hassrede, Diskriminierung, Rassismus, Extremismus  
- Belaestigung, Mobbing, Bedrohungen oder Erpressung  
- Gewaltverherrlichung oder Aufrufe zu Straftaten  
- Sexuelle Uebergriffe, sexuelle Ausbeutung, Inhalte mit Minderjaehrigen  
- Nicht-einvernehmliche intime Inhalte, Veroeffentlichung privater Daten  
- Betrug, Spam, Identitaetsmissbrauch oder illegale Werbung  
- Verletzungen von Rechten Dritter (Urheber-, Marken- oder Persoenlichkeitsrechte)

4. Nutzerinhalte  
Alle Inhalte werden von Nutzern erstellt. Nutzer sind allein fuer deren Rechtmaessigkeit und Inhalte verantwortlich.

5. Melden, Moderation & Entfernung  
Nutzer koennen Inhalte und andere Nutzer melden. Meldungen werden in der Regel innerhalb von 24 Stunden ueberprueft. PartyPin kann Inhalte ausblenden oder entfernen und weitere Massnahmen ergreifen.

6. Blockieren  
Nutzer koennen andere Nutzer blockieren. Inhalte blockierter Nutzer werden in der App ausgeblendet.

7. Sperre oder Bann  
Bei Verstoessen gegen diese Nutzungsbedingungen kann PartyPin Nutzer sperren oder dauerhaft bannen. Ein Anspruch auf Nutzung der App besteht nicht.

8. Teilnahme an Veranstaltungen  
Die Teilnahme an Partys und Veranstaltungen erfolgt ausschliesslich auf eigenes Risiko.

9. Haftungsausschluss – Veranstaltungen  
PartyPin haftet insbesondere nicht fuer:
- Verletzungen, Todesfaelle oder Sachschaeden  
- Diebstahl oder Verlust von Eigentum  
- Alkohol- oder Drogenkonsum  
- sexuelle Uebergriffe oder Belaestigungen  
- Streitigkeiten zwischen Nutzern oder strafbare Handlungen  
- behoerdliche Massnahmen oder abgesagte Veranstaltungen

10. Verfuegbarkeit & Haftung  
Eine dauerhafte oder fehlerfreie Verfuegbarkeit der App wird nicht garantiert. Die Haftung ist – soweit gesetzlich zulaessig – ausgeschlossen.

11. Aenderungen  
Diese Nutzungsbedingungen koennen jederzeit geaendert werden. Soweit erforderlich, muss die neue Version vor weiterer Nutzung akzeptiert werden.

12. Anwendbares Recht  
Es gilt oesterreichisches Recht, soweit zwingende Verbraucherschutzvorschriften nichts anderes bestimmen.
""",
                ),
                const SizedBox(height: 20),
                Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      "Zurueck",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =======================
// SUPPORT SCREEN
// =======================
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  Future<void> _sendEmail() async {
    final Uri emailLaunchUri = Uri(
      scheme: 'mailto',
      path: 'mypartypin@gmail.com',
      query: 'subject=Support-Anfrage&body=Hallo, ich benoetige Hilfe zu ...',
    );

    if (!await launchUrl(emailLaunchUri)) {
      debugPrint('Konnte keine E-Mail oeffnen');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Support",
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: _textPrimary,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: _accent,
          onPressed: () => Navigator.pop(context),
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
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _panelBorder),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Support & Hilfe",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: _accent,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                "Solltest du Fragen haben oder Unterstuetzung brauchen, kontaktiere uns per E-Mail:",
                style: TextStyle(color: _textSecondary),
              ),
              const SizedBox(height: 5),
              const Text(
                "mypartypin@gmail.com",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _accent,
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: ElevatedButton.icon(
                  onPressed: _sendEmail,
                  icon: const Icon(Icons.email),
                  label: const Text(
                    "Support per E-Mail schreiben",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
