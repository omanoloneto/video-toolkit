import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;

/// Which icon design language a theme uses.
enum IconFamily { fluent, material, cupertino }

/// Visual identity of one selectable theme: Fluent theme data plus the few
/// extra tokens the custom chrome (top bar, timeline clips) needs.
class AppThemeSpec {
  const AppThemeSpec({
    required this.id,
    required this.name,
    required this.brightness,
    required this.accent,
    required this.background,
    required this.surface,
    required this.topBarGradient,
    required this.topBarText,
    required this.cornerRadius,
    this.iconFamily = IconFamily.fluent,
    this.translucent = false,
    this.buttonBackground,
    this.buttonBorder,
  });

  final String id;
  final String name;
  final Brightness brightness;
  final Color accent;

  /// Scaffold/mica background.
  final Color background;

  /// Cards, menus, acrylic surfaces.
  final Color surface;

  /// One or two colors; single color renders as a flat bar.
  final List<Color> topBarGradient;
  final Color topBarText;

  /// Corner rounding for custom chrome (timeline clips, track rows).
  final double cornerRadius;

  final IconFamily iconFamily;

  /// Glass themes (Aero, macOS...): window gets an NSVisualEffectView blur
  /// and the app backgrounds become semi-transparent.
  final bool translucent;

  /// Custom button look; null keeps the stock Fluent style.
  final Color? buttonBackground;
  final Color? buttonBorder;

  Color get effectiveBackground =>
      translucent ? background.withValues(alpha: 0.72) : background;

  FluentThemeData buildTheme() {
    return FluentThemeData(
      brightness: brightness,
      accentColor: _swatch(accent),
      scaffoldBackgroundColor: effectiveBackground,
      micaBackgroundColor: effectiveBackground,
      cardColor: translucent ? surface.withValues(alpha: 0.82) : surface,
      acrylicBackgroundColor: surface,
      menuColor: surface,
      buttonTheme: _buttonTheme(),
    );
  }

  ButtonThemeData? _buttonTheme() {
    final background = buttonBackground;
    if (background == null) return null;
    final border = buttonBorder ?? background;
    final foreground = brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF1B1B1B);

    ShapeBorder shapeFor(Set<WidgetState> states) => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cornerRadius),
          side: BorderSide(
            color: states.contains(WidgetState.hovered) ? accent : border,
          ),
        );
    Color backgroundFor(Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return Color.lerp(background, accent, 0.25)!;
      }
      if (states.contains(WidgetState.hovered)) {
        return Color.lerp(background, accent, 0.10)!;
      }
      return background;
    }

    final style = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(backgroundFor),
      foregroundColor: WidgetStatePropertyAll(foreground),
      shape: WidgetStateProperty.resolveWith(shapeFor),
    );

    // Accent-filled buttons (e.g. "Salvar") follow the theme too: accent
    // background, matching corner radius, readable foreground.
    final onAccent = accent.computeLuminance() > 0.5
        ? const Color(0xFF1B1B1B)
        : const Color(0xFFFFFFFF);
    Color filledBackgroundFor(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) {
        return Color.lerp(accent, background, 0.6)!;
      }
      if (states.contains(WidgetState.pressed)) {
        return Color.lerp(accent, const Color(0xFF000000), 0.25)!;
      }
      if (states.contains(WidgetState.hovered)) {
        return Color.lerp(accent, const Color(0xFFFFFFFF), 0.12)!;
      }
      return accent;
    }

    final filledStyle = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(filledBackgroundFor),
      foregroundColor: WidgetStatePropertyAll(onAccent),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(cornerRadius),
      )),
    );

    return ButtonThemeData(
      defaultButtonStyle: style,
      iconButtonStyle: style,
      filledButtonStyle: filledStyle,
    );
  }

  static AccentColor _swatch(Color color) {
    Color shade(double f) => Color.lerp(color, const Color(0xFF000000), f)!;
    Color tint(double f) => Color.lerp(color, const Color(0xFFFFFFFF), f)!;
    return AccentColor.swatch({
      'darkest': shade(0.5),
      'darker': shade(0.35),
      'dark': shade(0.2),
      'normal': color,
      'light': tint(0.2),
      'lighter': tint(0.35),
      'lightest': tint(0.5),
    });
  }
}

