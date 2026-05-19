import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ─── Colors ───────────────────────────────────────────────────────────────────

class AppColors {
  static const bgTop    = Color(0xFF0E0F12);
  static const bgBottom = Color(0xFF141A22);
  static const panel    = Color(0xFF1C1F26);
  static const panelAlt = Color(0xFF232830);
  static const border   = Color(0xFF2E3340);
  static const text     = Colors.white;
  static const muted    = Color(0xFFB6BDC8);
  static const subtle   = Color(0xFF6B7280);
  static const accent   = Color(0xFFFF3B30);
  static const success  = Color(0xFF22C55E);
  static const teal     = Color(0xFF00C2A8);

  // Red border shades — use these everywhere for consistency
  static const accentBorder  = Color(0x2EFF3B30); // 18% — panels, cards
  static const accentBorder2 = Color(0x4DFF3B30); // 30% — title pills, active items
  static const accentBorder3 = Color(0x66FF3B30); // 40% — focused/selected
}

// ─── Radius ───────────────────────────────────────────────────────────────────

class AppRadius {
  static const double xs   = 6;
  static const double sm   = 10;
  static const double md   = 14;
  static const double lg   = 20;
  static const double xl   = 28;
  static const double full = 999;

  static BorderRadius get xsBr   => BorderRadius.circular(xs);
  static BorderRadius get smBr   => BorderRadius.circular(sm);
  static BorderRadius get mdBr   => BorderRadius.circular(md);
  static BorderRadius get lgBr   => BorderRadius.circular(lg);
  static BorderRadius get xlBr   => BorderRadius.circular(xl);
  static BorderRadius get fullBr => BorderRadius.circular(full);

  static BorderRadius get sheetBr => const BorderRadius.vertical(top: Radius.circular(26));
}

// ─── Durations ────────────────────────────────────────────────────────────────

class AppDurations {
  static const fast   = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 260);
  static const slow   = Duration(milliseconds: 420);
}

// ─── Curves ───────────────────────────────────────────────────────────────────

class AppCurves {
  static const enter = Curves.easeOutCubic;
  static const exit  = Curves.easeInCubic;
  static const spring = Curves.easeOutBack;
}

// ─── Page Transition ──────────────────────────────────────────────────────────
// Cupertino-Stil auf allen Plattformen: horizontaler Slide rein/raus PLUS
// Edge-Swipe-Back-Geste (von links nach rechts wischen → vorherige Seite).
// Kein eigener Builder mehr nötig — CupertinoPageTransitionsBuilder bringt
// beides "kostenlos" mit. Das gilt automatisch für jede Route, die über
// Navigator.push(MaterialPageRoute(...)) geöffnet wird.

// ─── Theme ────────────────────────────────────────────────────────────────────

class AppTheme {
  // Cache: das Theme ist immutable und teuer zu bauen (GoogleFonts.inter*
  // erzeugt komplette TextTheme-Hierarchie + ColorScheme + 8 Komponenten-
  // Themes). Bei jedem Rebuild von MaterialApp (z. B. wegen Sprachwechsel
  // via langNotifier) würde `theme: AppTheme.dark` sonst alles neu rechnen.
  static ThemeData? _cached;

  static ThemeData get dark => _cached ??= _buildDark();

  static ThemeData _buildDark() {
    final base = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);

    final textTheme = base.copyWith(
      displayLarge:  base.displayLarge?.copyWith(color: AppColors.text, fontWeight: FontWeight.w800),
      displayMedium: base.displayMedium?.copyWith(color: AppColors.text, fontWeight: FontWeight.w700),
      headlineLarge: base.headlineLarge?.copyWith(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 24),
      headlineMedium:base.headlineMedium?.copyWith(color: AppColors.text, fontWeight: FontWeight.w700, fontSize: 20),
      headlineSmall: base.headlineSmall?.copyWith(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 17),
      titleLarge:    base.titleLarge?.copyWith(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 16),
      titleMedium:   base.titleMedium?.copyWith(color: AppColors.text, fontWeight: FontWeight.w500, fontSize: 14),
      titleSmall:    base.titleSmall?.copyWith(color: AppColors.muted, fontSize: 13),
      bodyLarge:     base.bodyLarge?.copyWith(color: AppColors.text, fontSize: 15),
      bodyMedium:    base.bodyMedium?.copyWith(color: AppColors.text, fontSize: 14),
      bodySmall:     base.bodySmall?.copyWith(color: AppColors.muted, fontSize: 12),
      labelLarge:    base.labelLarge?.copyWith(color: AppColors.text, fontWeight: FontWeight.w600, fontSize: 14),
      labelSmall:    base.labelSmall?.copyWith(color: AppColors.muted, fontSize: 11, letterSpacing: 0.4),
    );

