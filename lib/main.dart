import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:media_kit/media_kit.dart';

import 'screens/editor_screen.dart';
import 'theme/app_themes.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isMacOS) await WindowManipulator.initialize();
  // The app runs without the macOS App Sandbox (needed to execute ffmpeg),
  // so file_picker's sandbox entitlement checks must be skipped.
  await FilePicker.skipEntitlementsChecks();
  final savedTheme = await loadSavedThemeId();
  runApp(AudioVideoEditorApp(
    initialPath: args.isNotEmpty ? args.first : null,
    initialThemeId: savedTheme,
  ));
}

class AudioVideoEditorApp extends StatefulWidget {
  const AudioVideoEditorApp({super.key, this.initialPath, this.initialThemeId});

  /// Optional video path passed on the command line.
  final String? initialPath;
  final String? initialThemeId;

  @override
  State<AudioVideoEditorApp> createState() => _AudioVideoEditorAppState();
}

class _AudioVideoEditorAppState extends State<AudioVideoEditorApp> {
  late AppThemeSpec _spec = themeById(widget.initialThemeId);

  @override
  void initState() {
    super.initState();
    _applyWindowEffects(_spec);
  }

  void _setTheme(AppThemeSpec spec) {
    setState(() => _spec = spec);
    saveThemeId(spec.id);
    _applyWindowEffects(spec);
  }

  /// Glass themes get an NSVisualEffectView blur behind the app; the
  /// others fall back to a solid window background.
  Future<void> _applyWindowEffects(AppThemeSpec spec) async {
    if (!Platform.isMacOS) return;
    try {
      await WindowManipulator.overrideMacOSBrightness(
          dark: spec.brightness == Brightness.dark);
      await WindowManipulator.setMaterial(spec.translucent
          ? (spec.brightness == Brightness.dark
              ? NSVisualEffectViewMaterial.hudWindow
              : NSVisualEffectViewMaterial.popover)
          : NSVisualEffectViewMaterial.windowBackground);
    } catch (_) {
      // Window effects are cosmetic; never break the app over them
      // (e.g. running in widget tests without the native plugin).
    }
  }

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'Video Toolkit',
      debugShowCheckedModeBanner: false,
      theme: _spec.buildTheme(),
      home: AppThemeScope(
        spec: _spec,
        setTheme: _setTheme,
        child: EditorScreen(initialPath: widget.initialPath),
      ),
    );
  }
}
