// lib/Widgets/bar_bottom_sheet.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Services/app_draggable_sheet.dart';
import '../Screens/bar_event_screen.dart';

/// ✅ Stabiler Event-Key (verhindert doppelte Keys durch UTC/Local/String/Timestamp Mix)
String computeEventKey(dynamic rawDate) {
  if (rawDate is Timestamp) {
    return rawDate.millisecondsSinceEpoch.toString();
  }
  if (rawDate is String) {
    final dt = DateTime.tryParse(rawDate);
    if (dt != null) return dt.toUtc().millisecondsSinceEpoch.toString();
  }
  return '0';
}

class BarBottomSheet extends StatefulWidget {
  final String barId;

  /// ✅ OPTIONAL:
  /// - Map/Marker: du kannst weiter barData übergeben (wie bisher)
  /// - "Meine Bar": du gibst nur barId -> Sheet lädt barData selbst aus Firestore
  final Map<String, dynamic>? barData;

  const BarBottomSheet({
    super.key,
    required this.barId,
    this.barData,
  });

  @override
  State<BarBottomSheet> createState() => _BarBottomSheetState();
}

class _BarBottomSheetState extends State<BarBottomSheet> {
  bool _showEventView = true;

  // ✅ Owner-Fallback (wenn dein Setup: barName == Account-Name aus Login)
  // -> Wir laden currentUsername einmal und vergleichen damit.
  String _currentUsernameLower = '';

  static const List<Map<String, String>> _days = [
    {'key': 'mon', 'short': 'Mo'},
    {'key': 'tue', 'short': 'Di'},
    {'key': 'wed', 'short': 'Mi'},
    {'key': 'thu', 'short': 'Do'},
    {'key': 'fri', 'short': 'Fr'},
    {'key': 'sat', 'short': 'Sa'},
    {'key': 'sun', 'short': 'So'},
  ];

  @override
  void initState() {
    super.initState();
    _loadCurrentUsername();
  }

