// lib/Social/avatar_stack.dart
//
// Friends & Social Activity Layer — Avatar-Stack.
//
// Drei überlappende Avatare + Suffix-Text:
//   [● ● ●]  +12 going
//
// Designziel: TikTok/IG-Story-Look, kein Business-Chip. Wenn keine
// Avatare verfügbar sind (Initial-Letter-Fallback), bleibt der Look
// trotzdem sozial — nicht leer-grau.
//
// Reads: 0 — diese Widget bekommt die Avatar-URLs bereits in
// `PartyActivity.goingRecent` mitgeliefert (vom Aggregator denormalisiert).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../Theme/app_theme.dart';
import 'party_activity.dart';

class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.activity,
    this.size = 24,
    this.maxAvatars = 3,
    this.highlightUsernames = const <String>{},
  });

  final PartyActivity activity;

  /// Avatar-Diameter. 22-26 ist die natürliche Range für Cards.
  final double size;

  /// Wie viele Köpfe maximal stacken. 3 ist der Sweet-Spot.
  final int maxAvatars;

  /// Usernames die einen grünen Friend-Ring kriegen. Leeres Set =
  /// kein Ring, alle Avatare gleichwertig (vom User explizit so
  /// gewählt: "Random going-UIDs, ohne Friend-Priorisierung").
  /// Bleibt als optionaler Hebel für spätere Iterationen drin.
  final Set<String> highlightUsernames;

  @override
  Widget build(BuildContext context) {
    if (activity.goingCount <= 0 || activity.goingRecent.isEmpty) {
      return const SizedBox.shrink();
    }
    final shown = activity.goingRecent.take(maxAvatars).toList();
    final overflow = activity.goingCount - shown.length;
    final overlap = size * 0.35;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: size,
          width: size + (shown.length - 1) * (size - overlap),
          child: Stack(
            children: [
              for (int i = 0; i < shown.length; i++)
                Positioned(
                  left: i * (size - overlap),
                  child: _SingleAvatar(
                    attendee: shown[i],
                    size: size,
                    highlight: highlightUsernames.contains(shown[i].username),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          overflow > 0
              ? '+$overflow going'
              : '${activity.goingCount} going',
          style: TextStyle(
            color: AppColors.muted,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
          ),
        ),
      ],
    );
  }
}

class _SingleAvatar extends StatelessWidget {
  const _SingleAvatar({
    required this.attendee,
    required this.size,
    required this.highlight,
  });

  final PartyAttendee attendee;
  final double size;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final url = attendee.avatarUrl ?? '';
    final ringColor = highlight ? AppColors.success : AppColors.panel;
    final ringWidth = highlight ? 2.0 : 1.5;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.panel,
        border: Border.all(color: ringColor, width: ringWidth),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 120),
              errorWidget: (_, __, ___) => _initialFallback(),
              placeholder: (_, __) => _initialFallback(),
            )
          : _initialFallback(),
    );
  }

  Widget _initialFallback() {
    final initial = attendee.username.isNotEmpty
        ? attendee.username[0].toUpperCase()
        : '?';
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
