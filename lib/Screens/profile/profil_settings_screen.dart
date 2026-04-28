
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ anonymous auth (Storage)
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String _bio = "";
  String _passwordFromDb = "";

  // ✅ users vs bars
  String _collection = "users";
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection(_collection);

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _currentPasswordController =
  TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();

  // null = nothing open; 'username' | 'bio' | 'password'
  String? _editing;

  bool _busyAvatar = false;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
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
      final bio = (data['bio'] ?? '').toString();

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
        _bio = bio;
        _bioController.text = bio;
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
      _showSnack('${Lang.t('profile_firebase_fail')}: $e', color: Colors.redAccent);
      return null;
    }
  }

  // ---------- Avatar / Foto ----------
  Future<bool> _ensureCameraPermission() async {
    // Check current status WITHOUT triggering a request first.
    // On iOS: .notDetermined → isDenied, .denied → isPermanentlyDenied
    var status = await Permission.camera.status;

    if (status.isGranted) return true;

    // Screen Time / MDM restriction — can't change from within the app
    if (status.isRestricted) {
      if (mounted) _showSnack(Lang.t('profile_cam_restricted'), color: Colors.redAccent);
      return false;
    }

    // Already permanently denied — go straight to settings
    if (status.isPermanentlyDenied) {
      _showPermissionSettingsDialog(Lang.t('perm_camera'));
      return false;
    }

    // Not yet asked (isDenied = notDetermined on iOS) — show the native dialog
    status = await Permission.camera.request();

    if (status.isGranted) return true;

    // After the dialog: still not granted → guide to settings
    _showPermissionSettingsDialog(Lang.t('perm_camera'));
    return false;
  }

  void _showPermissionSettingsDialog(String permissionName) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          '$permissionName${Lang.t('perm_access_denied')}',
          style: const TextStyle(color: AppColors.text, fontWeight: FontWeight.w700),
        ),
        content: Text(
          Platform.isIOS
              ? '${Lang.t('perm_ios_instruction')}$permissionName'
              : Lang.t('perm_android_instruction'),
          style: const TextStyle(color: AppColors.muted, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(Lang.t('cancel'), style: const TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: Text(Lang.t('perm_open_settings')),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFromSource(ImageSource source) async {
    if (_busyAvatar) return;

    if (source == ImageSource.camera) {
      final ok = await _ensureCameraPermission();
      if (!ok) return;
    }

    XFile? image;
    try {
      image = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 900,
      );
    } catch (e) {
      if (!mounted) return;
      // Only show the Fotos-dialog for gallery errors, not for camera failures
      if (source == ImageSource.gallery) {
        _showPermissionSettingsDialog(Lang.t('perm_photos'));
      } else {
        _showSnack(Lang.t('profile_cam_unavailable'), color: Colors.redAccent);
      }
      return;
    }

    if (image == null) return;

    if (_docId.isEmpty) {
      _showSnack(Lang.t('profile_doc_not_found'), color: Colors.redAccent);
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

      _showSnack(Lang.t('profile_updated'), color: AppColors.success);
    } on FirebaseException catch (e) {
      _showSnack('${Lang.t('profile_upload_failed')}: ${e.code}', color: Colors.redAccent);
    } catch (e) {
      _showSnack('${Lang.t('profile_upload_failed')}: $e', color: Colors.redAccent);
    } finally {
      if (mounted) setState(() => _busyAvatar = false);
    }
  }


  // ---------- Username / Passwort ----------
  Future<void> _saveUsername() async {
    final newUsername = _usernameController.text.trim();
    if (newUsername.isEmpty) {
      _showSnack(Lang.t('profile_username_empty'), color: Colors.redAccent);
      return;
    }

    if (newUsername == _username) {
      if (!mounted) return;
      setState(() => _editing = null);
      return;
    }

    if (_docId.isEmpty) {
      _showSnack(Lang.t('profile_doc_not_found_short'), color: Colors.redAccent);
      return;
    }

    final lower = newUsername.toLowerCase();

    // ✅ dup-check in der AKTUELLEN Collection (users ODER bars)
    final dup = await _col
        .where("username_lower", isEqualTo: lower)
        .limit(1)
        .get();

    if (dup.docs.isNotEmpty && dup.docs.first.id != _docId) {
      _showSnack(Lang.t('profile_username_taken'), color: Colors.redAccent);
      return;
    }

    final oldUsername = _username;

    await _col.doc(_docId).update({
      "username": newUsername,
      "username_lower": lower,
    });

    await _migrateUsernameReferences(oldUsername, newUsername);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', newUsername);
    await prefs.setString('currentUsername', newUsername);

    if (!mounted) return;
    setState(() {
      _username = newUsername;
      _editing = null;
    });

    _showSnack(Lang.t('profile_username_saved'), color: AppColors.success);
  }

  Future<void> _migrateUsernameReferences(
      String oldName, String newName) async {
    final db = FirebaseFirestore.instance;

    // ── Chats: members-Array + dynamische Felder aktualisieren ──
    final chatSnaps = await db
        .collection('chats')
        .where('members', arrayContains: oldName)
        .get();

    for (final chatDoc in chatSnaps.docs) {
      final d = chatDoc.data();
      final members = List<String>.from(d['members'] ?? []);
      final newMembers =
          members.map((m) => m == oldName ? newName : m).toList();

      final update = <String, dynamic>{'members': newMembers};

      if (d.containsKey('unread_$oldName')) {
        update['unread_$newName'] = d['unread_$oldName'];
        update['unread_$oldName'] = FieldValue.delete();
      }
      if (d.containsKey('lastRead_$oldName')) {
        update['lastRead_$newName'] = d['lastRead_$oldName'];
        update['lastRead_$oldName'] = FieldValue.delete();
      }
      if (d['lastFrom'] == oldName) {
        update['lastFrom'] = newName;
      }

      await chatDoc.reference.update(update);
    }

    // ── Friendships: Doc-ID ist sortierter Username-Pair → neu erstellen ──
    final shipSnaps = await db
        .collection('friendships')
        .where('members', arrayContains: oldName)
        .get();

    for (final shipDoc in shipSnaps.docs) {
      final d = shipDoc.data();
      final members = List<String>.from(d['members'] ?? []);
      final newMembers =
          members.map((m) => m == oldName ? newName : m).toList();
      final newId = (List<String>.from(newMembers)..sort()).join('__');

      final batch = db.batch();
      batch.set(
          db.collection('friendships').doc(newId), {...d, 'members': newMembers});
      batch.delete(shipDoc.reference);
      await batch.commit();
    }

    // ── FriendRequests: from-Seite ──
    final fromSnaps = await db
        .collection('friendRequests')
        .where('from', isEqualTo: oldName)
        .get();

    for (final reqDoc in fromSnaps.docs) {
      final d = reqDoc.data();
      final to = (d['to'] as String?) ?? '';
      final batch = db.batch();
      batch.set(db.collection('friendRequests').doc('${newName}__$to'),
          {...d, 'from': newName});
      batch.delete(reqDoc.reference);
      await batch.commit();
    }

    // ── FCM-Token-Doc (users/{username} als Doc-ID) ──────────
    final tokenSnap =
        await db.collection('users').doc(oldName).get();
    if (tokenSnap.exists) {
      final batch = db.batch();
      batch.set(db.collection('users').doc(newName),
          tokenSnap.data() ?? {});
      batch.delete(tokenSnap.reference);
      await batch.commit();
    }

    // ── FriendRequests: to-Seite ──
    final toSnaps = await db
        .collection('friendRequests')
        .where('to', isEqualTo: oldName)
        .get();

    for (final reqDoc in toSnaps.docs) {
      final d = reqDoc.data();
      final from = (d['from'] as String?) ?? '';
      final batch = db.batch();
      batch.set(db.collection('friendRequests').doc('${from}__$newName'),
          {...d, 'to': newName});
      batch.delete(reqDoc.reference);
      await batch.commit();
    }
  }

  static String _hashPassword(String username, String password) {
    final key = utf8.encode(username.toLowerCase());
    final bytes = utf8.encode(password);
    return Hmac(sha256, key).convert(bytes).toString();
  }

  Future<void> _savePassword() async {
    final current = _currentPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    if (newPass.isEmpty) {
      _showSnack(Lang.t('profile_password_empty'), color: Colors.redAccent);
      return;
    }
    if (_docId.isEmpty) {
      _showSnack(Lang.t('profile_doc_not_found_short'), color: Colors.redAccent);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '').trim();

    final snap = await _col.doc(_docId).get();
    final data = snap.data();
    final storedHash  = (data?['passwordHash'] ?? '').toString();
    final storedPlain = (data?['password']     ?? '').toString();
    final currentHash = _hashPassword(username, current);

    final verified = (storedHash.isNotEmpty && storedHash == currentHash) ||
                     (storedPlain.isNotEmpty && storedPlain == current);

    if (!verified) {
      _showSnack(Lang.t('profile_password_wrong'), color: Colors.redAccent);
      return;
    }

    final newHash = _hashPassword(username, newPass);
    await _col.doc(_docId).update({
      'passwordHash': newHash,
      'password': FieldValue.delete(),
    });

    if (!mounted) return;
    setState(() {
      _editing = null;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _passwordFromDb = '';
    });

    _showSnack(Lang.t('profile_password_saved'), color: AppColors.success);
  }

  // ---------- Logout / Account löschen ----------
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          Lang.t('profile_logout_title'),
          style: const TextStyle(color: AppColors.text),
        ),
        content: Text(
          Lang.t('profile_logout_msg'),
          style: const TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Lang.t('cancel'), style: const TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(Lang.t('yes'), style: const TextStyle(color: AppColors.success)),
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
        title: Text(
          Lang.t('profile_delete_title'),
          style: const TextStyle(color: AppColors.text),
        ),
        content: Text(
          Lang.t('profile_delete_msg'),
          style: const TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Lang.t('cancel'), style: const TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(Lang.t('yes'), style: const TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );

    if (confirm1 != true) return;

    final confirm2 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: Text(
          Lang.t('profile_delete_title2'),
          style: const TextStyle(color: AppColors.accent),
        ),
        content: Text(
          Lang.t('profile_delete_msg2'),
          style: const TextStyle(color: AppColors.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(Lang.t('cancel'), style: const TextStyle(color: AppColors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              Lang.t('profile_delete_confirm'),
              style: const TextStyle(color: AppColors.accent),
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

  Future<void> _saveBio() async {
    final newBio = _bioController.text.trim();
    if (_docId.isNotEmpty) {
      await _updateFirestoreField('bio', newBio);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bio', newBio);
    if (!mounted) return;
    setState(() {
      _bio = newBio;
      _editing = null;
    });
    _showSnack(Lang.t('profile_bio_saved'), color: AppColors.success);
  }

  void _viewProfilePicture() {
    final url = _avatar;
    if (url == null || url.isEmpty) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => _FullscreenAvatarPage(imageUrl: url),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  Future<void> _showAvatarOptions() async {
    final hasAvatar = _avatar != null && _avatar!.isNotEmpty;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  Lang.t('profile_avatar_title'),
                  style: const TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              const Divider(height: 1, color: Color(0xFF2A2D35)),
              _avatarOption(
                ctx: ctx,
                icon: Icons.photo_library_outlined,
                label: Lang.t('profile_avatar_gallery'),
                onTap: () => _pickFromSource(ImageSource.gallery),
              ),
              const Divider(height: 1, indent: 56, color: Color(0xFF2A2D35)),
              _avatarOption(
                ctx: ctx,
                icon: Icons.photo_camera_outlined,
                label: Lang.t('profile_avatar_camera'),
                onTap: () => _pickFromSource(ImageSource.camera),
              ),
              if (hasAvatar) ...[
                const Divider(height: 1, indent: 56, color: Color(0xFF2A2D35)),
                _avatarOption(
                  ctx: ctx,
                  icon: Icons.image_search_outlined,
                  label: Lang.t('profile_avatar_view'),
                  onTap: _viewProfilePicture,
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _avatarOption({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _accent.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: _accent, size: 19),
            ),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(
                color: _textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
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
                  onTap: _busyAvatar ? null : _showAvatarOptions,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [_accent, const Color(0xFF7B2FF7)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: CircleAvatar(
                          radius: 46,
                          backgroundColor: _card,
                          backgroundImage: _buildAvatarImageProvider(),
                          child: _buildAvatarImageProvider() == null
                              ? const Icon(Icons.person, color: Colors.white38, size: 40)
                              : null,
                        ),
                      ),
                      if (_busyAvatar)
                        const SizedBox(
                          width: 30, height: 30,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
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
                _sectionLabel(Lang.t('profile_section_account')),
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
                        label: Lang.t('profile_username_label'),
                        editing: _editing == 'username',
                        displayValue: _usernameController.text.isEmpty ? Lang.t('profile_username_not_set') : _usernameController.text,
                        editChild: _inputField(
                          controller: _usernameController,
                          hint: Lang.t('profile_username_hint'),
                        ),
                        onEdit: () => setState(() => _editing = 'username'),
                        onSave: _saveUsername,
                        onCancel: () => setState(() {
                          _editing = null;
                          _usernameController.text = _username;
                        }),
                      ),
                      const Divider(height: 1, color: Color(0xFF2A2D35)),
                      // Password row
                      _settingRow(
                        icon: Icons.lock_outline_rounded,
                        label: Lang.t('profile_password_label'),
                        editing: _editing == 'password',
                        displayValue: "••••••••",
                        editChild: Column(
                          children: [
                            _inputField(controller: _currentPasswordController, hint: Lang.t('profile_password_current'), obscure: true),
                            const SizedBox(height: 10),
                            _inputField(controller: _newPasswordController, hint: Lang.t('profile_password_new'), obscure: true),
                          ],
                        ),
                        onEdit: () => setState(() => _editing = 'password'),
                        onSave: _savePassword,
                        onCancel: () => setState(() {
                          _editing = null;
                          _currentPasswordController.clear();
                          _newPasswordController.clear();
                        }),
                      ),
                      const Divider(height: 1, color: Color(0xFF2A2D35)),
                      // Bio row
                      _settingRow(
                        icon: Icons.edit_note_rounded,
                        label: Lang.t('profile_bio_label'),
                        editing: _editing == 'bio',
                        displayValue: _bio.isEmpty ? Lang.t('profile_bio_none') : _bio,
                        editChild: TextField(
                          controller: _bioController,
                          maxLength: 80,
                          maxLengthEnforcement: MaxLengthEnforcement.truncateAfterCompositionEnds,
                          style: const TextStyle(color: _textPrimary, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: Lang.t('profile_bio_hint'),
                            hintStyle: const TextStyle(color: _textSecondary, fontSize: 14),
                            counterStyle: const TextStyle(color: _textSecondary, fontSize: 11),
                            filled: true,
                            fillColor: const Color(0xFF0E0F12),
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
                        ),
                        onEdit: () => setState(() => _editing = 'bio'),
                        onSave: _saveBio,
                        onCancel: () => setState(() {
                          _editing = null;
                          _bioController.text = _bio;
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
                    label: Text(Lang.t('profile_logout_btn'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
                  label: Text(Lang.t('profile_delete_btn'), style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ImageProvider? _buildAvatarImageProvider() {
    final avatar = _avatar;
    if (avatar == null || avatar.trim().isEmpty) return null;
    if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
      return NetworkImage(avatar);
    }
    final f = File(avatar);
    if (f.existsSync()) return FileImage(f);
    return null;
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
    return GestureDetector(
      onTap: editing ? null : onEdit,
      behavior: editing ? HitTestBehavior.deferToChild : HitTestBehavior.opaque,
      child: Padding(
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
                  child: Text(Lang.t('cancel'), style: const TextStyle(fontSize: 13)),
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
                  child: Text(Lang.t('save'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              ],
            ),
          ],
        ],
      ),
    ));
  }
}

class _FullscreenAvatarPage extends StatefulWidget {
  final String imageUrl;
  const _FullscreenAvatarPage({required this.imageUrl});

  @override
  State<_FullscreenAvatarPage> createState() => _FullscreenAvatarPageState();
}

class _FullscreenAvatarPageState extends State<_FullscreenAvatarPage> {
  double _dy = 0;
  double get _bgOpacity => (1.0 - (_dy.abs() / 300)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        onVerticalDragUpdate: (d) => setState(() => _dy += d.delta.dy),
        onVerticalDragEnd: (d) {
          if (_dy.abs() > 100 || (d.primaryVelocity ?? 0).abs() > 500) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dy = 0);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          color: Colors.black.withOpacity(_bgOpacity),
          child: Transform.translate(
            offset: Offset(0, _dy),
            child: Center(
              child: InteractiveViewer(
                child: Image.network(
                  widget.imageUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, color: Colors.white38, size: 60),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