  Future<void> _loadCurrentUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final u = (prefs.getString('currentUsername') ?? '').trim().toLowerCase();
      if (mounted) setState(() => _currentUsernameLower = u);
    } catch (_) {
      // ignore
    }
  }

  /// ✅ Besitzer-Check
  /// 1) primär über UID-Felder
  /// 2) Fallback: barName == currentUsername (SharedPreferences)
  bool _isOwner(Map<String, dynamic> barData) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    final ownerUid = (barData['ownerUid'] ??
        barData['ownerId'] ??
        barData['createdBy'] ??
        barData['userId'] ??
        '')
        .toString()
        .trim();

    if (ownerUid.isNotEmpty && ownerUid == uid) return true;

    final barName = (barData['barName'] ?? '').toString().trim().toLowerCase();
    if (barName.isNotEmpty &&
        _currentUsernameLower.isNotEmpty &&
        barName == _currentUsernameLower) {
      return true;
    }

    return false;
  }

  // --------------------------------------------------------------------------
  // WICHTIGER FIX: KEINE Composite-Index-Queries mehr
  // --------------------------------------------------------------------------

  /// ✅ Sichtbares Event: Kandidaten nach visibleFrom (desc) holen, lokal filtern.
  Query<Map<String, dynamic>> _visibleEventCandidatesQuery(String barId) {
    final nowTs = Timestamp.fromDate(DateTime.now());
    return FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('events')
        .where('visibleFrom', isLessThanOrEqualTo: nowTs)
        .orderBy('visibleFrom', descending: true)
        .limit(25);
  }

  /// ✅ Upcoming Liste: nach startAt sortiert holen, lokal filtern.
  Query<Map<String, dynamic>> _upcomingCandidatesQuery(String barId) {
    return FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('events')
        .orderBy('startAt', descending: false)
        .limit(50);
  }

  // ✅ Bar-Dokument Stream (für "Meine Bar": nur barId, Daten kommen aus Firestore)
  Stream<DocumentSnapshot<Map<String, dynamic>>> _barDocStream() {
    return FirebaseFirestore.instance.collection('bars').doc(widget.barId).snapshots();
  }

  DateTime? _readDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    if (v is DateTime) return v;
    return null;
  }

  bool _isActive(Map<String, dynamic> e) => e['active'] == true;

  bool _isNotOver(Map<String, dynamic> e) {
    final cleanupAt = _readDate(e['cleanupAt']);
    if (cleanupAt == null) return true; // wenn fehlt: lieber anzeigen als verstecken
    return DateTime.now().isBefore(cleanupAt);
  }

  bool _isVisibleNow(Map<String, dynamic> e) {
    final vf = _readDate(e['visibleFrom']);
    if (vf == null) return true; // wenn fehlt: lieber anzeigen als verstecken
    final now = DateTime.now();
    return now.isAfter(vf) || now.isAtSameMomentAs(vf);
  }

  /// ✅ Mapping: Event-Dokument (neues Schema) -> Legacy Keys (damit bestehende UI/EventBottomSheet passt)
  Map<String, dynamic> _applyEventMappingToBarData({
    required Map<String, dynamic> baseBarData,
    required String eventId,
    required Map<String, dynamic> e,
  }) {
    final merged = Map<String, dynamic>.from(baseBarData);

    merged['eventId'] = eventId;

    // Legacy Keys
    merged['eventActive'] = true;
    merged['eventDate'] = e['startAt']; // Timestamp
    merged['eventVisibleFrom'] = e['visibleFrom']; // Timestamp
    merged['eventCleanupAt'] = e['cleanupAt']; // Timestamp

    merged['eventTitle'] = (e['title'] ?? '').toString();
    merged['eventTagline'] = (e['tagline'] ?? '').toString();
    merged['eventDescription'] = (e['desc'] ?? '').toString();

    merged['eventSections'] = e['sections'];

    merged['eventEntry'] = (e['entry'] ?? '').toString();
    merged['eventEntryEnabled'] = e['entryEnabled'];

    merged['eventAge'] = (e['age'] ?? '').toString();
    merged['eventAgeEnabled'] = e['ageEnabled'];

    merged['eventMusic'] = (e['music'] ?? '').toString();
    merged['eventMusicEnabled'] = e['musicEnabled'];

    merged['eventDresscode'] = (e['dresscode'] ?? '').toString();
    merged['eventDresscodeEnabled'] = e['dresscodeEnabled'];

    return merged;
  }

  Future<void> _openEditEvent(String eventId) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BarEventScreen(
          barId: widget.barId,
          eventId: eventId,
        ),
      ),
    );
  }

  Future<bool> _confirmDeleteOnce({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0E1117),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(message, style: const TextStyle(color: Colors.white70)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmText),
            ),
          ],
        );
      },
    );
    return res == true;
  }

  Future<void> _deleteEventWithDoubleConfirm({
    required String eventId,
    required String title,
  }) async {
    final ok1 = await _confirmDeleteOnce(
      title: 'Event löschen?',
      message: 'Möchtest du "$title" wirklich löschen?',
      confirmText: 'Löschen',
    );
    if (!ok1) return;

    final ok2 = await _confirmDeleteOnce(
      title: 'Wirklich endgültig löschen?',
      message: 'Das kann nicht rückgängig gemacht werden.',
      confirmText: 'Endgültig löschen',
    );
    if (!ok2) return;

    try {
      await FirebaseFirestore.instance
          .collection('bars')
          .doc(widget.barId)
          .collection('events')
          .doc(eventId)
          .delete();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event gelöscht.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fehler beim Löschen des Events.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Wenn barData übergeben wurde (Marker-Klick etc.), alles wie bisher
    if (widget.barData != null) {
      return _buildSheetWithBarData(context, widget.barData!);
    }

    // ✅ Wenn KEIN barData übergeben wurde ("Meine Bar"): Bar-Daten live aus Firestore holen
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _barDocStream(),
      builder: (context, barSnap) {
        if (barSnap.hasError) {
          return const Center(
            child: Text(
              'Bar konnte nicht geladen werden.',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }
        if (!barSnap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!(barSnap.data?.exists ?? false)) {
          return const Center(
            child: Text(
              'Bar existiert nicht (mehr).',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        final data = barSnap.data!.data();
        if (data == null) {
          return const Center(
            child: Text(
              'Bar-Daten fehlen.',
              style: TextStyle(color: Colors.white70),
            ),
          );
        }

        return _buildSheetWithBarData(context, data);
      },
    );
  }

  // ✅ Original-Flow (dein bisheriges build), nur ausgelagert, damit barData von überall kommen kann
  Widget _buildSheetWithBarData(BuildContext context, Map<String, dynamic> barData) {
    // 1) Stream für Kandidaten (sichtbares Event)
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _visibleEventCandidatesQuery(widget.barId).snapshots(),
      builder: (context, visibleSnap) {
        final Map<String, dynamic> mergedBarData = Map<String, dynamic>.from(barData);

        // Wenn Firestore-Query wirklich hart scheitert, zeigen wir trotzdem das Sheet ohne Event
        if (visibleSnap.hasError) {
          mergedBarData['eventActive'] = false;
          mergedBarData.remove('eventId');
          return _buildWithUpcomingStream(context, mergedBarData, visibleError: visibleSnap.error);
        }

        if (visibleSnap.hasData && (visibleSnap.data?.docs.isNotEmpty ?? false)) {
          // Kandidaten: aktiv + sichtbar + nicht vorbei
          final candidates = visibleSnap.data!.docs.where((d) {
            final e = d.data();
            return _isActive(e) && _isVisibleNow(e) && _isNotOver(e);
          }).toList();

          if (candidates.isNotEmpty) {
            final doc = candidates.first;
            final e = doc.data();

            final mapped = _applyEventMappingToBarData(
              baseBarData: mergedBarData,
              eventId: doc.id,
              e: e,
            );

            mapped['eventActive'] = true;
            return _buildWithUpcomingStream(context, mapped);
          }
        }

        // Kein sichtbares Event
        mergedBarData['eventActive'] = false;
        mergedBarData.remove('eventId');
        return _buildWithUpcomingStream(context, mergedBarData);
      },
    );
  }

  /// 2) Stream für kommende Events Liste (Bar-Infos)
  Widget _buildWithUpcomingStream(
      BuildContext context,
      Map<String, dynamic> barDataForUi, {
        Object? visibleError,
      }) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _upcomingCandidatesQuery(widget.barId).snapshots(),
      builder: (context, upcomingSnap) {
        final upcomingDocs = (upcomingSnap.data?.docs ?? []);

        // ---------- BAR-DATEN ----------
        final barName = (barDataForUi['barName'] ?? 'Bar').toString();
        final address = (barDataForUi['address'] ?? '').toString();
        final city = (barDataForUi['city'] ?? '').toString();
        final country = (barDataForUi['country'] ?? '').toString();
        final description = (barDataForUi['description'] ?? '').toString();
        final profileImageUrl = (barDataForUi['profileImageUrl'] ?? '').toString().trim();

        final fullAddress = [
          address,
          [city, country].where((e) => e.trim().isNotEmpty).join(', ')
        ].where((e) => e.trim().isNotEmpty).join(' · ');

        final double? ratingAvg =
        barDataForUi['ratingAvg'] != null ? (barDataForUi['ratingAvg'] as num).toDouble() : null;
        final int ratingCount =
        barDataForUi['ratingCount'] != null ? (barDataForUi['ratingCount'] as num).toInt() : 0;

        final Map<String, dynamic>? openingHoursRaw = barDataForUi['openingHours'] is Map<String, dynamic>
            ? Map<String, dynamic>.from(barDataForUi['openingHours'])
            : null;

        final List<Map<String, dynamic>> barHighlights = _safeHighlights(barDataForUi['barHighlights']);

        // ---------- EVENT-DATEN (sichtbares Event für Event-Tab) ----------
        final bool eventActive = barDataForUi['eventActive'] == true;

        DateTime? eventDateTime;
        final rawDate = barDataForUi['eventDate'];
        if (rawDate is Timestamp) {
          eventDateTime = rawDate.toDate();
        } else if (rawDate is String) {
          eventDateTime = DateTime.tryParse(rawDate);
        }

        final String eventTitle = (barDataForUi['eventTitle'] ?? '').toString().trim();
        final String eventTagline = (barDataForUi['eventTagline'] ?? '').toString().trim();
        final String eventDesc = (barDataForUi['eventDescription'] ?? '').toString().trim();

        final bool entryEnabled = barDataForUi['eventEntryEnabled'] != false;
        final bool ageEnabled = barDataForUi['eventAgeEnabled'] != false;
        final bool musicEnabled = barDataForUi['eventMusicEnabled'] != false;
        final bool dresscodeEnabled = barDataForUi['eventDresscodeEnabled'] != false;

        final String entryRaw = (barDataForUi['eventEntry'] ?? '').toString().trim();
        final String ageRaw = (barDataForUi['eventAge'] ?? '').toString().trim();
        final String musicRaw = (barDataForUi['eventMusic'] ?? '').toString().trim();
        final String dresscodeRaw = (barDataForUi['eventDresscode'] ?? '').toString().trim();

        final String entryText = entryEnabled ? (entryRaw.isEmpty ? 'Details folgen' : entryRaw) : 'Kein Eintritt';
        final String ageText = ageEnabled ? (ageRaw.isEmpty ? 'Standard (z. B. 18+)' : ageRaw) : 'Kein Mindestalter';
        final String musicText =
        musicEnabled ? (musicRaw.isEmpty ? 'Musik wird noch bekannt gegeben' : musicRaw) : 'Keine Musikangabe';
        final String dresscodeText =
        dresscodeEnabled ? (dresscodeRaw.isEmpty ? 'Kein Dresscode vorgegeben' : dresscodeRaw) : 'Kein Dresscode';

        final List<Map<String, dynamic>> sections = _safeSections(barDataForUi['eventSections']);

        // Sichtbarkeit/cleanup fürs sichtbare Event
        DateTime? eventVisibleFrom;
        final rawVisibleFrom = barDataForUi['eventVisibleFrom'];
        if (rawVisibleFrom is Timestamp) {
          eventVisibleFrom = rawVisibleFrom.toDate();
        } else if (rawVisibleFrom is String) {
          eventVisibleFrom = DateTime.tryParse(rawVisibleFrom);
        }

        DateTime? eventCleanupAt;
        final rawCleanupAt = barDataForUi['eventCleanupAt'];
        if (rawCleanupAt is Timestamp) {
          eventCleanupAt = rawCleanupAt.toDate();
        } else if (rawCleanupAt is String) {
          eventCleanupAt = DateTime.tryParse(rawCleanupAt);
        }

        // ---------- Event-Status (sichtbares Event) ----------
        final now = DateTime.now();
        bool hasEvent = eventActive && eventDateTime != null;

        bool showEventCard = false; // sichtbar bis cleanupAt
        bool eventRunning12hWindow = false; // Start-1h bis cleanupAt
        bool showOnlyEventDateHint = false; // Vor Sichtbarkeit: nur Datum-Hinweis

        DateTime? start; // eventDate - 1h

        if (hasEvent) {
          final startAt = eventDateTime!;
          start = startAt.subtract(const Duration(hours: 1));

          final visibleFrom = eventVisibleFrom ?? start.subtract(const Duration(days: 7));
          final cleanupAt = eventCleanupAt ?? start.add(const Duration(hours: 12));

          if (now.isAfter(cleanupAt)) {
            showEventCard = false;
            showOnlyEventDateHint = false;
            hasEvent = false;
          } else {
            if ((now.isAfter(visibleFrom) || now.isAtSameMomentAs(visibleFrom)) && now.isBefore(cleanupAt)) {
              showEventCard = true;
            }

            if ((now.isAfter(start) || now.isAtSameMomentAs(start)) && now.isBefore(cleanupAt)) {
              eventRunning12hWindow = true;
            }

            if (!showEventCard && now.isBefore(visibleFrom)) {
              showOnlyEventDateHint = true;
            }
          }
        }

        // ---------- AVATAR ----------
        Widget avatar;
        if (profileImageUrl.isNotEmpty) {
          avatar = CircleAvatar(
            radius: 48,
            backgroundColor: const Color(0xFF1C1F26),
            backgroundImage: NetworkImage(profileImageUrl),
          );
        } else {
          avatar = Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1C1F26),
            ),
            child: const Icon(Icons.local_bar, color: Colors.white70, size: 40),
          );
        }

        final bool showAnyEventUi = hasEvent && showEventCard && eventDateTime != null;

        // Datum-Hinweis Text (für "davor nur Datum")
        String? eventDateHintText;
        if (hasEvent && eventDateTime != null) {
          final dateStr =
              '${eventDateTime.day.toString().padLeft(2, '0')}.${eventDateTime.month.toString().padLeft(2, '0')}.${eventDateTime.year}';
          final timeStr =
              '${eventDateTime.hour.toString().padLeft(2, '0')}:${eventDateTime.minute.toString().padLeft(2, '0')}';
          eventDateHintText = 'Nächstes Event: $dateStr · $timeStr';
        }

        final bool isOwner = _isOwner(barDataForUi);

        // ---------- UPCOMING LIST MODEL (für Bar-Infos) ----------
        final List<_UpcomingEventItem> upcomingItems = upcomingDocs.map((d) {
          final data = d.data();

          final startAt = _readDate(data['startAt']);
          final title = (data['title'] ?? '').toString().trim();

          return _UpcomingEventItem(
            eventId: d.id,
            startAt: startAt,
            title: title,
            active: data['active'] == true,
            cleanupAt: _readDate(data['cleanupAt']),
          );
        }).where((e) {
          if (!e.active) return false;
          if (e.startAt == null) return false;
          if (e.title.trim().isEmpty) return false;
          if (e.cleanupAt != null && !DateTime.now().isBefore(e.cleanupAt!)) return false;
          return true;
        }).toList();

        final upcomingHasError = upcomingSnap.hasError;

        return AppDraggableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.25,
          maxChildSize: 0.98,
          snapSizes: const [0.75, 0.98],
          panelColor: const Color(0xCC090B10),
          borderColor: const Color(0x22FFFFFF),
          autoFit: true,
          childBuilder: (context, scrollController) {
            return SafeArea(
              top: false,
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  MediaQuery.of(context).viewInsets.bottom + 16,
                ),
                children: [
                  const SizedBox(height: 8),

                  Center(child: avatar),
                  const SizedBox(height: 14),

                  Text(
                    barName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  if (ratingAvg != null && ratingCount > 0) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 18),
                        const SizedBox(width: 4),
                        Text(
                          ratingAvg.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '($ratingCount)',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 8),

                  if (fullAddress.isNotEmpty)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.location_on, color: Colors.redAccent, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            fullAddress,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFB6BDC8),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 10),

                  if (visibleError != null)
                    Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141A22),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: const Text(
                        'Event-Laden fehlgeschlagen. Bar-Infos werden trotzdem angezeigt.',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ),

                  // ✅ VOR Sichtbarkeit: Datum-Hinweis (Owner klickt -> Edit)
                  if (showOnlyEventDateHint && eventDateHintText != null) ...[
                    InkWell(
                      onTap: isOwner
                          ? () {
                        final String? eventId =
                        (barDataForUi['eventId'] ?? '').toString().trim().isEmpty
                            ? null
                            : (barDataForUi['eventId'] ?? '').toString().trim();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BarEventScreen(
                              barId: widget.barId,
                              eventId: eventId,
                            ),
                          ),
                        );
                      }
                          : null,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141A22),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.event, color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                eventDateHintText,
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ),
                            if (isOwner) const Icon(Icons.edit, color: Colors.white38, size: 18),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ] else ...[
                    const SizedBox(height: 18),
                  ],

                  // ✅ Tabs nur wenn Event-Card sichtbar ist (wie vorher)
                  if (showAnyEventUi) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ChoiceChip(
                          label: const Text('Event 🎉'),
                          selected: _showEventView,
                          onSelected: (_) => setState(() => _showEventView = true),
                          selectedColor: Colors.redAccent,
                          backgroundColor: const Color(0xFF1C1F26),
                          labelStyle: TextStyle(
                            color: _showEventView ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Bar-Infos 🍹'),
                          selected: !_showEventView,
                          onSelected: (_) => setState(() => _showEventView = false),
                          selectedColor: Colors.redAccent,
                          backgroundColor: const Color(0xFF1C1F26),
                          labelStyle: TextStyle(
                            color: !_showEventView ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (showAnyEventUi && _showEventView)
                    _buildEventInfoCard(
                      context: context,
                      eventDateTime: eventDateTime!,
                      eventRunning: eventRunning12hWindow,
                      eventData: barDataForUi,
                      entryText: entryText,
                      ageText: ageText,
                      musicText: musicText,
                      dresscodeText: dresscodeText,
                      sections: sections,
                      eventTitle: eventTitle,
                      eventTagline: eventTagline,
                      eventDesc: eventDesc,
                    )
                  else
                    _buildBarInfoContent(
                      description: description,
                      openingHours: openingHoursRaw,
                      barHighlights: barHighlights,
                      isOwner: isOwner,
                      upcoming: upcomingHasError ? const [] : upcomingItems,
                      showUpcomingErrorHint: upcomingHasError,
                    ),

                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ----------------- Helpers -----------------

  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw.where((e) => e is Map).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  List<Map<String, dynamic>> _safeHighlights(dynamic raw) {
    if (raw is List) {
      return raw.where((e) => e is Map).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  Widget _smallInfoChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 13),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ----------------- BAR INFOS + UPCOMING LIST -----------------

  Widget _buildBarInfoContent({
    required String description,
    required Map<String, dynamic>? openingHours,
    required List<Map<String, dynamic>> barHighlights,
    required bool isOwner,
    required List<_UpcomingEventItem> upcoming,
    required bool showUpcomingErrorHint,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showUpcomingErrorHint)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF141A22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: const Text(
                'Kommende Events konnten nicht geladen werden.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),

          // ✅ UPCOMING EVENTS LIST
          if (upcoming.isNotEmpty) ...[
            const Text(
              'Kommende Events',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            ...upcoming.map((e) => _upcomingEventRow(e, isOwner)),

            // ✅ Button am Ende der Liste (nur Owner)
            if (isOwner) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BarEventScreen(
                          barId: widget.barId,
                          eventId: null, // neues Event
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: const Text(
                    'Event erstellen',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),
          ] else ...[
            // Wenn keine Events da sind: Owner bekommt trotzdem einen Button
            if (isOwner) ...[
              const Text(
                'Kommende Events',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BarEventScreen(
                          barId: widget.barId,
                          eventId: null,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.add),
                  label: const Text(
                    'Erstes Event erstellen',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],

          Text(
            description.trim().isNotEmpty ? description : 'Keine zusätzlichen Bar-Infos hinterlegt.',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (openingHours != null && openingHours.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Öffnungszeiten',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            _buildOpeningHoursView(openingHours),
          ],
          if (barHighlights.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Bar-Highlights',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            ..._buildHighlightCards(barHighlights),
          ],
        ],
      ),
    );
  }

  Widget _upcomingEventRow(_UpcomingEventItem e, bool isOwner) {
    final dt = e.startAt!;
    final dateStr =
        '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.event, color: Colors.white70, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$dateStr · $timeStr — ${e.title}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isOwner) ...[
            IconButton(
              tooltip: 'Bearbeiten',
              onPressed: () => _openEditEvent(e.eventId),
              icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
            ),
            IconButton(
              tooltip: 'Löschen',
              onPressed: () => _deleteEventWithDoubleConfirm(
                eventId: e.eventId,
                title: e.title.isEmpty ? 'Event' : e.title,
              ),
              icon: const Icon(Icons.close, color: Colors.redAccent, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOpeningHoursView(Map<String, dynamic> opening) {
    final List<Widget> rows = [];

    for (final d in _days) {
      final key = d['key']!;
      final short = d['short']!;
      final raw = opening[key];

      bool closed = false;
      String openStr = '--:--';
      String closeStr = '--:--';

      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        closed = map['closed'] == true;
        final o = (map['open'] ?? '').toString();
        final c = (map['close'] ?? '').toString();
        if (o.isNotEmpty) openStr = o;
        if (c.isNotEmpty) closeStr = c;
      }

      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  short,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  closed ? 'geschlossen' : '$openStr – $closeStr',
                  style: TextStyle(
                    color: closed ? Colors.redAccent : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  List<Widget> _buildHighlightCards(List<Map<String, dynamic>> highlights) {
    final List<Widget> widgets = [];
    for (final h in highlights) {
      final text = (h['text'] ?? '').toString().trim();
      final imageUrl = (h['imageUrl'] ?? '').toString().trim();

      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF141A22),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                  child: Image.network(
                    imageUrl,
                    height: 140,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              if (text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return widgets;
  }

  // -------------------------------- Event --------------------------------

  Widget _buildEventInfoCard({
    required BuildContext context,
    required DateTime eventDateTime,
    required bool eventRunning,
    required Map<String, dynamic> eventData,
    required String entryText,
    required String ageText,
    required String musicText,
    required String dresscodeText,
    required List<Map<String, dynamic>> sections,
    required String eventTitle,
    required String eventTagline,
    required String eventDesc,
  }) {
    final now = DateTime.now();

    final startRaw = eventDateTime;
    final start = startRaw.subtract(const Duration(hours: 1));

    // cleanupAt bevorzugt (aus Firestore), sonst fallback 12h
    DateTime? cleanupAt;
    final rawCleanupAt = eventData['eventCleanupAt'];
    if (rawCleanupAt is Timestamp) cleanupAt = rawCleanupAt.toDate();
    if (rawCleanupAt is String) cleanupAt = DateTime.tryParse(rawCleanupAt);
    cleanupAt ??= start.add(const Duration(hours: 12));

    String label;
    if (now.isBefore(start)) {
      final diff = start.difference(now);
      label = '⏱️ Event startet in ${_formatDuration(diff)}';
    } else if (now.isAfter(start) && now.isBefore(cleanupAt)) {
      final diff = cleanupAt.difference(now);
      label = '🔥 Event läuft noch ${_formatDuration(diff)}';
    } else {
      label = 'Event ist bereits vorbei.';
    }

    final dateStr =
        '${eventDateTime.day.toString().padLeft(2, '0')}.${eventDateTime.month.toString().padLeft(2, '0')}.${eventDateTime.year}';
    final timeStr =
        '${eventDateTime.hour.toString().padLeft(2, '0')}:${eventDateTime.minute.toString().padLeft(2, '0')}';

    void openEventInfos() {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withOpacity(0.35),
        builder: (_) => EventBottomSheet(
          eventData: eventData,
          barId: widget.barId,
        ),
      );
    }

    return InkWell(
      onTap: openEventInfos,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1F26),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.redAccent.withOpacity(0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eventRunning ? 'Live-Event 🔥' : 'Nächstes Event 🎉',
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              eventTitle.isEmpty ? 'Event' : eventTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.calendar_month, color: Colors.white70, size: 18),
                const SizedBox(width: 6),
                Text(
                  '$dateStr · $timeStr',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.redAccent),
              ),
              child: Row(
                children: [
                  const Icon(Icons.timer, color: Colors.redAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _smallInfoChip(Icons.attach_money, entryText),
                _smallInfoChip(Icons.cake, ageText),
                _smallInfoChip(Icons.music_note, musicText),
                _smallInfoChip(Icons.checkroom, dresscodeText),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                ),
                onPressed: openEventInfos,
                child: const Text(
                  'Event-Infos',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds <= 0) return '0 Min';
    final days = d.inDays;
    final hours = d.inHours.remainder(24);
    final mins = d.inMinutes.remainder(60);

    final parts = <String>[];
    if (days > 0) parts.add('${days}T');
    if (hours > 0) parts.add('${hours}h');
    if (mins > 0) parts.add('${mins}m');

    return parts.join(' ');
  }
}

class _UpcomingEventItem {
  final String eventId;
  final DateTime? startAt;
  final String title;
  final bool active;
  final DateTime? cleanupAt;

  _UpcomingEventItem({
    required this.eventId,
    required this.startAt,
    required this.title,
    required this.active,
    required this.cleanupAt,
  });
}

/// BottomSheet nur für das Event
class EventBottomSheet extends StatelessWidget {
  final Map<String, dynamic> eventData;
  final String barId;

  const EventBottomSheet({
    super.key,
    required this.eventData,
    required this.barId,
  });

  DateTime? _readDate(dynamic v) {
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    if (v is DateTime) return v;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bool eventActive = eventData['eventActive'] == true;

    DateTime? eventDateTime;
    final rawDate = eventData['eventDate']; // ✅ rawDate behalten!
    if (rawDate is Timestamp) {
      eventDateTime = rawDate.toDate();
    } else if (rawDate is String) {
      eventDateTime = DateTime.tryParse(rawDate);
    }

    final String eventTitle = (eventData['eventTitle'] ?? '').toString().trim();
    final String eventTagline = (eventData['eventTagline'] ?? '').toString().trim();
    final String eventDesc = (eventData['eventDescription'] ?? '').toString().trim();

    final bool entryEnabled = eventData['eventEntryEnabled'] != false;
    final bool ageEnabled = eventData['eventAgeEnabled'] != false;
    final bool musicEnabled = eventData['eventMusicEnabled'] != false;
    final bool dresscodeEnabled = eventData['eventDresscodeEnabled'] != false;

    final String entryRaw = (eventData['eventEntry'] ?? '').toString().trim();
    final String ageRaw = (eventData['eventAge'] ?? '').toString().trim();
    final String musicRaw = (eventData['eventMusic'] ?? '').toString().trim();
    final String dresscodeRaw = (eventData['eventDresscode'] ?? '').toString().trim();

    final String entryText = entryEnabled ? (entryRaw.isEmpty ? 'Details folgen' : entryRaw) : 'Kein Eintritt';
    final String ageText = ageEnabled ? (ageRaw.isEmpty ? 'Standard (z. B. 18+)' : ageRaw) : 'Kein Mindestalter';
    final String musicText =
    musicEnabled ? (musicRaw.isEmpty ? 'Musik wird noch bekannt gegeben' : musicRaw) : 'Keine Musikangabe';
    final String dresscodeText =
    dresscodeEnabled ? (dresscodeRaw.isEmpty ? 'Kein Dresscode vorgegeben' : dresscodeRaw) : 'Kein Dresscode';

    final List<Map<String, dynamic>> sections = _safeSections(eventData['eventSections']);

    // ✅ Laufzeit / Rating aus cleanupAt ableiten
    final now = DateTime.now();
    bool hasEvent = eventActive && eventDateTime != null;

    bool eventRunning = false;
    bool ratingAllowed = false;

    if (hasEvent) {
      final startAt = eventDateTime!;
      final start = startAt.subtract(const Duration(hours: 1));

      DateTime? cleanupAt = _readDate(eventData['eventCleanupAt']);
      cleanupAt ??= start.add(const Duration(hours: 12));

      if (now.isAfter(cleanupAt)) {
        hasEvent = false;
      } else {
        eventRunning = (now.isAfter(start) || now.isAtSameMomentAs(start)) && now.isBefore(cleanupAt);

        // rating nur im 12h-Fenster wie vorher
        final ratingUntil = start.add(const Duration(hours: 12));
        ratingAllowed = (now.isAfter(start) || now.isAtSameMomentAs(start)) && now.isBefore(ratingUntil);
      }
    }

    return AppDraggableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.25,
      maxChildSize: 0.98,
      snapSizes: const [0.85, 0.98],
      panelColor: const Color(0xCC090B10),
      borderColor: const Color(0x22FFFFFF),
      autoFit: true,
      childBuilder: (context, scrollController) {
        return SafeArea(
          top: false,
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            children: [
              if (hasEvent && eventDateTime != null)
                EventDetailsCard(
                  barId: barId,
                  title: eventTitle,
                  tagline: eventTagline,
                  desc: eventDesc,
                  eventDateTime: eventDateTime!,
                  rawEventDate: rawDate,
                  eventRunning: eventRunning,
                  entryText: entryText,
                  ageText: ageText,
                  musicText: musicText,
                  dresscodeText: dresscodeText,
                  sections: sections,
                  ratingAllowed: ratingAllowed,
                )
              else
                const NoEventCard(),
            ],
          ),
        );
      },
    );
  }

  List<Map<String, dynamic>> _safeSections(dynamic raw) {
    if (raw is List) {
      return raw.where((e) => e is Map).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }
}

/// Karte mit den Event-Infos (wird von EventBottomSheet genutzt)
class EventDetailsCard extends StatelessWidget {
  final String barId;
  final String title;
  final String tagline;
  final String desc;
  final DateTime eventDateTime;
  final dynamic rawEventDate;
  final bool eventRunning;
  final String entryText;
  final String ageText;
  final String musicText;
  final String dresscodeText;
  final List<Map<String, dynamic>> sections;
  final bool ratingAllowed;

  const EventDetailsCard({
    super.key,
    required this.barId,
    required this.title,
    required this.tagline,
    required this.desc,
    required this.eventDateTime,
    required this.rawEventDate,
    required this.eventRunning,
    required this.entryText,
    required this.ageText,
    required this.musicText,
    required this.dresscodeText,
    required this.sections,
    required this.ratingAllowed,
  });

  String get _eventKey => computeEventKey(rawEventDate);

  Future<User?> _ensureUser(BuildContext context) async {
    final auth = FirebaseAuth.instance;

    if (auth.currentUser != null) return auth.currentUser;

    try {
      final cred = await auth.signInAnonymously();
      return cred.user;
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Login fehlgeschlagen. Bitte App neu starten.')),
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${eventDateTime.day.toString().padLeft(2, '0')}.${eventDateTime.month.toString().padLeft(2, '0')}.${eventDateTime.year}';
    final timeStr =
        '${eventDateTime.hour.toString().padLeft(2, '0')}:${eventDateTime.minute.toString().padLeft(2, '0')}';

    final headline = eventRunning ? 'Event läuft gerade 🔥' : 'Nächstes Event 🎉';

    final bool hasAnySectionImage = sections.any((s) {
      final imageUrl = (s['imageUrl'] ?? '').toString().trim();
      return imageUrl.isNotEmpty;
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.redAccent.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            headline,
            style: const TextStyle(
              color: Colors.redAccent,
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title.isEmpty ? 'Event' : title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (tagline.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              tagline,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.calendar_month, color: Colors.white70, size: 18),
              const SizedBox(width: 6),
              Text(
                '$dateStr · $timeStr',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow('💸', Colors.greenAccent, 'Eintritt', entryText),
          const SizedBox(height: 6),
          _infoRow('🎂', Colors.pinkAccent, 'Mindestalter', ageText),
          const SizedBox(height: 6),
          _infoRow('🎵', Colors.lightBlueAccent, 'Musik', musicText),
          const SizedBox(height: 6),
          _infoRow('👗', Colors.deepPurpleAccent, 'Dresscode', dresscodeText),
          const SizedBox(height: 16),
          _EventRatingSummary(barId: barId, eventKey: _eventKey),
          const SizedBox(height: 16),
          if (desc.isNotEmpty)
            Align(
              alignment: hasAnySectionImage ? Alignment.centerLeft : Alignment.center,
              child: Text(
                desc,
                textAlign: hasAnySectionImage ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: hasAnySectionImage ? 13 : 14,
                  height: 1.35,
                ),
              ),
            ),
          if (sections.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text(
              'Highlights ✨',
              style: TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            ..._buildSections(sections),
          ],
          if (ratingAllowed) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.center,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                ),
                onPressed: () async => _handleRatePressed(context),
                icon: const Icon(Icons.star_rate_rounded, size: 18),
                label: const Text(
                  'Event / Bar bewerten ⭐',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleRatePressed(BuildContext context) async {
    final user = await _ensureUser(context);
    if (user == null) return;

    final uid = user.uid;
    final firestore = FirebaseFirestore.instance;
    final feedbackRef = firestore.collection('bars').doc(barId).collection('eventFeedback');

    final String docId = '${_eventKey}_$uid';

    try {
      final snap = await feedbackRef.doc(docId).get();
      if (snap.exists) {
        final data = (snap.data() as Map<String, dynamic>?) ?? {};
        final existingRating = (data['rating'] is num) ? (data['rating'] as num).toInt() : 0;
        final existingComment = (data['comment'] ?? '').toString();
        _showAlreadyRatedSheet(
          context: context,
          rating: existingRating,
          comment: existingComment,
        );
        return;
      }

      _openRatingDialog(context);
    } catch (_) {
      _openRatingDialog(context);
    }
  }

  void _showAlreadyRatedSheet({
    required BuildContext context,
    required int rating,
    required String comment,
  }) {
    final TextEditingController c = TextEditingController(
      text: 'Du hast dieses Event bereits bewertet.',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF090B10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 46,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Bewertung vorhanden',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(5, (i) {
                      final filled = i < rating;
                      return Icon(
                        filled ? Icons.star : Icons.star_border,
                        color: Colors.amber,
                      );
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: c,
                    readOnly: true,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      filled: true,
                      fillColor: Color(0xFF141A22),
                      border: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                  ),
                  if (comment.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141A22),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        comment.trim(),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openRatingDialog(BuildContext context) {
    final TextEditingController controller = TextEditingController();
    int selectedRating = 0;
    bool isAnonymous = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF090B10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white12),
            ),
            child: StatefulBuilder(
              builder: (ctx, setState) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 46,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Bar / Event bewerten',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(5, (index) {
                          final starIndex = index + 1;
                          final filled = starIndex <= selectedRating;
                          return IconButton(
                            icon: Icon(filled ? Icons.star : Icons.star_border),
                            color: Colors.amber,
                            onPressed: () => setState(() => selectedRating = starIndex),
                          );
                        }),
                      ),
                      SwitchListTile(
                        value: isAnonymous,
                        onChanged: (v) => setState(() => isAnonymous = v),
                        activeColor: Colors.redAccent,
                        title: const Text(
                          'Anonym bewerten',
                          style: TextStyle(color: Colors.white),
                        ),
                        subtitle: const Text(
                          'Wenn aktiv, wird dein Name nicht angezeigt.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: controller,
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Optionales Feedback für die Bar ...',
                          hintStyle: TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Color(0xFF141A22),
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                            borderRadius: BorderRadius.all(Radius.circular(12)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                            borderRadius: BorderRadius.all(Radius.circular(12)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.redAccent),
                            borderRadius: BorderRadius.all(Radius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text(
                                'Abbrechen',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: selectedRating == 0
                                  ? null
                                  : () async {
                                final comment = controller.text;
                                Navigator.of(ctx).pop();
                                await _submitRating(
                                  context,
                                  selectedRating,
                                  comment,
                                  isAnonymous,
                                );
                              },
                              child: const Text('Senden'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _submitRating(
      BuildContext context,
      int rating,
      String? comment,
      bool anonymous,
      ) async {
    final user = await _ensureUser(context);
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte logge dich ein, um zu bewerten.')),
      );
      return;
    }

    final uid = user.uid;

    final prefs = await SharedPreferences.getInstance();
    final savedUsername = (prefs.getString('currentUsername') ?? '').trim();

    final fallbackName =
    user.displayName?.trim().isNotEmpty == true ? user.displayName!.trim() : 'Unbekannter Nutzer';
    final userName = savedUsername.isNotEmpty ? savedUsername : fallbackName;

    final firestore = FirebaseFirestore.instance;
    final barRef = firestore.collection('bars').doc(barId);
    final feedbackRef = barRef.collection('eventFeedback');

    final String eventKey = _eventKey;
    final String docId = '${eventKey}_$uid';

    try {
      await firestore.runTransaction((tx) async {
        final docRef = feedbackRef.doc(docId);
        final snap = await tx.get(docRef);

        if (snap.exists) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'already-exists',
            message: 'Already rated',
          );
        }

        tx.set(docRef, {
          'rating': rating,
          'comment': comment?.trim(),
          'anonymous': anonymous,
          'createdAt': FieldValue.serverTimestamp(),
          'eventDate': eventDateTime,
          'eventTitle': title,
          'userId': uid,
          'userName': anonymous ? null : userName,
          'eventKey': eventKey,
        });
      });

      final allSnap = await feedbackRef.get();
      double sum = 0;
      int count = 0;
      for (final doc in allSnap.docs) {
        final data = doc.data();
        final r = data['rating'];
        if (r == null) continue;
        final int? rr = r is int ? r : int.tryParse(r.toString());
        if (rr == null || rr < 1 || rr > 5) continue;
        sum += rr;
        count++;
      }

      await barRef.set(
        {
          'ratingAvg': count > 0 ? sum / count : null,
          'ratingCount': count,
        },
        SetOptions(merge: true),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Danke für dein Feedback!')),
      );
    } on FirebaseException catch (e) {
      if (e.code == 'already-exists') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Du hast dieses Event bereits bewertet.')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fehler beim Speichern der Bewertung.')),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fehler beim Speichern der Bewertung.')),
      );
    }
  }

  Widget _infoRow(String emoji, Color emojiColor, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$emoji ', style: TextStyle(fontSize: 16, color: emojiColor)),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections(List<Map<String, dynamic>> sections) {
    final List<Widget> widgets = [];
    for (final s in sections) {
      final text = (s['text'] ?? '').toString();
      final imageUrl = (s['imageUrl'] ?? '').toString();
      final imageLeft = s['imageLeft'] == true;

      if (imageUrl.trim().isEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _sectionText(text, center: true, big: true),
          ),
        );
        continue;
      }

      final rowChildren = <Widget>[
        Expanded(flex: 4, child: _sectionImage(imageUrl)),
        const SizedBox(width: 10),
        Expanded(flex: 6, child: _sectionText(text)),
      ];

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: imageLeft ? rowChildren : rowChildren.reversed.toList(),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _sectionImage(String imageUrl) {
    if (imageUrl.isEmpty) {
      return Container(
        height: 90,
        decoration: BoxDecoration(
          color: const Color(0xFF141A22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Icon(Icons.image_not_supported, color: Colors.white38, size: 28),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        imageUrl,
        height: 90,
        width: double.infinity,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _sectionText(String text, {bool center = false, bool big = false}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(big ? 12 : 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141A22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        text,
        textAlign: center ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          color: Colors.white70,
          fontSize: big ? 13.5 : 12,
          height: 1.3,
        ),
      ),
    );
  }
}

class _EventRatingSummary extends StatelessWidget {
  final String barId;
  final String eventKey;

  const _EventRatingSummary({
    super.key,
    required this.barId,
    required this.eventKey,
  });

  @override
  Widget build(BuildContext context) {
    final query = FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('eventFeedback')
        .where('eventKey', isEqualTo: eventKey);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: query.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Row(
            children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text(
                'Bewertungen werden geladen ...',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          );
        }

        if (snapshot.hasError) {
          return const Text(
            'Fehler beim Laden der Bewertungen.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          );
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Text(
            'Noch keine Bewertungen für dieses Event.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          );
        }

        double sum = 0;
        int count = 0;
        for (final d in docs) {
          final r = d.data()['rating'];
          if (r == null) continue;
          final int? rr = r is int ? r : int.tryParse(r.toString());
          if (rr == null || rr < 1 || rr > 5) continue;
          sum += rr;
          count++;
        }
        final avg = sum / (count == 0 ? 1 : count);

        return Row(
          children: [
            const Icon(Icons.star, color: Colors.amber, size: 18),
            const SizedBox(width: 4),
            Text(
              '${avg.toStringAsFixed(1)} / 5',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '($count Bewertungen)',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

class NoEventCard extends StatelessWidget {
  const NoEventCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1F26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: const Row(
        children: [
          Icon(Icons.event_busy, color: Colors.white54),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Aktuell ist kein Event eingetragen.',
              style: TextStyle(color: Colors.white60),
            ),
          ),
        ],
      ),
    );
  }
}

/// Feedbackstream für eine Bar (optional)
class BarFeedbackStream extends StatelessWidget {
  final String barId;

  const BarFeedbackStream({
    super.key,
    required this.barId,
  });

  @override
  Widget build(BuildContext context) {
    final feedbackQuery = FirebaseFirestore.instance
        .collection('bars')
        .doc(barId)
        .collection('eventFeedback')
        .orderBy('createdAt', descending: true);

    return StreamBuilder<QuerySnapshot>(
      stream: feedbackQuery.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text(
            'Fehler beim Laden des Feedbacks.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          return const Text(
            'Noch kein Feedback vorhanden.',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Feedback 📝',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            ...docs.map((d) {
              final data = d.data() as Map<String, dynamic>? ?? {};
              final rating = data['rating'] != null ? (data['rating'] as num).toInt() : 0;
              final comment = (data['comment'] ?? '').toString().trim();
              final createdAt = data['createdAt'] as Timestamp?;
              final dateStr = createdAt != null
                  ? '${createdAt.toDate().day.toString().padLeft(2, '0')}.${createdAt.toDate().month.toString().padLeft(2, '0')}.${createdAt.toDate().year}'
                  : '';

              final bool anonymous = data['anonymous'] == true;
              final String userName = anonymous
                  ? 'Anonym'
                  : ((data['userName'] ?? '').toString().trim().isNotEmpty
                  ? (data['userName'] ?? '').toString().trim()
                  : 'Unbekannter Nutzer');

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF141A22),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Row(
                          children: List.generate(5, (index) {
                            final filled = index < rating;
                            return Icon(
                              filled ? Icons.star : Icons.star_border,
                              size: 16,
                              color: Colors.amber,
                            );
                          }),
                        ),
                        const SizedBox(width: 8),
                        if (dateStr.isNotEmpty)
                          Text(
                            dateStr,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      userName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (comment.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        comment,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
