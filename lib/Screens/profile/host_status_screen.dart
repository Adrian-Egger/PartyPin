// lib/Screens/profile/host_status_screen.dart
//
// "Mein Host-Status" — eigener Reputation-Screen.
//   - HostStatsCard für den eingeloggten Username
//   - Triggert recomputeHostStats beim Öffnen (frische Zahlen)
//   - Zeigt Level-Up-Celebration einmalig pro Level-Up
//   - Trending-Hosts-Strip darunter (motivierender Vergleich)
//   - Tipps-Block: wie komme ich zum nächsten Level?

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../Social/host_level.dart';
import '../../Social/host_level_celebration.dart';
import '../../Social/host_stats.dart';
import '../../Social/host_stats_card.dart';
import '../../Social/host_stats_service.dart';
import '../../Social/trending_hosts_strip.dart';
import '../../Theme/app_theme.dart';
import 'user_profile_screen.dart';

class HostStatusScreen extends StatefulWidget {
  const HostStatusScreen({super.key});

  @override
  State<HostStatusScreen> createState() => _HostStatusScreenState();
}

class _HostStatusScreenState extends State<HostStatusScreen> {
  String _username = '';
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final me = (prefs.getString('currentUsername') ?? prefs.getString('username') ?? '').trim();
    if (!mounted) return;
    setState(() {
      _username = me;
      _loading = false;
    });
    if (me.isNotEmpty) {
      // Recompute fire-and-forget — die Stream-Subscription unten zeigt
      // dann automatisch die frischen Zahlen, sobald der CF-Write durch ist.
      _triggerRecompute();
    }
  }

  Future<void> _triggerRecompute() async {
    if (_username.isEmpty || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      await HostStatsService.requestRecompute(_username);
    } catch (_) {
      // Stream zeigt weiterhin den gecachten Stand — Fehler-UI ist nicht kritisch.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _openTrendingHost(String username) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => UserProfileScreen(
        username: username,
        myUsername: _username.isEmpty ? null : _username,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgTop,
      appBar: AppBar(
        backgroundColor: AppColors.bgTop,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: AppRadius.fullBr,
            border: Border.all(color: AppColors.accentBorder2),
          ),
          child: const Text(
            'Mein Host-Status',
            style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 15),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _refreshing ? null : _triggerRecompute,
            icon: _refreshing
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent),
                  )
                : const Icon(Icons.refresh_rounded, color: AppColors.accent),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent, strokeWidth: 2))
          : _username.isEmpty
              ? const _NoUsernamePlaceholder()
              : _Body(
                  username: _username,
                  onOpenHost: _openTrendingHost,
                ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.username, required this.onOpenHost});
  final String username;
  final void Function(String username) onOpenHost;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<HostStats>(
      stream: HostStatsService.watch(username),
      builder: (context, snap) {
        final stats = snap.data ?? HostStats.empty(username);

        // Celebration: nur wenn das Doc bereits existiert und ein
        // frischer Level-Up vorliegt. WidgetsBinding sicher, weil
        // showGeneralDialog im build nicht funktioniert.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          HostLevelCelebration.maybeShowIfFresh(context, stats);
        });

        return SingleChildScrollView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: HostStatsCard(stats: stats),
              ),
              if (stats.partyCount == 0) ...[
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: _NoPartiesYetCard(),
                ),
              ] else if (stats.hostLevel != HostLevel.elite) ...[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _TipsCard(stats: stats),
                ),
              ],
              const SizedBox(height: 24),
              TrendingHostsStrip(onTapHost: onOpenHost),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: _AntiSpamHint(),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NoPartiesYetCard extends StatelessWidget {
  const _NoPartiesYetCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.rocket_launch_rounded, color: AppColors.accent, size: 18),
              SizedBox(width: 8),
              Text(
                'Noch keine Party gehostet',
                style: TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Erstelle deine erste Party — schon ab 3 Gästen zählt sie als '
            'erfolgreich und du kletterst zum Local Host hoch.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _TipsCard extends StatelessWidget {
  const _TipsCard({required this.stats});
  final HostStats stats;

  @override
  Widget build(BuildContext context) {
    final next = stats.hostLevel.next;
    if (next == null) return const SizedBox.shrink();

    final tips = <_Tip>[];

    final eventsLeft = stats.eventsToNextLevel();
    if (eventsLeft > 0) {
      tips.add(_Tip(
        icon: Icons.event_available_rounded,
        text:
            '$eventsLeft erfolgreiche Event${eventsLeft == 1 ? '' : 's'} '
            'fehlen noch (≥3 Gäste pro Party).',
      ));
    }

    final scoreLeft = stats.scoreToNextLevel();
    if (scoreLeft > 0) {
      tips.add(_Tip(
        icon: Icons.bolt_rounded,
        text: '$scoreLeft Reputation-Punkte sammeln — '
            'jeder Daumen-hoch zählt 25, jeder Gast 2.',
      ));
    }

    if (stats.ratingPositiveRate < 0.7 &&
        next.rank >= HostLevel.rising.rank &&
        (stats.ratingsGood + stats.ratingsBad) > 0) {
      final pct = (stats.ratingPositiveRate * 100).round();
      tips.add(_Tip(
        icon: Icons.thumb_up_rounded,
        text: 'Aktuelle Quote: $pct% positiv. '
            'Für ${next.label} brauchst du ≥${(_minRateOf(next) * 100).round()}%.',
      ));
    }

    if (stats.ghostEventCount > 0) {
      tips.add(_Tip(
        icon: Icons.warning_amber_rounded,
        text:
            '${stats.ghostEventCount} Ghost-Event${stats.ghostEventCount == 1 ? '' : 's'} '
            '(0 Gäste) ziehen Punkte ab. Lieber weniger, dafür besuchte Partys.',
        warn: true,
      ));
    }

    if (tips.isEmpty) {
      tips.add(const _Tip(
        icon: Icons.celebration_rounded,
        text: 'Du bist auf dem besten Weg — mach weiter so.',
      ));
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(next.icon, color: next.color, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'So kommst du zum ${next.label}',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...tips.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      t.icon,
                      color: t.warn ? Colors.orangeAccent : AppColors.muted,
                      size: 14,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.text,
                        style: TextStyle(
                          color: t.warn ? Colors.orangeAccent : AppColors.muted,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}

double _minRateOf(HostLevel level) {
  for (final t in kHostLevelThresholds) {
    if (t.level == level) return t.minPositiveRate;
  }
  return 0;
}

class _Tip {
  const _Tip({required this.icon, required this.text, this.warn = false});
  final IconData icon;
  final String text;
  final bool warn;
}

class _AntiSpamHint extends StatelessWidget {
  const _AntiSpamHint();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Qualität schlägt Menge. Reports, Ghost-Events und gelöschte Partys '
      'ziehen Punkte ab. Wer echte gute Partys macht, kommt hoch.',
      style: TextStyle(
        color: AppColors.muted.withOpacity(0.7),
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _NoUsernamePlaceholder extends StatelessWidget {
  const _NoUsernamePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Wir konnten deinen Username nicht ermitteln. '
          'Bitte einmal aus- und wieder einloggen.',
          style: TextStyle(color: AppColors.muted.withOpacity(0.9), fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
