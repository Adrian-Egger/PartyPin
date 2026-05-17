
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart'; // ✅ anonymous auth (Storage)
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/login_screen.dart';
import '../../Services/auth_service.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';
// FEATURE_DISABLED_TICKETING — StripeService entfernt.
// E-Mail-Verifizierung läuft jetzt über EmailVerifyService.
// see archived/ticketing/README.md
import '../../Services/email_verify_service.dart';

// Auswahl aus dem Avatar-BottomSheet. Wir geben das Ergebnis aus dem
// Sheet zurück (statt direkt eine Aktion auszulösen), damit die
// Dismiss-Animation komplett durchläuft, bevor wir die Kamera oder den
// Photo-Picker öffnen — sonst kollidiert das auf iOS mit dem
// UIImagePickerController-Presenter.
enum _AvatarAction { gallery, camera, view }

// Einheitliches Log-Tag, damit der Avatar-Flow über `flutter logs`
// bzw. Xcode/Android-Studio-Console klar filterbar ist:
//   flutter logs | grep '\[AVATAR\]'
const String _kAvatarTag = '[AVATAR]';

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
  String _email = "";              // hinterlegte Mail (kann unbestätigt sein)
  String _pendingEmail = "";       // wartet auf Klick im Bestätigungslink
  bool _emailVerified = false;     // erst true, wenn emailVerifiedAt gesetzt
  String _passwordFromDb = "";

  // ✅ users vs bars
  String _collection = "users";
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection(_collection);

  // Für User-Docs heißt das Bild `avatarUrl`, für Bar-Docs `profileImageUrl`
  // (Quelle der Wahrheit ist in "Meine Bar"). Wir lesen und schreiben hier
  // einheitlich über diesen Getter — sonst hätten Bars zwei konkurrierende
  // Bildfelder, was zu Drift zwischen "Profil" und "Meine Bar" führt.
  String get _avatarFieldName =>
      _collection == "bars" ? "profileImageUrl" : "avatarUrl";

  bool get _isBarAccount => _collection == "bars";

  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _bioController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _currentPasswordController =
  TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();

  // null = nothing open; 'username' | 'bio' | 'password'
  String? _editing;

  bool _busyAvatar = false;

  // Live-Listener auf das User-Doc — aktualisiert _email / _pendingEmail
  // sofort, wenn die verifyEmailToken-Cloud-Function pendingEmail → email
  // verschiebt (User klickt den Bestätigungslink in der Mail).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userDocSub;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _userDocSub?.cancel();
    _usernameController.dispose();
    _bioController.dispose();
    _emailController.dispose();
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

      // Bars verwenden `profileImageUrl` (gleiches Feld wie "Meine Bar"),
      // damit das Bild zwischen Profil und Bar-Screen synchron bleibt.
      final avatarField =
          collectionName == "bars" ? "profileImageUrl" : "avatarUrl";
      avatarUrl = (data[avatarField] ?? '').toString().trim();
      password = (data['password'] ?? '').toString();
      final bio = (data['bio'] ?? '').toString();
      final email = (data['email'] ?? '').toString().trim();
      final pendingEmail =
          (data['pendingEmail'] ?? '').toString().trim();
      // Verifikation gilt nur, wenn die Cloud Function den Timestamp gesetzt
      // hat. Bar-Accounts kommen z. B. ohne diesen aus dem Wizard.
      final emailVerified = data['emailVerifiedAt'] != null;

      // Mail in Prefs spiegeln, damit andere Screens sie ohne Roundtrip lesen können.
      if (email.isNotEmpty) {
        await prefs.setString('userEmail', email);
      }

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
        _email = email;
        _pendingEmail = pendingEmail;
        _emailVerified = emailVerified;
        _emailController.text = email;
      });
      debugPrint(
          '$_kAvatarTag _loadUserData: collection=$collectionName docId=${doc.id} '
          'avatarUrl(firestore)="${avatarUrl ?? ""}" cachedAvatar="${cachedAvatar ?? ""}" '
          '_avatar="${_avatar ?? ""}"');

      // ✅ merken, damit künftig sofort richtig gesucht wird
      await prefs.setString(
          'accountType', collectionName == "bars" ? "bar" : "user");

      // ✅ Live-Listener aufsetzen — der Bildschirm wird automatisch
      //    aktualisiert, sobald der User den Bestätigungslink in der Mail
      //    klickt (Cloud Function schiebt pendingEmail → email).
      _attachUserDocListener();

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

  /// Live-Stream auf `users/{docId}` (oder `bars/{docId}`). Aktualisiert
  /// `_email` + `_pendingEmail` sofort, wenn der Server die Felder ändert
  /// — typisch: User klickt den Verifikationslink, Cloud Function setzt
  /// `email = pendingEmail` und löscht die `pendingEmail`-Felder.
  ///
  /// Bonus: zeigt einen kurzen Toast, wenn die ausstehende Mail gerade
  /// verifiziert wurde.
  void _attachUserDocListener() {
    _userDocSub?.cancel();
    if (_docId.isEmpty) return;

    _userDocSub = _col.doc(_docId).snapshots().listen((snap) async {
      if (!mounted || !snap.exists) return;
      final data = snap.data() ?? {};
      final newEmail = (data['email'] ?? '').toString().trim();
      final newPending = (data['pendingEmail'] ?? '').toString().trim();
      final newVerified = data['emailVerifiedAt'] != null;
      // Avatar live spiegeln — wenn „Meine Bar" das profileImageUrl
      // wechselt, soll der Profil-Screen das sofort übernehmen (und
      // umgekehrt). Für User-Accounts liest das den `avatarUrl`-Wert.
      final newAvatar =
          (data[_avatarFieldName] ?? '').toString().trim();

      // Übergang von „nicht verifiziert" → „verifiziert" → Feedback geben.
      final justVerified = !_emailVerified && newVerified;

      // Spiegel in SharedPreferences für schnellen Zugriff aus anderen Screens.
      if (newEmail.isNotEmpty && newEmail != _email) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userEmail', newEmail);
      }

      if (!mounted) return;
      setState(() {
        _email = newEmail;
        _pendingEmail = newPending;
        _emailVerified = newVerified;
        if (newAvatar != (_avatar ?? '')) {
          _avatar = newAvatar.isEmpty ? null : newAvatar;
        }
        if (_editing != 'email') {
          _emailController.text = newEmail;
        }
      });

      if (justVerified) {
        _showSnack('E-Mail $newEmail wurde bestätigt ✅',
            color: AppColors.success);
      }
    }, onError: (_) {
      // Listener-Fehler dürfen den Screen nicht crashen.
    });
  }

  Future<void> _updateFirestoreField(String field, dynamic value) async {
    if (_docId.isEmpty) return;
    await _col.doc(_docId).update({field: value});
  }

  // ---------- ✅ FIX: sicherstellen, dass Storage Upload erlaubt ist ----------
  Future<User?> _ensureFirebaseUser(BuildContext context) async {
    final auth = FirebaseAuth.instance;

    if (auth.currentUser != null) {
      debugPrint(
          '$_kAvatarTag _ensureFirebaseUser: existing uid=${auth.currentUser!.uid} anon=${auth.currentUser!.isAnonymous}');
      return auth.currentUser;
    }

    try {
      debugPrint('$_kAvatarTag _ensureFirebaseUser: signInAnonymously()');
      final cred = await auth.signInAnonymously();
      debugPrint(
          '$_kAvatarTag _ensureFirebaseUser: signed in uid=${cred.user?.uid}');
      return cred.user;
    } catch (e, st) {
      debugPrint('$_kAvatarTag _ensureFirebaseUser FAILED: $e\n$st');
      _showSnack('${Lang.t('profile_firebase_fail')}: $e', color: Colors.redAccent);
      return null;
    }
  }

  // ---------- Avatar / Foto ----------
  // Hinweis: KEINE manuelle Camera-Permission-Abfrage mehr.
  // Auf iOS hat permission_handler.Permission.camera.request() vor
  // _picker.pickImage(source: camera) zu einem Race mit dem
  // UIImagePickerController-Permission-Lifecycle geführt — Resultat:
  // "Kamera-Zugriff nicht erlaubt", obwohl die Berechtigung da war.
  // image_picker selbst löst den nativen iOS-Permission-Dialog aus.
  // permission_handler wird unten in _showPermissionSettingsDialog
  // weiterhin für openAppSettings() benutzt (permanente Verweigerung).

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
    if (_busyAvatar) {
      debugPrint('$_kAvatarTag _pickFromSource: ignored, _busyAvatar=true');
      return;
    }

    debugPrint('$_kAvatarTag _pickFromSource start, source=$source');

    // KEINE vorgeschaltete Permission-Abfrage. image_picker triggert den
    // nativen iOS-Permission-Dialog beim ersten Aufruf selbst. Eine
    // PlatformException kommt nur bei permanenter Verweigerung oder
    // Hardware-Restriktion zurück; in dem Fall verweisen wir auf die
    // App-Settings.
    XFile? image;
    try {
      image = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 900,
        // Auf iOS spart das einen zusätzlichen Photo-Library-Permission-
        // Roundtrip über PHPickerViewController.
        requestFullMetadata: false,
      );
    } on PlatformException catch (e, st) {
      debugPrint('$_kAvatarTag pickImage PlatformException code=${e.code} msg=${e.message}\n$st');
      if (!mounted) return;
      final code = e.code.toLowerCase();
      // iOS-Codes: 'camera_access_denied', 'photo_access_denied',
      // 'camera_access_restricted', 'photo_access_restricted'
      if (code.contains('denied') || code.contains('restricted')) {
        _showPermissionSettingsDialog(
          source == ImageSource.camera
              ? Lang.t('perm_camera')
              : Lang.t('perm_photos'),
        );
      } else {
        // z.B. 'camera_access_unknown', iPad-Simulator ohne Kamera, etc.
        _showSnack(
          source == ImageSource.camera
              ? Lang.t('profile_cam_unavailable')
              : Lang.t('profile_cam_unavailable'),
          color: Colors.redAccent,
        );
      }
      return;
    } catch (e, st) {
      debugPrint('$_kAvatarTag pickImage generic error: $e\n$st');
      if (!mounted) return;
      _showSnack(Lang.t('profile_cam_unavailable'), color: Colors.redAccent);
      return;
    }

    if (image == null) {
      debugPrint('$_kAvatarTag pickImage returned null (user cancelled)');
      return;
    }
    debugPrint('$_kAvatarTag picked: ${image.path}');

    if (_docId.isEmpty) {
      debugPrint('$_kAvatarTag abort: _docId is empty');
      _showSnack(Lang.t('profile_doc_not_found'), color: Colors.redAccent);
      return;
    }

    // ✅ FIX: sicherstellen, dass wir in Firebase auth sind (Storage Rules)
    final fbUser = await _ensureFirebaseUser(context);
    if (fbUser == null) {
      debugPrint('$_kAvatarTag abort: ensureFirebaseUser returned null');
      return;
    }
    debugPrint('$_kAvatarTag firebase user uid=${fbUser.uid} anonymous=${fbUser.isAnonymous}');

    if (!mounted) return;
    setState(() => _busyAvatar = true);

    final file = File(image.path);
    final int fileSize = await file.length();
    debugPrint('$_kAvatarTag local file exists=${file.existsSync()} size=$fileSize bytes');

    // Alten Storage-Pfad merken, um ihn NACH erfolgreichem Upload zu löschen.
    // Wir parsen den Pfad aus der derzeit hinterlegten URL — wenn das schief
    // geht, ignorieren wir das (kein Block für den Upload).
    final String? previousStoragePath = _storagePathFromUrl(_avatar);
    debugPrint(
        '$_kAvatarTag previous storage path to delete after upload: $previousStoragePath');

    try {
      // Cache-busting: immer neuer Dateiname
      final ts = DateTime.now().millisecondsSinceEpoch;
      final storagePath = 'avatars/$_docId-$ts.jpg';
      final ref = FirebaseStorage.instance.ref().child(storagePath);
      debugPrint('$_kAvatarTag uploading to bucket=${ref.bucket} path=$storagePath');

      final task = await ref.putFile(
        file,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      debugPrint(
        '$_kAvatarTag upload done: state=${task.state} '
        'bytesTransferred=${task.bytesTransferred}/${task.totalBytes}',
      );

      final url = await ref.getDownloadURL();
      debugPrint('$_kAvatarTag getDownloadURL OK -> $url');

      // Falls Flutter ImageCache eine alte/fehlerhafte Variante derselben
      // URL noch im RAM hat (z. B. nach einem 403), aggressiv rausschmeißen
      // — sonst rendert NetworkImage stumm das alte Failure-Result neu.
      final evicted = await NetworkImage(url).evict();
      debugPrint('$_kAvatarTag imageCache.evict($url) -> $evicted');

      // Zwingen, dass NetworkImage HIER lädt, damit Storage-Read-Fehler
      // (Rules, TLS, Token) im Log sichtbar werden — statt später still
      // im CircleAvatar zu verschwinden.
      if (mounted) {
        try {
          await precacheImage(NetworkImage(url), context);
          debugPrint('$_kAvatarTag precacheImage OK');
        } catch (e, st) {
          debugPrint('$_kAvatarTag precacheImage FAILED: $e\n$st');
          // Wir setzen die URL trotzdem; der errorBuilder im Widget
          // gibt dem User dann ein visuelles Broken-Image-Icon.
        }
      }

      if (!mounted) return;
      setState(() => _avatar = url);
      debugPrint('$_kAvatarTag setState applied, _avatar=$_avatar');

      // Firestore + Prefs speichern. Für Bars landet das Bild auf
      // `profileImageUrl` — selbes Feld wie „Meine Bar", damit Profil
      // und Bar-Detail-Screen denselben Wert sehen.
      await _updateFirestoreField(_avatarFieldName, url);
      debugPrint(
          '$_kAvatarTag Firestore $_collection/$_docId .$_avatarFieldName updated');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('avatar', url);
      debugPrint('$_kAvatarTag SharedPreferences "avatar" cached');

      // Alte Datei aufräumen — erst NACH erfolgreichem Firestore-Write,
      // damit ein Fehler hier nichts kaputtmacht. Wir gucken auch, dass
      // wir uns nicht selbst überschreiben (gleicher Pfad).
      if (previousStoragePath != null && previousStoragePath != storagePath) {
        try {
          await FirebaseStorage.instance
              .ref()
              .child(previousStoragePath)
              .delete();
          debugPrint(
              '$_kAvatarTag deleted previous avatar at $previousStoragePath');
        } on FirebaseException catch (e) {
          // object-not-found ist OK (Datei war schon weg).
          debugPrint(
              '$_kAvatarTag could not delete previous avatar ($previousStoragePath): code=${e.code}');
        } catch (e) {
          debugPrint(
              '$_kAvatarTag could not delete previous avatar ($previousStoragePath): $e');
        }
      }

      _showSnack(Lang.t('profile_updated'), color: AppColors.success);
    } on FirebaseException catch (e, st) {
      debugPrint('$_kAvatarTag FirebaseException code=${e.code} msg=${e.message}\n$st');
      _showSnack('${Lang.t('profile_upload_failed')}: ${e.code}', color: Colors.redAccent);
    } catch (e, st) {
      debugPrint('$_kAvatarTag generic upload failure: $e\n$st');
      _showSnack('${Lang.t('profile_upload_failed')}: $e', color: Colors.redAccent);
    } finally {
      if (mounted) setState(() => _busyAvatar = false);
      debugPrint('$_kAvatarTag flow finished, _busyAvatar=false');
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

  // SECURITY_HARDENING (Audit C1, Session 2026-05-17):
  // _hashPassword wurde entfernt — Hashing + Verifikation + Write
  // passieren server-seitig in functions/auth/changePasswordCallable.js.
  // Damit liest/schreibt der Client KEINEN passwordHash mehr direkt.
  //
  // Voraussetzung: User muss per Custom Token eingeloggt sein
  // (anonymous-Sessions kommen serverseitig nicht durch).

  Future<void> _savePassword() async {
    final current = _currentPasswordController.text.trim();
    final newPass = _newPasswordController.text.trim();

    if (newPass.isEmpty) {
      _showSnack(Lang.t('profile_password_empty'), color: Colors.redAccent);
      return;
    }
    if (current.isEmpty) {
      _showSnack(Lang.t('profile_password_wrong'), color: Colors.redAccent);
      return;
    }

    final err = await AuthService.changePassword(
      currentPassword: current,
      newPassword: newPass,
    );

    if (!mounted) return;

    if (err != null) {
      // Spezialfall: CF meldet falsches Passwort als permission-denied
      // mit unserer Standard-Message — wir mappen das auf die i18n-Key.
      final isWrongPw =
          err.toLowerCase().contains('falsch') ||
          err.toLowerCase().contains('aktuelles passwort');
      _showSnack(
        isWrongPw ? Lang.t('profile_password_wrong') : err,
        color: Colors.redAccent,
      );
      return;
    }

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

  Future<void> _saveEmail() async {
    final newEmail = _emailController.text.trim().toLowerCase();
    if (newEmail.isEmpty ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(newEmail)) {
      _showSnack('Bitte eine gültige E-Mail-Adresse eingeben.',
          color: Colors.redAccent);
      return;
    }

    if (newEmail == _email) {
      if (!mounted) return;
      setState(() => _editing = null);
      return;
    }

    if (_docId.isEmpty) {
      _showSnack(Lang.t('profile_doc_not_found_short'),
          color: Colors.redAccent);
      return;
    }

    // Bestehende Mail bleibt aktiv, bis der Bestätigungslink geklickt wurde.
    try {
      // Anonymen Login sicherstellen (für Cloud Function Auth-Check).
      await _ensureFirebaseUser(context);

      final result = await EmailVerifyService.requestEmailVerification(
        docId: _docId,
        email: newEmail,
        collection: _collection,
      );

      if (!mounted) return;

      if (result['alreadyVerified'] == true) {
        // Mail war schon als verifiziert hinterlegt — nur Prefs syncen.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('userEmail', newEmail);
        setState(() {
          _email = newEmail;
          _pendingEmail = '';
          _editing = null;
        });
        _showSnack('E-Mail bereits bestätigt.', color: AppColors.success);
        return;
      }

      setState(() {
        _pendingEmail = newEmail;
        _editing = null;
        // _email NICHT überschreiben — alte Mail bleibt aktiv.
      });
      _showSnack(
        'Bestätigungs-E-Mail an $newEmail verschickt. Bitte Link klicken.',
        color: AppColors.success,
      );
    } on FirebaseFunctionsException catch (e) {
      String msg;
      switch (e.message) {
        case 'invalid_email_format':
          msg = 'Ungültiges E-Mail-Format.';
          break;
        case 'user_not_found':
          msg = 'Profil nicht gefunden.';
          break;
        case 'send_failed':
          msg = 'Versand fehlgeschlagen — bitte später erneut versuchen.';
          break;
        default:
          msg = e.message ?? e.code;
      }
      if (mounted) _showSnack(msg, color: Colors.redAccent);
    } catch (e) {
      if (mounted) _showSnack('Fehler: $e', color: Colors.redAccent);
    }
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

    // Sheet liefert das Ergebnis zurück — genau EIN Pop pro Tap.
    // useRootNavigator: true sorgt dafür, dass das Sheet am Root-
    // Navigator hängt, nicht an einem ggf. eingebetteten Tab-Navigator;
    // das macht die Dismiss-Animation auf iOS deterministisch.
    final action = await showModalBottomSheet<_AvatarAction>(
      context: context,
      backgroundColor: _panel,
      useRootNavigator: true,
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
                onTap: () => Navigator.pop(ctx, _AvatarAction.gallery),
              ),
              const Divider(height: 1, indent: 56, color: Color(0xFF2A2D35)),
              _avatarOption(
                ctx: ctx,
                icon: Icons.photo_camera_outlined,
                label: Lang.t('profile_avatar_camera'),
                onTap: () => Navigator.pop(ctx, _AvatarAction.camera),
              ),
              if (hasAvatar) ...[
                const Divider(height: 1, indent: 56, color: Color(0xFF2A2D35)),
                _avatarOption(
                  ctx: ctx,
                  icon: Icons.image_search_outlined,
                  label: Lang.t('profile_avatar_view'),
                  onTap: () => Navigator.pop(ctx, _AvatarAction.view),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (!mounted || action == null) return;

    // iOS: einen Render-Frame abwarten, damit das Sheet komplett
    // entfernt ist, bevor UIImagePickerController präsentiert wird.
    if (Platform.isIOS) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
    }

    switch (action) {
      case _AvatarAction.gallery:
        await _pickFromSource(ImageSource.gallery);
        break;
      case _AvatarAction.camera:
        await _pickFromSource(ImageSource.camera);
        break;
      case _AvatarAction.view:
        _viewProfilePicture();
        break;
    }
  }

  Widget _avatarOption({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    // Pop passiert ausschließlich im onTap-Callback des Aufrufers
    // (Navigator.pop(ctx, _AvatarAction.x)). Kein zweiter Pop hier.
    return InkWell(
      onTap: onTap,
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
                // WICHTIG: KEIN `CircleAvatar.backgroundImage` mehr.
                // backgroundImage hat KEINEN errorBuilder — schlägt der
                // NetworkImage-Decode/Download fehl (Storage Rules,
                // abgelaufener Token, TLS, Decode-Fehler), bleibt der
                // Kreis stumm leer. Wir verwenden ClipOval + Image.network
                // mit loadingBuilder/errorBuilder, damit Fehler sichtbar
                // werden und ins Log fließen.
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
                        child: ClipOval(
                          child: Container(
                            width: 92,
                            height: 92,
                            color: _card,
                            child: _buildAvatarWidget(),
                          ),
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
                      const Divider(height: 1, color: Color(0xFF2A2D35)),
                      // E-Mail row (Account-Kontakt-Adresse).
                      // Status-Badge rechts:
                      //   • verifiziert (email vorhanden, pending leer) → grünes ✓
                      //   • pending vorhanden                            → oranges Sanduhr-Icon
                      //   • nichts                                       → kein Badge
                      _settingRow(
                        icon: Icons.alternate_email_rounded,
                        label: 'E-Mail',
                        editing: _editing == 'email',
                        trailing: _emailStatusBadge(),
                        displayValue: _email.isEmpty
                            ? (_pendingEmail.isNotEmpty
                                ? '$_pendingEmail · wartet auf Bestätigung'
                                : 'Keine E-Mail hinterlegt')
                            : (_pendingEmail.isNotEmpty &&
                                    _pendingEmail != _email
                                ? '$_email\n→ neu: $_pendingEmail (unbestätigt)'
                                : _email),
                        editChild: TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          style: const TextStyle(
                              color: _textPrimary, fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'deine@email.com',
                            hintStyle: const TextStyle(
                                color: _textSecondary, fontSize: 14),
                            filled: true,
                            fillColor: const Color(0xFF0E0F12),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: Color(0xFF2A2D35)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: Color(0xFF2A2D35)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide:
                                  const BorderSide(color: _accent, width: 1.5),
                            ),
                          ),
                        ),
                        onEdit: () => setState(() => _editing = 'email'),
                        onSave: _saveEmail,
                        onCancel: () => setState(() {
                          _editing = null;
                          _emailController.text = _email;
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

  /// Extrahiert den Storage-Pfad (z.B. `avatars/<docId>-<ts>.jpg`) aus einer
  /// Firebase-Storage-Download-URL bzw. einem `gs://` Pfad. Liefert null, wenn
  /// es keine Storage-URL ist (z. B. ein lokaler Datei-Pfad oder eine externe
  /// Bild-URL) — dann darf NICHT gelöscht werden.
  String? _storagePathFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('gs://')) {
      // gs://<bucket>/<path>
      final without = url.substring('gs://'.length);
      final slash = without.indexOf('/');
      if (slash == -1) return null;
      return without.substring(slash + 1);
    }
    // https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<urlencoded-path>?...
    const marker = '/o/';
    final i = url.indexOf(marker);
    if (i == -1) return null;
    final rest = url.substring(i + marker.length);
    final q = rest.indexOf('?');
    final encoded = q == -1 ? rest : rest.substring(0, q);
    try {
      return Uri.decodeComponent(encoded);
    } catch (_) {
      return encoded;
    }
  }

  /// Rendert den Avatar.
  ///
  /// - **Bar-Accounts**: zeigt das echte `profileImageUrl` (gleiches Bild wie
  ///   in „Meine Bar"). Inkl. error-/loadingBuilder.
  /// - **User-Accounts**: ABSICHTLICH immer das Default-Icon
  ///   (per früherer Anforderung „immer so als hätte man kein Profilbild").
  Widget _buildAvatarWidget() {
    if (!_isBarAccount) {
      return const Icon(Icons.person, color: Colors.white38, size: 40);
    }

    final avatar = _avatar;
    if (avatar == null || avatar.trim().isEmpty) {
      return const Icon(Icons.local_bar, color: Colors.white38, size: 40);
    }
    if (avatar.startsWith('http://') || avatar.startsWith('https://')) {
      return Image.network(
        avatar,
        key: ValueKey(avatar),
        width: 92,
        height: 92,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        loadingBuilder: (ctx, child, progress) {
          if (progress == null) {
            debugPrint('$_kAvatarTag bar Image.network rendered OK: $avatar');
            return child;
          }
          return const Center(
            child: SizedBox(
              width: 24, height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
          );
        },
        errorBuilder: (ctx, error, stack) {
          debugPrint('$_kAvatarTag bar Image.network ERROR for $avatar');
          debugPrint('$_kAvatarTag   error: $error');
          return const Center(
            child: Icon(Icons.local_bar,
                color: Colors.white38, size: 40),
          );
        },
      );
    }
    return const Icon(Icons.local_bar, color: Colors.white38, size: 40);
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

  /// Liefert das Status-Icon, das rechts neben dem E-Mail-Eintrag erscheint.
  ///   • Verifiziert (emailVerifiedAt gesetzt + kein pending) → grüner Haken
  ///   • Pending Verifikation (pendingEmail gesetzt)          → orange Sanduhr
  ///   • Mail vorhanden aber unbestätigt                      → graues Info
  ///   • Sonst                                                → leer
  ///
  /// AnimatedSwitcher sorgt für sanften Wechsel beim Live-Update aus dem
  /// User-Doc-Listener.
  Widget _emailStatusBadge() {
    Widget child;
    if (_emailVerified && _pendingEmail.isEmpty) {
      child = Container(
        key: const ValueKey('verified'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.success.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: AppColors.success.withOpacity(0.55), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.check_circle_rounded,
                color: AppColors.success, size: 14),
            SizedBox(width: 4),
            Text(
              'verifiziert',
              style: TextStyle(
                color: AppColors.success,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
    } else if (_pendingEmail.isNotEmpty) {
      child = Container(
        key: const ValueKey('pending'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFFA000).withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: const Color(0xFFFFA000).withOpacity(0.55), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.hourglass_top_rounded,
                color: Color(0xFFFFA000), size: 14),
            SizedBox(width: 4),
            Text(
              'wartet',
              style: TextStyle(
                color: Color(0xFFFFA000),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
    } else if (_email.isNotEmpty) {
      // Mail ist hinterlegt, aber nie verifiziert (z. B. Bar-Self-Signup).
      child = Container(
        key: const ValueKey('unverified'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.muted.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: AppColors.muted.withOpacity(0.4), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.info_outline_rounded,
                color: AppColors.muted, size: 14),
            SizedBox(width: 4),
            Text(
              'unbestätigt',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      );
    } else {
      child = const SizedBox(key: ValueKey('none'), width: 0);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: anim,
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: child,
    );
  }

  Widget _settingRow({
    required IconData icon,
    required String label,
    required bool editing,
    required String displayValue,
    required Widget editChild,
    required VoidCallback onEdit,
    required VoidCallback onSave,
    required VoidCallback onCancel,
    Widget? trailing,
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
              if (trailing != null && !editing) ...[
                const SizedBox(width: 8),
                trailing,
              ],
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
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: SizedBox(
                        width: 32, height: 32,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white70,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (_, error, stack) {
                    debugPrint(
                        '$_kAvatarTag Fullscreen Image.network ERROR for ${widget.imageUrl}: $error');
                    return const Icon(Icons.broken_image,
                        color: Colors.white38, size: 60);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