    const colorScheme = ColorScheme.dark(
      primary:    AppColors.accent,
      onPrimary:  Colors.white,
      secondary:  AppColors.teal,
      onSecondary:Colors.white,
      surface:    AppColors.panel,
      onSurface:  AppColors.text,
      error:      AppColors.accent,
      onError:    Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: AppColors.bgTop,

      // Page transitions — Cupertino-Slide + Swipe-Back-Geste auf ALLEN
      // Plattformen. Auf Android wird die Edge-Swipe-Geste durch
      // CupertinoPageTransitionsBuilder automatisch aktiv.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS:     CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS:   CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux:   CupertinoPageTransitionsBuilder(),
        },
      ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.bgTop,
        foregroundColor: AppColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: GoogleFonts.inter(
          color: AppColors.text,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarBrightness: Brightness.dark,
          statusBarIconBrightness: Brightness.light,
        ),
      ),

      // NavigationBar (Material 3)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black54,
        elevation: 0,
        indicatorColor: AppColors.accent.withValues(alpha: 0.15),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.accent, size: 23);
          }
          return const IconThemeData(color: AppColors.subtle, size: 23);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.inter(
              color: AppColors.accent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            );
          }
          return GoogleFonts.inter(
            color: AppColors.subtle,
            fontSize: 11,
            letterSpacing: 0.2,
          );
        }),
        height: 66,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),

      // Cards
      cardTheme: CardThemeData(
        color: AppColors.panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdBr,
          side: const BorderSide(color: AppColors.accentBorder, width: 1),
        ),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 15),
          splashFactory: InkRipple.splashFactory,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.text,
          side: const BorderSide(color: AppColors.accentBorder2),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),

      // Input fields
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.panelAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: AppRadius.smBr,
          borderSide: const BorderSide(color: AppColors.accentBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.smBr,
          borderSide: const BorderSide(color: AppColors.accentBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.smBr,
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.smBr,
          borderSide: const BorderSide(color: AppColors.accent),
        ),
        labelStyle: GoogleFonts.inter(color: AppColors.muted, fontSize: 14),
        hintStyle: GoogleFonts.inter(color: AppColors.subtle, fontSize: 14),
        prefixIconColor: AppColors.muted,
        suffixIconColor: AppColors.muted,
      ),

      // Dividers
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),

      // SnackBar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.panelAlt,
        contentTextStyle: GoogleFonts.inter(color: AppColors.text, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.smBr),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),

      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgBr,
          side: const BorderSide(color: AppColors.accentBorder, width: 1),
        ),
        titleTextStyle: GoogleFonts.inter(
          color: AppColors.text,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: GoogleFonts.inter(color: AppColors.muted, fontSize: 14),
      ),

      // BottomSheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.panel,
        modalBackgroundColor: AppColors.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.sheetBr,
          side: const BorderSide(color: AppColors.accentBorder, width: 1),
        ),
      ),

      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.panelAlt,
        selectedColor: AppColors.accent.withValues(alpha: 0.18),
        labelStyle: GoogleFonts.inter(color: AppColors.text, fontSize: 13),
        side: const BorderSide(color: AppColors.accentBorder),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.xsBr),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? AppColors.accent : AppColors.subtle),
        trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected)
            ? AppColors.accent.withValues(alpha: 0.35)
            : AppColors.border),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      // ListTile
      listTileTheme: ListTileThemeData(
        tileColor: Colors.transparent,
        iconColor: AppColors.muted,
        textColor: AppColors.text,
        subtitleTextStyle: GoogleFonts.inter(color: AppColors.muted, fontSize: 13),
      ),

      // Icon
      iconTheme: const IconThemeData(color: AppColors.muted),

      // Splash / ripple
      splashFactory: InkRipple.splashFactory,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
    );
  }
}