/// Themes inspired by the classic desktop OS looks (colors and shapes; not
/// pixel-perfect recreations of each OS chrome).
const appThemes = <AppThemeSpec>[
  AppThemeSpec(
    id: 'win98',
    name: 'Windows 98',
    brightness: Brightness.light,
    accent: Color(0xFF000080),
    background: Color(0xFFC0C0C0),
    surface: Color(0xFFD4D0C8),
    topBarGradient: [Color(0xFF000080), Color(0xFF1084D0)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 0,
    buttonBackground: Color(0xFFD4D0C8),
    buttonBorder: Color(0xFF808080),
  ),
  AppThemeSpec(
    id: 'winxp',
    name: 'Windows XP',
    brightness: Brightness.light,
    accent: Color(0xFF316AC5),
    background: Color(0xFFECE9D8),
    surface: Color(0xFFFFFFFF),
    topBarGradient: [Color(0xFF245EDC), Color(0xFF57A8FF)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 3,
    buttonBackground: Color(0xFFF1F0E5),
    buttonBorder: Color(0xFF7F9DB9),
  ),
  AppThemeSpec(
    id: 'winvista',
    name: 'Windows Vista',
    brightness: Brightness.dark,
    accent: Color(0xFF46A0E0),
    background: Color(0xFF1B2430),
    surface: Color(0xFF232E3C),
    topBarGradient: [Color(0xFF10151C), Color(0xFF3D5A73)],
    topBarText: Color(0xFFEAF4FC),
    cornerRadius: 6,
    translucent: true,
    buttonBackground: Color(0xFF2E3B4A),
    buttonBorder: Color(0xFF55677A),
  ),
  AppThemeSpec(
    id: 'win7',
    name: 'Windows 7 (Aero)',
    brightness: Brightness.light,
    accent: Color(0xFF2B8DD9),
    background: Color(0xFFEAF2FA),
    surface: Color(0xFFF7FBFF),
    topBarGradient: [Color(0xFFDDEBF7), Color(0xFFA9CBEA)],
    topBarText: Color(0xFF1C3F5E),
    cornerRadius: 6,
    translucent: true,
    buttonBackground: Color(0xFFF2F7FC),
    buttonBorder: Color(0xFF8E9CAA),
  ),
  AppThemeSpec(
    id: 'win8',
    name: 'Windows 8',
    brightness: Brightness.light,
    accent: Color(0xFF2672EC),
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFF2F2F2),
    topBarGradient: [Color(0xFF2672EC)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 0,
    buttonBackground: Color(0xFFFFFFFF),
    buttonBorder: Color(0xFFACACAC),
  ),
  AppThemeSpec(
    id: 'win10',
    name: 'Windows 10',
    brightness: Brightness.dark,
    accent: Color(0xFF0078D7),
    background: Color(0xFF171717),
    surface: Color(0xFF202020),
    topBarGradient: [Color(0xFF1F1F1F)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 2,
    translucent: true,
    buttonBackground: Color(0xFF333333),
    buttonBorder: Color(0xFF4D4D4D),
  ),
  AppThemeSpec(
    id: 'win11',
    name: 'Windows 11',
    brightness: Brightness.dark,
    accent: Color(0xFF4CC2FF),
    background: Color(0xFF202020),
    surface: Color(0xFF2B2B2B),
    topBarGradient: [Color(0xFF202020)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 6,
  ),
  AppThemeSpec(
    id: 'macclassic',
    name: 'Mac OS Clássico',
    brightness: Brightness.light,
    accent: Color(0xFF6666CC),
    background: Color(0xFFDDDDDD),
    surface: Color(0xFFEEEEEE),
    topBarGradient: [Color(0xFFE8E8E8), Color(0xFFB0B0B0)],
    topBarText: Color(0xFF1A1A1A),
    cornerRadius: 2,
    iconFamily: IconFamily.cupertino,
    buttonBackground: Color(0xFFE8E8E8),
    buttonBorder: Color(0xFF888888),
  ),
  AppThemeSpec(
    id: 'macmodern',
    name: 'macOS Moderno',
    brightness: Brightness.light,
    accent: Color(0xFF007AFF),
    background: Color(0xFFF5F5F7),
    surface: Color(0xFFFFFFFF),
    topBarGradient: [Color(0xFFF6F6F6)],
    topBarText: Color(0xFF1D1D1F),
    cornerRadius: 10,
    iconFamily: IconFamily.cupertino,
    translucent: true,
    buttonBackground: Color(0xFFFFFFFF),
    buttonBorder: Color(0xFFD1D1D6),
  ),
  AppThemeSpec(
    id: 'ubuntu',
    name: 'Ubuntu',
    brightness: Brightness.dark,
    accent: Color(0xFFE95420),
    background: Color(0xFF2A1226),
    surface: Color(0xFF38203A),
    topBarGradient: [Color(0xFF300A24)],
    topBarText: Color(0xFFFFFFFF),
    cornerRadius: 8,
    iconFamily: IconFamily.material,
    buttonBackground: Color(0xFF443C46),
    buttonBorder: Color(0xFF5E5560),
  ),
];

AppThemeSpec themeById(String? id) =>
    appThemes.firstWhere((t) => t.id == id, orElse: () => appThemes[6]);

/// Exposes the active theme spec and the switcher to the whole tree.
class AppThemeScope extends InheritedWidget {
  const AppThemeScope({
    super.key,
    required this.spec,
    required this.setTheme,
    required super.child,
  });

  final AppThemeSpec spec;
  final ValueChanged<AppThemeSpec> setTheme;

  static AppThemeScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()!;

  /// Active spec, falling back to the default theme when no scope is
  /// present (e.g. isolated widget tests).
  static AppThemeSpec specOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppThemeScope>()?.spec ??
      themeById(null);

  @override
  bool updateShouldNotify(AppThemeScope oldWidget) =>
      oldWidget.spec.id != spec.id;
}

// ------------------------------------------------------------- persistence

String get _configPath => p.join(
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.',
    '.video_toolkit',
    'theme.txt');

Future<String?> loadSavedThemeId() async {
  try {
    final file = File(_configPath);
    if (!await file.exists()) return null;
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  } catch (_) {
    return null;
  }
}

Future<void> saveThemeId(String id) async {
  try {
    final file = File(_configPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(id);
  } catch (_) {}
}
