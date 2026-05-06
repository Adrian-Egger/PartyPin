// lib/Screens/bar_feedback_screen.dart
//
// Bar-Owner-Feedback-Ansicht mit:
//   • Filter-Chips (Alle / 5★ / 4★ / ≤3★ / Nur mit Text)
//   • Hide-Toggle pro Feedback (ausblenden / wieder einblenden)
//   • Report-Dialog fuer Spam/Beleidigung (markiert isHidden + reportedFeedback)
//
// Datenmodell pro feedbackDoc:
//   { eventTitle, userName, anonymous, comment, rating, createdAt, isHidden }

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../Theme/app_theme.dart';
import '../../l10n/lang.dart';

class BarFeedbackScreen extends StatefulWidget {
  const BarFeedbackScreen({super.key});

  @override
  State<BarFeedbackScreen> createState() => _BarFeedbackScreenState();
}

class _BarFeedbackScreenState extends State<BarFeedbackScreen> {
  String? _barId;
  bool _loadingBarId = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBarId();
  }

  Future<void> _loadBarId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final barId = prefs.getString('barId');
      if (barId == null || barId.trim().isEmpty) {
        setState(() {
          _error =
              'Keine Bar-ID gefunden. Stelle sicher, dass dein Bar-Account richtig verknüpft ist.';
          _loadingBarId = false;
        });
        return;
      }
      setState(() {
        _barId = barId.trim();
        _loadingBarId = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Fehler beim Laden der Bar-ID: $e';
        _loadingBarId = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loadingBarId) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!,
              style: const TextStyle(color: AppColors.muted),
              textAlign: TextAlign.center),
        ),
      );
    } else {
      body = _FeedbackContent(barId: _barId!);
    }

    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      builder: (context, _, __) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AppColors.bgBottom,
          elevation: 0,
          centerTitle: true,
          title: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: AppRadius.fullBr,
              border: Border.all(color: AppColors.accentBorder2, width: 1),
            ),
            child: Text(
              Lang.t('bar_feedback_header'),
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w700,
                fontSize: 15,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ),
        backgroundColor: AppColors.bgTop,
        body: body,
      ),
    );
  }
}

// ─── Filter ────────────────────────────────────────────────────────────

enum _Filter { all, fiveStar, fourStar, lowRated, withComment }

extension _FilterX on _Filter {
  String get label {
    switch (this) {
      case _Filter.all:
        return 'Alle';
      case _Filter.fiveStar:
        return '5★';
      case _Filter.fourStar:
        return '4★';
      case _Filter.lowRated:
        return '≤3★';
      case _Filter.withComment:
        return 'Mit Text';
    }
  }
}

class _FeedbackContent extends StatefulWidget {
  const _FeedbackContent({required this.barId});
  final String barId;

  @override
  State<_FeedbackContent> createState() => _FeedbackContentState();
}

class _FeedbackContentState extends State<_FeedbackContent> {
  _Filter _filter = _Filter.all;
  bool _showHidden = false; // Bar-Owner darf ausgeblendete sehen

  static int? _parseRating(dynamic v) {
    if (v == null) return null;
    if (v is int) return (v >= 1 && v <= 5) ? v : null;
    final p = int.tryParse(v.toString());
    return (p != null && p >= 1 && p <= 5) ? p : null;
  }

