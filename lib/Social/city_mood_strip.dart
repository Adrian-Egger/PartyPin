// lib/Social/city_mood_strip.dart
//
// City Mood Layer — UI-Strip.
//
// Slimme horizontale Reihe mit 2-4 Mood-Pillen. Auto-Hide wenn der
// City-Mood-Level `quiet` ist. Bewusst keine Glow/Animation — nur
// ein dezenter atmosphärischer Status.
//
// Reads: 0 — bekommt vorberechnete `CityMood` vom Parent.

import 'package:flutter/material.dart';

import '../Theme/app_theme.dart';
import 'city_mood.dart';

class CityMoodStrip extends StatelessWidget {
  const CityMoodStrip({
    super.key,
    required this.mood,
    this.horizontalPadding = 14,
  });

  final CityMood mood;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    if (!mood.isVisible) return const SizedBox.shrink();

    final pills = _buildPills(mood);
    if (pills.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        itemCount: pills.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) => pills[i],
      ),
    );
  }

  List<Widget> _buildPills(CityMood mood) {
    final out = <Widget>[];

    // Reihenfolge: Aktivität → Freunde → Districts → Mood-Level-Hint
    if (mood.surgingPartiesCount > 0) {
      final txt = mood.surgingPartiesCount == 1
          ? '1 Party füllt sich gerade'
          : '${mood.surgingPartiesCount} Partys füllen sich gerade';
      out.add(_MoodPill(text: txt, accent: AppColors.accent));
    } else if (mood.totalGoingTonight >= 10) {
      out.add(_MoodPill(
        text: '${mood.totalGoingTonight} gehen heute aus',
        accent: AppColors.accent,
      ));
    }

    if (mood.friendsGoingTonight >= 2) {
      final fc = mood.friendsGoingTonight;
      out.add(_MoodPill(
        text: '$fc ${fc == 1 ? 'Freund' : 'Freunde'} unterwegs',
        accent: AppColors.success,
      ));
    }

    // Districts: max 2 Pillen, sonst wird's Cluttered
    for (final d in mood.activeDistricts.take(2)) {
      final txt = d.isSurging ? '${d.name} zieht an' : '${d.name} aktiv';
      out.add(_MoodPill(
        text: txt,
        accent: d.isSurging ? AppColors.accent : AppColors.text,
      ));
    }

    // Bei electric noch ein Mood-Statement (sonst nicht — Pillen
    // sprechen für sich)
    if (mood.level == CityMoodLevel.electric && out.length < 4) {
      out.add(const _MoodPill(
        text: 'Heute ungewöhnlich aktiv',
        accent: AppColors.accent,
      ));
    }

    // Maximal 4 Pillen — alles weitere würde clutter erzeugen
    return out.take(4).toList();
  }
}

class _MoodPill extends StatelessWidget {
  const _MoodPill({required this.text, required this.accent});
  final String text;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.panel.withOpacity(0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withOpacity(0.42), width: 0.9),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.1,
          height: 1.0,
        ),
      ),
    );
  }
}
