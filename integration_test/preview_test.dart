import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
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

  // linha do EDL: %bytes do caminho%caminho,início,duração[,layout=this]
  ({String path, double start, double length}) entryOf(String line) {
    final size = RegExp(r'^%(\d+)%').firstMatch(line)!;
    final rest = utf8.encode(line.substring(size.end));
    final bytes = int.parse(size.group(1)!);
    final fields = utf8.decode(rest.sublist(bytes + 1)).split(',');
    return (
      path: utf8.decode(rest.sublist(0, bytes)),
      start: double.parse(fields[0]),
      length: double.parse(fields[1]),
    );
  }

  testWidgets('the preview plays what the timeline shows', (tester) async {
    await tester.pumpWidget(AudioVideoEditorApp(initialPath: video));
    await waitFor(tester, 'the player', () => find.byType(Video).evaluate().isNotEmpty);
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    String loaded() => player.state.playlist.medias.firstOrNull?.uri ?? '';
    String program() => loaded().endsWith('.edl') && File(loaded()).existsSync()
        ? File(loaded()).readAsStringSync()
        : '';
    // o media_kit não acompanha a faixa escolhida direto no mpv
    Future<String> mpv(String property) =>
        (player.platform as NativePlayer).getProperty(property);
    Future<double> mpvTime() async =>
        double.tryParse(await mpv('time-pos')) ?? double.nan;
    VoidCallback press(String tooltip) => tester
        .widget<IconButton>(find.descendant(
          of: find.byWidgetPredicate(
              (w) => w is Tooltip && w.message == tooltip),
          matching: find.byType(IconButton),
        ))
        .onPressed!;

    // nada editado: toca o próprio arquivo
    await waitFor(tester, 'the file', () => loaded() == video);
    await waitFor(tester, 'the first audio', () async => await mpv('aid') == '1');
    await waitFor(tester, 'the end of loading',
        () => find.byType(ProgressRing).evaluate().isEmpty);

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

    // a borda do vídeo mexe só no vídeo: o começo fica preto e o som não muda
    await tester.pump(const Duration(milliseconds: 400));
    final before = program();
    final sound = before.substring(before.indexOf('!new_stream'));
    final videoStart = find.byKey(const ValueKey('trim-start')).first;
    await tester.drag(videoStart, const Offset(80, 0));
    await waitFor(
        tester,
        'the black before the trimmed video',
        () =>
            program().split('\n').elementAtOrNull(2)?.contains('/black-') ??
            false);
    final trimmed = program();
    final image = [
      for (final line in trimmed.split('!new_stream').first.split('\n'))
        if (line.startsWith('%')) entryOf(line),
    ];
    expect(image, hasLength(2));
    final (black, clip) = (image.first, image.last);
    expect(black.start, 0);
    expect(black.length, greaterThan(0.2));
    // a lista fica na pasta do cache, junto do preto que ela usa
    expect(p.dirname(black.path), p.dirname(loaded()));
    expect(clip.path, video);
    expect(clip.start, closeTo(black.length, 1e-6));
    expect(trimmed.substring(trimmed.indexOf('!new_stream')), sound);

    // espaço toca a partir do cursor
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'playback', () => player.state.playing);
    await waitFor(tester, 'time passing',
        () => player.state.position > const Duration(milliseconds: 800));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'pause', () => !player.state.playing);

    // o cursor mexido enquanto o programa novo abre não se perde
    press('Voltar 5 s')();
    await waitFor(tester, 'the start', () async => await mpvTime() < 0.1);
    final shown = loaded();
    final forward = press('Avançar 5 s');
    var stepped = false;
    final onOpen = player.stream.playlist.listen((playlist) {
      final uri = playlist.medias.firstOrNull?.uri;
      if (stepped || uri == null || uri == shown) return;
      stepped = true;
      forward();
    });
    final videoEnd = find.byKey(const ValueKey('trim-end')).first;
    await tester.drag(videoEnd, const Offset(-80, 0));
    await waitFor(tester, 'a step while the program opens', () => stepped);
    await onOpen.cancel();
    await waitFor(tester, 'the image at the step',
        () async => (await mpvTime() - 5).abs() < 0.2);

    // no fim do programa, play logo depois de editar toca a edição do começo
    bool playingFromStart() {
      final position = player.state.position;
      return player.state.playing &&
          position > const Duration(milliseconds: 300) &&
          position < const Duration(seconds: 4);
    }
    for (var i = 0; i < 3; i++) {
      press('Avançar 5 s')();
    }
    await waitFor(tester, 'the end', () async => await mpvTime() > 10);
    await tester.drag(audioStart, const Offset(-40, 0));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'playback from the start', playingFromStart);
    // o recomeço é decidido antes de recarregar: a edição já abre no começo
    expect(player.state.playlist.medias.single.start, Duration.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'pause after the restart', () => !player.state.playing);

    // play no fim com a edição ainda abrindo espera a carga; com a UI presa
    // quando ela termina (forçada aqui), o mpv tocava o fim e parava
    for (var i = 0; i < 3; i++) {
      press('Avançar 5 s')();
    }
    await waitFor(tester, 'the end again', () async => await mpvTime() > 10);
    final atEnd = loaded();
    final play = press('Reproduzir (espaço)');
    var played = false;
    final onReload = player.stream.playlist.listen((playlist) {
      final uri = playlist.medias.firstOrNull?.uri;
      if (played || uri == null || uri == atEnd) return;
      played = true;
      play();
    });
    var stalled = false;
    final onLoaded = player.stream.duration.listen((duration) {
      if (!played || stalled || duration <= Duration.zero) return;
      stalled = true;
      sleep(const Duration(seconds: 1));
    });
    await tester.drag(audioStart, const Offset(40, 0));
    await waitFor(tester, 'a play while the edit loads', () => stalled);
    await onReload.cancel();
    await onLoaded.cancel();
    await waitFor(tester, 'playback from the start after the load',
        playingFromStart);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, 'pause after the load', () => !player.state.playing);

    // o macOS sai sem desmontar a tela: o pedido de saída leva a pasta
    final folder = File(loaded()).parent;
    expect(folder.existsSync(), isTrue);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(folder.existsSync(), isFalse);
  });
}
