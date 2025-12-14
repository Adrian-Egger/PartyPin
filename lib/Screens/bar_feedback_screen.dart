// lib/Screens/bar_feedback_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    const bgColor = Color(0xFF090B10);
    const accent = Color(0xFFFF3B30);

    Widget body;
    if (_loadingBarId) {
      body = const Center(
        child: CircularProgressIndicator(color: accent),
      );
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else {
      body = _FeedbackContent(barId: _barId!);
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141A22),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: accent, // ✅ Pfeil rot
          ),
          onPressed: () {
            Navigator.pop(context); // Karte bleibt offen
          },
        ),
        title: const Text(
          'Bar-Feedback 🍹⭐📝', // ✅ Emojis in Überschrift
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
      ),
      backgroundColor: bgColor,
      body: body,
    );
  }
}

/// Eigentliche Feedback-Ansicht (Bar-ID ist garantiert vorhanden)
class _FeedbackContent extends StatelessWidget {
  final String barId;

  const _FeedbackContent({required this.barId});

  static const Color cardColor = Color(0xFF1C1F26);
  static const Color accent = Color(0xFFFF3B30);

  @override
  Widget build(BuildContext context) {
    final feedbackStream = FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('eventFeedback')
        .orderBy('createdAt', descending: true)
        .snapshots();

    // Optional: Bar-Daten (Name + globaler Rating-Durchschnitt aus dem Bar-Dokument)
    final barDocStream = FirebaseFirestore.instance.collection('bars').doc(barId).snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: barDocStream,
      builder: (context, barSnap) {
        final barData = barSnap.data?.data();
        final barName = (barData?['barName'] ?? 'Deine Bar').toString().trim();

        final double? barRatingAvg =
        barData?['ratingAvg'] != null ? (barData!['ratingAvg'] as num).toDouble() : null;

        final int barRatingCount =
        barData?['ratingCount'] != null ? (barData!['ratingCount'] as num).toInt() : 0;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: feedbackStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(color: accent),
              );
            }

            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Fehler beim Laden der Feedbacks: ${snapshot.error}',
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            final docs = snapshot.data?.docs ?? [];

