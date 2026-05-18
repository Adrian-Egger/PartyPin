// lib/Screens/selection_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'home_shell.dart';
import '../party/map_picker_screen.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';
import '../../Services/geocoding_services.dart';

class SelectionScreen extends StatefulWidget {
  const SelectionScreen({super.key});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
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
  String _enteredAddress = '';

  // Coordinates resolved from the address field (via live-validation or map picker)
  double? _pickedAddressLat;
  double? _pickedAddressLng;

  bool _addressValid = false;
  bool _addressValidating = false;
  Timer? _debounceTimer;

  String? _addressError;

  final List<String> _countries = const ['Austria', 'Germany', 'Switzerland'];
  final TextEditingController _cityController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();

  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _cityController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  String _normalizeCityForGeocode(String city) {
    switch (city.trim().toLowerCase()) {
      case 'wien': return 'Vienna';
      case 'linz': return 'Linz';
      case 'graz': return 'Graz';
      default:     return city.trim();
    }
  }

  Future<GeocodedLocation?> _geocodeAddress(String address) async {
    final geocodeCity = _normalizeCityForGeocode(_enteredCity);
    GeocodedLocation? loc;
    if (geocodeCity.isNotEmpty) {
      loc = await GeocodingService.getLocationFromAddress(
          '$address, $geocodeCity, $_selectedCountry');
    }
    loc ??= await GeocodingService.getLocationFromAddress(
        '$address, $_selectedCountry');
    loc ??= await GeocodingService.getLocationFromAddress(address);
    return loc;
  }

