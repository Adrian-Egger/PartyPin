import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

const _gradTop = AppColors.bgTop;
const _gradBottom = AppColors.bgBottom;
const _panel = Color(0xFF15171C);
const _textPrimary = AppColors.text;
const _textSecondary = AppColors.muted;
const _accent = AppColors.accent;

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  bool _notifChat = true;
  bool _notifFriends = true;
  bool _notifNearbyParties = true;
  bool _notifNearbyBars = true;
  bool _loading = true;
  String _docId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Eigenes User-Doc == authentifizierte UID. Die Firestore-Doc-ID ist der
    // volle Name (== uid, siehe signupCallable), NICHT der Username — deshalb
    // NIE doc(username) für das eigene Doc verwenden (sonst PERMISSION_DENIED
    // bzw. Schreiben ins falsche/nicht-eigene Dokument).
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (!mounted) return;
    _docId = uid;

    if (uid.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final data = doc.data() ?? {};

    if (!mounted) return;
    setState(() {
      _notifChat          = data['notifChat']          != false;
      _notifFriends       = data['notifFriends']       != false;
      _notifNearbyParties = data['notifNearbyParties'] != false;
      _notifNearbyBars    = data['notifNearbyBars']    != false;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_docId.isEmpty) return;
    await FirebaseFirestore.instance.collection('users').doc(_docId).set({
      'notifChat':          _notifChat,
      'notifFriends':       _notifFriends,
      'notifNearbyParties': _notifNearbyParties,
      'notifNearbyBars':    _notifNearbyBars,
    }, SetOptions(merge: true));
  }

  Future<void> _toggle(String field, bool value) async {
    setState(() {
      switch (field) {
        case 'notifChat':          _notifChat          = value;
        case 'notifFriends':       _notifFriends       = value;
        case 'notifNearbyParties': _notifNearbyParties = value;
        case 'notifNearbyBars':    _notifNearbyBars    = value;
      }
    });
    await _save();
  }

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
            Lang.t('notif_title'),
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
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _accent))
            : SafeArea(
                top: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                  children: [
                    _sectionLabel(Lang.t('notif_section_activity')),
                    const SizedBox(height: 8),
                    _notifCard([
                      _notifTile(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: Lang.t('notif_chat_title'),
                        subtitle: Lang.t('notif_chat_sub'),
                        value: _notifChat,
                        onChanged: (v) => _toggle('notifChat', v),
                        divider: true,
                      ),
                      _notifTile(
                        icon: Icons.person_add_alt_1_rounded,
                        title: Lang.t('notif_friends_title'),
                        subtitle: Lang.t('notif_friends_sub'),
                        value: _notifFriends,
                        onChanged: (v) => _toggle('notifFriends', v),
                        divider: false,
                      ),
                    ]),
                    const SizedBox(height: 24),
                    _sectionLabel(Lang.t('notif_section_going_out')),
                    const SizedBox(height: 8),
                    _notifCard([
                      _notifTile(
                        icon: Icons.celebration_rounded,
                        title: Lang.t('notif_parties_title'),
                        subtitle: Lang.t('notif_parties_sub'),
                        value: _notifNearbyParties,
                        onChanged: (v) => _toggle('notifNearbyParties', v),
                        divider: true,
                      ),
                      _notifTile(
                        icon: Icons.local_bar_rounded,
                        title: Lang.t('notif_bars_title'),
                        subtitle: Lang.t('notif_bars_sub'),
                        value: _notifNearbyBars,
                        onChanged: (v) => _toggle('notifNearbyBars', v),
                        divider: false,
                      ),
                    ]),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        Lang.t('notif_location_hint'),
                        style: const TextStyle(
                          color: _textSecondary,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _sectionLabel(String label) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            color: _textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
      );

  Widget _notifCard(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accentBorder),
        ),
        child: Column(children: children),
      );

  Widget _notifTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required bool divider,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _accent.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: _accent, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: _textSecondary,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeColor: _accent,
                activeTrackColor: _accent.withAlpha(80),
                inactiveThumbColor: _textSecondary,
                inactiveTrackColor: const Color(0xFF2A2D35),
              ),
            ],
          ),
        ),
        if (divider) const Divider(height: 1, color: Color(0xFF2A2D35)),
      ],
    );
  }
}
