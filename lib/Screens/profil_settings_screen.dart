import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:permission_handler/permission_handler.dart';
import '../Screens/login_screen.dart';

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
          doc.data().containsKey("avatar") ? doc["avatar"] : null;
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

  Future<void> _pickAvatar() async {
    PermissionStatus status = await Permission.photos.request();
    if (!status.isGranted) return;

    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _avatarPath = image.path;
      });
      await _updateFirestoreField("avatar", image.path);
    }
  }

  Future<void> _saveUsername() async {
    final newUsername = _usernameController.text.trim();
    if (newUsername.isEmpty) return;

    await _updateFirestoreField("username", newUsername);
    setState(() {
      _username = newUsername;
      _editingUsername = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Username erfolgreich geändert!")),
    );
  }

  Future<void> _savePassword() async {
    final current = _currentPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    if (current != _password) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Aktuelles Passwort ist falsch!")),
      );
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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Passwort erfolgreich geändert!")),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text("Logout bestätigen",
            style: TextStyle(color: Colors.white)),
        content: const Text("Willst du dich wirklich ausloggen?",
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
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
        backgroundColor: Colors.black,
        title:
        const Text("Account löschen", style: TextStyle(color: Colors.white)),
        content: const Text("Bist du sicher, dass du deinen Account löschen willst?",
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Nein", style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm1 != true) return;

    final confirm2 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text("Letzte Warnung", style: TextStyle(color: Colors.red)),
        content: const Text(
          "Dieser Vorgang ist endgültig und alle Daten werden gelöscht. "
              "Willst du wirklich fortfahren?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Abbrechen", style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Ja, löschen", style: TextStyle(color: Colors.red)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        centerTitle: true,
        title: const Text(
          "Profil",
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.red),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            GestureDetector(
              onTap: _pickAvatar,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundImage: _avatarPath != null
                        ? FileImage(File(_avatarPath!))
                        : const AssetImage('lib/Pics/profile_pic.png')
                    as ImageProvider,
                    backgroundColor: Colors.grey[800],
                  ),
                  Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.red,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(
                      Icons.edit,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Username
            Card(
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: const Icon(Icons.person, color: Colors.red),
                title: !_editingUsername
                    ? Text(
                  _usernameController.text.isEmpty
                      ? "Kein Username gespeichert"
                      : _usernameController.text,
                  style: const TextStyle(color: Colors.white),
                )
                    : TextField(
                  controller: _usernameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    border: UnderlineInputBorder(),
                    hintText: "Neuer Username",
                    hintStyle: TextStyle(color: Colors.white54),
                  ),
                ),
                trailing: IconButton(
                  icon: Icon(
                    _editingUsername ? Icons.check : Icons.edit,
                    color: Colors.red,
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
            ),
            const SizedBox(height: 10),

            // Passwort
            Card(
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                leading: const Icon(Icons.lock, color: Colors.red),
                title: !_editingPassword
                    ? const Text("********",
                    style: TextStyle(color: Colors.white))
                    : Column(
                  children: [
                    TextField(
                      controller: _currentPasswordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        border: UnderlineInputBorder(),
                        hintText: "Aktuelles Passwort",
                        hintStyle: TextStyle(color: Colors.white54),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _newPasswordController,
                      obscureText: true,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        border: UnderlineInputBorder(),
                        hintText: "Neues Passwort",
                        hintStyle: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ],
                ),
                trailing: IconButton(
                  icon: Icon(
                    _editingPassword ? Icons.check : Icons.edit,
                    color: Colors.red,
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
            ),
            const SizedBox(height: 30),

            // Logout Button
            ElevatedButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout, color: Colors.white),
              label: const Text("Logout"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding:
                const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 15),

            // Account löschen Button
            ElevatedButton.icon(
              onPressed: _deleteAccount,
              icon: const Icon(Icons.delete_forever, color: Colors.white),
              label: const Text("Account löschen"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[900],
                foregroundColor: Colors.white,
                padding:
                const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Colors.red, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
