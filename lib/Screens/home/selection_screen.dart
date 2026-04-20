// lib/Screens/selection_screen.dart
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'home_shell.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

class SelectionScreen extends StatefulWidget {
  const SelectionScreen({super.key});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  // --- Farben ---
  static const _gradTop = AppColors.bgTop;
  static const _gradBottom = AppColors.bgBottom;
  static const _panel = Color(0xFF15171C);
  static const _card = AppColors.panel;
  static const _textPrimary = AppColors.text;
  static const _textSecondary = AppColors.muted;
  static const _accent = AppColors.accent;

  String _selectedLanguage = 'de';
  String _selectedCountry = 'Austria';
  String _enteredCity = '';

  final List<String> _countries = const ['Austria', 'Germany', 'Switzerland'];

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
      _selectedLanguage = prefs.getString('language') ?? 'de';
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

    // lokal
    await prefs.setString('city', city);
    await prefs.setString('language', _selectedLanguage);
    await prefs.setString('country', country);
    await prefs.setDouble('selectedLat', lat);
    await prefs.setDouble('selectedLng', lng);
    await prefs.setBool('hasLocationSetup', true);

    // in Firestore beim User/BAR hinterlegen
    final username = prefs.getString('currentUsername');
    final isBar = prefs.getBool('isBar') ?? false;

    if (username == null || username.trim().isEmpty) return;

    final colName = isBar ? 'bars' : 'users';
    final col = FirebaseFirestore.instance.collection(colName);

    final query = await col
        .where('username', isEqualTo: username)
        .limit(1)
        .get();

    if (query.docs.isEmpty) return;

    await query.docs.first.reference.set(
      {
        'language': _selectedLanguage,
        'country': country,
        'city': city,
        'selectedLat': lat,
        'selectedLng': lng,
        'hasLocationSetup': true,
      },
      SetOptions(merge: true),
    );
  }

  Future<void> _goToPartyMap() async {
    if (_enteredCity.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Lang.t('selection_city_missing')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
          SnackBar(
          content: Text(Lang.t('selection_city_not_found')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
      // Set language AFTER navigation so ValueListenableBuilder doesn't
      // rebuild SelectionScreen while it is still visible
      await Lang.set(_selectedLanguage);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Lang.t('selection_city_not_found')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
      labelStyle:
      const TextStyle(color: _textSecondary, fontWeight: FontWeight.w600),
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF93A0B4)),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      filled: true,
      fillColor: _card,
      contentPadding:
      const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
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
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.fullBr,
            border: Border.all(color: AppColors.accentBorder2, width: 1),
          ),
          child: Text(
            Lang.tLang(_selectedLanguage, 'selection_title'),
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
            ),
          ),
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
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                decoration: BoxDecoration(
                  color: _panel,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.accentBorder),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x24000000),
                        blurRadius: 14,
                        offset: Offset(0, 10)),
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Icon(Icons.public, size: 56, color: _accent),
                    const SizedBox(height: 10),
                    Text(
                      Lang.tLang(_selectedLanguage, 'selection_heading'),
                      style: const TextStyle(
                          color: _textPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 18),
                    ),
                    const SizedBox(height: 16),

                    // Sprache
                    DropdownButtonFormField<String>(
                      value: _selectedLanguage,
                      items: const [
                        DropdownMenuItem(
                          value: 'de',
                          child: Text('Deutsch 🇩🇪',
                              style: TextStyle(color: _textPrimary)),
                        ),
                        DropdownMenuItem(
                          value: 'en',
                          child: Text('English 🇬🇧',
                              style: TextStyle(color: _textPrimary)),
                        ),
                      ],
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() => _selectedLanguage = val);
                      },
                      decoration: _dec(
                          label: Lang.tLang(_selectedLanguage, 'selection_language'),
                          icon: Icons.language),
                      dropdownColor: _card,
                      style: const TextStyle(color: _textPrimary),
                      iconEnabledColor: _textSecondary,
                    ),
                    const SizedBox(height: 12),

                    // Land
                    DropdownButtonFormField<String>(
                      value: _selectedCountry,
                      items: _countries
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c,
                                    style: const TextStyle(
                                        color: _textPrimary)),
                              ))
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedCountry = val!),
                      decoration: _dec(
                          label: Lang.tLang(_selectedLanguage, 'selection_country'),
                          icon: Icons.flag_outlined),
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
                        label: Lang.tLang(_selectedLanguage, 'selection_city'),
                        icon: Icons.location_city_outlined,
                        hint: Lang.tLang(_selectedLanguage, 'selection_city_hint'),
                      ),
                      textInputAction: TextInputAction.done,
                    ),

                    const SizedBox(height: 20),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: _textSecondary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            Lang.tLang(_selectedLanguage, 'selection_map_info'),
                            style:
                                const TextStyle(color: _textSecondary),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isSearching ? null : _goToPartyMap,
                        icon: _isSearching
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.map_outlined),
                        label: Text(_isSearching
                            ? Lang.tLang(_selectedLanguage, 'searching')
                            : Lang.tLang(_selectedLanguage, 'selection_go')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          disabledBackgroundColor:
                              _accent.withValues(alpha: 0.4),
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
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
