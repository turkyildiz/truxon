import 'package:flutter/material.dart';

/// Trux design system — the whole look lives here.
///
/// Truck-cab rules: 48px+ touch targets (gloves), tonal depth instead of
/// drop shadows, generous corner radii, and automatic DARK MODE for night
/// driving (main.dart passes ThemeMode.system).
ThemeData truxTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF2456E6), // brighter road-sign blue
    brightness: brightness,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: brightness == Brightness.light
        ? scheme.surfaceContainerLowest
        : scheme.surface,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      titleTextStyle: base.textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface),
    ),
    cardTheme: base.cardTheme.copyWith(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 44)),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    progressIndicatorTheme:
        ProgressIndicatorThemeData(color: scheme.primary),
  );
}

/// One shared meaning-of-color for load statuses (readable on light + dark).
({Color fg, Color bg}) statusColors(BuildContext context, String status) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  Color tone(MaterialColor c) => dark ? c.shade300 : c.shade700;
  Color tint(MaterialColor c) =>
      dark ? c.shade900.withValues(alpha: 0.45) : c.shade50;
  return switch (status) {
    'assigned' => (fg: tone(Colors.blue), bg: tint(Colors.blue)),
    'in_transit' => (fg: tone(Colors.orange), bg: tint(Colors.orange)),
    'delivered' ||
    'completed' ||
    'billed' =>
      (fg: tone(Colors.green), bg: tint(Colors.green)),
    'cancelled' => (fg: tone(Colors.red), bg: tint(Colors.red)),
    _ => (
        fg: Theme.of(context).colorScheme.onSurfaceVariant,
        bg: Theme.of(context).colorScheme.surfaceContainerHigh
      ),
  };
}

/// Pill-shaped status chip used on load cards and detail rows.
class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key, this.label});
  final String status;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = statusColors(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        (label ?? status).replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
            color: c.fg,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6),
      ),
    );
  }
}
