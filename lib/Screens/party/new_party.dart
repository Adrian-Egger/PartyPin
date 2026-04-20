// lib/Screens/new_party.dart
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

import 'package:geocoding/geocoding.dart' as geo;

// ✅ (Coming soon) Bilder-Funktionalität bleibt im Code,
// aber UI ist komplett deaktiviert und es gibt keinen Premium-/Payment-Flow.
import 'package:image_picker/image_picker.dart';

import '../../Services/geocoding_services.dart';
import 'map_picker_screen.dart';
import '../../Social/friends_model.dart';
import 'exclude_friends.dart';

// ✅ HomeShell (WICHTIG für BottomNav!)
import '../home/home_shell.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

class NewPartyScreen extends StatefulWidget {
  final Map<String, dynamic>? existingData;
  final String? docId;

  /// Optional: Wird weiter aufgerufen (z.B. PartyMapScreen kann refreshen)
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

class _NewPartyScreenState extends State<NewPartyScreen> with SingleTickerProviderStateMixin {
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
  bool _navigatedAway = false;
  bool _detailsSubmitted = false;


  bool _isLoading = false;
  bool _triedSubmit = false;

  String? _stripeAccountId;
  bool _checkingStripe = true;


  String? _hostName;
  String _partyType = 'Open';
  String? _addressCountryError;

  double? _pickedLat;
  double? _pickedLng;

  // Friends-only + Excludes (Only4Friends steuert das)
  final FriendsModel _friendsModel = FriendsModel();
  bool _friendsOnly = false; // visibility: friends/public
  List<String> _excludedFriends = []; // usernames

  static const _bg = AppColors.bgTop;
  static const _gradTop = AppColors.bgTop;
  static const _gradBottom = AppColors.bgBottom;
  static const _panel = Color(0xFF15171C);
  static const _card = AppColors.panel;
  static const _textPrimary = AppColors.text;
  static const _textSecondary = AppColors.muted;
  static const _accent = AppColors.accent;
  static const _secondary = AppColors.accent;

  static const _accentSoft = Color(0x26FF3B30);
  static const _accentLine = Color(0x66FF3B30);

  // BottomNav Index (lokal nur fürs UI hier)
  // 0=Feedback, 1=Map, 2=Freunde, 3=Neue Party
  int _currentIndex = 3;

  // Legal Gate nur hier
  bool _legalGateHandled = false;

  void _unfocus() => FocusManager.instance.primaryFocus?.unfocus();

  // ===========================
  // ✅ Coming soon: Party Bilder
  // ===========================
  // Premium/Payment ist komplett deaktiviert. Der Code bleibt,
  // aber UI ist gesperrt und es gibt keinen Link zu PremiumScreen.
  static const bool _partyImagesComingSoon = true;

  final ImagePicker _picker = ImagePicker();

  static const int _maxImageBlocks = 5; // max 5 Blöcke
  static const int _maxImagesPerBlock = 5; // max 5 Bilder je Block

  final List<_ImageBlockDraft> _imageBlocks = [
    _ImageBlockDraft(), // 1 Block standardmäßig
  ];

