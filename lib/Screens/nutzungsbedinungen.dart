//lib/Screens/terms_screen.dart
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

  // --- Farben: ident mit NewPartyScreen ---
  static const _bg = Color(0xFF0E0F12);
  static const _gradTop = Color(0xFF0E0F12);
  static const _gradBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF15171C);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _card = Color(0xFF1C1F26);
  static const _textPrimary = Colors.white;
  static const _textSecondary = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30); // Rot
  static const _secondary = Color(0xFF00C2A8); // Türkis (falls gebraucht)

  Future<void> _acceptTerms() async {
    setState(() => _isSaving = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('termsAccepted', true);
    if (!mounted) return;
    setState(() => _isSaving = false);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const PartyMapScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Nutzungsbedingungen & Datenschutz",
          style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
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
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _panelBorder),
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 10)),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.gavel, size: 56, color: _accent),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        "Datenschutzerklärung & AGB",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: _textPrimary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        decoration: BoxDecoration(
                          color: _card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _panelBorder),
                        ),
                        constraints: const BoxConstraints(minHeight: 260, maxHeight: 360),
                        padding: const EdgeInsets.all(14),
                        child: const Scrollbar(
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            child: Text(
                              '''
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

Anfragen an: mypartypin@gmail.com

7. Sicherheit
Wir setzen technische und organisatorische Maßnahmen ein, um die Daten vor Verlust, Missbrauch und unbefugtem Zugriff zu schützen.

8. Änderungen
Wir behalten uns vor, diese Datenschutzerklärung anzupassen. Die aktuelle Version ist in der App abrufbar.

9. Anwendbares Recht
Es gilt österreichisches Recht, soweit zwingendes Verbraucherrecht nicht entgegensteht.


Allgemeine Geschäftsbedingungen (AGB)

Geltungsbereich
Diese App ermöglicht es, Partys auf einer Karte darzustellen, sich anzumelden und zu kommunizieren. Nutzung ausschließlich auf Grundlage dieser AGB.

Registrierung
Erforderlich sind Vorname, Nachname, Alter und Benutzername. Angaben müssen wahrheitsgemäß sein.

Nutzung der App
Nutzer können Partys anlegen und verwalten. Der Ersteller ist für Inhalte verantwortlich.

Verantwortlichkeiten
Die App ist eine Plattform. Für Inhalte und Organisation haften die Nutzer. Keine Haftung der Betreiber, soweit gesetzlich zulässig.

Pflichten der Nutzer
- Keine rechtswidrigen Inhalte
- Keine Belästigung oder Betrug
- Rechte Dritter wahren

Verfügbarkeit
Keine Garantie auf dauerhafte Verfügbarkeit.

Änderungen der AGB
Änderungen werden in der App angezeigt. Weitere Nutzung gilt als Zustimmung.

Anwendbares Recht
Es gilt österreichisches Recht, soweit zwingendes Verbraucherrecht nicht entgegensteht.
''',
                              style: TextStyle(color: _textSecondary, fontSize: 14, height: 1.35),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _accepted,
                            activeColor: _accent,
                            side: const BorderSide(color: _panelBorder),
                            onChanged: (val) => setState(() => _accepted = val ?? false),
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              "Ich habe die Datenschutzerklärung und AGB gelesen und akzeptiere sie.",
                              style: TextStyle(color: _textSecondary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: (_accepted && !_isSaving) ? _acceptTerms : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _accent,
                            disabledBackgroundColor: Colors.grey[700],
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _isSaving
                              ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                              : const Text(
                            "Weiter",
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
