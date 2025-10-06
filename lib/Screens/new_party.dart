import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../Services/geocoding_services.dart';

class NewPartyScreen extends StatefulWidget {
  final Map<String, dynamic>? existingData;
  final String? docId;

  /// Parent-Callback: setzt unten „Karte“ aktiv, refresht die Map
  /// und zoomt optional auf die neue Party.
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

  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _guestLimitController = TextEditingController();
  final TextEditingController _timeController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _minAgeController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  bool _isUnlimitedGuests = false;
  bool _isFreeEntry = false;
  bool _isLoading = false;
  bool _triedSubmit = false;

  String? _hostName;
  String _partyType = 'Open';

  String? _addressCountryError; // Inline-Fehler, wenn Adresse nicht im ausgewählten Land

  // Theme
  Color get _bg => Colors.grey[900]!;
  Color get _panel => Colors.grey[850]!;
  Color get _card => Colors.grey[800]!;
  Color get _textPrimary => Colors.white;
  Color get _textSecondary => Colors.white70;
  Color get _accent => Colors.redAccent;

  @override
  void initState() {
    super.initState();
    _loadHostData();

    if (widget.existingData != null) {
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
      if (data['date'] is Timestamp) {
        _selectedDate = (data['date'] as Timestamp).toDate();
      }
      if (data['time'] != null) {
        final parts = (data['time'] as String).split(':');
        if (parts.length == 2) {
          _selectedTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
          _timeController.text = data['time'];
        }
      }
      _partyType = data['type'] ?? 'Open';
      _minAgeController.text = (data['minAge'] != null) ? data['minAge'].toString() : '';
    }

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
        setState(() {
          if (c == _addressController) _addressCountryError = null; // zurücksetzen bei Eingabe
        });
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

  @override
  void dispose() {
    _addressController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _guestLimitController.dispose();
    _timeController.dispose();
    _priceController.dispose();
    _minAgeController.dispose();
    super.dispose();
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

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
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
          colorScheme: const ColorScheme.dark(
            primary: Colors.redAccent,
            onPrimary: Colors.white,
          ),
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

  String? _validateRequired(String? v, {String label = "Pflichtfeld"}) {
    if (v == null || v.trim().isEmpty) return "$label darf nicht leer sein.";
    return null;
  }

  String _humanCountryName(String iso2lower) {
    switch (iso2lower) {
      case 'at':
        return 'Österreich';
      case 'de':
        return 'Deutschland';
      case 'ch':
        return 'Schweiz';
      case 'it':
        return 'Italien';
      case 'cz':
        return 'Tschechien';
      case 'sk':
        return 'Slowakei';
      case 'hu':
        return 'Ungarn';
      default:
        return iso2lower.toUpperCase();
    }
  }

  Future<String?> _getSelectedCountryCode() async {
    final prefs = await SharedPreferences.getInstance();
    String? raw = prefs.getString('countryCode') ??
        prefs.getString('selectedCountryCode') ??
        prefs.getString('countryISO2') ??
        prefs.getString('country') ??
        prefs.getString('country_name');

    if (raw == null || raw.trim().isEmpty) return null;
    final v = raw.trim().toLowerCase();
    if (RegExp(r'^[a-z]{2}$').hasMatch(v)) return v;

    const map = {
      'österreich': 'at',
      'austria': 'at',
      'deutschland': 'de',
      'germany': 'de',
      'schweiz': 'ch',
      'switzerland': 'ch',
      'italien': 'it',
      'italy': 'it',
      'tschechien': 'cz',
      'czechia': 'cz',
      'czech republic': 'cz',
      'slowakei': 'sk',
      'slovakia': 'sk',
      'ungarn': 'hu',
      'hungary': 'hu',
    };
    return map[v];
  }

  /// ---------- NEU: Sprechende, eindeutige Doc-IDs ----------
  /// Partynamen in eine saubere Doc-ID überführen:
  /// - lowercase
  /// - Leerzeichen -> _
  /// - nur [a-z0-9_-]
  /// - keine führenden/folgenden Underscores
  String _slugifyPartyName(String name) {
    final lower = name.toLowerCase().trim();
    final spaceToUnderscore = lower.replaceAll(RegExp(r'\s+'), '_');
    final cleaned = spaceToUnderscore.replaceAll(RegExp(r'[^a-z0-9_\-]'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^_+'), '').replaceAll(RegExp(r'_+$'), '');
    return trimmed.isEmpty ? 'party' : trimmed;
  }

  /// Prüft, ob ein Dokument mit dieser ID existiert.
  Future<bool> _docExists(String id) async {
    final doc = await FirebaseFirestore.instance.collection('Party').doc(id).get();
    return doc.exists;
  }

  /// Liefert eine eindeutige Doc-ID nach dem Partynamen.
  /// Wenn bereits vorhanden: hängt 0,1,2,3,... an.
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

  /// Zentraler Rückweg: Parent-Callback (+ Map refresh/zoom), dann Pop mit Result.
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

    setState(() {}); // Inline-Hinweise zeigen

    if (!valid || !dateOk || !timeOk || _isLoading) return;

    setState(() => _isLoading = true);

    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final guestLimit =
    _isUnlimitedGuests ? 'Unbegrenzt' : int.tryParse(_guestLimitController.text.trim());
    final price = _isFreeEntry
        ? 0.0
        : double.tryParse(_priceController.text.replaceAll(',', '.').trim()) ?? 0.0;
    final address = _addressController.text.trim(); // Umlaute bleiben
    final date = _selectedDate!;
    final time = _timeController.text;
    final minAge = int.tryParse(_minAgeController.text.trim());
    final type = _partyType;

    double? lat;
    double? lng;

    // Länder-Restriktion holen
    final cc = await _getSelectedCountryCode();

    // Geocoding (strict auf cc, wenn vorhanden)
    GeocodedLocation? loc;
    try {
      loc = await GeocodingService.getLocationFromAddress(address, countryCode: cc);
    } catch (_) {}

    if (cc != null) {
      // Mit Länder-Filter MUSS die Adresse gefunden werden und im Land liegen
      if (loc == null || (loc.countryCode?.toLowerCase() != cc.toLowerCase())) {
        final countryName = _humanCountryName(cc);
        _addressCountryError = "Adresse muss in $countryName liegen.";
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Adresse nicht akzeptiert: nur $countryName erlaubt.")),
        );
        return;
      }
    }

    if (loc != null) {
      lat = loc.latitude;
      lng = loc.longitude;
    }

    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'unknown_user';

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
        // --------- NEU: sprechende Doc-ID nach Partynamen (mit 0,1,2,… bei Kollision) ---------
        final uniqueId = await _generateUniqueDocId(name);
        final ref = FirebaseFirestore.instance.collection('Party').doc(uniqueId);
        await ref.set(baseData, SetOptions(merge: true));
        savedDocId = uniqueId;
        await ref.set({'docId': savedDocId}, SetOptions(merge: true));
      } else {
        // EDIT: vorhandenes Dokument beibehalten
        final ref = FirebaseFirestore.instance.collection('Party').doc(widget.docId);
        await ref.set(baseData, SetOptions(merge: true));
        savedDocId = widget.docId!;
        await ref.set({'docId': savedDocId}, SetOptions(merge: true));
      }

      _goToMapAndPop(updated: true, payload: {
        'data': {...baseData, 'docId': savedDocId},
        'lat': lat,
        'lng': lng,
        'docId': savedDocId,
      });
    } catch (e) {
      // optional: Fehlermeldung
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

  InputDecoration _dec(String label, {String? hint, IconData? icon, Widget? suffix, String? errorText}) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: _textSecondary),
      hintText: hint,
      hintStyle: TextStyle(color: _textSecondary),
      prefixIcon: icon != null ? Icon(icon, color: _textSecondary) : null,
      suffixIcon: suffix,
      filled: true,
      fillColor: _card,
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.transparent)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: _accent, width: 1.2)),
      errorText: errorText,
    );
  }

  Widget _section({required String title, required Widget child, IconData? icon}) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, color: _textSecondary), const SizedBox(width: 8),
            ],
            Text(title,
                style: TextStyle(color: _textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
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
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: _textSecondary), const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(label,
                style: TextStyle(color: _textPrimary, fontWeight: FontWeight.w600)),
          ),
          Switch(value: value, onChanged: onChanged, activeColor: _accent),
        ],
      ),
    );
  }

  Widget _typeChip({required String value, required String label, required IconData icon}) {
    final isSelected = _partyType == value;
    final border = isSelected ? _accent : Colors.white24;
    final textColor = isSelected ? Colors.white : _textPrimary;
    final iconColor = isSelected ? Colors.white : Colors.white70;

    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) => setState(() => _partyType = value),
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

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingData != null;

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
              backgroundColor: _bg,
              elevation: 0.5,
              title: Text(
                isEditing ? "Party bearbeiten" : "Neue Party",
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              leading: IconButton(
                icon: Icon(Icons.map_outlined, color: _accent),
                onPressed: () => _goToMapAndPop(updated: false),
                tooltip: "Zur Karte",
              ),
              actions: [
                if (_hostName != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person, size: 16, color: Colors.white70),
                        const SizedBox(width: 6),
                        Text(
                          _hostName!,
                          style: const TextStyle(
                              color: Colors.white70, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    // Basis
                    _section(
                      title: "Basis",
                      icon: Icons.celebration_outlined,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _nameController,
                            style: TextStyle(color: _textPrimary),
                            decoration: _dec("Party Name", icon: Icons.title),
                            validator: (v) => _validateRequired(v, label: "Party Name"),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _descriptionController,
                            minLines: 3,
                            maxLines: null,
                            style: TextStyle(color: _textPrimary),
                            decoration: _dec("Beschreibung", icon: Icons.notes),
                            validator: (v) => _validateRequired(v, label: "Beschreibung"),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Gäste & Preis + Mindestalter
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
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  enabled: !_isUnlimitedGuests,
                                  style: TextStyle(color: _textPrimary),
                                  decoration: _dec(
                                    "Gästelimit",
                                    hint: "Zahl eingeben",
                                    icon: Icons.groups,
                                    errorText: (!_isUnlimitedGuests && _triedSubmit
                                        && (int.tryParse(_guestLimitController.text.trim()) == null))
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
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(
                                      RegExp(r'^\d*[,]?\d{0,2}$|^\d*[.]?\d{0,2}$'),
                                    ),
                                  ],
                                  enabled: !_isFreeEntry,
                                  style: TextStyle(color: _textPrimary),
                                  decoration: _dec(
                                    "Eintrittspreis",
                                    hint: "Preis in €",
                                    icon: Icons.euro,
                                    errorText: (!_isFreeEntry && _triedSubmit
                                        && (double.tryParse(_priceController.text.replaceAll(',', '.').trim()) == null))
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
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            style: TextStyle(color: _textPrimary),
                            decoration: _dec(
                              "Mindestalter",
                              hint: "z. B. 16",
                              icon: Icons.cake_outlined,
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return "Mindestalter darf nicht leer sein.";
                              }
                              final n = int.tryParse(v.trim());
                              if (n == null) return "Mindestalter muss eine Zahl sein.";
                              if (n < 0) return "Mindestalter darf nicht negativ sein.";
                              if (n > 99) return "Bitte ein realistisches Alter (0–99) eingeben.";
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Ort — ALLES erlaubt (keine Formatter)
                    _section(
                      title: "Ort",
                      icon: Icons.location_on_outlined,
                      child: TextFormField(
                        controller: _addressController,
                        keyboardType: TextInputType.text, // volle Zeichenpalette
                        textInputAction: TextInputAction.done,
                        enableSuggestions: true,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.fullStreetAddress],
                        // KEINE inputFormatters → wirklich alles erlaubt (ä/ö/ü/ß, Emojis, usw.)
                        style: TextStyle(color: _textPrimary),
                        decoration: _dec(
                          "Adresse",
                          hint: "z. B. Münzgasse 4, 1030 Wien",
                          icon: Icons.place,
                          errorText: _addressCountryError,
                        ),
                        validator: (v) => _validateRequired(v, label: "Adresse"),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Datum & Zeit
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
                                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  onPressed: _pickDate,
                                  icon: Icon(Icons.calendar_today, color: _accent),
                                  label: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 150),
                                    child: Text(
                                      _selectedDate == null
                                          ? "Datum wählen"
                                          : "${_selectedDate!.day.toString().padLeft(2, '0')}.${_selectedDate!.month.toString().padLeft(2, '0')}.${_selectedDate!.year}",
                                      key: ValueKey(_selectedDate?.toIso8601String() ?? 'none'),
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
                                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                  onPressed: _pickTime,
                                  icon: Icon(Icons.access_time, color: _accent),
                                  label: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 150),
                                    child: Text(
                                      (_selectedTime == null) ? "Uhrzeit wählen" : _timeController.text,
                                      key: ValueKey(_timeController.text.isEmpty ? 'none' : _timeController.text),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_triedSubmit && _selectedDate == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text("Bitte ein Datum wählen.", style: TextStyle(color: Colors.orangeAccent)),
                            ),
                          if (_triedSubmit && _selectedTime == null)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text("Bitte eine Uhrzeit wählen.", style: TextStyle(color: Colors.orangeAccent)),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Party-Typ
                    _section(
                      title: "Party-Typ",
                      icon: Icons.lock_open_outlined,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          _typeChip(value: "Open", label: "Open", icon: Icons.lock_open_rounded),
                          _typeChip(value: "Closed", label: "Closed", icon: Icons.lock_rounded),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Aktionen
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isLoading ? null : _saveParty,
                            icon: const Icon(Icons.add_location_alt_outlined),
                            label: Text(isEditing ? "Party aktualisieren" : "Party speichern"),
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
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading ? null : () => _goToMapAndPop(updated: false),
                            icon: const Icon(Icons.map_outlined, color: Colors.white70),
                            label: const Text("Zur Karte"),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white24),
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
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                              label: const Text("Löschen", style: TextStyle(color: Colors.redAccent)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.redAccent),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),

          if (_isLoading)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: true,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  color: Colors.black.withOpacity(0.35),
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
