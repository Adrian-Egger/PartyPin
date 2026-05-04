// lib/Screens/admin/admin_users_tab.dart
//
// Einfache User-Suche mit Live-Filter. Tap → Detail-BottomSheet mit
// schnellen Aktionen (Banausbau, Hide-Profile-Toggle).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';

class AdminUsersTab extends StatefulWidget {
  const AdminUsersTab({super.key});

  @override
  State<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _AdminUsersTabState extends State<AdminUsersTab> {
  final _searchCtrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) =>
                setState(() => _q = v.trim().toLowerCase()),
            style: const TextStyle(color: AppColors.text, fontSize: 14),
            decoration: InputDecoration(
              prefixIcon:
                  const Icon(Icons.search_rounded, color: AppColors.muted),
              hintText: 'Username oder Name suchen…',
              hintStyle: const TextStyle(color: AppColors.subtle),
              filled: true,
              fillColor: AppColors.panelAlt,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              border: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide: const BorderSide(color: AppColors.accentBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide: const BorderSide(color: AppColors.accentBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: AppRadius.smBr,
                borderSide:
                    const BorderSide(color: AppColors.accent, width: 1.5),
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream:
                FirebaseFirestore.instance.collection('users').snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              var docs = snap.data?.docs ?? [];
              if (_q.isNotEmpty) {
                docs = docs.where((d) {
                  final data = d.data();
                  final u = (data['username'] ?? '')
                      .toString()
                      .toLowerCase();
                  final fn = (data['fullName'] ?? '')
                      .toString()
                      .toLowerCase();
                  return u.contains(_q) || fn.contains(_q);
                }).toList();
              }
              if (docs.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _q.isEmpty ? 'Noch keine User.' : 'Keine Treffer.',
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, i) => _UserTile(doc: docs[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.doc});
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final username = (data['username'] ?? '').toString();
    final fullName = (data['fullName'] ?? '').toString();
    final banned = data['banned'] == true;
    final avatar = (data['avatarUrl'] ?? '').toString().trim();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.panelAlt,
          backgroundImage: avatar.isNotEmpty ? NetworkImage(avatar) : null,
          child: avatar.isEmpty
              ? Text(
                  username.isEmpty ? '?' : username[0].toUpperCase(),
                  style: const TextStyle(
                      color: AppColors.muted, fontWeight: FontWeight.w700),
                )
              : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                username.isEmpty ? doc.id : username,
                style: const TextStyle(
                    color: AppColors.text, fontWeight: FontWeight.w700),
              ),
            ),
            if (banned)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('banned',
                    style: TextStyle(
                        color: AppColors.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        subtitle: Text(fullName.isEmpty ? doc.id : fullName,
            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        trailing: IconButton(
          icon: Icon(
            banned ? Icons.lock_open_rounded : Icons.block_rounded,
            color: banned ? AppColors.success : AppColors.accent,
          ),
          tooltip: banned ? 'Ban aufheben' : 'User bannen',
          onPressed: () async {
            await doc.reference.set(
              {
                'banned': !banned,
                if (!banned) 'bannedAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
              },
              SetOptions(merge: true),
            );
          },
        ),
      ),
    );
  }
}