  bool _matchesFilter(Map<String, dynamic> data) {
    final r = _parseRating(data['rating']) ?? 0;
    final hasText = (data['comment'] ?? '').toString().trim().isNotEmpty;
    switch (_filter) {
      case _Filter.all:
        return true;
      case _Filter.fiveStar:
        return r == 5;
      case _Filter.fourStar:
        return r == 4;
      case _Filter.lowRated:
        return r > 0 && r <= 3;
      case _Filter.withComment:
        return hasText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedbackStream = FirebaseFirestore.instance
        .collection('bars')
        .doc(widget.barId)
        .collection('eventFeedback')
        .orderBy('createdAt', descending: true)
        .snapshots();

    final barDocStream = FirebaseFirestore.instance
        .collection('bars')
        .doc(widget.barId)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: barDocStream,
      builder: (context, barSnap) {
        final barData = barSnap.data?.data();
        final barName = (barData?['barName'] ?? 'Deine Bar').toString().trim();
        final double? barRatingAvg = barData?['ratingAvg'] != null
            ? (barData!['ratingAvg'] as num).toDouble()
            : null;
        final int barRatingCount = barData?['ratingCount'] != null
            ? (barData!['ratingCount'] as num).toInt()
            : 0;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: feedbackStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Fehler: ${snapshot.error}',
                      style: const TextStyle(color: AppColors.muted),
                      textAlign: TextAlign.center),
                ),
              );
            }

            final allDocs = snapshot.data?.docs ?? [];

            // Aggregation: Avg + Distribution (über NICHT-hidden Feedbacks).
            double sum = 0;
            int count = 0;
            final dist = <int, int>{5: 0, 4: 0, 3: 0, 2: 0, 1: 0};
            for (final d in allDocs) {
              final data = d.data();
              if (data['isHidden'] == true) continue;
              final r = _parseRating(data['rating']);
              if (r != null && r > 0) {
                sum += r;
                count++;
                dist[r] = (dist[r] ?? 0) + 1;
              }
            }
            final overallAvg = count > 0 ? sum / count : null;

            // Sichtbare Liste je nach Filter + Hidden-Toggle.
            final visible = allDocs.where((d) {
              final data = d.data();
              if (!_showHidden && data['isHidden'] == true) return false;
              return _matchesFilter(data);
            }).toList();

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              itemCount: visible.length + 2, // summary + filter-row + items
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return _buildSummaryCard(
                    barName: barName,
                    barRatingAvg: barRatingAvg,
                    barRatingCount: barRatingCount,
                    overallAvg: overallAvg,
                    overallCount: count,
                    distribution: dist,
                  );
                }
                if (i == 1) {
                  return _buildFilterRow(allDocs);
                }
                return _buildFeedbackCard(visible[i - 2]);
              },
            );
          },
        );
      },
    );
  }

  // ── Summary ────────────────────────────────────────────────────────

  Widget _buildSummaryCard({
    required String barName,
    required double? barRatingAvg,
    required int barRatingCount,
    required double? overallAvg,
    required int overallCount,
    required Map<int, int> distribution,
  }) {
    final avg = overallAvg ?? barRatingAvg;
    final cnt = overallCount > 0 ? overallCount : barRatingCount;
    final hasAny = cnt > 0 && avg != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: AppRadius.lgBr,
        border: Border.all(color: AppColors.accentBorder2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(barName,
              style: const TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 18)),
          const SizedBox(height: 4),
          const Text('Dein Bar- & Event-Rating 🍹⭐',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.star_rounded, color: Colors.amber, size: 36),
              const SizedBox(width: 10),
              if (hasAny)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${avg.toStringAsFixed(1)} / 5',
                        style: const TextStyle(
                            color: AppColors.text,
                            fontWeight: FontWeight.w800,
                            fontSize: 22)),
                    Text(
                        '$cnt Bewertung${cnt == 1 ? '' : 'en'}',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 13)),
                  ],
                )
              else
                const Expanded(
                  child: Text('Noch keine Bewertungen vorhanden.',
                      style:
                          TextStyle(color: AppColors.muted, fontSize: 13)),
                ),
            ],
          ),
          if (hasAny) ...[
            const SizedBox(height: 14),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [5, 4, 3, 2, 1].map((s) {
                final c = distribution[s] ?? 0;
                final pct = cnt > 0 ? c / cnt : 0.0;
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.bgTop,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppColors.accentBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$s★',
                          style: const TextStyle(
                              color: Colors.amber,
                              fontWeight: FontWeight.w700,
                              fontSize: 12)),
                      const SizedBox(width: 6),
                      Text('$c',
                          style: const TextStyle(
                              color: AppColors.text, fontSize: 12)),
                      const SizedBox(width: 4),
                      Text('(${(pct * 100).round()}%)',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 11)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── Filter-Row + Hidden-Toggle ─────────────────────────────────────

  Widget _buildFilterRow(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> all) {
    final hiddenCount =
        all.where((d) => d.data()['isHidden'] == true).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _Filter.values.map((f) {
              final active = _filter == f;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _filter = f),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: active ? AppColors.accent : AppColors.panel,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: active
                              ? AppColors.accent
                              : AppColors.accentBorder),
                    ),
                    child: Text(
                      f.label,
                      style: TextStyle(
                          color: active ? Colors.white : AppColors.muted,
                          fontWeight: FontWeight.w700,
                          fontSize: 12),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        if (hiddenCount > 0) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$hiddenCount Feedback${hiddenCount == 1 ? '' : 's'} ausgeblendet',
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 12),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _showHidden = !_showHidden),
                child: Text(
                  _showHidden ? 'Verstecken' : 'Anzeigen',
                  style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── Feedback-Card ──────────────────────────────────────────────────

  Widget _buildFeedbackCard(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final eventTitle =
        (data['eventTitle'] ?? 'Unbekanntes Event').toString().trim();
    final anon = data['anonymous'] == true;
    final userName = anon
        ? 'Anonym'
        : ((data['userName'] ?? '').toString().trim().isNotEmpty
            ? (data['userName'] ?? '').toString().trim()
            : 'Unbekannter Nutzer');
    final comment = (data['comment'] ?? '').toString().trim();
    final rating = _parseRating(data['rating']) ?? 0;
    final isHidden = data['isHidden'] == true;

    return Opacity(
      opacity: isHidden ? 0.55 : 1.0,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: AppRadius.mdBr,
          border: Border.all(
              color: isHidden ? AppColors.muted : AppColors.accentBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(eventTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 14)),
                ),
                if (isHidden)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.muted.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('ausgeblendet',
                        style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _buildStars(rating),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('von $userName',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12)),
                ),
              ],
            ),
            if (comment.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(comment,
                  style: const TextStyle(
                      color: AppColors.text, height: 1.35, fontSize: 13.5)),
            ],
            const SizedBox(height: 10),
            // Action-Row
            Row(
              children: [
                _ActionButton(
                  icon: isHidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  label: isHidden ? 'Einblenden' : 'Ausblenden',
                  color: AppColors.muted,
                  onTap: () => _toggleHidden(doc, isHidden),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.flag_outlined,
                      color: AppColors.muted, size: 18),
                  tooltip: 'Inhalt melden',
                  onPressed: () => _showReportDialog(doc.reference),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStars(int r) {
    r = r.clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < r ? Icons.star_rounded : Icons.star_border_rounded,
          color: i < r ? Colors.amber : AppColors.subtle,
          size: 16,
        );
      }),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────

  Future<void> _toggleHidden(
      QueryDocumentSnapshot<Map<String, dynamic>> doc, bool current) async {
    await doc.reference.set(
      {'isHidden': !current, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
  }

  Future<void> _showReportDialog(DocumentReference feedbackRef) async {
    String reason = 'Belästigung';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.panel,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBr),
        title: const Text('Feedback melden',
            style: TextStyle(
                color: AppColors.text, fontWeight: FontWeight.w800)),
        content: DropdownButtonFormField<String>(
          dropdownColor: AppColors.panel,
          initialValue: reason,
          style: const TextStyle(color: AppColors.text),
          items: const [
            DropdownMenuItem(value: 'Belästigung', child: Text('Belästigung')),
            DropdownMenuItem(
                value: 'Hass', child: Text('Hass / Diskriminierung')),
            DropdownMenuItem(
                value: 'Sexuell', child: Text('Sexueller Inhalt')),
            DropdownMenuItem(value: 'Gewalt', child: Text('Gewalt')),
            DropdownMenuItem(value: 'Spam', child: Text('Spam / Werbung')),
          ],
          onChanged: (v) => reason = v ?? reason,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppColors.muted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white),
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('reportedFeedback')
                  .add({
                'feedbackRef': feedbackRef,
                'reason': reason,
                'reportedAt': FieldValue.serverTimestamp(),
                'status': 'pending',
              });
              await feedbackRef.set(
                {'isHidden': true},
                SetOptions(merge: true),
              );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Melden'),
          ),
        ],
      ),
    );
  }
}

// ─── Action button ────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}