            if (docs.isEmpty) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: [
                  _buildSummaryCard(
                    barName: barName,
                    barRatingAvg: barRatingAvg,
                    barRatingCount: barRatingCount,
                    hasAnyFeedback: false,
                    overallAvg: null,
                    overallCount: 0,
                    distribution: const {},
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: const Text(
                      'Noch keine Feedbacks zu deinen Events vorhanden.\n'
                          'Motiviere deine Gäste, nach dem Event kurz zu bewerten – '
                          'damit sie dir zeigen können, wie ihnen deine Bar gefällt.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              );
            }

            // Durchschnitt + Verteilung aus allen Feedbacks berechnen
            double sum = 0;
            int count = 0;
            final Map<int, int> distribution = {5: 0, 4: 0, 3: 0, 2: 0, 1: 0};

            for (final d in docs) {
              final data = d.data();
              final r = _parseRating(data['rating']);
              if (r != null && r > 0) {
                sum += r;
                count++;
                distribution[r] = (distribution[r] ?? 0) + 1;
              }
            }

            final double? overallAvg = count > 0 ? sum / count : null;

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildSummaryCard(
                    barName: barName,
                    barRatingAvg: barRatingAvg,
                    barRatingCount: barRatingCount,
                    hasAnyFeedback: count > 0,
                    overallAvg: overallAvg,
                    overallCount: count,
                    distribution: distribution,
                  );
                }

                final data = docs[index - 1].data();
                return _buildFeedbackCard(data);
              },
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemCount: docs.length + 1,
            );
          },
        );
      },
    );
  }

  /// Zusammenfassung: Bar-Name, globales Rating aus Bar-Dokument + Event-Durchschnitt
  static Widget _buildSummaryCard({
    required String barName,
    required double? barRatingAvg,
    required int barRatingCount,
    required bool hasAnyFeedback,
    required double? overallAvg,
    required int overallCount,
    required Map<int, int> distribution,
  }) {
    final double? effectiveAvg = overallAvg ?? barRatingAvg;
    final int effectiveCount = overallCount > 0 ? overallCount : barRatingCount;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withOpacity(0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            barName,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Dein Bar- & Event-Rating 🍹⭐',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.star_rounded, color: Colors.amber, size: 34),
              const SizedBox(width: 10),
              if (effectiveAvg != null && effectiveCount > 0) ...[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${effectiveAvg.toStringAsFixed(1)} / 5',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$effectiveCount Bewertung${effectiveCount == 1 ? '' : 'en'}',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ] else ...[
                const Expanded(
                  child: Text(
                    'Noch keine Bewertungen vorhanden.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (hasAnyFeedback && distribution.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            Text(
              'Verteilung deiner Sterne ✨',
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [5, 4, 3, 2, 1].map((star) {
                final cnt = distribution[star] ?? 0;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$star★',
                        style: const TextStyle(
                          color: Colors.amber,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        cnt.toString(),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 10),
          const Text(
            'Hinweis: Diese Werte sind nur für dich sichtbar und basieren auf allen Event-Bewertungen deiner Bar.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildFeedbackCard(Map<String, dynamic> data) {
    final eventTitle = (data['eventTitle'] ?? 'Unbekanntes Event').toString().trim();

    // ✅ anonym richtig auslesen
    final bool anonymous = data['anonymous'] == true;

    // ✅ Username korrekt: wenn anonym -> "Anonym", sonst userName (Fallback)
    final String userName = anonymous
        ? 'Anonym'
        : ((data['userName'] ?? '').toString().trim().isNotEmpty
        ? (data['userName'] ?? '').toString().trim()
        : 'Unbekannter Nutzer');

    final comment = (data['comment'] ?? '').toString().trim();
    final rating = _parseRating(data['rating']) ?? 0;

    DateTime? eventDate;
    final rawEventDate = data['eventDate'];
    if (rawEventDate is Timestamp) {
      eventDate = rawEventDate.toDate();
    } else if (rawEventDate is String) {
      eventDate = DateTime.tryParse(rawEventDate);
    }

    DateTime? createdAt;
    final rawCreated = data['createdAt'];
    if (rawCreated is Timestamp) {
      createdAt = rawCreated.toDate();
    } else if (rawCreated is String) {
      createdAt = DateTime.tryParse(rawCreated);
    }

    final eventLine = eventDate != null ? '$eventTitle · ${_formatDate(eventDate)}' : eventTitle;
    final createdLine = createdAt != null ? _formatDateTime(createdAt) : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eventLine,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'von $userName',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildStars(rating),
              if (createdLine != null) ...[
                const SizedBox(width: 8),
                Text(
                  createdLine,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                  ),
                ),
              ]
            ],
          ),
          const SizedBox(height: 10),
          if (comment.isNotEmpty)
            Text(
              comment,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.35,
              ),
            )
          else
            const Text(
              'Kein Text-Feedback angegeben.',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  // ---------- Helper ----------

  static int? _parseRating(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      if (value < 1 || value > 5) return null;
      return value;
    }
    final parsed = int.tryParse(value.toString());
    if (parsed == null) return null;
    if (parsed < 1 || parsed > 5) return null;
    return parsed;
  }

  static Widget _buildStars(int rating) {
    rating = rating.clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i < rating) {
          return const Icon(Icons.star_rounded, color: Colors.amber, size: 18);
        } else {
          return const Icon(Icons.star_border_rounded, color: Colors.white38, size: 18);
        }
      }),
    );
  }

  static String _formatDate(DateTime d) {
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    final year = d.year.toString();
    return '$day.$month.$year';
  }

  static String _formatDateTime(DateTime d) {
    final date = _formatDate(d);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$date · $hh:$mm';
  }
}
