// lib/Screens/menu_screen.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../Services/language_services.dart';
import '../Screens/party_map_screen.dart';
import '../Screens/selection_screen.dart';
import '../Screens/feedback_screen.dart';
import '../Screens/AdminCreatesBarScreen.dart';
import '../Screens/premium_screen.dart';
import '../Screens/access_parties_screen.dart';


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
// MENU SCREEN
// =======================
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  static const String _adminUsername = "admin_pp";

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

  Future<bool> _isCurrentUserAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('currentUsername') ?? '';
    return username == _adminUsername;
  }

  // ✅ BAR CHECK: Premium Tile ausblenden, wenn Bar-Account
  // Unterstützt beide Varianten:
  // A) users/{username}.isBarAccount == true
  // B) bars/{username} existiert
  Future<bool> _isBarAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('currentUsername') ?? '').trim();
    if (username.isEmpty) return false;

    try {
      final userSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(username)
          .get();

      final isBarFlag = userSnap.data()?['isBarAccount'] == true;
      if (isBarFlag) return true;
    } catch (_) {
      // ignorieren -> fallback check
    }

    try {
      final barSnap = await FirebaseFirestore.instance
          .collection('bars')
          .doc(username)
          .get();
      if (barSnap.exists) return true;
    } catch (_) {
      // ignorieren
    }

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

    return Scaffold(
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
            _menuTile(
              icon: Icons.map,
              title: LanguageService.getText('party_map', lang),
              onTap: () async {
                // wenn Menü über Drawer/Overlay geöffnet wurde → einfach schließen
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                  return;
                }

                final location = await _getSavedLocation();
                if (location != null) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => const PartyMapScreen()),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SelectionScreen()),
                  );
                }
              },
            ),
            _menuTile(
              icon: Icons.verified_rounded,
              title: "Zugelassene Partys",
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AccessPartiesScreen()),
                );
              },
            ),

            // ✅ Premium Tile nur wenn KEIN Bar-Account
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
            ),

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
                      "Bald verfügbar:\n\n"
                          "- Freunde-Feature ✔\n"
                          "- Benachrichtigungen\n"
                          "- Weitere Premium-Vorteile\n"
                          "- Chatting\n"
                          "- Eure Wünsche\n\n"
                          "Wir bitten um dein Feedback und deine Ideen, um unsere App nach deinen Wünschen zu gestalten!",
                      style: TextStyle(
                        color: _textSecondary,
                        height: 1.4,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          "Schließen",
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

            _menuTile(
              icon: Icons.feedback,
              title: "Feedback",
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const FeedbackScreen(openedFromMenu: true),
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
                return _menuTile(
                  icon: Icons.admin_panel_settings,
                  title: "Admin Bereich💻",
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AdminCreateBarScreen(),
                      ),
                    );
                  },
                );
              },
            ),
          ],
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
                  "PartyPin\nE-Mail: mypartypin@gmail.com\nAdresse: Beispielstraße 1, 1010 Wien\n"
                      "Geschäftsführer: Max Mustermann\nUID: ATU12345678",
                ),
                _section(
                  "Datenschutzerklärung",
                  """1. Erhobene Daten
- Registrierungsdaten (Vorname, Nachname, Alter, Benutzername)
- Standortdaten (zur Anzeige von Partys)
- Profildaten (z. B. Profilbild)
- Kommunikationsinhalte zwischen Nutzern

2. Zweck der Verarbeitung
- Registrierung & Anmeldung
- Partys anzeigen & Teilnahme verwalten
- Kommunikation zwischen Nutzern
- Sicherheit der App gewährleisten

3. Rechtsgrundlage
- Art. 6 Abs. 1 lit. b DSGVO
- Art. 6 Abs. 1 lit. f DSGVO

4. Weitergabe
- Nur gesetzlich erforderlich oder zur App-Funktion notwendig

5. Speicherung & Löschung
- Daten solange wie das Nutzerkonto besteht

6. Rechte der Nutzer
- Auskunft, Berichtigung, Löschung, Einschränkung, Widerspruch, Datenübertragbarkeit
- Kontakt: mypartypin@gmail.com

7. Sicherheit
- Technische & organisatorische Maßnahmen

8. Änderungen
- Anpassung an App-Funktionen oder rechtliche Anforderungen

9. Anwendbares Recht
- Recht der Bundesrepublik Österreich, soweit zwingendes Verbraucherrecht nicht entgegensteht
""",
                ),
                _section(
                  "AGB / Nutzungsbedingungen",
                  """1. Geltungsbereich
- App zur Darstellung & Teilnahme an Partys

2. Registrierung
- Wahrheitsgemäße Angaben nötig

3. Nutzung der App
- Partys anlegen & verwalten
- Verantwortlich für Inhalte sind die Nutzer

4. Pflichten der Nutzer
- Keine rechtswidrigen Inhalte
- Keine Nutzung zum Zwecke von Belästigung oder Betrug
- Wahrung der Rechte Dritter

5. Haftung
- Betreiber übernehmen keine Garantie für Inhalte oder Verfügbarkeit

6. Änderungen der AGB
- Änderungen werden in der App angezeigt
- Nutzung nach Änderung gilt als Zustimmung

7. Anwendbares Recht
- Österreichisches Recht soweit zulässig
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
                      "Zurück",
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
      query: 'subject=Support-Anfrage&body=Hallo, ich benötige Hilfe zu ...',
    );

    if (!await launchUrl(emailLaunchUri)) {
      debugPrint('Konnte keine E-Mail öffnen');
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
                "Sollten Sie Fragen haben, weitere Informationen benötigen oder Unterstützung wünschen, zögern Sie bitte nicht, uns zu kontaktieren. Unser Team steht Ihnen jederzeit gerne zur Verfügung. Sie erreichen uns zuverlässig und unkompliziert per E-Mail unter folgender Adresse:",
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