  @override
  void initState() {
    super.initState();
    _loadHostData();
    _loadStripeStatus();
    _preloadExisting();
    _wireListeners();

    _deleteDraftSilently();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final isEditing = widget.existingData != null;
      if (isEditing) return;

      if (_legalGateHandled) return;
      _legalGateHandled = true;

      final ok = await _ensureLegalConsentBeforeCreating();
      if (!ok) {
        if (!mounted) return;
        Navigator.of(context).pop({'updated': false});
        return;
      }
    });
  }

  @override
  void dispose() {
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

    for (final b in _imageBlocks) {
      b.dispose();
    }

    super.dispose();
  }

  Future<void> _deleteDraftSilently() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('draft_newparty');
    } catch (_) {}
  }

  Future<String?> _askForEmail() async {
    final controller = TextEditingController();

    return await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.panel,
          title: const Text(
            "Email eingeben",
            style: TextStyle(color: AppColors.text),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: "deine@email.com",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Abbrechen"),
            ),
            ElevatedButton(
              onPressed: () {
                final email = controller.text.trim();

                if (email.isEmpty ||
                    !RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
                  return;
                }

                Navigator.pop(context, email);
              },
              child: const Text("Weiter"),
            ),
          ],
        );
      },
    );
  }

  void _preloadExisting() {
    if (widget.existingData == null) return;
    final data = widget.existingData!;

    _nameController.text = (data['name'] ?? '').toString();
    _descriptionController.text = (data['description'] ?? '').toString();

    _guestLimitController.text = data['guestLimit'] != null && data['guestLimit'] != 'Unbegrenzt'
        ? data['guestLimit'].toString()
        : '';
    _isUnlimitedGuests = data['guestLimit'] == 'Unbegrenzt';

    _priceController.text = data['price'] != null && data['price'] != 0 ? data['price'].toString() : '';
    _isFreeEntry = (data['price'] ?? 0) == 0;

    _addressController.text = (data['address'] ?? '').toString();

    if (data['startTime'] is Timestamp) {
      final dt = (data['startTime'] as Timestamp).toDate();
      _selectedDate = DateTime(dt.year, dt.month, dt.day);
      _selectedTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
      _timeController.text = "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } else {
      if (data['date'] is Timestamp) {
        final d = (data['date'] as Timestamp).toDate();
        _selectedDate = DateTime(d.year, d.month, d.day);
      }
      if (data['time'] != null) {
        final parts = (data['time'] as String).split(':');
        if (parts.length == 2) {
          _selectedTime = TimeOfDay(
            hour: int.tryParse(parts[0]) ?? 0,
            minute: int.tryParse(parts[1]) ?? 0,
          );
          _timeController.text = data['time'];
        }
      }
    }

    _partyType = (data['type'] ?? 'Open').toString();
    _minAgeController.text = (data['minAge'] != null) ? data['minAge'].toString() : '';
    _pickedLat = (data['lat'] as num?)?.toDouble();
    _pickedLng = (data['lng'] as num?)?.toDouble();

    final vis = data['visibility'];
    _friendsOnly = (vis == 'friends');

    if (_friendsOnly && _partyType != 'Only4Friends') {
      _partyType = 'Only4Friends';
    }

    final ex = data['excludedFriends'];
    if (ex is List) _excludedFriends = ex.cast<String>();
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
    if (!mounted) return;
    setState(() {
      final full = "$vorname $nachname".trim();
      _hostName = full.isEmpty ? null : full;
    });
  }

  Future<void> _loadStripeStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username');

    if (username == null) {
      setState(() => _checkingStripe = false);
      return;
    }

    // 🔎 User korrekt über username finden
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: username)
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      setState(() => _checkingStripe = false);
      return;
    }

    final userDoc = query.docs.first;
    final stripeId = userDoc.data()['stripeAccountId'];

    if (stripeId == null) {
      setState(() {
        _stripeAccountId = null;
        _detailsSubmitted = false;
        _checkingStripe = false;
      });
      return;
    }

    try {
      // 🔥 Backend Status prüfen
      final response = await http.post(
        Uri.parse("http://192.168.1.5:3000/check-stripe-status"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "stripeAccountId": stripeId,
        }),
      );

      if (response.statusCode != 200) {
        setState(() {
          _stripeAccountId = stripeId;
          _detailsSubmitted = false;
          _checkingStripe = false;
        });
        return;
      }

      final data = jsonDecode(response.body);

      setState(() {
        _stripeAccountId = stripeId;
        _detailsSubmitted = data["detailsSubmitted"] ?? false;
        _checkingStripe = false;
      });

    } catch (e) {
      setState(() {
        _stripeAccountId = stripeId;
        _detailsSubmitted = false;
        _checkingStripe = false;
      });
    }
  }



  Future<void> _createStripeAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username');

    if (username == null) return;

    final email = await _askForEmail();
    if (email == null) return;

    // 🔎 richtigen User suchen
    final query = await FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: username)
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("User nicht gefunden."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final userDoc = query.docs.first;
    final docId = userDoc.id;

    final response = await http.post(
      Uri.parse("http://192.168.1.5:3000/create-host-account"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"email": email}),
    );

    if (response.statusCode != 200) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Backend Fehler."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final data = jsonDecode(response.body);
    final accountId = data["accountId"];
    final onboardingUrl = data["onboardingUrl"];

    // ✅ Stripe ID im richtigen Dokument speichern
    await FirebaseFirestore.instance
        .collection('users')
        .doc(docId)
        .set({
      "stripeAccountId": accountId,
    }, SetOptions(merge: true));

    await launchUrl(
      Uri.parse(onboardingUrl),
      mode: LaunchMode.externalApplication,
    );

    setState(() {
      _stripeAccountId = accountId;
    });
  }


  Future<void> _openStripeDashboard() async {
    if (_stripeAccountId == null) return;

    final response = await http.post(
      Uri.parse("http://192.168.1.5:3000/create-login-link"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "stripeAccountId": _stripeAccountId,
      }),
    );

    if (response.statusCode != 200) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Stripe Login Fehler."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final url = jsonDecode(response.body)["url"];

    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _resumeOnboarding() async {
    final response = await http.post(
      Uri.parse("http://192.168.1.5:3000/resume-onboarding"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "stripeAccountId": _stripeAccountId,
      }),
    );

    if (response.statusCode != 200) return;

    final url = jsonDecode(response.body)["url"];

    await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }


  Future<bool> _ensureLegalConsentBeforeCreating() async {
    final prefs = await SharedPreferences.getInstance();

    // Lokaler Cache – schneller Check
    if (prefs.getBool('legal_consent_create_v1') == true) return true;

    // Firestore-Check (pro Account)
    final username = prefs.getString('username') ?? prefs.getString('currentUsername') ?? '';
    if (username.isNotEmpty) {
      final doc = await FirebaseFirestore.instance.collection('users').doc(username).get();
      if (doc.data()?['legalConsentCreateV1'] == true) {
        await prefs.setBool('legal_consent_create_v1', true);
        return true;
      }
    }

    final acceptedNow = await _showLegalGateDialog();
    if (acceptedNow) {
      await prefs.setBool('legal_consent_create_v1', true);
      await prefs.setString('legal_consent_create_v1_date', DateTime.now().toIso8601String());
      if (username.isNotEmpty) {
        await FirebaseFirestore.instance.collection('users').doc(username).set(
          {'legalConsentCreateV1': true, 'legalConsentCreateV1At': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );
      }
    }
    return acceptedNow;
  }

  Future<bool> _showLegalGateDialog() async {
    bool checkbox = false;
    bool accepted = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSB) {
            return AlertDialog(
              backgroundColor: AppColors.panel,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              title: Row(
                children: const [
                  Icon(Icons.gavel_outlined, color: AppColors.accent),
                  SizedBox(width: 8),
                  Text("Rechtlicher Hinweis", style: TextStyle(color: AppColors.text)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Das Erstellen von Fake-Partys ist VERBOTEN. Du bestätigst, dass alle Angaben wahrheitsgemäß sind und die Veranstaltung wirklich stattfindet.",
                      style: TextStyle(
                        color: AppColors.muted,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: checkbox,
                      onChanged: (v) => setSB(() => checkbox = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppColors.accent,
                      title: const Text(
                        "Ich habe den Hinweis gelesen und stimme zu.",
                        style: TextStyle(color: AppColors.text),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              actions: [
                if (checkbox)
                  ElevatedButton.icon(
                    onPressed: () {
                      accepted = true;
                      Navigator.of(ctx).pop();
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text("Fertig", style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );

    return accepted;
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
      prefixIcon: icon != null ? Icon(icon, color: _secondary) : null,
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
        border: Border.all(color: AppColors.accentBorder),
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
                  border: Border.all(color: AppColors.accentBorder),
                ),
                child: Icon(icon, color: _accent, size: 16),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              title,
              style: const TextStyle(
                color: _textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  // ✅ FIX: verhindert abgeschnittene Labels / Wortbruch
  // - Wenn label '\n' enthält => 2 Zeilen
  // - Sonst => FittedBox scaleDown => "Unbegrenzt" wird nie abgeschnitten
  Widget _switchTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    IconData? icon,
  }) {
    final bool twoLines = label.contains('\n');

    final Widget labelWidget = twoLines
        ? Text(
      label,
      maxLines: 2,
      softWrap: true,
      overflow: TextOverflow.visible,
      style: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w600),
    )
        : FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: const TextStyle(color: _textPrimary, fontWeight: FontWeight.w600),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), // mehr Höhe => 2 Zeilen passen sicher
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: _secondary),
            const SizedBox(width: 10),
          ],
          Expanded(child: labelWidget),
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

  Widget _typeChip({
    required String value,
    required String label,
    required IconData icon,
  }) {
    final isSelected = _partyType == value;
    final border = isSelected ? _accent : AppColors.accentBorder;
    final textColor = isSelected ? Colors.white : _textPrimary;
    final iconColor = isSelected ? Colors.white : _secondary;

    return ChoiceChip(
      selected: isSelected,
      onSelected: (_) {
        _unfocus();
        HapticFeedback.selectionClick();
        setState(() {
          _partyType = value;

          if (value == "Only4Friends") {
            _friendsOnly = true;
          } else {
            _friendsOnly = false;
            _excludedFriends = [];
          }
        });
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
    _unfocus();
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
    _unfocus();
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
        _timeController.text = "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _openMapPicker() async {
    _unfocus();
    LatLng initial = LatLng(_pickedLat ?? 48.2082, _pickedLng ?? 16.3738);

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

    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => MapPickerScreen(initial: initial)),
    );

    if (picked != null && mounted) {
      setState(() {
        _pickedLat = picked.latitude;
        _pickedLng = picked.longitude;
      });

      try {
        final placemarks = await geo.placemarkFromCoordinates(picked.latitude, picked.longitude);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final street = [p.street, p.subThoroughfare].where((e) => e != null && e.trim().isNotEmpty).join(' ');
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
      } catch (_) {}

      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Standort übernommen"),
        backgroundColor: AppColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  void _scrollToFirstError() {
    _scrollCtrl
        .animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    )
        .then(
          (_) => _scrollCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      ),
    );
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

  // ✅ WICHTIG: immer zurück in HomeShell(Map) -> BottomNav bleibt
  void _closeWithResult({required bool updated, Map<String, dynamic>? payload}) {
    if (!mounted || _navigatedAway) return;
    _navigatedAway = true;

    widget.onGoToMapAndRefresh?.call(updated: updated, payload: payload);

    Navigator.of(context).pop({
      'updated': updated,
      'payload': payload,
    });
  }





  Future<void> _openExcludeFriendsDialog() async {
    _unfocus();
    final prefs = await SharedPreferences.getInstance();
    final me = prefs.getString('username') ?? 'unknown_user';

    final friends = await _friendsModel.myFriends(me);

    final selected = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => ExcludeFriendsScreen(
          friends: friends,
          initialExcluded: _excludedFriends,
          cardColor: _card,
          borderColor: AppColors.accentBorder,
          accent: _accent,
          textPrimary: _textPrimary,
          textSecondary: _textSecondary,
          panel: _panel,
        ),
      ),
    );

    if (selected != null && mounted) {
      setState(() => _excludedFriends = selected);
    }
  }

  // ===========================
  // Coming soon: Bilder UI (gesperrt)
  // ===========================

  Widget _xfileThumb(XFile f) {
    if (kIsWeb) {
      return Image.network(f.path, width: 86, height: 86, fit: BoxFit.cover);
    }
    return Image.file(File(f.path), width: 86, height: 86, fit: BoxFit.cover);
  }

  Future<void> _pickImagesForBlock(int blockIndex) async {
    _unfocus();
    if (blockIndex < 0 || blockIndex >= _imageBlocks.length) return;

    final block = _imageBlocks[blockIndex];
    final remaining = _maxImagesPerBlock - block.images.length;

    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Maximal 5 Bilder pro Block."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final picked = await _picker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty) return;

    final toAdd = picked.take(remaining).toList();
    setState(() => block.images.addAll(toAdd));

    if (picked.length > remaining) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Es sind nur 5 Bilder pro Block erlaubt."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  void _addBlock() {
    if (_imageBlocks.length >= _maxImageBlocks) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Maximal 5 Blöcke möglich."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    setState(() => _imageBlocks.add(_ImageBlockDraft()));
  }

  void _removeBlock(int i) {
    if (_imageBlocks.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Mindestens 1 Block muss bleiben."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    setState(() {
      _imageBlocks[i].dispose();
      _imageBlocks.removeAt(i);
    });
  }

  // ===========================
// Coming soon: Bilder UI (gesperrt, aber “leicht sehbar” + Teaser)
// ===========================

  Widget _partyImagesSection() {
    // ✅ dauerhaft gesperrt (kein Premium, kein Redirect)
    final locked = _partyImagesComingSoon;

    Widget plusRow() {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: locked ? null : _addBlock,
              icon: const Icon(Icons.add, color: _secondary),
              label: Text(
                "Block hinzufügen (${_imageBlocks.length}/$_maxImageBlocks)",
                style: const TextStyle(color: Colors.white),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.accentBorder),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      );
    }

    Widget blockCard(int i) {
      final b = _imageBlocks[i];

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.accentBorder),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: locked ? null : () => _pickImagesForBlock(i),
                    icon: const Icon(Icons.add_photo_alternate_outlined, color: _secondary),
                    label: Text(
                      b.images.isEmpty ? "Bilder hinzufügen" : "Bilder (${b.images.length}/5)",
                      style: const TextStyle(color: Colors.white),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.accentBorder),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: "Block löschen",
                  onPressed: locked ? null : () => _removeBlock(i),
                  icon: const Icon(Icons.delete_outline, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: b.caption,
              enabled: !locked,
              maxLength: 80,
              style: const TextStyle(color: _textPrimary),
              decoration: _dec(
                "Text zu diesem Block",
                hint: locked ? "Bald verfügbar…" : "z. B. Dresscode, Thema, Infos…",
                icon: Icons.short_text_rounded,
                maxLength: 80,
              ),
            ),
            if (b.images.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(b.images.length, (imgIndex) {
                  return Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _xfileThumb(b.images[imgIndex]),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          padding: const EdgeInsets.all(4),
                          child: const Icon(Icons.lock, size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ],
          ],
        ),
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < _imageBlocks.length; i++) blockCard(i),
        const SizedBox(height: 4),
        plusRow(),
      ],
    );

    // ✅ “Verschlossen”, aber noch sichtbar:
    // - leichte Abdunkelung
    // - klares Lock + Coming soon + Mini-Werbetext
    // - KEIN onTap, KEIN Premium-Screen
    return _section(
      title: "Party Bilder 🔒",
      icon: Icons.photo_camera_back_outlined,
      child: Stack(
        children: [
          // leicht sichtbar, aber klar “locked”
          Opacity(
            opacity: 0.75,
            child: IgnorePointer(
              ignoring: true, // komplett nicht bedienbar
              child: content,
            ),
          ),

          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.black.withOpacity(0.18),
              ),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.62),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.accentBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.lock_rounded, color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Text(
                          "Coming soon",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      "Bald kannst du Party-Bilder in Blöcken hinzufügen.\nMehr Aufmerksamkeit. Mehr Gäste. 🔥",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }


  // ===========================

  Future<void> _saveParty() async {

    _unfocus();
    setState(() => _triedSubmit = true);
    _addressCountryError = null;

    final valid = _formKey.currentState?.validate() ?? false;
    final dateOk = _selectedDate != null;
    final timeOk = _selectedTime != null;

    if (!valid || !dateOk || !timeOk || _isLoading) {
      _scrollToFirstError();
      return;
    }

    // 🔥 PRICE NUR EINMAL DEFINIEREN
    final price = _isFreeEntry
        ? 0.0
        : double.tryParse(
      _priceController.text.replaceAll(',', '.').trim(),
    ) ?? 0.0;

    // 🔥 Stripe nur bei kostenpflichtigen Events verlangen
    if (price > 0) {
      if (_stripeAccountId == null || !_detailsSubmitted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text(
            "Für kostenpflichtige Events ist ein verifizierter Stripe Account nötig.",
          ),
          backgroundColor: AppColors.accent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        return;
      }
    }

    setState(() => _isLoading = true);

    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();

    final guestLimit = _isUnlimitedGuests
        ? 'Unbegrenzt'
        : int.tryParse(_guestLimitController.text.trim());


    final address = _addressController.text.trim();
    final date = _selectedDate!;
    final
    timeOfDay = _selectedTime!;

    String time = _timeController.text.trim();
    if (time.isEmpty) {
      time = "${timeOfDay.hour.toString().padLeft(2, '0')}:${timeOfDay.minute.toString().padLeft(2, '0')}";
    }

    final minAge = int.tryParse(_minAgeController.text.trim());
    final type = _partyType;

    final startDateTime = DateTime(date.year, date.month, date.day, timeOfDay.hour, timeOfDay.minute);

    double? lat = _pickedLat;
    double? lng = _pickedLng;

    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('username') ?? 'unknown_user').trim();

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Adresse nicht gefunden. Bitte genauer angeben oder Standort auf der Karte wählen."),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final baseData = <String, dynamic>{
      'name': name,
      'description': description,
      'guestLimit': guestLimit,
      'startTime': Timestamp.fromDate(startDateTime),
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
      'stripeAccountId': _stripeAccountId,
      'isClosed': false,
      'requests': widget.existingData?['requests'] ?? [],
      'approved': widget.existingData?['approved'] ?? [],
      'updatedAt': FieldValue.serverTimestamp(),
      'visibility': _friendsOnly ? 'friends' : 'public',
      'excludedFriends': _friendsOnly ? _excludedFriends : [],
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

      // ✅ Coming soon: kein Upload / kein Premium speichern

      await _deleteDraftSilently();

      HapticFeedback.mediumImpact();

      // ✅ zurück in HomeShell(Map) mit BottomNav
      _closeWithResult(updated: true, payload: {
        'data': {...baseData, 'docId': savedDocId},
        'lat': lat,
        'lng': lng,
        'docId': savedDocId,
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Fehler beim Speichern: $e"),
        backgroundColor: AppColors.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteParty() async {
    _unfocus();
    if (widget.docId == null || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance.collection('Party').doc(widget.docId).delete();
      await _deleteDraftSilently();

      // ✅ auch hier zurück in HomeShell(Map)
      _closeWithResult(updated: true, payload: {'deleted': true, 'docId': widget.docId});
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// ✅ BottomNav: NIEMALS PartyMapScreen direkt pushen → immer HomeShell
  Future<void> _onBottomNavTapped(int index) async {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);

    if (index == 3) return; // bleibt auf Neu

    // Lokale Indizes: 0 Feedback, 1 Map, 2 Freunde, 3 Neu
    // HomeShell (User): 0 Feedback, 1 Freunde, 2 Map, 3 Neu, 4 Profil
    final homeIndex = switch (index) {
      0 => 0, // Feedback
      1 => 2, // Map
      2 => 1, // Freunde
      _ => 2,
    };

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomeShell(initialIndex: homeIndex)),
          (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final isEditing = widget.existingData != null;

    return WillPopScope(
      onWillPop: () async {
        if (_isLoading || _navigatedAway) return false;
        _closeWithResult(updated: false);
        return false;
      },

      child: Stack(
        children: [
          Scaffold(
            backgroundColor: _bg,
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.transparent,
              automaticallyImplyLeading: false,
              centerTitle: true,
              title: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: AppRadius.fullBr,
                  border: Border.all(color: AppColors.accentBorder2, width: 1),
                ),
                child: Text(
                  isEditing ? Lang.t('new_party_edit') : Lang.t('new_party_header'),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              actions: [
                if (_hostName != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.accentBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.person, size: 16, color: _secondary),
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
            body: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _unfocus,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_gradTop, _gradBottom],
                  ),
                ),
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  child: Form(
                    key: _formKey,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                      children: [
                        if (!_checkingStripe)
                          Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _stripeAccountId != null ? Colors.green : Colors.redAccent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _stripeAccountId != null
                                      ? Icons.check_circle
                                      : Icons.warning,
                                  color: _stripeAccountId != null
                                      ? Colors.green
                                      : Colors.redAccent,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _stripeAccountId != null
                                        ? "Stripe Account verbunden"
                                        : "Stripe Account erforderlich um Tickets zu verkaufen",
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                if (_stripeAccountId == null)
                                  TextButton(
                                    onPressed: _createStripeAccount,
                                    child: const Text(
                                      "Erstellen",
                                      style: TextStyle(color: Colors.redAccent),
                                    ),
                                  )
                                else if (!_detailsSubmitted)
                                  TextButton(
                                    onPressed: _resumeOnboarding,
                                    child: const Text(
                                      "Onboarding fortsetzen",
                                      style: TextStyle(color: Colors.orange),
                                    ),
                                  )
                                else
                                  TextButton(
                                    onPressed: _openStripeDashboard,
                                    child: const Text(
                                      "Dashboard",
                                      style: TextStyle(color: Colors.green),
                                    ),
                                  ),
                              ],
                            ),
                          ),

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
                                            (int.tryParse(_guestLimitController.text.trim()) == null))
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
                                        _unfocus();
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
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                                            (double.tryParse(
                                                _priceController.text.replaceAll(',', '.').trim()) ==
                                                null))
                                            ? "Preis muss eine Zahl sein."
                                            : null,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _switchTile(
                                      label: "Gratis\nEintritt", // ✅ 2 Zeilen erzwingen
                                      value: _isFreeEntry,
                                      icon: Icons.card_giftcard,
                                      onChanged: (v) {
                                        _unfocus();
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
                                decoration: _dec("Mindestalter", hint: "z. B. 16", icon: Icons.cake_outlined),
                                validator: (v) {
                                  if (v == null || v.trim().isEmpty) return "Mindestalter darf nicht leer sein.";
                                  final n = int.tryParse(v.trim());
                                  if (n == null) return "Mindestalter muss eine Zahl sein.";
                                  if (n < 0) return "Mindestalter darf nicht negativ sein.";
                                  if (n > 99) return "Bitte 0–99 eingeben.";
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
                            onFieldSubmitted: (_) => _unfocus(),
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
                                icon: const Icon(Icons.map_rounded, color: _secondary),
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
                                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                      ),
                                      onPressed: _pickDate,
                                      icon: const Icon(Icons.calendar_today, color: _secondary),
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
                                      icon: const Icon(Icons.access_time, color: _secondary),
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
                                  child:
                                  Text("Bitte eine Uhrzeit wählen.", style: TextStyle(color: Colors.orangeAccent)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        _section(
                          title: "Party-Typ",
                          icon: Icons.lock_open_outlined,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                children: [
                                  _typeChip(value: "Open", label: "Open", icon: Icons.lock_open_rounded),
                                  _typeChip(value: "Closed", label: "Closed", icon: Icons.lock_rounded),
                                  _typeChip(value: "Only4Friends", label: "Only4Friends", icon: Icons.people_alt),
                                ],
                              ),
                              if (_partyType == "Only4Friends") ...[
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  onPressed: _openExcludeFriendsDialog,
                                  icon: const Icon(Icons.person_off, size: 18, color: _secondary),
                                  label: Text(
                                    _excludedFriends.isEmpty
                                        ? "Freunde ausschließen"
                                        : "Ausgeschlossen (${_excludedFriends.length})",
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: AppColors.accentBorder),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                ),
                                if (_excludedFriends.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    "Ausgeschlossen: ${_excludedFriends.join(', ')}",
                                    style: const TextStyle(color: _textSecondary, fontSize: 12),
                                  ),
                                ],
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),

                        // ✅ Coming soon: Party Bilder (gesperrt + Schloss + Coming soon)
                        _partyImagesSection(),

                        const SizedBox(height: 28),
                        Center(
                          child: ElevatedButton.icon(
                            onPressed: _isLoading ? null : _saveParty,
                            icon: const Icon(Icons.check_rounded, size: 22),
                            label: Text(
                              isEditing ? "Aktualisieren" : "Party speichern",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.3,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white,
                              elevation: 8,
                              shadowColor: _accent,
                              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),
                        ),

                        if (isEditing) ...[
                          const SizedBox(height: 14),
                          Center(
                            child: TextButton.icon(
                              onPressed: _isLoading ? null : _deleteParty,
                              icon: const Icon(Icons.delete_outline, color: _accent),
                              label: const Text(
                                "Party löschen",
                                style: TextStyle(color: _accent, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 36),
                      ],
                    ),
                  ),
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
                  child: const Center(child: CircularProgressIndicator(strokeWidth: 3)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================
// Helper: Draft Block
// ===========================
class _ImageBlockDraft {
  final TextEditingController caption = TextEditingController();
  final List<XFile> images = [];

  void dispose() => caption.dispose();
}
