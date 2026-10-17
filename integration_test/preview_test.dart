import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_toolkit/main.dart';

/// Roda o app de verdade (media_kit + libmpv + FFmpeg): a prévia tem que
/// carregar o programa editado e ouvir a faixa montada.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late Directory dir;
  late String video;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('vt-integration-');
    video = '${dir.path}/episódio, teste.mkv';
    final result = await Process.run('/opt/homebrew/bin/ffmpeg', [
      '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc2=s=320x240:r=25:d=12',
      '-f', 'lavfi', '-i', "aevalsrc='0.5*sin(2*PI*440*t)':s=48000:d=12",
      '-f', 'lavfi', '-i', "aevalsrc='0.5*sin(2*PI*880*t)':s=48000:d=12",
      '-map', '0:v', '-map', '1:a', '-map', '2:a',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '25',
      '-c:a', 'aac',
      video,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  });

  tearDownAll(() => dir.delete(recursive: true));

  Future<void> waitFor(
      WidgetTester tester, String what, FutureOr<bool> Function() done,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final limit = DateTime.now().add(timeout);
    while (!await done()) {
      if (DateTime.now().isAfter(limit)) fail('timeout waiting for $what');
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the preview plays what the timeline shows', (tester) async {
    await tester.pumpWidget(AudioVideoEditorApp(initialPath: video));
    await waitFor(tester, 'the player', () => find.byType(Video).evaluate().isNotEmpty);
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    String loaded() => player.state.playlist.medias.firstOrNull?.uri ?? '';
    // o media_kit não acompanha a faixa escolhida direto no mpv
    Future<String> mpv(String property) =>
        (player.platform as NativePlayer).getProperty(property);

    // nada editado: toca o próprio arquivo
    await waitFor(tester, 'the file', () => loaded() == video);
    await waitFor(tester, 'the first audio', () async => await mpv('aid') == '1');

    // a borda esquerda do primeiro áudio encolhe: começa em silêncio
    final audioStart = find.byKey(const ValueKey('trim-start')).at(1);
    await tester.drag(audioStart, const Offset(120, 0));
    await waitFor(tester, 'the edited program', () => loaded().endsWith('.edl'));
    final edl = File(loaded()).readAsStringSync();
    expect(edl, contains('silence.flac,0.000000,'));
    expect(edl, contains('!track_meta,lang=zxx'));
    await waitFor(tester, 'the assembled audio',
        () async => await mpv('current-tracks/audio/lang') == 'zxx');

    // a forma de onda aparece quando a cópia do áudio fica pronta
    await waitFor(
        tester,
        'the waveform',
        () => find
            .byWidgetPredicate((w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == '_WaveformPainter')
            .evaluate()
            .isNotEmpty);

    // o vídeo perde o começo: a prévia recarrega com o corte
    final videoStart = find.byKey(const ValueKey('trim-start')).first;
    await tester.drag(videoStart, const Offset(80, 0));
    await waitFor(tester, 'the trimmed video', () {
      final text = loaded().endsWith('.edl') && File(loaded()).existsSync()
          ? File(loaded()).readAsStringSync()
          : '';
      final first = text.split('\n').firstWhere(
          (l) => l.contains('.mkv,'), orElse: () => '');
      return first.isNotEmpty && !first.contains(',0.000000,');
    });

    // espaço toca a partir do cursor
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'playback', () => player.state.playing);
    await waitFor(tester, 'time passing',
        () => player.state.position > const Duration(milliseconds: 800));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'pause', () => !player.state.playing);
  });
}
