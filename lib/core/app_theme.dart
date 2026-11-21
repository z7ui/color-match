import 'package:flutter/material.dart';

/// 一套「建材对比」用的克制配色：中性灰底 + 一个主色，避免影响用户判断颜色。
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF2F6FED);
  static const Color success = Color(0xFF2E7D32);
  static const Color warning = Color(0xFFEF6C00);
  static const Color danger = Color(0xFFC62828);

  static const Color background = Color(0xFFF5F6F8);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color divider = Color(0xFFE4E7EB);
  static const Color text = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF5A6068);
  static const Color textHint = Color(0xFF9AA1A9);

  static const Color backgroundDark = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color dividerDark = Color(0xFF2C2C2C);
  static const Color textDark = Color(0xFFEDEDED);
  static const Color textSecondaryDark = Color(0xFFB0B6BC);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color sub(BuildContext context) =>
      isDark(context) ? textSecondaryDark : textSecondary;

  static Color card(BuildContext context) =>
      isDark(context) ? surfaceDark : surface;

  static Color line(BuildContext context) =>
      isDark(context) ? dividerDark : divider;

  static Color page(BuildContext context) =>
      isDark(context) ? backgroundDark : background;

  static Color label(BuildContext context) =>
      isDark(context) ? textDark : text;
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  AppRadius._();

  static const double control = 10;
  static const double card = 14;
}

ThemeData buildTheme(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  final Color page = dark ? AppColors.backgroundDark : AppColors.background;
  final Color card = dark ? AppColors.surfaceDark : AppColors.surface;
  final Color fg = dark ? AppColors.textDark : AppColors.text;

  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme.copyWith(surface: page),
    scaffoldBackgroundColor: page,
    appBarTheme: AppBarTheme(
      backgroundColor: page,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle:
          TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: fg),
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: dark ? AppColors.dividerDark : AppColors.divider),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control)),
        textStyle:
            const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF242424) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: dark ? AppColors.dividerDark : AppColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide(color: dark ? AppColors.dividerDark : AppColors.divider),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
    ),
  );
}

/// 统一的 AppBar：标题 + 右侧动作。
///
/// 之前这个函数白拿一个 context 却从不使用（空壳抽象），调用点看起来「统一」而已。
/// 需要 context 时才传，不需要就不传。
AppBar buildAppBar(String title, {List<Widget>? actions, Widget? leading}) {
  return AppBar(title: Text(title), actions: actions, leading: leading);
}

/// 统一的轻提示。
void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : null,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 4 : 2),
      ),
    );
}
