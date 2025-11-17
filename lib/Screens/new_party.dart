// lib/Screens/new_party.dart
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geocoding/geocoding.dart' as geo;

import '../Services/geocoding_services.dart';
import 'map_picker_screen.dart';

class NewPartyScreen extends StatefulWidget {
  final Map<String, dynamic>? existingData;
  final String? docId;
  final void Function({bool updated, Map<String, dynamic>? payload})? onGoToMapAndRefresh;

  const NewPartyScreen({
    Key? key,
    this.existingData,
    this.docId,
    this.onGoToMapAndRefresh,
  }) : super(key: key);

  @override
  State<NewPartyScreen> createState() => _NewPartyScreenState();
}

class _NewPartyScreenState extends State<NewPartyScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollCtrl = ScrollController();

  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _guestLimitController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _minAgeController = TextEditingController();

  final _nameNode = FocusNode();
  final _descNode = FocusNode();
  final _guestNode = FocusNode();
  final _priceNode = FocusNode();
  final _ageNode = FocusNode();
  final _addrNode = FocusNode();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  bool _isUnlimitedGuests = false;
  bool _isFreeEntry = false;
  bool _isLoading = false;
  bool _triedSubmit = false;

  String? _hostName;
  String _partyType = 'Open';
  String? _addressCountryError;

  double? _pickedLat;
  double? _pickedLng;

  Timer? _draftTimer;

  static const _bg = Color(0xFF0E0F12);
  static const _gradTop = Color(0xFF0E0F12);
  static const _gradBottom = Color(0xFF141A22);
  static const _panel = Color(0xFF15171C);
  static const _panelBorder = Color(0xFF2A2F38);
  static const _card = Color(0xFF1C1F26);
  static const _textPrimary = Colors.white;
  static const _textSecondary = Color(0xFFB6BDC8);
  static const _accent = Color(0xFFFF3B30);
  static const _secondary = Color(0xFF00C2A8);

  @override
  void initState() {
    super.initState();
    _loadHostData();
    _preloadExisting();
    _wireListeners();
    _maybeOfferDraftRestore();
    _startAutosave();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _scrollCtrl.dispose();

    _nameNode.dispose();
    _descNode.dispose();
    _guestNode.dispose();
    _priceNode.dispose();
    _ageNode.dispose();
    _addrNode.dispose();

    _addressController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _guestLimitController.dispose();
    _timeController.dispose();
    _priceController.dispose();
    _minAgeController.dispose();
    super.dispose();
  }

  void _preloadExisting() {
    if (widget.existingData == null) return;
    final data = widget.existingData!;
    _nameController.text = data['name'] ?? '';
    _descriptionController.text = data['description'] ?? '';
    _guestLimitController.text =
    data['guestLimit'] != null && data['guestLimit'] != 'Unbegrenzt'
        ? data['guestLimit'].toString()
        : '';
    _isUnlimitedGuests = data['guestLimit'] == 'Unbegrenzt';
    _priceController.text =
    data['price'] != null && data['price'] != 0 ? data['price'].toString() : '';
    _isFreeEntry = (data['price'] ?? 0) == 0;
    _addressController.text = data['address'] ?? '';
    if (data['date'] is Timestamp) _selectedDate = (data['date'] as Timestamp).toDate();
    if (data['time'] != null) {
      final parts = (data['time'] as String).split(':');
      if (parts.length == 2) {
        _selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
        _timeController.text = data['time'];
      }
    }
    _partyType = data['type'] ?? 'Open';
    _minAgeController.text = (data['minAge'] != null) ? data['minAge'].toString() : '';
    _pickedLat = (data['lat'] as num?)?.toDouble();
    _pickedLng = (data['lng'] as num?)?.toDouble();
  }

  void _wireListeners() {
    for (final c in [
      _nameController,
      _descriptionController,
      _addressController,
      _guestLimitController,
      _priceController,
      _minAgeController,
    ]) {
      c.addListener(() {
        if (_triedSubmit) _formKey.currentState?.validate();
        if (c == _addressController) _addressCountryError = null;
      });
    }
    _guestLimitController.addListener(() {
      if (_guestLimitController.text.isNotEmpty) _isUnlimitedGuests = false;
      if (_triedSubmit) _formKey.currentState?.validate();
      setState(() {});
    });
    _priceController.addListener(() {
      if (_priceController.text.isNotEmpty) _isFreeEntry = false;
      if (_triedSubmit) _formKey.currentState?.validate();
      setState(() {});
    });
  }

  Future<void> _loadHostData() async {
    final prefs = await SharedPreferences.getInstance();
    final vorname = prefs.getString('vorname') ?? '';
    final nachname = prefs.getString('nachname') ?? '';
    setState(() {
      final full = "$vorname $nachname".trim();
      _hostName = full.isEmpty ? null : full;
    });
  }

  void _startAutosave() {
    _draftTimer = Timer.periodic(const Duration(seconds: 2), (_) => _saveDraft());
  }

  Future<void> _saveDraft() async {
    final p = await SharedPreferences.getInstance();
    final data = {
      'name': _nameController.text,
      'desc': _descriptionController.text,
      'addr': _addressController.text,
      'guest': _guestLimitController.text,
      'free': _isFreeEntry,
      'unl': _isUnlimitedGuests,
      'price': _priceController.text,
      'age': _minAgeController.text,
      'date': _selectedDate?.toIso8601String(),
      'time': _timeController.text,
      'type': _partyType,
      'plat': _pickedLat,
      'plng': _pickedLng,
    };
    p.setString('draft_newparty', jsonEncode(data));
  }

  Future<void> _maybeOfferDraftRestore() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('draft_newparty');
    if (raw == null || raw.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Entwurf gefunden. Wiederherstellen?'),
          action: SnackBarAction(
            label: 'LADEN',
            onPressed: () {
              final d = jsonDecode(raw) as Map<String, dynamic>;
              _nameController.text = d['name'] ?? '';
              _descriptionController.text = d['desc'] ?? '';
              _addressController.text = d['addr'] ?? '';
              _guestLimitController.text = d['guest'] ?? '';
              _isFreeEntry = d['free'] == true;
              _isUnlimitedGuests = d['unl'] == true;
              _priceController.text = d['price'] ?? '';
              _minAgeController.text = d['age'] ?? '';
              final ds = d['date'] as String?;
              if (ds != null) _selectedDate = DateTime.tryParse(ds);
              _timeController.text = d['time'] ?? '';
              if ((_timeController.text).contains(':')) {
                final parts = _timeController.text.split(':');
                _selectedTime = TimeOfDay(
                  hour: int.tryParse(parts[0]) ?? 0,
                  minute: int.tryParse(parts[1]) ?? 0,
                );
              }
              _partyType = d['type'] ?? 'Open';
              _pickedLat = (d['plat'] as num?)?.toDouble();
              _pickedLng = (d['plng'] as num?)?.toDouble();
              setState(() {});
            },
          ),
        ),
      );
    });
  }

  String? _validateRequired(String? v, {String label = "Pflichtfeld"}) {
    if (v == null || v.trim().isEmpty) return "$label darf nicht leer sein.";
    return null;
  }

  InputDecoration _dec(
      String label, {
        String? hint,
        IconData? icon,
        Widget? suffix,
        String? errorText,
        int? maxLength,
      }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _textSecondary),
      hintText: hint,
      hintStyle: const TextStyle(color: _textSecondary),
      prefixIcon: icon != null ? Icon(icon, color: _textSecondary) : null,
      suffixIcon: suffix,
      filled: true,
      fillColor: _card,
      counterText: maxLength != null ? '' : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.transparent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _accent, width: 1.2),
      ),
      errorText: errorText,
    );
  }

  Widget _section({required String title, required Widget child, IconData? icon}) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 10)),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _panelBorder),
                ),
                child: Icon(icon, color: _textSecondary, size: 16),
              ),
              const SizedBox(width: 8),
            ],
            const Text(" ", style: TextStyle(fontSize: 0)),
            Text(
              title,
              style:
              const TextStyle(color: _textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ]),
          const SizedBox(height: 12),
          child
        ],
      ),
    );
  }

  Widget _switchTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    IconData? icon,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _panelBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: _textSecondary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(label,
                style: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w600)),
          ),
          Switch(
            value: value,
            onChanged: (v) {
              HapticFeedback.selectionClick();
              onChanged(v);
            },
            activeColor: _accent,
          ),
        ],
      ),
    );
  }

  Widget _typeChip({required String value, required String label, required IconData icon}) {
    final isSelected = _partyType == value;
    final border = isSelected ? _accent : _panelBorder;
    final textColor = isSelected ? Colors.white : _textPrimary;
    final iconColor = isSelected ? Colors.white : Colors.white70;

    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) {
        HapticFeedback.selectionClick();
        setState(() => _partyType = value);
      },
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
        ],
      ),
      showCheckmark: false,
      pressElevation: 0,
      backgroundColor: _card,
      selectedColor: _accent,
      side: BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _accent,
            onPrimary: Colors.white,
            surface: _panel,
            onSurface: Colors.white,
          ),
          dialogBackgroundColor: _panel,
        ),
        child: child!,
      ),
    );
    if (date != null) setState(() => _selectedDate = date);
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: _accent, onPrimary: Colors.white),
        ),
        child: child!,
      ),
    );
    if (time != null) {
      setState(() {
        _selectedTime = time;
        _timeController.text =
        "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  /// Vollbild-MapPicker + Reverse-Geocoding der Adresse
  Future<void> _openMapPicker() async {
    LatLng initial = LatLng(_pickedLat ?? 48.2082, _pickedLng ?? 16.3738);

    // Startposition auf gespeicherte Stadt legen, wenn noch kein Punkt gewählt wurde
    if (_pickedLat == null || _pickedLng == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final city = prefs.getString('city');
        final country = prefs.getString('country');
        String? query;
        if (city != null && city.trim().isNotEmpty) {
          query = city.trim();
          if (country != null && country.trim().isNotEmpty) {
            query = '$query, ${country.trim()}';
          }
        }
        if (query != null) {
          final loc = await GeocodingService.getLocationFromAddress(query);
          if (loc != null) {
            initial = LatLng(loc.latitude, loc.longitude);
          }
        }
      } catch (_) {}
    }

    // Map-Screen öffnen, LatLng zurückbekommen
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(initial: initial),
      ),
    );

    if (picked != null && mounted) {
      setState(() {
        _pickedLat = picked.latitude;
        _pickedLng = picked.longitude;
      });

      // Adresse automatisch aus Koordinaten holen
      try {
        final placemarks = await geo.placemarkFromCoordinates(
          picked.latitude,
          picked.longitude,
        );
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final street = [
            p.street,
            p.subThoroughfare,
          ].where((e) => e != null && e.trim().isNotEmpty).join(' ');
          final city = p.locality ?? p.subAdministrativeArea ?? '';
          final postal = p.postalCode ?? '';
          final country = p.country ?? '';

          final addrParts = [
            street.trim(),
            [postal, city].where((e) => e.trim().isNotEmpty).join(' '),
            country.trim(),
          ].where((e) => e.trim().isNotEmpty).toList();

          if (addrParts.isNotEmpty) {
            _addressController.text = addrParts.join(', ');
          }
        }
      } catch (_) {
        // Wenn Reverse-Geocoding fehlschlägt: egal, Lat/Lng sind trotzdem gesetzt
      }

      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Standort übernommen")),
      );
    }
  }

  void _scrollToFirstError() {
    _scrollCtrl
        .animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    )
        .then((_) => _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    ));
  }

  String _slugifyPartyName(String name) {
    final lower = name.toLowerCase().trim();
    final spaceToUnderscore = lower.replaceAll(RegExp(r'\s+'), '_');
    final cleaned = spaceToUnderscore.replaceAll(RegExp(r'[^a-z0-9_\-]'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^_+'), '').replaceAll(RegExp(r'_+$'), '');
    return trimmed.isEmpty ? 'party' : trimmed;
  }

  Future<bool> _docExists(String id) async {
    final doc = await FirebaseFirestore.instance.collection('Party').doc(id).get();
    return doc.exists;
  }

  Future<String> _generateUniqueDocId(String partyName) async {
    final base = _slugifyPartyName(partyName);
    var candidate = base;
    var i = 0;
    while (await _docExists(candidate)) {
      candidate = '$base$i';
      i++;
    }
    return candidate;
  }

  void _goToMapAndPop({required bool updated, Map<String, dynamic>? payload}) {
    HapticFeedback.lightImpact();
    widget.onGoToMapAndRefresh?.call(updated: updated, payload: payload);
    final result = {'targetTab': 'map', 'updated': updated, if (payload != null) ...payload};
    if (mounted) Navigator.of(context).pop(result);
  }

  Future<void> _saveParty() async {
    setState(() => _triedSubmit = true);
    _addressCountryError = null;

    final valid = _formKey.currentState?.validate() ?? false;
    final dateOk = _selectedDate != null;
    final timeOk = _selectedTime != null;
    setState(() {});
    if (!valid || !dateOk || !timeOk || _isLoading) {
      _scrollToFirstError();
      return;
    }

    setState(() => _isLoading = true);

    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final guestLimit =
    _isUnlimitedGuests ? 'Unbegrenzt' : int.tryParse(_guestLimitController.text.trim());
    final price = _isFreeEntry
        ? 0.0
        : double.tryParse(_priceController.text.replaceAll(',', '.').trim()) ?? 0.0;
    final address = _addressController.text.trim();
    final date = _selectedDate!;
    final time = _timeController.text;
    final minAge = int.tryParse(_minAgeController.text.trim());
    final type = _partyType;

    double? lat = _pickedLat;
    double? lng = _pickedLng;

    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'unknown_user';

    if (lat == null || lng == null) {
      GeocodedLocation? loc;
      try {
        loc = await GeocodingService.getLocationFromAddress(address);
      } catch (_) {}

      if (loc == null) {
        final savedCity = prefs.getString('city');
        final savedCountry = prefs.getString('country');
        String? query;

        if (savedCity != null && savedCity.trim().isNotEmpty) {
          query = '$address, ${savedCity.trim()}';
          if (savedCountry != null && savedCountry.trim().isNotEmpty) {
            query = '$query, ${savedCountry.trim()}';
          }
        }

        if (query != null) {
          try {
            loc = await GeocodingService.getLocationFromAddress(query);
          } catch (_) {}
        }
      }

      if (loc != null) {
        lat = loc.latitude;
        lng = loc.longitude;
      }
    }

    if (lat == null || lng == null) {
      _addressCountryError =
      "Adresse nicht gefunden. Bitte genauer angeben, Stadt ergänzen oder Standort auf der Karte wählen.";
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Adresse nicht gefunden. Bitte genauer angeben oder Standort auf der Karte wählen.",
          ),
        ),
      );
      return;
    }

    final baseData = {
      'name': name,
      'description': description,
      'guestLimit': guestLimit,
      'date': Timestamp.fromDate(DateTime(date.year, date.month, date.day)),
      'time': time,
      'lat': lat,
      'lng': lng,
      'type': type,
      'price': price,
      'minAge': minAge,
      'address': address,
      'hostName': _hostName ?? 'unknown',
      'hostId': username,
      'isClosed': false,
      'requests': widget.existingData?['requests'] ?? [],
      'approved': widget.existingData?['approved'] ?? [],
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      String savedDocId;
      if (widget.docId == null) {
        final uniqueId = await _generateUniqueDocId(name);
        final ref = FirebaseFirestore.instance.collection('Party').doc(uniqueId);
        await ref.set(baseData, SetOptions(merge: true));
        savedDocId = uniqueId;
        await ref.set({'docId': savedDocId}, SetOptions(merge: true));
      } else {
        final ref = FirebaseFirestore.instance.collection('Party').doc(widget.docId);
        await ref.set(baseData, SetOptions(merge: true));
        savedDocId = widget.docId!;
        await ref.set({'docId': savedDocId}, SetOptions(merge: true));
      }

      HapticFeedback.mediumImpact();
      _goToMapAndPop(updated: true, payload: {
        'data': {...baseData, 'docId': savedDocId},
        'lat': lat,
        'lng': lng,
        'docId': savedDocId,
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Fehler beim Speichern: $e")),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteParty() async {
    if (widget.docId == null || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('Party').doc(widget.docId).delete();
      _goToMapAndPop(updated: true, payload: {'deleted': true, 'docId': widget.docId});
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingData != null;

    final stickyBar = SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: _bg,
          border: Border(top: BorderSide(color: _panelBorder)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isLoading ? null : () => _goToMapAndPop(updated: false),
                icon: const Icon(Icons.map_outlined, color: Colors.white70),
                label: const Text("Zur Karte"),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _panelBorder),
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            if (isEditing) ...[
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isLoading ? null : _deleteParty,
                  icon: const Icon(Icons.delete_outline, color: _accent),
                  label: const Text("Löschen", style: TextStyle(color: _accent)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: _accent),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _saveParty,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(isEditing ? "Aktualisieren" : "Speichern"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  disabledBackgroundColor: Colors.grey[700],
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return WillPopScope(
      onWillPop: () async {
        _goToMapAndPop(updated: false);
        return false;
      },
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: _bg,
            appBar: AppBar(
              backgroundColor: _panel,
              elevation: 0.5,
              title: Text(
                isEditing ? "Party bearbeiten" : "Neue Party",
                style:
                const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              leading: IconButton(
                icon: const Icon(Icons.map_outlined, color: _accent),
                onPressed: () => _goToMapAndPop(updated: false),
                tooltip: "Zur Karte",
              ),
              actions: [
                if (_hostName != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _panelBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person, size: 16, color: Colors.white70),
                        const SizedBox(width: 6),
                        Text(
                          _hostName!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_gradTop, _gradBottom],
                ),
              ),
              child: SingleChildScrollView(
                controller: _scrollCtrl,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    children: [
                      _section(
                        title: "Basis",
                        icon: Icons.celebration_outlined,
                        child: Column(
                          children: [
                            TextFormField(
                              controller: _nameController,
                              focusNode: _nameNode,
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _descNode.requestFocus(),
                              maxLength: 40,
                              style: const TextStyle(color: _textPrimary),
                              decoration: _dec("Party Name", icon: Icons.title, maxLength: 40),
                              validator: (v) => _validateRequired(v, label: "Party Name"),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _descriptionController,
                              focusNode: _descNode,
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _guestNode.requestFocus(),
                              minLines: 3,
                              maxLines: null,
                              maxLength: 500,
                              style: const TextStyle(color: _textPrimary),
                              decoration: _dec("Beschreibung", icon: Icons.notes, maxLength: 500),
                              validator: (v) => _validateRequired(v, label: "Beschreibung"),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _section(
                        title: "Gäste & Preis",
                        icon: Icons.group_outlined,
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _guestLimitController,
                                    focusNode: _guestNode,
                                    textInputAction: TextInputAction.next,
                                    onFieldSubmitted: (_) => _priceNode.requestFocus(),
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                    enabled: !_isUnlimitedGuests,
                                    style: const TextStyle(color: _textPrimary),
                                    decoration: _dec(
                                      "Gästelimit",
                                      hint: "Zahl",
                                      icon: Icons.groups,
                                      errorText: (!_isUnlimitedGuests &&
                                          _triedSubmit &&
                                          (int.tryParse(
                                              _guestLimitController.text.trim()) ==
                                              null))
                                          ? "Gästelimit muss eine Zahl sein."
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _switchTile(
                                    label: "Unbegrenzt",
                                    value: _isUnlimitedGuests,
                                    icon: Icons.all_inclusive,
                                    onChanged: (v) {
                                      setState(() {
                                        _isUnlimitedGuests = v;
                                        if (v) _guestLimitController.clear();
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _priceController,
                                    focusNode: _priceNode,
                                    textInputAction: TextInputAction.next,
                                    onFieldSubmitted: (_) => _ageNode.requestFocus(),
                                    keyboardType:
                                    const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(
                                        RegExp(r'^\d*[,]?\d{0,2}$|^\d*[.]?\d{0,2}$'),
                                      ),
                                    ],
                                    enabled: !_isFreeEntry,
                                    style: const TextStyle(color: _textPrimary),
                                    decoration: _dec(
                                      "Eintrittspreis",
                                      hint: "€",
                                      icon: Icons.euro,
                                      errorText: (!_isFreeEntry &&
                                          _triedSubmit &&
                                          (double.tryParse(_priceController.text
                                              .replaceAll(',', '.')
                                              .trim()) ==
                                              null))
                                          ? "Preis muss eine Zahl sein."
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _switchTile(
                                    label: "Gratis Eintritt",
                                    value: _isFreeEntry,
                                    icon: Icons.card_giftcard,
                                    onChanged: (v) {
                                      setState(() {
                                        _isFreeEntry = v;
                                        if (v) _priceController.clear();
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _minAgeController,
                              focusNode: _ageNode,
                              textInputAction: TextInputAction.next,
                              onFieldSubmitted: (_) => _addrNode.requestFocus(),
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              style: const TextStyle(color: _textPrimary),
                              decoration:
                              _dec("Mindestalter", hint: "z. B. 16", icon: Icons.cake_outlined),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) {
                                  return "Mindestalter darf nicht leer sein.";
                                }
                                final n = int.tryParse(v.trim());
                                if (n == null) return "Mindestalter muss eine Zahl sein.";
                                if (n < 0) return "Mindestalter darf nicht negativ sein.";
                                if (n > 99) {
                                  return "Bitte ein realistisches Alter (0–99) eingeben.";
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _section(
                        title: "Ort",
                        icon: Icons.location_on_outlined,
                        child: TextFormField(
                          controller: _addressController,
                          focusNode: _addrNode,
                          textInputAction: TextInputAction.done,
                          enableSuggestions: true,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.fullStreetAddress],
                          style: const TextStyle(color: _textPrimary),
                          decoration: _dec(
                            "Adresse",
                            hint: "z. B. Münzgasse 4, 1030 Wien",
                            icon: Icons.place,
                            errorText: _addressCountryError,
                            suffix: IconButton(
                              tooltip: 'Standort auf Karte wählen',
                              onPressed: _openMapPicker,
                              icon: const Icon(Icons.map_rounded, color: Colors.white70),
                            ),
                          ),
                          validator: (v) => _validateRequired(v, label: "Adresse"),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _section(
                        title: "Datum & Zeit",
                        icon: Icons.schedule_outlined,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _card,
                                      foregroundColor: _textPrimary,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14, horizontal: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14)),
                                    ),
                                    onPressed: _pickDate,
                                    icon: const Icon(Icons.calendar_today, color: _accent),
                                    label: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 150),
                                      child: Text(
                                        _selectedDate == null
                                            ? "Datum wählen"
                                            : "${_selectedDate!.day.toString().padLeft(2, '0')}.${_selectedDate!.month.toString().padLeft(2, '0')}.${_selectedDate!.year}",
                                        key: ValueKey(
                                            _selectedDate?.toIso8601String() ?? 'none'),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _card,
                                      foregroundColor: _textPrimary,
                                      elevation: 0,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 14, horizontal: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14)),
                                    ),
                                    onPressed: _pickTime,
                                    icon: const Icon(Icons.access_time, color: _accent),
                                    label: AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 150),
                                      child: Text(
                                        (_selectedTime == null)
                                            ? "Uhrzeit wählen"
                                            : _timeController.text,
                                        key: ValueKey(_timeController.text.isEmpty
                                            ? 'none'
                                            : _timeController.text),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              children: [
                                _quickTimeChip("Heute 22:00", () {
                                  final now = DateTime.now();
                                  _selectedDate =
                                      DateTime(now.year, now.month, now.day);
                                  _selectedTime =
                                  const TimeOfDay(hour: 22, minute: 0);
                                  _timeController.text = "22:00";
                                  setState(() {});
                                }),
                                _quickTimeChip("Morgen 21:00", () {
                                  final now =
                                  DateTime.now().add(const Duration(days: 1));
                                  _selectedDate =
                                      DateTime(now.year, now.month, now.day);
                                  _selectedTime =
                                  const TimeOfDay(hour: 21, minute: 0);
                                  _timeController.text = "21:00";
                                  setState(() {});
                                }),
                                _quickTimeChip("Fr 22:00", () {
                                  final now = DateTime.now();
                                  final diff = (5 - now.weekday + 7) % 7;
                                  final d = now.add(Duration(days: diff == 0 ? 7 : diff));
                                  _selectedDate =
                                      DateTime(d.year, d.month, d.day);
                                  _selectedTime =
                                  const TimeOfDay(hour: 22, minute: 0);
                                  _timeController.text = "22:00";
                                  setState(() {});
                                }),
                              ],
                            ),
                            if (_triedSubmit && _selectedDate == null)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  "Bitte ein Datum wählen.",
                                  style: TextStyle(color: Colors.orangeAccent),
                                ),
                              ),
                            if (_triedSubmit && _selectedTime == null)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  "Bitte eine Uhrzeit wählen.",
                                  style: TextStyle(color: Colors.orangeAccent),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _section(
                        title: "Party-Typ",
                        icon: Icons.lock_open_outlined,
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            _typeChip(
                                value: "Open",
                                label: "Open",
                                icon: Icons.lock_open_rounded),
                            _typeChip(
                                value: "Closed",
                                label: "Closed",
                                icon: Icons.lock_rounded),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            bottomNavigationBar: stickyBar,
          ),
          if (_isLoading)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: Colors.black.withOpacity(0.35),
                  child:
                  const Center(child: CircularProgressIndicator(strokeWidth: 3)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _quickTimeChip(String label, VoidCallback onPressed) {
    return ActionChip(
      label: Text(label),
      onPressed: onPressed,
      backgroundColor: _card,
      shape: StadiumBorder(side: BorderSide(color: _panelBorder)),
      labelStyle:
      const TextStyle(color: _textPrimary, fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    );
  }
}
