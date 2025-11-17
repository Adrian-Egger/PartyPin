import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';

import '../Screens/login_screen.dart';

// ---------- Farben wie bei PartyMap / NewParty ----------
const _gradTop = Color(0xFF0E0F12);
const _gradBottom = Color(0xFF141A22);
const _panel = Color(0xFF15171C);
const _panelBorder = Color(0xFF2A2F38);
const _card = Color(0xFF1C1F26);
const _textPrimary = Colors.white;
const _textSecondary = Color(0xFFB6BDC8);
const _accent = Color(0xFFFF3B30); // Rot
const _secondary = Color(0xFF00C2A8); // Türkis, falls du es wo brauchst

class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  String _docId = "";
  String _username = "";
  String? _avatarPath;
  String _password = "";

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _currentPasswordController =
  TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();

  bool _editingUsername = false;
  bool _editingPassword = false;

  final ImagePicker _picker = ImagePicker();

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
    final username = prefs.getString('username') ?? "";
    final avatar = prefs.getString('avatar');
    final password = prefs.getString('password') ?? "";

    setState(() {
      _usernameController.text = username;
      _username = username;
      _avatarPath = avatar;
      _password = password;
    });

    if (username.isNotEmpty) {
      final query = await FirebaseFirestore.instance
          .collection("users")
          .where("username", isEqualTo: username)
          .get();

      if (query.docs.isNotEmpty) {
        final doc = query.docs.first;
        setState(() {
          _docId = doc.id;
          _usernameController.text = doc["username"];
          _username = doc["username"];
          _avatarPath =
          doc.data().containsKey("avatar") ? doc["avatar"] : avatar;
          _password =
          doc.data().containsKey("password") ? doc["password"] : password;
        });
      }
    }
  }

  Future<void> _updateFirestoreField(String field, String value) async {
    if (_docId.isEmpty) return;

    await FirebaseFirestore.instance
        .collection("users")
        .doc(_docId)
        .update({field: value});

    final prefs = await SharedPreferences.getInstance();
    if (field == "username") await prefs.setString('username', value);
    if (field == "avatar") await prefs.setString('avatar', value);
    if (field == "password") await prefs.setString('password', value);
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
    } else {
      PermissionStatus status;
      if (Platform.isIOS) {
        status = await Permission.photos.request();
      } else {
        status = await Permission.storage.request();
      }

      if (!status.isGranted) {
        _showSnack("Zugriff auf Fotos wurde verweigert.");
        return false;
      }
      return true;
    }
  }

  Future<void> _pickFromSource(ImageSource source) async {
    final ok = await _ensurePermissionForSource(source);
    if (!ok) return;

    final XFile? image = await _picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 900,
    );

    if (image != null) {
      setState(() {
        _avatarPath = image.path;
      });
      await _updateFirestoreField("avatar", image.path);
      _showSnack("Profilbild aktualisiert.");
    }
  }

  Future<void> _pickAvatar() async {
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
    if (newUsername.isEmpty) return;

    await _updateFirestoreField("username", newUsername);
    setState(() {
      _username = newUsername;
      _editingUsername = false;
    });

    _showSnack("Username erfolgreich geändert.");
  }

  Future<void> _savePassword() async {
    final current = _currentPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    if (current != _password) {
      _showSnack("Aktuelles Passwort ist falsch.");
      return;
    }

    if (newPass.isEmpty) return;

    await _updateFirestoreField("password", newPass);
    setState(() {
      _editingPassword = false;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _password = newPass;
    });

    _showSnack("Passwort erfolgreich geändert.");
  }

  // ---------- Logout / Account löschen ----------

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          "Logout bestätigen",
          style: TextStyle(color: _textPrimary),
        ),
        content: const Text(
          "Willst du dich wirklich ausloggen?",
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: _textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: _accent)),
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
        backgroundColor: _panel,
        title: const Text(
          "Account löschen",
          style: TextStyle(color: _textPrimary),
        ),
        content: const Text(
          "Bist du sicher, dass du deinen Account löschen willst?",
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Nein", style: TextStyle(color: _textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: _accent)),
          ),
        ],
      ),
    );

    if (confirm1 != true) return;

    final confirm2 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          "Letzte Warnung",
          style: TextStyle(color: _accent),
        ),
        content: const Text(
          "Dieser Vorgang ist endgültig und alle Daten werden gelöscht. "
              "Willst du wirklich fortfahren?",
          style: TextStyle(color: _textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: _textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              "Ja, löschen",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm2 == true && _docId.isNotEmpty) {
      await FirebaseFirestore.instance.collection("users").doc(_docId).delete();

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

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _gradTop,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0B0D), // etwas dunkler als _gradTop
        elevation: 0.5,
        centerTitle: true,
        title: const Text(
          "Profil",
          style: TextStyle(
            color: _textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        iconTheme: const IconThemeData(color: _accent),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [_gradTop, _gradBottom], // 2-farbiger Hintergrund
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          top: false, // AppBar kümmert sich oben um den Hintergrund
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _pickAvatar,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      // Einfarbig roter Ring um das Profilbild
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent,
                        ),
                        child: CircleAvatar(
                          radius: 50,
                          backgroundColor: _card,
                          backgroundImage: _avatarPath != null
                              ? FileImage(File(_avatarPath!))
                              : const AssetImage('lib/Pics/profile_pic.png')
                          as ImageProvider,
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent,
                          border: Border.all(color: _panel, width: 2),
                        ),
                        padding: const EdgeInsets.all(4),
                        child: const Icon(
                          Icons.edit,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Username
                _profileCard(
                  icon: Icons.person,
                  title: "Username",
                  child: !_editingUsername
                      ? Text(
                    _usernameController.text.isEmpty
                        ? "Kein Username gespeichert"
                        : _usernameController.text,
                    style: const TextStyle(color: _textPrimary),
                  )
                      : TextField(
                    controller: _usernameController,
                    style: const TextStyle(color: _textPrimary),
                    decoration: const InputDecoration(
                      border: UnderlineInputBorder(),
                      hintText: "Neuer Username",
                      hintStyle: TextStyle(color: _textSecondary),
                    ),
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      _editingUsername ? Icons.check : Icons.edit,
                      color: _accent,
                    ),
                    onPressed: () {
                      if (_editingUsername) {
                        _saveUsername();
                      } else {
                        setState(() {
                          _editingUsername = true;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),

                // Passwort
                _profileCard(
                  icon: Icons.lock,
                  title: "Passwort",
                  child: !_editingPassword
                      ? const Text(
                    "********",
                    style: TextStyle(color: _textPrimary),
                  )
                      : Column(
                    children: [
                      TextField(
                        controller: _currentPasswordController,
                        obscureText: true,
                        style: const TextStyle(color: _textPrimary),
                        decoration: const InputDecoration(
                          border: UnderlineInputBorder(),
                          hintText: "Aktuelles Passwort",
                          hintStyle: TextStyle(color: _textSecondary),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _newPasswordController,
                        obscureText: true,
                        style: const TextStyle(color: _textPrimary),
                        decoration: const InputDecoration(
                          border: UnderlineInputBorder(),
                          hintText: "Neues Passwort",
                          hintStyle: TextStyle(color: _textSecondary),
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      _editingPassword ? Icons.check : Icons.edit,
                      color: _accent,
                    ),
                    onPressed: () {
                      if (_editingPassword) {
                        _savePassword();
                      } else {
                        setState(() {
                          _editingPassword = true;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 30),

                // Logout
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout),
                    label: const Text("Logout"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Account löschen
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _deleteAccount,
                    icon: const Icon(Icons.delete_forever, color: _accent),
                    label: const Text(
                      "Account löschen",
                      style: TextStyle(color: _accent),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _accent, width: 1.5),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
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

  Widget _profileCard({
    required IconData icon,
    required String title,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _panelBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                child,
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}
