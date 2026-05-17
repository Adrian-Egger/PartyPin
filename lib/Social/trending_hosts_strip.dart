// lib/Social/trending_hosts_strip.dart
//
// Horizontaler Scroller mit den Top-Trending-Hosts.
// Liest 1 Doc (trendingHosts/global) — minimaler Read-Footprint.
//
// Tap auf einen Host → öffnet User-Profile-Screen.
//
// Wird auf Map-Top und im Menu eingebaut.

import 'package:flutter/material.dart';

import '../Theme/app_theme.dart';
import 'host_badge.dart';
import 'host_level.dart';
import 'host_stats.dart';
import 'host_stats_service.dart';

class TrendingHostsStrip extends StatelessWidget {
  const TrendingHostsStrip({
    super.key,
    required this.onTapHost,
    this.title = 'Trending Hosts',
    this.maxItems,
    this.hideWhenEmpty = false,
    this.boostUsernames = const <String>{},
  });

  /// Callback wenn der User auf einen Trending-Host tippt.
  /// Caller entscheidet, wohin navigiert wird (UserProfile braucht
  /// `myUsername`, das hier nicht bekannt ist).
  final void Function(String username) onTapHost;
  final String title;

  /// Limitiert auf die Top-N Hosts. Null = alle anzeigen.
  /// Discovery-Surfaces wie access_parties verwenden i.d.R. 5,
  /// im persönlichen Host-Menu zeigen wir alle 10.
  final int? maxItems;

  /// Wenn true und keine Trending-Hosts existieren, rendert das Widget
  /// nichts (SizedBox.shrink). Default: false — wir zeigen einen
  /// motivierenden Empty-State. Sinnvoll für Discovery-Surfaces, wo
  /// ein leerer Strip nur Platz frisst.
  final bool hideWhenEmpty;

  /// Phase-4: Usernames mit aktiver (surging) Party heute. Diese
  /// werden vor reinen Lifetime-Trending-Hosts einsortiert — macht
  /// den Strip emotionaler ("wer ist heute aktiv" > "wer war letzte
  /// Woche groß"). Wird vom Caller aus bereits geladenen Party-Daten
  /// berechnet — keine zusätzlichen Reads.
  final Set<String> boostUsernames;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TrendingHost>>(
      stream: HostStatsService.watchTrending(),
      builder: (context, snap) {
        final raw = snap.data ?? const <TrendingHost>[];

        // Boost-Sort: aktive Hosts heute zuerst, dann Lifetime-Score.
        // Stable sort durch List.sort (Dart-Implementierung ist stable).
        List<TrendingHost> all = raw;
        if (boostUsernames.isNotEmpty) {
          all = List<TrendingHost>.from(raw)
            ..sort((a, b) {
              final aBoost = boostUsernames.contains(a.username) ? 1 : 0;
              final bBoost = boostUsernames.contains(b.username) ? 1 : 0;
              if (aBoost != bBoost) return bBoost - aBoost;
              return b.trendingScore.compareTo(a.trendingScore);
            });
        }

        final entries = maxItems != null && all.length > maxItems!
            ? all.sublist(0, maxItems!)
            : all;

        if (hideWhenEmpty && entries.isEmpty) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.local_fire_department_rounded,
                        size: 17, color: AppColors.accent),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const Spacer(),
                    if (entries.isNotEmpty)
                      Text(
                        '${entries.length} aktiv',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              if (entries.isEmpty)
                // Empty-State: motivational, nicht versteckt. Adrian's
                // erste 20–50 Hosts brauchen Sichtbarkeit.
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _TrendingEmptyCard(),
                )
              else
                SizedBox(
                  height: 96,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _TrendingTile(
                      host: entries[i],
                      rank: i + 1,
                      onTap: () => onTapHost(entries[i].username),
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

class _TrendingEmptyCard extends StatelessWidget {
  const _TrendingEmptyCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.panel,
            AppColors.accent.withOpacity(0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withOpacity(0.30)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accent.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.rocket_launch_rounded,
                color: AppColors.accent, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Noch keine Trending Hosts',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Sei einer der ersten Hosts in Linz — '
                  'eine erfolgreiche Party reicht.',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendingTile extends StatelessWidget {
  const _TrendingTile({
    required this.host,
    required this.rank,
    required this.onTap,
  });

  final TrendingHost host;
  final int rank;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = host.hostLevel;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 168,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.panel,
              level.color.withOpacity(0.18),
            ],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: level.color.withOpacity(0.55),
            width: 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    '#$rank',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const Spacer(),
                Icon(level.icon, color: level.color, size: 17),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '@${host.username}',
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              level.shortLabel,
              style: TextStyle(
                color: level.color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            Text(
              host.recentEvents7d > 0
                  ? '${host.recentAttendees7d} Gäste · 7 Tage'
                  : '${host.recentAttendees7d} Gäste',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim-Variante für die Map: einzeilige horizontale Pills mit
/// `HostBadge.tiny` + `@username`. Auto-Hide wenn keine Trending-Hosts.
///
/// Designziel: Map bleibt Discovery-first. Kein RPG-Look, kein extra
/// Section-Header, keine Stats. Nur ein subtiles "hier passiert was
/// in Linz"-Signal. Höhe ~36px.
class TrendingHostsPills extends StatelessWidget {
  const TrendingHostsPills({
    super.key,
    required this.onTapHost,
    this.maxItems = 5,
    this.horizontalPadding = 14,
  });

  final void Function(String username) onTapHost;
  final int maxItems;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TrendingHost>>(
      stream: HostStatsService.watchTrending(),
      builder: (context, snap) {
        final all = snap.data ?? const <TrendingHost>[];
        if (all.isEmpty) return const SizedBox.shrink();
        final entries = all.length > maxItems
            ? all.sublist(0, maxItems)
            : all;

        return SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final h = entries[i];
              return _TrendingPill(
                host: h,
                onTap: () => onTapHost(h.username),
              );
            },
          ),
        );
      },
    );
  }
}

class _TrendingPill extends StatelessWidget {
  const _TrendingPill({required this.host, required this.onTap});
  final TrendingHost host;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final level = host.hostLevel;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.panel.withOpacity(0.92),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: level.color.withOpacity(0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              HostBadge.tiny(level: level),
              const SizedBox(width: 6),
              Text(
                '@${host.username}',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.1,
                ),
              ),
              if (host.isNewcomer) ...[
                const SizedBox(width: 6),
                Text(
                  '🚀',
                  style: const TextStyle(fontSize: 11),
                ),
              ] else if (host.isGrowing) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.trending_up_rounded,
                  size: 13,
                  color: AppColors.success,
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}
