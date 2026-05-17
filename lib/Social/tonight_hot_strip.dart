// lib/Social/tonight_hot_strip.dart
//
// Friends & Social Activity Layer — "Heute Abend in Linz"-Strip.
//
// Horizontale Liste der heute startenden Partys, sortiert nach
// goingCount (vom Aggregator gepflegt). Max 5 Cards.
//
// Reads:
//   - 1 Query (Party where startTime in [today, tomorrow])
//   - Default-Limit 30 pro Query (gefiltert + sortiert client-seitig)
//
// Auto-Hide wenn keine Party heute Abend. Tap → öffnet das übergebene
// onOpenParty-Callback (Caller entscheidet wie er das Sheet öffnet).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../Theme/app_theme.dart';
import 'party_activity.dart';

class _HotParty {
  const _HotParty({
    required this.id,
    required this.name,
    required this.start,
    required this.address,
    required this.activity,
  });
  final String id;
  final String name;
  final DateTime start;
  final String address;
  final PartyActivity activity;
}

class TonightHotStrip extends StatefulWidget {
  const TonightHotStrip({
    super.key,
    required this.onOpenParty,
    this.maxItems = 5,
    this.title = 'Heute Abend',
  });

  /// Callback wenn der User eine Card tippt. Bekommt die Party-ID.
  final void Function(String partyId) onOpenParty;
  final int maxItems;
  final String title;

  @override
  State<TonightHotStrip> createState() => _TonightHotStripState();
}

class _TonightHotStripState extends State<TonightHotStrip> {
  Future<List<_HotParty>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_HotParty>> _load() async {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    // Range-Query auf startTime. Sortierung nach goingCount machen wir
    // client-seitig — spart einen Composite-Index. 30 Docs decken jede
    // realistische Linz-Nightlife-Nacht.
    final snap = await FirebaseFirestore.instance
        .collection('Party')
        .where('startTime',
            isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart),
            isLessThan: Timestamp.fromDate(dayEnd))
        .limit(30)
        .get();

    final items = <_HotParty>[];
    for (final doc in snap.docs) {
      final d = doc.data();
      final start = (d['startTime'] is Timestamp)
          ? (d['startTime'] as Timestamp).toDate()
          : null;
      if (start == null) continue;
      // Nur "tonight" — heute aber noch nicht vorbei (Start in Zukunft
      // oder maximal 2h gestartet, damit laufende Partys mitgezählt
      // werden).
      if (start.isBefore(now.subtract(const Duration(hours: 2)))) continue;

      final activity = PartyActivity.fromPartyData(d);
      items.add(_HotParty(
        id: doc.id,
        name: (d['name'] ?? 'Party').toString().trim(),
        start: start,
        address: (d['address'] ?? '').toString().trim(),
        activity: activity,
      ));
    }

    // Phase-3-Sort: Momentum bevorzugt vor reinem Volumen. Surging
    // (≥5 RSVPs/h) ≈ +50 Sort-Boost, Rising ≈ +20. So überholt eine
    // wachsende Mini-Party eine stagnierende Großparty — was psycho-
    // logisch korrekt ist („was passiert gerade", nicht „was war").
    int sortKey(_HotParty p) {
      final base = p.activity.goingCount;
      if (!p.activity.isMomentumFresh) return base;
      final d = p.activity.goingDelta60m;
      if (d >= 5) return base + 50;
      if (d >= 2) return base + 20;
      return base;
    }
    items.sort((a, b) => sortKey(b).compareTo(sortKey(a)));
    return items.take(widget.maxItems).toList();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_HotParty>>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data ?? const <_HotParty>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        if (items.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.bolt_rounded,
                        size: 17, color: AppColors.accent),
                    const SizedBox(width: 6),
                    Text(
                      widget.title,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 104,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => _HotTile(
                    party: items[i],
                    onTap: () => widget.onOpenParty(items[i].id),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HotTile extends StatelessWidget {
  const _HotTile({required this.party, required this.onTap});
  final _HotParty party;
  final VoidCallback onTap;

  String _hhmm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final goingCount = party.activity.goingCount;
    final avatars = party.activity.goingRecent.take(3).toList();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 200,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.panel,
              AppColors.accent.withOpacity(0.12),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.accent.withOpacity(0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 12, color: AppColors.accent),
                const SizedBox(width: 4),
                Text(
                  _hhmm(party.start),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              party.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
              ),
            ),
            if (party.address.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                party.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const Spacer(),
            if (goingCount > 0)
              _MiniAvatarRow(
                avatars: avatars,
                goingCount: goingCount,
              )
            else
              Text(
                'Sei der erste',
                style: TextStyle(
                  color: AppColors.muted.withOpacity(0.8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniAvatarRow extends StatelessWidget {
  const _MiniAvatarRow({required this.avatars, required this.goingCount});
  final List<PartyAttendee> avatars;
  final int goingCount;

  @override
  Widget build(BuildContext context) {
    const size = 20.0;
    const overlap = 6.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: size,
          width: avatars.isEmpty
              ? 0
              : size + (avatars.length - 1) * (size - overlap),
          child: Stack(
            children: [
              for (int i = 0; i < avatars.length; i++)
                Positioned(
                  left: i * (size - overlap),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.panel,
                      border: Border.all(
                          color: AppColors.panel, width: 1.4),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: (avatars[i].avatarUrl ?? '').isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: avatars[i].avatarUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Container(
                              color: AppColors.bgTop,
                            ),
                            errorWidget: (_, __, ___) =>
                                _initial(avatars[i].username, size),
                          )
                        : _initial(avatars[i].username, size),
                  ),
                ),
            ],
          ),
        ),
        if (avatars.isNotEmpty) const SizedBox(width: 6),
        Text(
          '$goingCount going',
          style: TextStyle(
            color: AppColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  static Widget _initial(String username, double size) {
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    return Container(
      alignment: Alignment.center,
      color: AppColors.bgTop,
      child: Text(
        initial,
        style: TextStyle(
          color: AppColors.text,
          fontSize: size * 0.45,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
