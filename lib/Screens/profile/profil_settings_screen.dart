
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ anonymous auth (Storage)
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/login_screen.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

// ---------- Farben wie bei PartyMap / NewParty ----------
const _gradTop = AppColors.bgTop;
const _gradBottom = AppColors.bgBottom;
const _panel = Color(0xFF15171C);
const _card = AppColors.panel;
const _textPrimary = AppColors.text;
const _textSecondary = AppColors.muted;
const _accent = AppColors.accent;

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  String _docId = "";
  String _username = "";
  String? _avatar; // URL (avatarUrl)
  String _passwordFromDb = "";

  // ✅ users vs bars
  String _collection = "users";
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection(_collection);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _currentPasswordController =
  TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();

  bool _editingUsername = false;
  bool _editingPassword = false;

  bool _busyAvatar = false;

  final ImagePicker _picker = ImagePicker();

  // ✅ Coming soon Toggle: Profilbild-Funktion komplett deaktiviert
  final bool _avatarComingSoon = true;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  // ---------- User-Daten laden ----------
  Future<void> _loadUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('username') ?? "").trim();
    final cachedAvatar = prefs.getString('avatar'); // URL gecached

    // ✅ accountType sollte beim Login gesetzt werden: "user" oder "bar"
    // Wir sind robust: wenn es fehlt, versuchen wir users UND bars.
    final accountType = (prefs.getString('accountType') ?? "").toLowerCase();

    String? avatarUrl;
    String password = "";

    Future<bool> tryLoadFrom(String collectionName) async {
      if (username.isEmpty) return false;

      final lower = username.toLowerCase();
      final query = await FirebaseFirestore.instance
          .collection(collectionName)
          .where("username_lower", isEqualTo: lower)
          .limit(1)
          .get();

      if (query.docs.isEmpty) return false;

      final doc = query.docs.first;
      final data = doc.data();

      avatarUrl = (data['avatarUrl'] ?? '').toString().trim();
      password = (data['password'] ?? '').toString();

      if (!mounted) return true;
      setState(() {
        _collection = collectionName;
        _docId = doc.id;
        _username = (data['username'] ?? username).toString();
        _usernameController.text = _username;
        _avatar = (avatarUrl != null && avatarUrl!.isNotEmpty)
            ? avatarUrl
            : cachedAvatar;
        _passwordFromDb = password;
      });

      // ✅ merken, damit künftig sofort richtig gesucht wird
      await prefs.setString(
          'accountType', collectionName == "bars" ? "bar" : "user");

      return true;
    }

    // 1) Wenn accountType bekannt: direkt richtig suchen
    if (accountType == "bar" || accountType == "bars" || accountType == "ba") {
      final ok = await tryLoadFrom("bars");
      if (ok) return;
    } else if (accountType == "user" || accountType.isNotEmpty) {
      final ok = await tryLoadFrom("users");
      if (ok) return;
    }

    // 2) Fallback (falls accountType nicht gesetzt/alt): erst users, dann bars
    if (await tryLoadFrom("users")) return;
    if (await tryLoadFrom("bars")) return;

    // Fallback: nur Prefs, falls Firestore nichts gefunden hat
    if (!mounted) return;
    setState(() {
      _username = username;
      _usernameController.text = username;
      _avatar = cachedAvatar;
      _passwordFromDb = password;
      _docId = "";
    });
  }

  Future<void> _updateFirestoreField(String field, dynamic value) async {
    if (_docId.isEmpty) return;
    await _col.doc(_docId).update({field: value});
  }

  // ---------- ✅ FIX: sicherstellen, dass Storage Upload erlaubt ist ----------
  Future<User?> _ensureFirebaseUser(BuildContext context) async {
    final auth = FirebaseAuth.instance;

    if (auth.currentUser != null) return auth.currentUser;

    try {
      final cred = await auth.signInAnonymously();
      return cred.user;
    } catch (e) {
      _showSnack("Firebase Login fehlgeschlagen: $e");
      return null;
    }
  }

  // ---------- Avatar / Foto ----------
  Future<bool> _ensurePermissionForSource(ImageSource source) async {
    if (source == ImageSource.camera) {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        _showSnack("Kamera-Zugriff wurde verweigert.");
        return false;
      }
      return true;
    }

    // Galerie (robust):
    try {
      if (Platform.isAndroid) {
        final p = await Permission.photos.request();
        if (p.isGranted) return true;

        final s = await Permission.storage.request();
        if (!s.isGranted) {
          _showSnack("Zugriff auf Fotos wurde verweigert.");
          return false;
        }
        return true;
      } else {
        final status = await Permission.photos.request();
        if (!status.isGranted) {
          _showSnack("Zugriff auf Fotos wurde verweigert.");
          return false;
        }
        return true;
      }
    } catch (_) {
      final s = await Permission.storage.request();
      if (!s.isGranted) {
        _showSnack("Zugriff auf Fotos wurde verweigert.");
        return false;
      }
      return true;
    }
  }

  Future<void> _pickFromSource(ImageSource source) async {
    if (_busyAvatar) return;

    // ✅ Coming soon: komplette Avatar-Funktion deaktiviert (kein Picker/Permissions/Upload)
    if (_avatarComingSoon) {
      _showSnack("Profilbild: Coming soon");
      return;
    }

    final okPerm = await _ensurePermissionForSource(source);
    if (!okPerm) return;

    XFile? image;
    try {
      image = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 900,
      );
    } catch (e) {
      _showSnack("Bild wählen fehlgeschlagen: $e");
      return;
    }

    if (image == null) return;

    if (_docId.isEmpty) {
      _showSnack("Dokument nicht gefunden. Bitte neu einloggen.");
      return;
    }

    // ✅ FIX: sicherstellen, dass wir in Firebase auth sind (Storage Rules)
    final fbUser = await _ensureFirebaseUser(context);
    if (fbUser == null) return;

    if (!mounted) return;
    setState(() => _busyAvatar = true);

    final file = File(image.path);

    try {
      // Cache-busting: immer neuer Dateiname
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseStorage.instance
          .ref()
          .child('avatars')
          .child('$_docId-$ts.jpg');

      await ref.putFile(
        file,
        SettableMetadata(contentType: 'image/jpeg'),
      );

      final url = await ref.getDownloadURL();

      if (!mounted) return;
      setState(() => _avatar = url);

      // Firestore + Prefs speichern (URL)
      await _updateFirestoreField("avatarUrl", url);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('avatar', url);

      _showSnack("Profilbild aktualisiert.");
    } on FirebaseException catch (e) {
      _showSnack("Upload fehlgeschlagen: ${e.code}");
    } catch (e) {
      _showSnack("Upload fehlgeschlagen: $e");
    } finally {
      if (mounted) setState(() => _busyAvatar = false);
    }
  }

  Future<void> _pickAvatar() async {
    // ✅ Coming soon: BottomSheet gar nicht mehr öffnen
    if (_avatarComingSoon) {
      _showSnack("Profilbild: Coming soon");
      return;
    }

    await showModalBottomSheet(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Text(
                  "Profilbild auswählen",
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library, color: _accent),
                title: const Text(
                  "Aus Galerie wählen",
                  style: TextStyle(color: _textPrimary),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickFromSource(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera, color: _accent),
                title: const Text(
                  "Foto aufnehmen",
                  style: TextStyle(color: _textPrimary),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickFromSource(ImageSource.camera);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // ---------- Username / Passwort ----------
  Future<void> _saveUsername() async {
    final newUsername = _usernameController.text.trim();
    if (newUsername.isEmpty) {
      _showSnack("Username darf nicht leer sein.");
      return;
    }

    if (newUsername == _username) {
      if (!mounted) return;
      setState(() => _editingUsername = false);
      return;
    }

    if (_docId.isEmpty) {
      _showSnack("Dokument nicht gefunden.");
      return;
    }

    final lower = newUsername.toLowerCase();

    // ✅ dup-check in der AKTUELLEN Collection (users ODER bars)
    final dup = await _col
        .where("username_lower", isEqualTo: lower)
        .limit(1)
        .get();

    if (dup.docs.isNotEmpty && dup.docs.first.id != _docId) {
      _showSnack("Dieser Username ist bereits vergeben.");
      return;
    }

    await _col.doc(_docId).update({
      "username": newUsername,
      "username_lower": lower,
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', newUsername);
    await prefs.setString('currentUsername', newUsername);

    if (!mounted) return;
    setState(() {
      _username = newUsername;
      _editingUsername = false;
    });

    _showSnack("Username erfolgreich geändert.");
  }

  Future<void> _savePassword() async {
    final current = _currentPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    if (newPass.isEmpty) {
      _showSnack("Neues Passwort darf nicht leer sein.");
      return;
    }

    if (_docId.isEmpty) {
      _showSnack("Dokument nicht gefunden.");
      return;
    }

    final snap = await _col.doc(_docId).get();
    final data = snap.data();
    final pwInDb = (data?['password'] ?? '').toString();

    if (current != pwInDb) {
      _showSnack("Aktuelles Passwort ist falsch.");
      return;
    }

    await _updateFirestoreField("password", newPass);

    if (!mounted) return;
    setState(() {
      _editingPassword = false;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _passwordFromDb = newPass;
    });

    _showSnack("Passwort erfolgreich geändert.");
  }

  // ---------- Logout / Account löschen ----------
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text(
          "Logout bestätigen",
          style: TextStyle(color: AppColors.text),
        ),
        content: const Text(
          "Willst du dich wirklich ausloggen?",
          style: TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: AppColors.success)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
            (route) => false,
      );
    }
  }

  Future<void> _deleteAccount() async {
    final confirm1 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text(
          "Account löschen",
          style: TextStyle(color: AppColors.text),
        ),
        content: const Text(
          "Bist du sicher, dass du deinen Account löschen willst?",
          style: TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Nein", style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );

    if (confirm1 != true) return;

    final confirm2 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text(
          "Letzte Warnung",
          style: TextStyle(color: AppColors.accent),
        ),
        content: const Text(
          "Dieser Vorgang ist endgültig und alle Daten werden gelöscht. Willst du wirklich fortfahren?",
          style: TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              "Ja, löschen",
              style: TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );

    if (confirm2 == true && _docId.isNotEmpty) {
      await _col.doc(_docId).delete();

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      if (context.mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
              (route) => false,
        );
      }
    }
  }

  void _showSnack(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color ?? AppColors.panel,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: _accent),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.fullBr,
            border: Border.all(color: AppColors.accentBorder2, width: 1),
          ),
          child: Text(
            Lang.t('profile_header'),
            style: const TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
            ),
          ),
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
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── Avatar ──────────────────────────────────────
                GestureDetector(
                  onTap: () => _showSnack("Profilbild: Coming soon"),
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white12, width: 2),
                        ),
                        child: CircleAvatar(
                          radius: 46,
                          backgroundColor: _card,
                          backgroundImage: _buildAvatarImageProvider(),
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: _panel,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: Colors.white10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: _busyAvatar
                            ? const SizedBox(
                                width: 12, height: 12,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                              )
                            : const Text("soon", style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _username.isEmpty ? "—" : _username,
                  style: const TextStyle(color: _textPrimary, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                ),
                const SizedBox(height: 28),

                // ── Account-Einstellungen ────────────────────────
                _sectionLabel("Account"),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.accentBorder),
                  ),
                  child: Column(
                    children: [
                      // Username row
                      _settingRow(
                        icon: Icons.person_outline_rounded,
                        label: "Username",
                        editing: _editingUsername,
                        displayValue: _usernameController.text.isEmpty ? "Nicht gesetzt" : _usernameController.text,
                        editChild: _inputField(
                          controller: _usernameController,
                          hint: "Neuer Username",
                        ),
                        onEdit: () => setState(() => _editingUsername = true),
                        onSave: _saveUsername,
                        onCancel: () => setState(() {
                          _editingUsername = false;
                          _usernameController.text = _username;
                        }),
                      ),
                      const Divider(height: 1, color: Color(0xFF2A2D35)),
                      // Password row
                      _settingRow(
                        icon: Icons.lock_outline_rounded,
                        label: "Passwort",
                        editing: _editingPassword,
                        displayValue: "••••••••",
                        editChild: Column(
                          children: [
                            _inputField(controller: _currentPasswordController, hint: "Aktuelles Passwort", obscure: true),
                            const SizedBox(height: 10),
                            _inputField(controller: _newPasswordController, hint: "Neues Passwort", obscure: true),
                          ],
                        ),
                        onEdit: () => setState(() => _editingPassword = true),
                        onSave: _savePassword,
                        onCancel: () => setState(() {
                          _editingPassword = false;
                          _currentPasswordController.clear();
                          _newPasswordController.clear();
                        }),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // ── Logout ────────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text("Abmelden", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // ── Account löschen ───────────────────────────────
                TextButton.icon(
                  onPressed: _deleteAccount,
                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                  label: const Text("Account löschen", style: TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ImageProvider _buildAvatarImageProvider() {
    final avatar = _avatar;
    if (avatar == null || avatar.trim().isEmpty) {
      return const AssetImage('lib/Pics/profile_pic.png');
    }
    if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
      return NetworkImage(avatar);
    }
    if (File(avatar).existsSync()) {
      return FileImage(File(avatar));
    }
    return const AssetImage('lib/Pics/profile_pic.png');
  }

  static Widget _sectionLabel(String label) => Align(
    alignment: Alignment.centerLeft,
    child: Text(label, style: const TextStyle(color: _textSecondary, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: .6)),
  );

  static Widget _inputField({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
  }) =>
      TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: _textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: _textSecondary, fontSize: 14),
          filled: true,
          fillColor: Color(0xFF0E0F12),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A2D35)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A2D35)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent, width: 1.5),
          ),
        ),
      );

  Widget _settingRow({
    required IconData icon,
    required String label,
    required bool editing,
    required String displayValue,
    required Widget editChild,
    required VoidCallback onEdit,
    required VoidCallback onSave,
    required VoidCallback onCancel,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: _accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: .4)),
                    const SizedBox(height: 2),
                    if (!editing)
                      Text(displayValue, style: const TextStyle(color: _textPrimary, fontSize: 14, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              if (!editing)
                GestureDetector(
                  onTap: onEdit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _accent.withAlpha(20),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _accent.withAlpha(60)),
                    ),
                    child: const Text("Ändern", style: TextStyle(color: _accent, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
          if (editing) ...[
            const SizedBox(height: 12),
            editChild,
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: _textSecondary, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
                  child: const Text("Abbrechen", style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onSave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    elevation: 0,
                  ),
                  child: const Text("Speichern", style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
