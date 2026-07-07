// lib/Screens/festl/admin_festln_list_tab.dart
//
// Liste aller Festln (Admin). Tap → Festl-Editor. FAB unten rechts öffnet
// den Editor leer für ein neues Festl. Analog zu AdminBarsListTab.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import '../../Services/timestamp_ext.dart';
import 'admin_create_festl_screen.dart';

class AdminFestlnListTab extends StatefulWidget {
  const AdminFestlnListTab({super.key});

  @override
  State<AdminFestlnListTab> createState() => _AdminFestlnListTabState();
}

class _AdminFestlnListTabState extends State<AdminFestlnListTab> {
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
                    .collection('festln')
                    .orderBy('startTime', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting &&
                      !snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  var docs = snap.data?.docs ?? [];

                  if (_search.isNotEmpty) {
                    final q = _search.toLowerCase();
                    docs = docs.where((d) {
                      final data = d.data();
                      final name =
                          (data['festlName'] ?? '').toString().toLowerCase();
                      final city =
                          (data['city'] ?? '').toString().toLowerCase();
                      return name.contains(q) || city.contains(q);
                    }).toList();
                  }

                  if (docs.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _search.isNotEmpty
                              ? 'Keine Festln passend zur Suche.'
                              : 'Noch keine Festln angelegt.',
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
                    itemBuilder: (_, i) => _FestlTile(doc: docs[i]),
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
            heroTag: 'admin-new-festl',
            backgroundColor: const Color(0xFF8E24AA),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Neues Festl'),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const AdminCreateFestlScreen()));
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _search = v.trim()),
        style: const TextStyle(color: AppColors.text, fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search_rounded, color: AppColors.muted),
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
            borderSide: const BorderSide(color: Color(0xFF8E24AA), width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _FestlTile extends StatelessWidget {
  const _FestlTile({required this.doc});

  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  String _fmtDate(dynamic v) {
    if (v is Timestamp) {
      final d = v.toLocalDateTime();
      return "${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}";
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final name = (data['festlName'] ?? doc.id).toString();
    final city = (data['city'] ?? '').toString();
    final status = (data['status'] ?? 'approved').toString();
    final cover = (data['profileImageUrl'] ?? '').toString().trim();
    final date = _fmtDate(data['startTime']);
    final subtitle =
        [if (city.isNotEmpty) city, if (date.isNotEmpty) date].join(' · ');

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
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF8E24AA),
            borderRadius: BorderRadius.circular(8),
            image: cover.isNotEmpty
                ? DecorationImage(image: NetworkImage(cover), fit: BoxFit.cover)
                : null,
          ),
          child: cover.isEmpty
              ? const Text('🎡', style: TextStyle(fontSize: 20))
              : null,
        ),
        title: Text(name,
            style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle.isEmpty ? doc.id : subtitle,
            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (status == 'approved' ? AppColors.success : AppColors.muted)
                .withOpacity(0.18),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(status,
              style: TextStyle(
                  color:
                      status == 'approved' ? AppColors.success : AppColors.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3)),
        ),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AdminCreateFestlScreen(festlId: doc.id)));
        },
      ),
    );
  }
}
