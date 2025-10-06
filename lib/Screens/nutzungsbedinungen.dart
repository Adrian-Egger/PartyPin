import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'party_map_screen.dart';

class TermsScreen extends StatefulWidget {
  const TermsScreen({Key? key}) : super(key: key);

  @override
  State<TermsScreen> createState() => _TermsScreenState();
}

class _TermsScreenState extends State<TermsScreen> {
  bool _accepted = false;
  bool _isSaving = false;

  Future<void> _acceptTerms() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('termsAccepted', true);
    setState(() => _isSaving = false);

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const PartyMapScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Nutzungsbedingungen & Datenschutz"),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0f0f0f), Color(0xFF1f1f1f)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                color: Colors.grey[900]!.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 12,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(Icons.gavel, size: 64, color: Colors.redAccent),
                      const SizedBox(height: 16),
                      const Text(
                        "Datenschutzerklärung & AGB",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 300,
                        child: SingleChildScrollView(
                          child: const Text(
                            """
Datenschutzerklärung

1. Erhobene Daten
Wir verarbeiten folgende personenbezogene Daten:
- Registrierungsdaten (Vorname, Nachname, Alter, Benutzername)
- Standortdaten (zur Anzeige von Partys auf der Karte)
- Profildaten (sofern vom Nutzer angegeben, z. B. Bild)
- Kommunikationsinhalte (z. B. Chat-Nachrichten zwischen Nutzern)

2. Zweck der Datenverarbeitung
Die Daten werden verwendet, um:
- die Registrierung und Anmeldung in der App zu ermöglichen
- Partys auf einer Karte darzustellen und Teilnahme zu verwalten
- Kommunikation zwischen Nutzern zu ermöglichen
- die Sicherheit der App zu gewährleisten

3. Rechtsgrundlage
Die Verarbeitung erfolgt auf Grundlage von:
- Art. 6 Abs. 1 lit. b DSGVO (Vertragserfüllung – Nutzung der App)
- Art. 6 Abs. 1 lit. f DSGVO (berechtigtes Interesse – sichere Nutzung der App)

4. Weitergabe von Daten
Daten werden nicht an Dritte weitergegeben, außer:
- es ist zur Erfüllung der App-Funktionen erforderlich (z. B. Hosting-Anbieter)
- eine gesetzliche Verpflichtung besteht

5. Speicherung und Löschung
Die Daten werden solange gespeichert, wie das Nutzerkonto besteht.
Nach Löschung des Kontos werden die Daten gelöscht, soweit keine gesetzlichen Aufbewahrungspflichten bestehen.

6. Rechte der Nutzer
Nutzer haben das Recht auf:
- Auskunft über die gespeicherten Daten
- Berichtigung unrichtiger Daten
- Löschung der Daten („Recht auf Vergessenwerden“)
- Einschränkung der Verarbeitung
- Widerspruch gegen die Verarbeitung
- Datenübertragbarkeit

Dazu kann eine Anfrage an mypartypin@gmail.com gestellt werden.

7. Sicherheit
Wir setzen technische und organisatorische Maßnahmen ein, um die Daten vor Verlust, Missbrauch und unbefugtem Zugriff zu schützen.

8. Änderungen
Wir behalten uns vor, diese Datenschutzerklärung zu ändern, um sie an geänderte Funktionen der App oder rechtliche Anforderungen anzupassen. Die aktuelle Version ist jederzeit in der App abrufbar.

9. Anwendbares Recht
Es gilt das Recht der Bundesrepublik Österreich, soweit zwingendes Verbraucherrecht nicht entgegensteht.


Allgemeine Geschäftsbedingungen (AGB)

Geltungsbereich
Diese App ermöglicht es Nutzerinnen und Nutzern, öffentliche Veranstaltungen („Partys“) auf einer Karte darzustellen, sich für Partys anzumelden und mit anderen Teilnehmern zu kommunizieren. Die Nutzung erfolgt ausschließlich auf Grundlage dieser AGB.

Registrierung
Zur Nutzung der App ist eine Registrierung mit Vorname, Nachname, Alter und Benutzername erforderlich. Der Nutzer verpflichtet sich, bei der Registrierung wahrheitsgemäße Angaben zu machen.

Nutzung der App
Nutzer können Partys anlegen und verwalten. Es gibt offene Partys (sichtbar für alle registrierten Nutzer). Der Ersteller einer Party ist verantwortlich für deren Inhalt und Einladungen.

Verantwortlichkeiten
Die App stellt lediglich die technische Plattform bereit. Für den Inhalt der Partys und die Organisation der Veranstaltungen sind ausschließlich die Nutzer verantwortlich. Die Betreiber übernehmen keine Haftung für Schäden, die im Zusammenhang mit Partys entstehen.

Pflichten der Nutzer
- Keine Veröffentlichung von rechtswidrigen Inhalten
- Keine Nutzung der App zum Zwecke von Belästigung oder Betrug
- Wahrung der Rechte Dritter

Haftungsausschluss
Die Betreiber übernehmen keine Garantie für die Verfügbarkeit der App. Eine Haftung für Schäden, die durch die Nutzung der App entstehen, ist ausgeschlossen, soweit gesetzlich zulässig.

Änderungen der AGB
Die Betreiber behalten sich vor, diese AGB jederzeit zu ändern. Änderungen werden in der App angezeigt. Die weitere Nutzung nach Änderung gilt als Zustimmung.

Anwendbares Recht
Es gilt das Recht der Bundesrepublik Österreich, soweit zwingendes Verbraucherrecht nicht entgegensteht.
""",
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Checkbox(
                            value: _accepted,
                            activeColor: Colors.redAccent,
                            onChanged: (val) {
                              setState(() {
                                _accepted = val ?? false;
                              });
                            },
                          ),
                          const Expanded(
                            child: Text(
                              "Ich habe die Datenschutzerklärung und AGB gelesen und akzeptiere sie.",
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 300),
                          opacity: (_accepted && !_isSaving) ? 1.0 : 0.5,
                          child: ElevatedButton(
                            onPressed: (_accepted && !_isSaving) ? _acceptTerms : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: _isSaving
                                ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                                : const Text(
                              "Weiter",
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
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
      ),
    );
  }
}
