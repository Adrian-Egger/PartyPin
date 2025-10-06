import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../Services/language_services.dart';
import '../Screens/party_map_screen.dart';
import '../Screens/selection_screen.dart';
import '../Screens/feedback_screen.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    final lang = LanguageService.currentLanguage;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          LanguageService.getText('menu_title', lang),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.grey[900],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Colors.redAccent,
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        color: Colors.grey[850],
        child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.map, color: Colors.redAccent, size: 32),
              title: Text(
                LanguageService.getText('party_map', lang),
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              onTap: () async {
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
                    MaterialPageRoute(builder: (context) => const SelectionScreen()),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.language, color: Colors.redAccent, size: 32),
              title: Text(
                LanguageService.getText('change_language', lang),
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SelectionScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.upcoming, color: Colors.redAccent, size: 32),
              title: const Text(
                "Coming Soon",
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              onTap: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: Colors.grey[900],
                    title: const Text("Coming Soon", style: TextStyle(color: Colors.redAccent)),
                    content: const Text(
                      "Bald verfügbar:\n- Freunde-Feature\n- Benachrichtigungen\n- Premium-Accounts\n- Chatting\n- Eure Wünsche\n\n"
                          "Wir bitten um dein Feedback und deine Ideen, um unsere App nach deinen Wünschen zu gestalten und zu perfektionieren!",
                      style: TextStyle(color: Colors.white),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text("Schließen", style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.feedback, color: Colors.redAccent, size: 32),
              title: const Text("Feedback", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const FeedbackScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.info, color: Colors.redAccent, size: 32),
              title: const Text("Rechtliches", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LegalScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.support_agent, color: Colors.redAccent, size: 32),
              title: const Text("Support", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SupportScreen()),
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
              color: Colors.redAccent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: const TextStyle(
              fontSize: 16,
              color: Colors.white,
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
      appBar: AppBar(
        title: const Text(
          "Rechtliches",
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.grey[900],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Colors.redAccent,
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        color: Colors.grey[850],
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section(
                "Impressum",
                "PartyPin\nE-Mail: mypartypin@gmail.com\nAdresse: Beispielstraße 1, 1010 Wien\nGeschäftsführer: Max Mustermann\nUID: ATU12345678",
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
                  child: const Text("Zurück"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
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
      appBar: AppBar(
        title: const Text(
          "Support",
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.grey[900],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          color: Colors.redAccent,
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Container(
        color: Colors.grey[850],
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Support & Hilfe",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.redAccent),
            ),
            const SizedBox(height: 10),
            const Text(
              "Wenn du Fragen hast oder Hilfe benötigst, kontaktiere uns bitte per E-Mail:",
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 5),
            const Text(
              "mypartypin@gmail.com",
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _sendEmail,
              icon: const Icon(Icons.email),
              label: const Text("Support per E-Mail schreiben"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
