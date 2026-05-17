// lib/Social/host_stats_card.dart
//
// Vollständige Stats-Karte für User-Profile.
//
// Layout (von oben nach unten):
//   - Level-Hero (großes Icon + Level-Name + Tagline)
//   - Stats-Grid (3 KPIs: Events / Attendees / Rating)
//   - Progress-Hint zum nächsten Level (falls nicht Elite)
//
// Stil: gradient Hero-Block, Glow für ≥ Local. Dunkler Card-Hintergrund.

import 'package:flutter/material.dart';

import '../Theme/app_theme.dart';
import 'host_level.dart';
import 'host_stats.dart';

class HostStatsCard extends StatelessWidget {
  const HostStatsCard({
    super.key,
    required this.stats,
    this.compact = false,
  });

  final HostStats stats;

  /// Kompakte Variante: kein Progress-Footer, kleinere Hero.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final level = stats.hostLevel;
    final isElevated = level.rank >= HostLevel.local.rank;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isElevated
              ? level.color.withOpacity(0.45)
              : AppColors.accentBorder,
          width: 1.1,
        ),
        boxShadow: isElevated
            ? [
                BoxShadow(
                  color: level.color.withOpacity(0.18),
                  blurRadius: 24,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Hero(stats: stats, compact: compact),
          const SizedBox(height: 14),
          _StatsGrid(stats: stats),
          if (!compact && level != HostLevel.elite) ...[
            const SizedBox(height: 14),
            _ProgressFooter(stats: stats),
          ],
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.stats, required this.compact});
  final HostStats stats;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final level = stats.hostLevel;
    final isElevated = level.rank >= HostLevel.local.rank;
    final iconSize = compact ? 36.0 : 44.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: iconSize + 18,
          height: iconSize + 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Rookie: dezent (kein Gradient-Pop, kein Glow). Ab Local:
            // voller Akzent + Drop-Shadow.
            gradient: isElevated
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [level.color, level.colorAccent],
                  )
                : null,
            color: isElevated ? null : level.color.withOpacity(0.18),
            shape: BoxShape.circle,
            border: isElevated
                ? null
                : Border.all(color: level.color.withOpacity(0.45), width: 1),
            boxShadow: isElevated
                ? [
                    BoxShadow(
                      color: level.color.withOpacity(0.45),
                      blurRadius: 16,
                      spreadRadius: -2,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            level.icon,
            color: isElevated ? Colors.white : level.color,
            size: iconSize,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      level.label,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.3,
                        height: 1.1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(level.emoji, style: const TextStyle(fontSize: 18)),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                level.tagline,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});
  final HostStats stats;

  @override
  Widget build(BuildContext context) {
    final positivePct = (stats.ratingPositiveRate * 100).round();

    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.event_available_rounded,
            value: stats.successfulEvents.toString(),
            label: 'Events',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            icon: Icons.group_rounded,
            value: stats.attendeeCount.toString(),
            label: 'Gäste',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatTile(
            icon: Icons.thumb_up_rounded,
            value: stats.ratingsGood + stats.ratingsBad > 0
                ? '$positivePct%'
                : '—',
            label: 'Positiv',
            accent: positivePct >= 70 ? AppColors.success : null,
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.accent,
  });
  final IconData icon;
  final String value;
  final String label;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final accentColor = accent ?? AppColors.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.bgTop.withOpacity(0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        children: [
          Icon(icon, size: 16, color: AppColors.muted),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: accentColor,
              fontSize: 17,
              fontWeight: FontWeight.w900,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressFooter extends StatelessWidget {
  const _ProgressFooter({required this.stats});
  final HostStats stats;

  @override
  Widget build(BuildContext context) {
    final next = stats.hostLevel.next;
    if (next == null) return const SizedBox.shrink();

    final eventsLeft = stats.eventsToNextLevel();
    final scoreLeft = stats.scoreToNextLevel();
    final progress = stats.progressToNextLevel().clamp(0.0, 1.0);

    final hint = eventsLeft > 0
        ? '$eventsLeft erfolgreiche Event${eventsLeft == 1 ? '' : 's'} bis ${next.label}'
        : scoreLeft > 0
            ? '$scoreLeft Punkte bis ${next.label}'
            : 'Fast bei ${next.label} ${next.emoji}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(next.icon, size: 13, color: next.color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                hint,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                ),
              ),
            ),
            Text(
              '${(progress * 100).round()}%',
              style: TextStyle(
                color: next.color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: AppColors.bgTop,
            valueColor: AlwaysStoppedAnimation<Color>(next.color),
          ),
        ),
      ],
    );
  }
}
