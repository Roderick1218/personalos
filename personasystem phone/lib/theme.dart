import 'package:flutter/material.dart';

/// 跟网站端 v5.0 深色科技风重新设计用同一套配色 (css/style.css 的 :root 变量) ——
/// Flutter 端不用 CSS 变量，改用这个常量类 + ThemeData 集中定义，各个页面尽量吃 Theme 默认值，
/// 不用每个 widget 都手动指定颜色。
class AppColors {
  static const bg = Color(0xFF0A0E17);
  static const surface = Color(0xFF111827);
  static const surfaceAlt = Color(0xFF0D1420);
  static const border = Color(0x1FFFFFFF); // 白色 12% 透明度
  static const accent = Color(0xFF00E5FF); // 荧光蓝 (手机上饱和度略降，长时间看比较不刺眼)
  static const success = Color(0xFF00E676);
  static const danger = Color(0xFFFF3366);
  static const warning = Color(0xFFFFB020);
  static const text = Color(0xFFE6EDF3);
  static const textMuted = Color(0xFF8A97A8);
  static const onAccent = Color(0xFF04141A);

  static const priorityUrgent = Color(0xFFFF3366);
  static const priorityHigh = Color(0xFFFF3366);
  static const priorityMedium = Color(0xFFFFB020);
  static const priorityLow = Color(0xFF00E676);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.accent,
      surface: AppColors.surface,
      error: AppColors.danger,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      foregroundColor: AppColors.text,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: const EdgeInsets.only(bottom: 14),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textMuted,
      textColor: AppColors.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.textMuted),
      hintStyle: TextStyle(color: AppColors.textMuted.withValues(alpha: 0.6)),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.bg,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.textMuted,
      type: BottomNavigationBarType.fixed,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: AppColors.bg),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceAlt,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceAlt,
      contentTextStyle: const TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.onAccent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AppColors.accent),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? AppColors.accent : AppColors.textMuted),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? AppColors.accent.withValues(alpha: 0.4) : Colors.white24),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? AppColors.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(AppColors.onAccent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
  );
}

/// 财务卡片/图例用的多色盘 (跟网站端 COLOR_PALETTE 同一组色，区分不同分类/账户用，
/// 不是主题色，纯粹拿来让好几个类别在图表里看起来彼此不一样)
const List<Color> kChartPalette = [
  Color(0xFF00E5FF), Color(0xFFFF3366), Color(0xFF00E676), Color(0xFFF59E0B),
  Color(0xFFA78BFA), Color(0xFFEC4899), Color(0xFF38BDF8), Color(0xFFFB923C),
  Color(0xFF34D399), Color(0xFFF472B6), Color(0xFF818CF8), Color(0xFFFBBF24),
];
