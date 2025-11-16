// lib/Screens/selection_screen.dart
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
  // --- Farben im selben Schema wie Terms/NewParty/CreateAccount ---
  static const _gradTop = Color(0xFF0E0F12);
  static const _gradBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF15171C);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _card = Color(0xFF1C1F26);
  static const _textPrimary = Colors.white;
  static const _textSecondary = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30); // Rot
  static const _secondary = Color(0xFF00C2A8); // Türkis (optional)

  String _selectedLanguage = 'de'; // Immer Deutsch (disabled)
  String _selectedCountry = 'Austria';
  String _enteredCity = '';

  final List<String> _countries = const ['Austria', 'Germany', 'Switzerland'];

  // Controller als State, nicht in build
  final TextEditingController _cityController = TextEditingController();

  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  @override
  void dispose() {
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedLanguage = 'de';
      _selectedCountry = prefs.getString('country') ?? 'Austria';
      _enteredCity = prefs.getString('city') ?? '';
      _cityController.text = _enteredCity;
    });
  }

  Future<void> _saveUserSelection(
      String city,
      String country,
      double lat,
      double lng,
      ) async {
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

    setState(() => _isSearching = true);

    String city = _enteredCity.trim();

    // einfache Alias-Mappings
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
        setState(() => _isSearching = false);
        return;
      }

      final lat = locations.first.latitude;
      final lng = locations.first.longitude;

      await _saveUserSelection(city, _selectedCountry, lat, lng);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const PartyMapScreen()),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Stadt nicht gefunden")),
      );
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  InputDecoration _dec({
    required String label,
    IconData? icon,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textSecondary, fontWeight: FontWeight.w600),
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF93A0B4)),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      filled: true,
      fillColor: _card,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
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
          "Welcome",
          style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: _accent),
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
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _panelBorder),
                  boxShadow: const [
                    BoxShadow(color: Color(0x24000000), blurRadius: 14, offset: Offset(0, 10)),
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Header Icon
                    const Icon(Icons.public, size: 56, color: _accent),
                    const SizedBox(height: 10),
                    const Text(
                      "App-Sprache, Land & Stadt",
                      style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w800, fontSize: 18),
                    ),
                    const SizedBox(height: 16),

                    // Sprache (fest auf Deutsch)
                    AbsorbPointer(
                      absorbing: true,
                      child: DropdownButtonFormField<String>(
                        value: _selectedLanguage,
                        items: const [
                          DropdownMenuItem(
                            value: 'de',
                            child: Text("Deutsch", style: TextStyle(color: _textPrimary)),
                          ),
                        ],
                        onChanged: (_) {},
                        decoration: _dec(label: "Sprache", icon: Icons.language),
                        dropdownColor: _card,
                        style: const TextStyle(color: _textPrimary),
                        iconEnabledColor: _textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Land
                    DropdownButtonFormField<String>(
                      value: _selectedCountry,
                      items: _countries
                          .map(
                            (c) => DropdownMenuItem(
                          value: c,
                          child: Text(c, style: const TextStyle(color: _textPrimary)),
                        ),
                      )
                          .toList(),
                      onChanged: (val) => setState(() => _selectedCountry = val!),
                      decoration: _dec(label: "Land", icon: Icons.flag_outlined),
                      dropdownColor: _card,
                      style: const TextStyle(color: _textPrimary),
                      iconEnabledColor: _textSecondary,
                    ),
                    const SizedBox(height: 12),

                    // Stadt
                    TextFormField(
                      controller: _cityController,
                      onChanged: (val) => _enteredCity = val,
                      style: const TextStyle(color: _textPrimary),
                      decoration: _dec(
                        label: "Stadt",
                        icon: Icons.location_city_outlined,
                        hint: "z. B. Vienna / Linz / Graz",
                      ),
                      textInputAction: TextInputAction.done,
                    ),

                    const SizedBox(height: 20),

                    // Hinweis
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.info_outline, size: 16, color: _textSecondary),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            "Die Karte startet in deiner gewählten Stadt.",
                            style: TextStyle(color: _textSecondary),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isSearching ? null : _goToPartyMap,
                        icon: _isSearching
                            ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.map_outlined),
                        label: Text(_isSearching ? "Suche…" : "Zur Karte"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          disabledBackgroundColor: _accent.withOpacity(0.4),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    );
  }
}
