// lib/Screens/admin/admin_stats_tab.dart
//
// Schlanke Counter-Statistiken. Live, weil StreamBuilder gegen die
// Top-Collections — keine Aggregations-Function nötig.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';

class AdminStatsTab extends StatelessWidget {
  const AdminStatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionTitle('Bars'),
        Row(
          children: [
            Expanded(
                child: _CountCard(
                    label: 'Aktiv',
                    color: AppColors.success,
                    icon: Icons.check_circle_rounded,
                    stream: _countWhere('bars', 'status', 'approved'))),
            const SizedBox(width: 10),
            Expanded(
                child: _CountCard(
                    label: 'Pending',
                    color: const Color(0xFFFFA000),
                    icon: Icons.hourglass_top_rounded,
                    stream: _countWhere('bars', 'status', 'pending'))),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
                child: _CountCard(
                    label: 'Abgelehnt',
                    color: AppColors.accent,
                    icon: Icons.block_rounded,
                    stream: _countWhere('bars', 'status', 'rejected'))),
            const SizedBox(width: 10),
            Expanded(
                child: _CountCard(
                    label: 'Bars gesamt',
                    color: AppColors.text,
                    icon: Icons.local_bar_rounded,
                    stream: _countAll('bars'))),
          ],
        ),
        const SizedBox(height: 24),
        const _SectionTitle('Community'),
        Row(
          children: [
            Expanded(
                child: _CountCard(
                    label: 'User',
                    color: AppColors.teal,
                    icon: Icons.people_rounded,
                    stream: _countAll('users'))),
            const SizedBox(width: 10),
            Expanded(
                child: _CountCard(
                    label: 'Partys',
                    color: AppColors.accent,
                    icon: Icons.celebration_rounded,
                    stream: _countAll('Party'))),
          ],
        ),
      ],
    );
  }

  Stream<int> _countAll(String collection) =>
      FirebaseFirestore.instance
          .collection(collection)
          .snapshots()
          .map((s) => s.size);

  Stream<int> _countWhere(String collection, String field, dynamic value) =>
      FirebaseFirestore.instance
          .collection(collection)
          .where(field, isEqualTo: value)
          .snapshots()
          .map((s) => s.size);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(title.toUpperCase(),
          style: const TextStyle(
              color: AppColors.muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }
}

class _CountCard extends StatelessWidget {
  const _CountCard({
    required this.label,
    required this.icon,
    required this.color,
    required this.stream,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Stream<int> stream;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.mdBr,
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          StreamBuilder<int>(
            stream: stream,
            builder: (context, snap) {
              final n = snap.data;
              return Text(
                n == null ? '…' : n.toString(),
                style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 28,
                    fontWeight: FontWeight.w800),
              );
            },
          ),
        ],
      ),
    );
  }
}
