// lib/Screens/admin/admin_screen.dart
//
// Schlanker Admin-Bereich mit TabBar. Ersetzt das frühere 2731-Zeilen-Mega-
// Widget AdminCreatesBarScreen, indem es die Funktionen logisch in vier
// separate Tab-Widgets aufteilt:
//
//   • PendingBarsTab  — Bar-Anfragen freischalten / ablehnen
//   • BarsListTab     — alle Bars, Tap öffnet den vollen Bar-Editor
//   • StatsTab        — schlichte Counter-Statistiken
//   • UsersTab        — User-Suche + Schnellaktionen
//
// Der ursprüngliche AdminCreatesBarScreen wird weiterhin als „Bar-Editor"
// für einzelne Bars genutzt (alle CRUD-Felder, Highlights, Öffnungszeiten,
// Geocoding, Bilder-Upload).

import 'package:flutter/material.dart';

import '../../Theme/app_theme.dart';
import 'admin_bars_list_tab.dart';
import 'admin_pending_bars_tab.dart';
import 'admin_stats_tab.dart';
import 'admin_users_tab.dart';

class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: AppColors.bgTop,
        appBar: AppBar(
          backgroundColor: AppColors.bgTop,
          elevation: 0,
          title: const Text('Admin'),
          bottom: const TabBar(
            isScrollable: true,
            labelColor: AppColors.accent,
            unselectedLabelColor: AppColors.muted,
            indicatorColor: AppColors.accent,
            indicatorWeight: 2.5,
            labelStyle:
                TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            tabs: [
              Tab(icon: Icon(Icons.inbox_rounded), text: 'Anfragen'),
              Tab(icon: Icon(Icons.local_bar_rounded), text: 'Bars'),
              Tab(icon: Icon(Icons.analytics_rounded), text: 'Stats'),
              Tab(icon: Icon(Icons.group_rounded), text: 'User'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            AdminPendingBarsTab(),
            AdminBarsListTab(),
            AdminStatsTab(),
            AdminUsersTab(),
          ],
        ),
      ),
    );
  }
}
