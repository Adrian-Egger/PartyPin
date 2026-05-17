// lib/Social/host_badge.dart
//
// Wiederverwendbares Host-Badge. Drei Größen:
//   - HostBadge.tiny  → nur Icon (Map-Marker, sehr enge Cards)
//   - HostBadge.small → Icon + Kurz-Label (Party-Card, Bottom-Sheet-Inline)
//   - HostBadge.full  → Icon + Voll-Label (Profil-Header)
//
// Stil: gradient pill mit Glow, Snapchat/TikTok-Tonalität — keine flachen
// Business-Chips. Rookie-Hosts haben einen dezenten Look (kein Glow).

import 'package:flutter/material.dart';

import 'host_level.dart';

enum HostBadgeSize { tiny, small, full }

class HostBadge extends StatelessWidget {
  const HostBadge({
    super.key,
    required this.level,
    this.size = HostBadgeSize.small,
    this.onTap,
  });

  /// Convenience: nur Icon. Für Map-Marker.
  const HostBadge.tiny({super.key, required this.level, this.onTap})
      : size = HostBadgeSize.tiny;

  /// Convenience: Icon + Kurz-Label. Default für Cards.
  const HostBadge.small({super.key, required this.level, this.onTap})
      : size = HostBadgeSize.small;

  /// Convenience: Icon + Voll-Label. Für Profile.
  const HostBadge.full({super.key, required this.level, this.onTap})
      : size = HostBadgeSize.full;

  final HostLevel level;
  final HostBadgeSize size;
  final VoidCallback? onTap;

  bool get _isElevated => level.rank >= HostLevel.local.rank;

  @override
  Widget build(BuildContext context) {
    final dims = _dims;
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _isElevated
          ? [level.color, level.colorAccent]
          : [level.color.withOpacity(0.30), level.color.withOpacity(0.18)],
    );

    final content = Container(
      padding: dims.padding,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(dims.radius),
        border: Border.all(
          color: _isElevated
              ? level.color.withOpacity(0.55)
              : level.color.withOpacity(0.40),
          width: 0.8,
        ),
        boxShadow: _isElevated
            ? [
                BoxShadow(
                  color: level.color.withOpacity(0.35),
                  blurRadius: dims.glow,
                  spreadRadius: 0.0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            level.icon,
            size: dims.icon,
            color: _isElevated ? Colors.white : level.color,
          ),
          if (size != HostBadgeSize.tiny) ...[
            SizedBox(width: dims.gap),
            Text(
              size == HostBadgeSize.full ? level.label : level.shortLabel,
              style: TextStyle(
                color: _isElevated ? Colors.white : level.color,
                fontSize: dims.font,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.1,
                height: 1.0,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(dims.radius),
      child: content,
    );
  }

  _BadgeDims get _dims {
    switch (size) {
      case HostBadgeSize.tiny:
        return const _BadgeDims(
          padding: EdgeInsets.all(5),
          icon: 13,
          font: 0,
          gap: 0,
          radius: 999,
          glow: 6,
        );
      case HostBadgeSize.small:
        return const _BadgeDims(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          icon: 13,
          font: 11,
          gap: 5,
          radius: 999,
          glow: 6,
        );
      case HostBadgeSize.full:
        return const _BadgeDims(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          icon: 16,
          font: 13,
          gap: 7,
          radius: 999,
          glow: 10,
        );
    }
  }
}

class _BadgeDims {
  const _BadgeDims({
    required this.padding,
    required this.icon,
    required this.font,
    required this.gap,
    required this.radius,
    required this.glow,
  });
  final EdgeInsets padding;
  final double icon;
  final double font;
  final double gap;
  final double radius;
  final double glow;
}
