import 'dart:io';

import 'package:video_toolkit/main.dart';
import 'package:video_toolkit/screens/editor_screen.dart';
import 'package:video_toolkit/theme/app_themes.dart';
import 'package:video_toolkit/theme/theme_icons.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('all 10 themes exist with unique ids and build valid theme data', () {
    expect(appThemes, hasLength(10));
    expect(appThemes.map((t) => t.id).toSet(), hasLength(10));
    for (final spec in appThemes) {
      final data = spec.buildTheme();
      expect(data.brightness, spec.brightness);
      expect(data.scaffoldBackgroundColor, spec.effectiveBackground);
    }
  });

  test('themeById falls back to Windows 11', () {
    expect(themeById('nope').id, 'win11');
    expect(themeById(null).id, 'win11');
    expect(themeById('ubuntu').name, 'Ubuntu');
  });

  test('glass themes are translucent, icon families match the OS', () {
    expect(themeById('win7').translucent, isTrue);
    expect(themeById('winvista').translucent, isTrue);
    expect(themeById('win10').translucent, isTrue);
    expect(themeById('macmodern').translucent, isTrue);
    expect(themeById('win98').translucent, isFalse);

    expect(themeById('macmodern').iconFamily, IconFamily.cupertino);
    expect(themeById('macclassic').iconFamily, IconFamily.cupertino);
    expect(themeById('ubuntu').iconFamily, IconFamily.material);
    expect(themeById('winxp').iconFamily, IconFamily.fluent);

    // Distinct icon sets actually resolve to distinct glyphs.
    expect(ThemeIcons.fluent.play, isNot(ThemeIcons.cupertino.play));
    expect(ThemeIcons.fluent.play, isNot(ThemeIcons.material.play));
  });

  testWidgets('setTheme switches the app theme', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // setTheme persists to disk — keep the user's real choice intact.
    final config = File(p.join(Platform.environment['HOME'] ?? '.',
        '.video_toolkit', 'theme.txt'));
    final previous = config.existsSync() ? config.readAsStringSync() : null;
    addTearDown(() {
      if (previous == null) {
        if (config.existsSync()) config.deleteSync();
      } else {
        config.writeAsStringSync(previous);
      }
    });

    await tester.pumpWidget(const AudioVideoEditorApp());
    await tester.pump(const Duration(milliseconds: 100));

    final context = tester.element(find.byType(EditorScreen));
    AppThemeScope.of(context).setTheme(themeById('win98'));
    // FluentApp animates theme changes — pump past the transition.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final themed = tester.element(find.text('Video Toolkit'));
    expect(FluentTheme.of(themed).scaffoldBackgroundColor,
        const Color(0xFFC0C0C0));
  });
}
