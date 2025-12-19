import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../Services/language_services.dart';
import '../Screens/party_map_screen.dart';
import '../Screens/selection_screen.dart';
import '../Screens/feedback_screen.dart';
import '../Screens/AdminCreatesBarScreen.dart';
import '../Services/paypal.dart'; // PayPal-Service

// --- Zentrales Farb-Theme ---
const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _card = Color(0xFF1C1F26);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30);
const _secondary = Color(0xFF00C2A8);

// ------------------- Menu Screen -------------------
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  static const String _adminUsername = "admin_pp";

  Future<Map<String, dynamic>?> _getSavedLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final city = prefs.getString('city');
    final lat = prefs.getDouble('selectedLat');
    final lng = prefs.getDouble('selectedLng');

    if (city != null && lat != null && lng != null) {
      return {
        'city': city,
        'latitude': lat,
        'longitude': lng,
      };
    }
    return null;
  }

  Future<bool> _isCurrentUserAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('currentUsername') ?? '';
    return username == _adminUsername;
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
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                  return;
                }

                final location = await _getSavedLocation();
                if (location != null) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const PartyMapScreen(),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SelectionScreen(),
                    ),
                  );
                }
              },
            ),
            _menuTile(
              icon: Icons.workspace_premium,
              title: "Premium ⭐",
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PremiumScreen(),
                  ),
                );
              },
            ),
            _menuTile(
              icon: Icons.language,
              title: LanguageService.getText('change_language', lang),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SelectionScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (context) => const LegalScreen(),
                  ),
                );
              },
            ),
            _menuTile(
              icon: Icons.support_agent,
              title: "Support",
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SupportScreen(),
                  ),
                );
              },
            ),
            FutureBuilder<bool>(
              future: _isCurrentUserAdmin(),
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data != true) {
                  return const SizedBox.shrink();
                }
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

// ------------------- Legal Screen -------------------
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 30,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      "Zurück",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
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

// ------------------- Support Screen -------------------
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
                "Wenn du Fragen hast oder Hilfe benötigst, kontaktiere uns bitte per E-Mail:",
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
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
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

// ------------------- Premium Screen -------------------
class PremiumScreen extends StatefulWidget {
  const PremiumScreen({super.key});

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  PayPalPlan _selectedPlan = PayPalPlan.monthly; // ✅ Enum statt String
  bool _isLoading = false;
  String? _currentUsername;

  @override
  void initState() {
    super.initState();
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentUsername = prefs.getString('currentUsername');
    });
  }

  String _planTitle(PayPalPlan plan) =>
      plan == PayPalPlan.monthly ? 'Monatlich' : 'Jährlich';

  String _planPriceText(PayPalPlan plan) =>
      plan == PayPalPlan.monthly ? '1,49 € / Monat' : '14,99 € / Jahr';

  String _payButtonLabel(PayPalPlan plan) => 'Mit PayPal zahlen';

  String _savingsText() {
    // 12 * 1,49 = 17,88 ; 17,88 - 14,99 = 2,89 Ersparnis
    return 'Spare ca. 2,89 € pro Jahr';
  }

  Future<void> _openSubscriptionCheckout() async {
    final u = _currentUsername?.trim() ?? '';
    if (u.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: _panel,
          content: Text(
            'Kein Username gefunden. Bitte neu einloggen.',
            style: TextStyle(color: _textPrimary),
          ),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final uri = PayPalCheckout.buildCheckoutUri(
        username: u,
        plan: _selectedPlan, // ✅ Enum (monthly/yearly)
      );

      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('Konnte PayPal-Seite nicht öffnen.');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _panel,
          content: Text(
            'PayPal geöffnet (${_planTitle(_selectedPlan)}). Nach Abschluss wird Premium automatisch aktiviert.',
            style: const TextStyle(color: _textPrimary),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _panel,
          content: Text(
            'Fehler beim Öffnen von PayPal: $e',
            style: const TextStyle(color: _textPrimary),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF090B10);
    const panel = Color(0xFF141A22);
    const accentRed = Color(0xFFFF3B30);

    final yearlySelected = _selectedPlan == PayPalPlan.yearly;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,

        // ✅ kleiner Zurückpfeil
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.white),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Zurück',
        ),

        title: const Text(
          'Premium ⭐',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
      ),
      body: _currentUsername == null
          ? const Center(
        child: Text(
          'Kein Benutzer gefunden. Bitte neu einloggen.',
          style: TextStyle(color: Colors.white70),
        ),
      )
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ✅ Header-Karte kundenfreundlicher (wie bei dir)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mehr Überblick. Mehr Spaß.',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Mit PartyPin Premium siehst du live, auf welche Partys deine Freunde gehen '
                        '(„Ich komme“ / „Vielleicht“). Außerdem bekommst du früher Zugriff auf neue Features.',
                    style: TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 14),

                  _benefitRow(Icons.people_alt, 'Freunde-Status in Echtzeit'),
                  const SizedBox(height: 8),
                  _benefitRow(Icons.bolt, 'Früher Zugriff auf neue Features'),
                  const SizedBox(height: 8),
                  _benefitRow(Icons.shield, 'Premium ist accountgebunden'),
                ],
              ),
            ),

            const SizedBox(height: 16),

            const Text(
              'Wähle dein Abo',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),

            // ✅ Plans (wie bei dir)
            _planCard(
              title: 'Monatlich',
              subtitle: 'Flexibel kündbar – ideal zum Testen.',
              price: _planPriceText(PayPalPlan.monthly),
              selected: _selectedPlan == PayPalPlan.monthly,
              highlight: null,
              onTap: () => setState(() => _selectedPlan = PayPalPlan.monthly),
            ),
            const SizedBox(height: 10),
            _planCard(
              title: 'Jährlich',
              subtitle: 'Bestes Angebot – weniger Aufwand.',
              price: _planPriceText(PayPalPlan.yearly),
              selected: yearlySelected,
              highlight: _savingsText(),
              onTap: () => setState(() => _selectedPlan = PayPalPlan.yearly),
            ),

            const SizedBox(height: 18),

            // ✅ klarerer Checkout-Button (wie bei dir)
            ElevatedButton(
              onPressed: _isLoading ? null : _openSubscriptionCheckout,
              style: ElevatedButton.styleFrom(
                backgroundColor: accentRed,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.payment, size: 18),
                  const SizedBox(width: 10),
                  Text(
                    _payButtonLabel(_selectedPlan),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '• ${_planPriceText(_selectedPlan)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // ✅ Hinweis-Box (wie bei dir)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F121A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white10),
              ),
              child: const Text(
                'Hinweis: Abos werden über PayPal abgewickelt. Premium wird nach erfolgreicher Bestätigung automatisch aktiviert. '
                    'Kündigung jederzeit in PayPal möglich.',
                style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _benefitRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _planCard({
    required String title,
    required String subtitle,
    required String price,
    required bool selected,
    required VoidCallback onTap,
    String? highlight,
  }) {
    // ✅ Wenn du NICHT willst, dass "selected" rot ist:
    // ersetze unten accentRed durch Colors.amber (oder was du willst).
    const accentRed = Color(0xFFFF3B30);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E2230) : const Color(0xFF141824),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? accentRed : Colors.white12,
            width: selected ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? accentRed : Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                      if (highlight != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: accentRed.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: accentRed),
                          ),
                          child: Text(
                            highlight,
                            style: const TextStyle(
                              color: accentRed,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              price,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ),
    );
  }
}
