import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../Screens/party_map_screen.dart';

class SelectionScreen extends StatefulWidget {
  const SelectionScreen({super.key});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  String _selectedLanguage = 'de'; // Immer Deutsch
  String _selectedCountry = 'Austria';
  String _enteredCity = '';

  final List<String> _countries = ['Austria', 'Germany', 'Switzerland'];

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedLanguage = 'de';
      _selectedCountry = prefs.getString('country') ?? 'Austria';
      _enteredCity = prefs.getString('city') ?? '';
    });
  }

  Future<void> _saveUserSelection(
      String city, String country, double lat, double lng) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('city', city);
    await prefs.setString('language', 'de');
    await prefs.setString('country', country);
    await prefs.setDouble('selectedLat', lat);
    await prefs.setDouble('selectedLng', lng);
  }

  Future<void> _goToPartyMap() async {
    if (_enteredCity.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Bitte eine Stadt eingeben")),
      );
      return;
    }

    String city = _enteredCity.trim();

    switch (city.toLowerCase()) {
      case 'wien':
        city = 'Vienna';
        break;
      case 'linz':
        city = 'Linz';
        break;
      case 'graz':
        city = 'Graz';
        break;
    }

    try {
      final locations = await locationFromAddress("$city, $_selectedCountry");
      if (locations.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Stadt nicht gefunden")),
        );
        return;
      }

      final lat = locations.first.latitude;
      final lng = locations.first.longitude;

      await _saveUserSelection(city, _selectedCountry, lat, lng);

      if (context.mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const PartyMapScreen()),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Stadt nicht gefunden")),
      );
    }
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white),
      filled: true,
      fillColor: Colors.grey[800],
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cityController = TextEditingController(text: _enteredCity);

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: const Text(
          "Welcome",
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.redAccent),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Sprache Dropdown
            DropdownButtonFormField<String>(
              value: _selectedLanguage,
              items: const [
                DropdownMenuItem(
                  value: 'de',
                  child: Text("Deutsch", style: TextStyle(color: Colors.white)),
                ),
              ],
              onChanged: (val) {},
              decoration: _inputDecoration("Sprache"),
              dropdownColor: Colors.grey[850],
            ),
            const SizedBox(height: 16),

            // Länder Dropdown
            DropdownButtonFormField<String>(
              value: _selectedCountry,
              items: _countries
                  .map((c) => DropdownMenuItem(
                value: c,
                child: Text(c, style: const TextStyle(color: Colors.white)),
              ))
                  .toList(),
              onChanged: (val) => setState(() => _selectedCountry = val!),
              decoration: _inputDecoration("Land"),
              dropdownColor: Colors.grey[850],
            ),
            const SizedBox(height: 16),

            // Stadtfeld
            TextFormField(
              controller: cityController,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration("Stadt"),
              onChanged: (val) => _enteredCity = val,
            ),

            const Spacer(),

            // Button
            ElevatedButton(
              onPressed: _goToPartyMap,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("Zur Karte", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
