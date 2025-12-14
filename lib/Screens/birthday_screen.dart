import 'package:flutter/material.dart';
import 'party_map_screen.dart';
// TODO: richtigen Screen importieren:
// import 'create_party_screen.dart';

class BirthdayScreen extends StatelessWidget {
  final String username;
  const BirthdayScreen({super.key, required this.username});

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFF0E0F12);
    const bgBottom = Color(0xFF141A22);
    const accent = Color(0xFFFF3B30);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [bgTop, bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cake, size: 64, color: Colors.amber),
                const SizedBox(height: 14),
                const Text(
                  "Alles Gute zum Geburtstag!",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  username,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  "Tipp: Wenn du heute eine Geburtstagsparty machst, erstell sie gleich in PartyPin.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, height: 1.4),
                ),
                const SizedBox(height: 22),

                // 1) Party erstellen
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // TODO: hier deinen Party-Create Screen einsetzen:
                      // Navigator.pushReplacement(
                      //   context,
                      //   MaterialPageRoute(builder: (_) => const CreatePartyScreen()),
                      // );

                      // Fallback (solange du den Screen noch nicht eingefügt hast):
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.celebration),
                    label: const Text(
                      "Geburtstagsparty erstellen",
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),

                const SizedBox(height: 10),

                // 2) Zur Karte
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      foregroundColor: Colors.white70,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.map),
                    label: const Text(
                      "Zur Karte",
                      style: TextStyle(fontWeight: FontWeight.w700),
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
