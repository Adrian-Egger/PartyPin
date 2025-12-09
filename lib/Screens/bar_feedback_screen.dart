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
    const cardColor = Color(0xFF1C1F26);
    const accent = Color(0xFFFF3B30);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141A22),
        title: const Text(
          'Bar-Feedback',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        centerTitle: true,
      ),
      backgroundColor: bgColor,
      body: _loadingBarId
          ? const Center(
        child: CircularProgressIndicator(color: accent),
      )
          : _error != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ),
      )
          : _buildFeedbackStream(cardColor, accent),
    );
  }

  Widget _buildFeedbackStream(Color cardColor, Color accent) {
    final stream = FirebaseFirestore.instance
        .collection('bars')
        .doc(_barId)
        .collection('eventFeedback') // MUSS zur Schreib-Logik passen
        .orderBy('createdAt', descending: true)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
              child: CircularProgressIndicator(color: accent));
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
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Noch keine Feedbacks zu deinen Events vorhanden.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        // Durchschnitts-Rating berechnen
        double sum = 0;
        int count = 0;
        for (final d in docs) {
          final data = d.data();
          final r = _parseRating(data['rating']);
          if (r != null && r > 0) {
            sum += r;
            count++;
          }
        }
        final double? avg = count > 0 ? sum / count : null;

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          itemBuilder: (context, index) {
            if (index == 0 && avg != null) {
              // Oben eine kleine Karte mit Durchschnitt und Anzahl
              return Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: accent.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            color: Colors.amber, size: 28),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Durchschnitt: ${avg.toStringAsFixed(1)} / 5',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              '$count Feedback${count == 1 ? '' : 's'} insgesamt',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildFeedbackCard(
                    docs[0].data(),
                    cardColor: cardColor,
                    accent: accent,
                  ),
                ],
              );
            }

            final data = docs[avg != null ? index - 1 : index].data();
            return _buildFeedbackCard(
              data,
              cardColor: cardColor,
              accent: accent,
            );
          },
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemCount: avg != null ? docs.length + 1 : docs.length,
        );
      },
    );
  }

  Widget _buildFeedbackCard(
      Map<String, dynamic> data, {
        required Color cardColor,
        required Color accent,
      }) {
    final eventTitle =
    (data['eventTitle'] ?? 'Unbekanntes Event').toString().trim();
    final userName =
    (data['userName'] ?? 'Unbekannter Nutzer').toString().trim();
    final comment = (data['comment'] ?? '').toString().trim();

    final rating = _parseRating(data['rating']) ?? 0;

    DateTime? eventDate;
    final rawEventDate = data['eventDate'];
    if (rawEventDate is Timestamp) {
      eventDate = rawEventDate.toDate();
    }

    DateTime? createdAt;
    final rawCreated = data['createdAt'];
    if (rawCreated is Timestamp) {
      createdAt = rawCreated.toDate();
    }

    final eventLine = eventDate != null
        ? '$eventTitle · ${_formatDate(eventDate)}'
        : eventTitle;

    final createdLine =
    createdAt != null ? _formatDateTime(createdAt) : null;

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
          // Eventname + Datum
          Text(
            eventLine,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          // Wer es geschrieben hat
          Text(
            'von $userName',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          // Sterne
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
          // Kommentar
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

  int? _parseRating(dynamic value) {
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

  Widget _buildStars(int rating) {
    rating = rating.clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i < rating) {
          return const Icon(Icons.star_rounded,
              color: Colors.amber, size: 18);
        } else {
          return const Icon(Icons.star_border_rounded,
              color: Colors.white38, size: 18);
        }
      }),
    );
  }

  String _formatDate(DateTime d) {
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    final year = d.year.toString();
    return '$day.$month.$year';
  }

  String _formatDateTime(DateTime d) {
    final date = _formatDate(d);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$date · $hh:$mm';
  }
}