  // ── load / save ────────────────────────────────────────────────────────────

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedLanguage = prefs.getString('language') ?? 'de';
      _selectedCountry  = prefs.getString('country')  ?? 'Austria';
      _enteredCity      = prefs.getString('city')     ?? '';
      _cityController.text = _enteredCity;
      _enteredAddress   = prefs.getString('preciseAddress') ?? '';
      _addressController.text = _enteredAddress;
    });

    // Restore valid state for already-saved address
    if (_enteredAddress.isNotEmpty) {
      final savedLat = prefs.getDouble('selectedLat');
      final savedLng = prefs.getDouble('selectedLng');
      if (savedLat != null && savedLng != null) {
        setState(() {
          _pickedAddressLat = savedLat;
          _pickedAddressLng = savedLng;
          _addressValid = true;
        });
      }
    }
  }

  Future<void> _saveUserSelection(
    String city,
    String country,
    double lat,
    double lng, {
    String? address,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('city', city);
    await prefs.setString('language', _selectedLanguage);
    await prefs.setString('country', country);
    await prefs.setDouble('selectedLat', lat);
    await prefs.setDouble('selectedLng', lng);
    await prefs.setBool('hasLocationSetup', true);

    if (address != null && address.isNotEmpty) {
      await prefs.setString('preciseAddress', address);
    } else {
      await prefs.remove('preciseAddress');
    }

    final username = prefs.getString('currentUsername');
    final isBar    = prefs.getBool('isBar') ?? false;
    if (username == null || username.trim().isEmpty) return;

    final colName = isBar ? 'bars' : 'users';
    final query   = await FirebaseFirestore.instance
        .collection(colName)
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
        if (address != null && address.isNotEmpty) 'preciseAddress': address,
      },
      SetOptions(merge: true),
    );
  }

  // ── live validation ────────────────────────────────────────────────────────

  void _onAddressChanged(String val) {
    _enteredAddress = val;

    // Reset validation state on every keystroke
    if (_addressValid || _addressError != null) {
      setState(() {
        _addressValid     = false;
        _addressError     = null;
        _pickedAddressLat = null;
        _pickedAddressLng = null;
      });
    }

    _debounceTimer?.cancel();

    if (val.trim().length < 5) {
      if (_addressValidating) setState(() => _addressValidating = false);
      return;
    }

    setState(() => _addressValidating = true);

    _debounceTimer = Timer(const Duration(milliseconds: 750), () async {
      if (!mounted) return;
      final loc = await _geocodeAddress(val.trim());
      if (!mounted) return;
      setState(() {
        _addressValidating = false;
        _addressValid      = loc != null;
        if (loc != null) {
          _pickedAddressLat = loc.latitude;
          _pickedAddressLng = loc.longitude;
        }
      });
    });
  }

  // ── map picker ─────────────────────────────────────────────────────────────

  Future<void> _openAddressMapPicker() async {
    // Default: Vienna city center; use city coords if available
    LatLng initial = LatLng(
      _pickedAddressLat ?? 48.2082,
      _pickedAddressLng ?? 16.3738,
    );

    if (_pickedAddressLat == null || _pickedAddressLng == null) {
      final geocodeCity = _normalizeCityForGeocode(_enteredCity);
      if (geocodeCity.isNotEmpty) {
        try {
          final loc = await GeocodingService.getLocationFromAddress(
              '$geocodeCity, $_selectedCountry');
          if (loc != null) initial = LatLng(loc.latitude, loc.longitude);
        } catch (_) {}
      }
    }

    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => MapPickerScreen(initial: initial)),
    );

    if (picked == null || !mounted) return;

    // Mark as valid immediately since it's a direct map pick
    setState(() {
      _pickedAddressLat = picked.latitude;
      _pickedAddressLng = picked.longitude;
      _addressValid     = true;
      _addressValidating = false;
      _addressError     = null;
    });

    // Reverse-geocode to fill the text field
    try {
      final placemarks = await GeocodingService.placemarkFromCoordinates(
          picked.latitude, picked.longitude);
      if (placemarks.isNotEmpty && mounted) {
        final p = placemarks.first;

        String street = (p.street ?? '').trim();
        String number = (p.subThoroughfare ?? '').trim();
        if (number.isNotEmpty && street.contains(number)) number = '';
        final fullStreet = [street, number]
            .where((e) => e.isNotEmpty)
            .join(' ');

        final city   = (p.locality ?? p.subAdministrativeArea ?? '').trim();
        final postal = (p.postalCode ?? '').trim();

        final addrParts = [
          fullStreet,
          [postal, city].where((e) => e.isNotEmpty).join(' '),
        ].where((e) => e.isNotEmpty).toList();

        if (addrParts.isNotEmpty) {
          final addr = addrParts.join(', ');
          setState(() {
            _enteredAddress = addr;
            _addressController.text = addr;
          });
        }
      }
    } catch (_) {}
  }

  // ── go to map ──────────────────────────────────────────────────────────────

  Future<void> _goToPartyMap() async {
    if (_enteredCity.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(Lang.tLang(_selectedLanguage, 'selection_city_missing')),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    _debounceTimer?.cancel();
    setState(() { _isSearching = true; _addressError = null; });

    final originalCity = _enteredCity.trim();
    final address      = _enteredAddress.trim();
    final geocodeCity  = _normalizeCityForGeocode(originalCity);

    try {
      double lat;
      double lng;

      if (address.isNotEmpty) {
        // If already validated (live check or map picker) — use cached coords
        if (_pickedAddressLat != null && _pickedAddressLng != null) {
          lat = _pickedAddressLat!;
          lng = _pickedAddressLng!;
        } else {
          // User pressed button before debounce finished → geocode now
          final loc = await _geocodeAddress(address);
          if (loc == null) {
            if (!mounted) return;
            setState(() {
              _isSearching  = false;
              _addressValid = false;
              _addressError = Lang.tLang(_selectedLanguage, 'selection_address_not_found');
            });
            return;
          }
          lat = loc.latitude;
          lng = loc.longitude;
          setState(() {
            _pickedAddressLat = lat;
            _pickedAddressLng = lng;
            _addressValid     = true;
          });
        }
      } else {
        // No address — geocode city (existing behaviour)
        final loc = await GeocodingService.getBestLocationNear(
            '$geocodeCity, $_selectedCountry');
        if (loc == null) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(Lang.tLang(_selectedLanguage, 'selection_city_not_found')),
            backgroundColor: AppColors.accent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
          setState(() => _isSearching = false);
          return;
        }
        lat = loc.latitude;
        lng = loc.longitude;
      }

      final displayCity = originalCity.isEmpty
          ? geocodeCity
          : originalCity[0].toUpperCase() + originalCity.substring(1);

      await _saveUserSelection(
        displayCity,
        _selectedCountry,
        lat,
        lng,
        address: address.isNotEmpty ? address : null,
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeShell()),
      );
      await Lang.set(_selectedLanguage);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(Lang.tLang(_selectedLanguage, 'selection_city_not_found')),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  // ── decoration helper ──────────────────────────────────────────────────────

  InputDecoration _dec({
    required String label,
    IconData? icon,
    String? hint,
    Widget? suffix,
    String? errorText,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle:
          const TextStyle(color: _textSecondary, fontWeight: FontWeight.w600),
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF93A0B4)),
      prefixIcon: icon != null ? Icon(icon, color: _accent) : null,
      suffix: suffix,
      errorText: errorText,
      errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
      filled: true,
      fillColor: _card,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: errorText != null
            ? const BorderSide(color: Colors.redAccent)
            : const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: errorText != null
            ? const BorderSide(color: Colors.redAccent, width: 1.5)
            : const BorderSide(color: _accent, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
      ),
    );
  }

  // ── build ──────────────────────────────────────────────────────────────────

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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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

                    // ── Sprache ──────────────────────────────────────────
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
                          label: Lang.tLang(
                              _selectedLanguage, 'selection_language'),
                          icon: Icons.language),
                      dropdownColor: _card,
                      style: const TextStyle(color: _textPrimary),
                      iconEnabledColor: _textSecondary,
                    ),
                    const SizedBox(height: 12),

                    // ── Land ─────────────────────────────────────────────
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
                          label: Lang.tLang(
                              _selectedLanguage, 'selection_country'),
                          icon: Icons.flag_outlined),
                      dropdownColor: _card,
                      style: const TextStyle(color: _textPrimary),
                      iconEnabledColor: _textSecondary,
                    ),
                    const SizedBox(height: 12),

                    // ── Stadt ─────────────────────────────────────────────
                    TextFormField(
                      controller: _cityController,
                      onChanged: (val) => _enteredCity = val,
                      style: const TextStyle(color: _textPrimary),
                      decoration: _dec(
                        label: Lang.tLang(
                            _selectedLanguage, 'selection_city'),
                        icon: Icons.location_city_outlined,
                        hint: Lang.tLang(
                            _selectedLanguage, 'selection_city_hint'),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),

                    // ── Adresse (optional) ────────────────────────────────
                    TextFormField(
                      controller: _addressController,
                      onChanged: _onAddressChanged,
                      style: const TextStyle(color: _textPrimary),
                      decoration: _dec(
                        label: Lang.tLang(
                            _selectedLanguage, 'selection_address'),
                        icon: Icons.home_outlined,
                        hint: Lang.tLang(
                            _selectedLanguage, 'selection_address_hint'),
                        errorText: _addressError,
                        // ── Suffix: status icon + map button ──────────────
                        suffix: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Animated status: spinner → checkmark → nothing
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              transitionBuilder: (child, anim) =>
                                  ScaleTransition(scale: anim, child: child),
                              child: _addressValidating
                                  ? SizedBox(
                                      key: const ValueKey('loading'),
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: _accent,
                                      ),
                                    )
                                  : _addressValid
                                      ? const Icon(
                                          key: ValueKey('valid'),
                                          Icons.check_circle_rounded,
                                          color: AppColors.success,
                                          size: 20,
                                        )
                                      : const SizedBox(
                                          key: ValueKey('empty'),
                                          width: 20),
                            ),
                            const SizedBox(width: 6),
                            // Map picker button
                            InkWell(
                              onTap: _openAddressMapPicker,
                              borderRadius: BorderRadius.circular(6),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.map_rounded,
                                    color: _textSecondary, size: 20),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                        ),
                      ),
                      textInputAction: TextInputAction.done,
                      enableSuggestions: true,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.fullStreetAddress],
                    ),
                    const SizedBox(height: 10),

                    // ── Info-Box ──────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: _accent.withAlpha(13),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _accent.withAlpha(45)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.my_location_rounded,
                              size: 15,
                              color: _accent.withAlpha(190)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              Lang.tLang(_selectedLanguage,
                                  'selection_address_info'),
                              style: const TextStyle(
                                  color: _textSecondary,
                                  fontSize: 12,
                                  height: 1.45),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ── Map-Info ──────────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: _textSecondary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            Lang.tLang(
                                _selectedLanguage, 'selection_map_info'),
                            style:
                                const TextStyle(color: _textSecondary),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // ── Button ────────────────────────────────────────────
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
