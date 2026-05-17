// lib/Social/host_level_celebration.dart
//
// One-shot Overlay-Dialog für Level-Up. Wird genau einmal pro Level-Up
// gezeigt — Tracking läuft über SharedPreferences (Key:
// `host_celebrated_level_<username>` = lastLevelUpAt-Millis).
//
// Vom Aufrufer kommt:
//   await HostLevelCelebration.maybeShowIfFresh(context, stats);
//
// Snapchat-/TikTok-Tonalität: Confetti via einfacher Particle-Painter
// (kein extra Package), Tap-to-Dismiss, Auto-Hide nach 6s.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../Theme/app_theme.dart';
import 'host_level.dart';
import 'host_stats.dart';

class HostLevelCelebration {
  HostLevelCelebration._();

  /// Zeigt die Celebration genau dann, wenn ein Level-Up frischer ist
  /// als das zuletzt vom Client bestätigte.
  static Future<void> maybeShowIfFresh(
    BuildContext context,
    HostStats stats,
  ) async {
    final ts = stats.lastLevelUpAt;
    if (ts == null) return;
    if (stats.previousLevel.rank >= stats.hostLevel.rank) return;

    final prefs = await SharedPreferences.getInstance();
    final key = 'host_celebrated_level_${stats.username}';
    final lastSeen = prefs.getInt(key) ?? 0;
    if (ts.millisecondsSinceEpoch <= lastSeen) return;

    if (!context.mounted) return;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Level Up',
      barrierColor: Colors.black.withOpacity(0.72),
      transitionDuration: const Duration(milliseconds: 360),
      pageBuilder: (_, __, ___) => _CelebrationContent(stats: stats),
      transitionBuilder: (_, anim, __, child) {
        final scale = Tween<double>(begin: 0.85, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutBack))
            .animate(anim);
        return ScaleTransition(
          scale: scale,
          child: FadeTransition(opacity: anim, child: child),
        );
      },
    );

    await prefs.setInt(key, ts.millisecondsSinceEpoch);
  }
}

class _CelebrationContent extends StatefulWidget {
  const _CelebrationContent({required this.stats});
  final HostStats stats;

  @override
  State<_CelebrationContent> createState() => _CelebrationContentState();
}

class _CelebrationContentState extends State<_CelebrationContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..forward();
    HapticFeedback.heavyImpact();
    _autoDismiss = Timer(const Duration(seconds: 6), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.stats.hostLevel;

    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Konfetti
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => CustomPaint(
                  painter: _ConfettiPainter(
                    progress: _ctrl.value,
                    accent: level.color,
                    secondary: level.colorAccent,
                  ),
                ),
              ),
            ),
          ),
          // Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.panel,
                    level.color.withOpacity(0.16),
                  ],
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: level.color.withOpacity(0.55), width: 1.4),
                boxShadow: [
                  BoxShadow(
                    color: level.color.withOpacity(0.35),
                    blurRadius: 40,
                    spreadRadius: -2,
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'LEVEL UP',
                    style: TextStyle(
                      color: level.color,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3.0,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: 96,
                    height: 96,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [level.color, level.colorAccent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: level.color.withOpacity(0.6),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: Icon(level.icon, color: Colors.white, size: 52),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Du bist jetzt',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${level.label} ${level.emoji}',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    level.tagline,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.bgTop,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Lass es weiter laufen',
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Konfetti-Painter — kein externes Package nötig.
class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({
    required this.progress,
    required this.accent,
    required this.secondary,
  }) : _particles = List.generate(60, (i) => _Particle.random(i));

  final double progress;
  final Color accent;
  final Color secondary;
  final List<_Particle> _particles;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in _particles) {
      final localProgress = ((progress - p.delay).clamp(0.0, 1.0) / (1 - p.delay)).clamp(0.0, 1.0);
      if (localProgress <= 0) continue;
      final x = size.width * p.xStart + math.sin(localProgress * math.pi * 2 + p.phase) * 28 * p.sway;
      final y = -20 + (size.height + 40) * Curves.easeIn.transform(localProgress);
      final colorIdx = p.colorIdx;
      final color = colorIdx == 0
          ? accent
          : colorIdx == 1
              ? secondary
              : Colors.white;
      paint.color = color.withOpacity((1 - localProgress).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(localProgress * p.spin * 6.0);
      final w = p.size;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: w * 0.5),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) =>
      old.progress != progress;
}

class _Particle {
  _Particle({
    required this.xStart,
    required this.delay,
    required this.size,
    required this.phase,
    required this.sway,
    required this.spin,
    required this.colorIdx,
  });

  factory _Particle.random(int seed) {
    final rnd = math.Random(seed * 31 + 7);
    return _Particle(
      xStart: rnd.nextDouble(),
      delay: rnd.nextDouble() * 0.55,
      size: 6 + rnd.nextDouble() * 10,
      phase: rnd.nextDouble() * math.pi * 2,
      sway: 0.4 + rnd.nextDouble() * 1.0,
      spin: -1 + rnd.nextDouble() * 2,
      colorIdx: rnd.nextInt(3),
    );
  }

  final double xStart;
  final double delay;
  final double size;
  final double phase;
  final double sway;
  final double spin;
  final int colorIdx;
}
