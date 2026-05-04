// lib/Screens/admin/admin_bars_list_tab.dart
//
// Liste aller Bars (alle Stati). Tap → kompletter Bar-Editor (existing
// AdminCreatesBarScreen). FAB unten rechts öffnet den Editor leer für
// einen manuellen Neuzugang.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import '../bar/AdminCreatesBarScreen.dart';

class AdminBarsListTab extends StatefulWidget {
  const AdminBarsListTab({super.key});

  @override
  State<AdminBarsListTab> createState() => _AdminBarsListTabState();
}

class _AdminBarsListTabState extends State<AdminBarsListTab> {
  String _filter = 'all'; // all | approved | pending | rejected
  String _search = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            _buildToolbar(),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('bars')
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  var docs = snap.data?.docs ?? [];

                  // Filter & Suche client-side (Anzahl Bars ist begrenzt).
                  if (_filter != 'all') {
                    docs = docs
                        .where((d) =>
                            (d.data()['status'] ?? 'approved').toString() ==
                            _filter)
                        .toList();
                  }
                  if (_search.isNotEmpty) {
                    final q = _search.toLowerCase();
                    docs = docs
                        .where((d) {
                          final data = d.data();
                          final name =
                              (data['barName'] ?? '').toString().toLowerCase();
                          final city =
                              (data['city'] ?? '').toString().toLowerCase();
                          return name.contains(q) || city.contains(q);
                        })
                        .toList();
                  }

                  if (docs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _search.isNotEmpty || _filter != 'all'
                              ? 'Keine Bars passend zu Filter / Suche.'
                              : 'Noch keine Bars angelegt.',
                          style: const TextStyle(color: AppColors.muted),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) => _BarTile(doc: docs[i]),
                  );
                },
              ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 20,
          child: FloatingActionButton.extended(
            heroTag: 'admin-new-bar',
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Neue Bar'),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const AdminCreateBarScreen()));
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v.trim()),
            style: const TextStyle(color: AppColors.text, fontSize: 14),
            decoration: InputDecoration(
              prefixIcon:
                  const Icon(Icons.search_rounded, color: AppColors.muted),
              hintText: 'Name oder Stadt suchen…',
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
          const SizedBox(height: 8),
          Row(
            children: [
              _FilterChip(
                  label: 'Alle',
                  active: _filter == 'all',
                  onTap: () => setState(() => _filter = 'all')),
              const SizedBox(width: 6),
              _FilterChip(
                  label: 'Aktiv',
                  active: _filter == 'approved',
                  onTap: () => setState(() => _filter = 'approved')),
              const SizedBox(width: 6),
              _FilterChip(
                  label: 'Pending',
                  active: _filter == 'pending',
                  onTap: () => setState(() => _filter = 'pending')),
              const SizedBox(width: 6),
              _FilterChip(
                  label: 'Abgelehnt',
                  active: _filter == 'rejected',
                  onTap: () => setState(() => _filter = 'rejected')),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(
      {required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.accent : AppColors.panelAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: active
                  ? AppColors.accent
                  : AppColors.accentBorder),
        ),
        child: Text(label,
            style: TextStyle(
                color: active ? Colors.white : AppColors.muted,
                fontWeight: FontWeight.w700,
                fontSize: 12)),
      ),
    );
  }
}

class _BarTile extends StatelessWidget {
  const _BarTile({required this.doc});

  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  Color _statusColor(String s) {
    switch (s) {
      case 'approved':
        return AppColors.success;
      case 'pending':
        return const Color(0xFFFFA000);
      case 'rejected':
      case 'declined':
        return AppColors.accent;
      default:
        return AppColors.muted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final name = (data['barName'] ?? doc.id).toString();
    final city = (data['city'] ?? '').toString();
    final status = (data['status'] ?? 'approved').toString();
    final logo = (data['profileImageUrl'] ?? '').toString().trim();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.smBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.panelAlt,
            borderRadius: BorderRadius.circular(8),
            image: logo.isNotEmpty
                ? DecorationImage(
                    image: NetworkImage(logo), fit: BoxFit.cover)
                : null,
          ),
          child: logo.isEmpty
              ? const Icon(Icons.local_bar_rounded,
                  color: AppColors.muted, size: 20)
              : null,
        ),
        title: Text(name,
            style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        subtitle: Text(city.isEmpty ? doc.id : city,
            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _statusColor(status).withOpacity(0.18),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(status,
              style: TextStyle(
                  color: _statusColor(status),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3)),
        ),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const AdminCreateBarScreen()));
        },
      ),
    );
  }
}
