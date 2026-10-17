// End-to-end check of FfmpegService against a real ffmpeg install.
// Run with: dart run tool/e2e.dart
//
// Recreates the app's "mesclar áudios" scenario on generated media:
// audio 1 keeps its first 3 seconds, audio 2 fills the rest, merged
// into a single output track.
import 'dart:convert';
import 'dart:io';

import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/ffmpeg_service.dart';

Future<void> main() async {
  final service = FfmpegService();
  if (!await service.locate()) {
    stderr.writeln('ffmpeg/ffprobe not found');
    exit(2);
  }

  final dir = await Directory.systemTemp.createTemp('ave-e2e-');
  var failures = 0;

  void check(String name, bool condition, [String? detail]) {
    if (condition) {
      stdout.writeln('PASS $name');
    } else {
      failures++;
      stdout.writeln('FAIL $name${detail == null ? '' : ' — $detail'}');
    }
  }

  try {
    final src = '${dir.path}/test.mkv';
    await _run(service.ffmpegPath!, [
      '-y',
      '-f', 'lavfi', '-i', 'testsrc=duration=6:size=320x240:rate=25',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-f', 'lavfi', '-i', 'sine=frequency=880:duration=6',
      '-map', '0', '-map', '1', '-map', '2',
      '-metadata:s:a:0', 'title=PT',
      '-metadata:s:a:1', 'title=EN',
      '-c:v', 'libx264', '-c:a', 'aac', '-ar', '48000',
      src,
    ]);

    // -------------------------------------------------- passthrough save
    var info = await service.probe(src);
    check('probe finds 3 tracks', info.tracks.length == 3,
        '${info.tracks.length}');
    check('audio tracks carry one full segment',
        info.byType(TrackType.audio).every((t) => t.segments.length == 1));

    final passOut = '${dir.path}/pass.mkv';
    var result =
        await service.save(source: info, added: [], outputPath: passOut);
    check('passthrough save succeeds', result.success, result.errorTail);
    var streams = await _probeStreams(service.ffprobePath!, passOut);
    check('passthrough keeps 3 streams', streams.length == 3);
    check('passthrough copies aac',
        streams.where((s) => s['codec_type'] == 'audio')
            .every((s) => s['codec_name'] == 'aac'));

    // -------------------------------------------------- merge scenario
    info = await service.probe(src);
    final audios = info.byType(TrackType.audio);
    final a1 = audios[0], a2 = audios[1];

    // Split both at 3s, keep a1's first half and a2's second half. Both
    // lanes become fragmentary, so save() auto-merges them into one track.
    splitSegment(a1.segments, a1.segments.single, 3);
    splitSegment(a2.segments, a2.segments.single, 3);
    a1.segments.removeAt(1);
    a2.segments.removeAt(0);

    for (final ext in ['mkv', 'mp4']) {
      final out = '${dir.path}/merged.$ext';
      result = await service.save(source: info, added: [], outputPath: out);
      check('merged save ($ext) succeeds', result.success, result.errorTail);
      if (!result.success) continue;

      streams = await _probeStreams(service.ffprobePath!, out);
      final audioStreams =
          streams.where((s) => s['codec_type'] == 'audio').toList();
      check('merged output ($ext) has 1 audio stream',
          audioStreams.length == 1, '${audioStreams.length}');

      final duration = await _mediaDuration(service.ffprobePath!, out);
      check('merged output ($ext) lasts ~6s', (duration - 6).abs() < 0.4,
          duration.toStringAsFixed(2));

      // Content check: 440 Hz tone before the cut, 880 Hz after. Through a
      // 660 Hz highpass the 440 Hz half must come out clearly quieter than
      // the 880 Hz half (absolute levels depend on the source amplitude).
      const hp = 'highpass=f=660,highpass=f=660';
      final early = await _meanVolume(service.ffmpegPath!, out, 0.5, 2.0, hp);
      final late = await _meanVolume(service.ffmpegPath!, out, 3.5, 5.5, hp);
      final rawEarly =
          await _meanVolume(service.ffmpegPath!, out, 0.5, 2.0, 'anull');
      final rawLate =
          await _meanVolume(service.ffmpegPath!, out, 3.5, 5.5, 'anull');
      check('merged output ($ext) switches source at 3s', late - early > 8,
          'early=${early.toStringAsFixed(1)}dB late=${late.toStringAsFixed(1)}dB');
      check('merged output ($ext) keeps steady loudness across the cut',
          (rawEarly - rawLate).abs() < 6,
          'early=${rawEarly.toStringAsFixed(1)}dB late=${rawLate.toStringAsFixed(1)}dB');
    }

    // -------------------------------------------------- merge with a leading gap
    // o primeiro trecho começa depois do zero: o FFmpeg 9 quebrava os
    // timestamps e o arquivo saía com duração "infinita"
    info = await service.probe(src);
    final g1 = info.byType(TrackType.audio)[0];
    final g2 = info.byType(TrackType.audio)[1];
    splitSegment(g1.segments, g1.segments.single, 1);
    splitSegment(g1.segments, g1.segments[1], 3);
    g1.segments
      ..removeAt(2)
      ..removeAt(0);
    splitSegment(g2.segments, g2.segments.single, 3);
    g2.segments.removeAt(0);

    final gapOut = '${dir.path}/gap.mkv';
    result = await service.save(source: info, added: [], outputPath: gapOut);
    check('merge with leading gap succeeds', result.success, result.errorTail);
    if (result.success) {
      final gapDuration = await _mediaDuration(service.ffprobePath!, gapOut);
      check('merge with leading gap keeps a real duration',
          (gapDuration - 6).abs() < 0.4, gapDuration.toStringAsFixed(2));
      final silence =
          await _meanVolume(service.ffmpegPath!, gapOut, 0.1, 0.8, 'anull');
      final sound =
          await _meanVolume(service.ffmpegPath!, gapOut, 1.5, 2.5, 'anull');
      check('merge with leading gap is silent until the first piece',
          sound - silence > 20,
          'silence=${silence.toStringAsFixed(1)}dB sound=${sound.toStringAsFixed(1)}dB');
    }

    // -------------------------------------------------- program edits
    // corta 1–2 s, insere um vídeo de outro tamanho (com som) no começo e
    // confere imagem, duração, áudio e legenda
    final subs = '${dir.path}/legenda.srt';
    await File(subs).writeAsString(
        '1\n00:00:00,500 --> 00:00:01,000\num\n\n'
        '2\n00:00:03,000 --> 00:00:04,000\ndois\n');
    final progSrc = '${dir.path}/programa.mkv';
    await _run(service.ffmpegPath!, [
      '-y',
      '-f', 'lavfi', '-i', 'testsrc=duration=6:size=320x240:rate=25',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-i', subs,
      '-map', '0', '-map', '1', '-map', '2',
      '-c:v', 'libx264', '-c:a', 'aac', '-c:s', 'srt',
      progSrc,
    ]);
    final insertSrc = '${dir.path}/abertura.mp4';
    await _run(service.ffmpegPath!, [
      '-y',
      '-f', 'lavfi', '-i', 'testsrc2=duration=2:size=640x360:rate=30',
      '-f', 'lavfi', '-i', 'sine=frequency=1320:duration=2',
      '-c:v', 'libx264', '-c:a', 'aac', '-shortest',
      insertSrc,
    ]);

    final program = await service.probe(progSrc);
    final insertable = await service.probeVideoClip(insertSrc);
    check('insertable video is probed', insertable != null);
    final edit = ProgramEdit(program, [])..cut(1, 2);
    edit.insert(
      insertable!.clip,
      at: 0,
      audio: AudioSource(path: insertSrc, audioTypeIndex: 0),
      audioDuration: insertable.audioDuration,
    );

    final progOut = '${dir.path}/programa-editado.mkv';
    result =
        await service.save(source: program, added: [], outputPath: progOut);
    check('edited program save succeeds', result.success, result.errorTail);
    if (result.success) {
      streams = await _probeStreams(service.ffprobePath!, progOut);
      final videoOut =
          streams.firstWhere((s) => s['codec_type'] == 'video');
      check('edited program is AV1 in the source frame',
          videoOut['codec_name'] == 'av1' &&
              videoOut['width'] == 320 &&
              videoOut['height'] == 240,
          '${videoOut['codec_name']} ${videoOut['width']}x${videoOut['height']}');
      final duration = await _mediaDuration(service.ffprobePath!, progOut);
      check('edited program lasts 6 - 1 + 2 = 7s', (duration - 7).abs() < 0.3,
          duration.toStringAsFixed(2));

      const hp = 'highpass=f=900,highpass=f=900';
      final inserted =
          await _meanVolume(service.ffmpegPath!, progOut, 0.3, 1.7, hp);
      final original =
          await _meanVolume(service.ffmpegPath!, progOut, 3.0, 5.0, hp);
      check('inserted sound plays where the inserted video is',
          inserted - original > 8,
          'inserido=${inserted.toStringAsFixed(1)}dB original=${original.toStringAsFixed(1)}dB');

      final cues = await Process.run(service.ffmpegPath!, [
        '-v', 'error', '-i', progOut, '-map', '0:s:0', '-f', 'srt', '-',
      ]);
      final text = cues.stdout as String;
      check('subtitles follow the cut and the insertion',
          text.contains('00:00:02,500 --> 00:00:03,000') &&
              text.contains('00:00:04,000 --> 00:00:05,000'),
          text.replaceAll('\n', ' | '));
    }

    // -------------------------------------------------- program gaps
    // vídeo afastado sem mexer no áudio: o vão fica preto nos quadros que caem
    // nele, sem atraso que se acumule de um vão pro outro, e o áudio segue
    // inteiro, tocando por baixo do preto
    final landscape = '${dir.path}/deitado.mp4';
    await _run(service.ffmpegPath!, [
      '-y',
      '-f', 'lavfi', '-i', 'testsrc=duration=6:size=320x240:rate=25',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6',
      '-c:v', 'libx264', '-c:a', 'aac',
      landscape,
    ]);
    final phone = '${dir.path}/celular.mp4';
    await _run(service.ffmpegPath!, [
      '-y', '-display_rotation', '90', '-i', landscape, '-c', 'copy', phone,
    ]);
    final film = '${dir.path}/filme.mkv';
    await _run(service.ffmpegPath!, [
      '-y',
      '-f', 'lavfi', '-i', 'testsrc=duration=10:size=320x240:rate=24000/1001',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=10',
      '-c:v', 'libx264', '-c:a', 'aac',
      film,
    ]);

    Future<MediaFileInfo> edited(
        String path, void Function(List<VideoClip>) edit) async {
      final file = await service.probe(path);
      edit(file.mainVideo!.clips);
      return file;
    }

    void moveSecondHalf(List<VideoClip> clips) {
      splitSegment(clips, clips.single, 2);
      clips.last.timelineStart = 3;
    }

    void delayStart(List<VideoClip> clips) => clips.single.timelineStart = 1;

    void trimEdgesInPlace(List<VideoClip> clips) {
      for (final t in [2.13, 4.27, 6.06, 8.31]) {
        splitSegment(clips, clips.last, t);
      }
      const left = [0.0, 0.37, 0.52, 0.29, 0.61];
      const right = [0.23, 0.0, 0.41, 0.17, 0.0];
      for (var i = 0; i < clips.length; i++) {
        clips[i]
          ..sourceStart += left[i]
          ..timelineStart += left[i]
          ..sourceEnd -= right[i];
      }
    }

    void spreadApart(List<VideoClip> clips) {
      for (final t in [1.5, 3.0, 4.5]) {
        splitSegment(clips, clips.last, t);
      }
      for (var i = 0; i < clips.length; i++) {
        clips[i].timelineStart += 0.41 * i;
      }
    }

    for (final (name, file, size) in [
      ('gap between clips', await edited(src, moveSecondHalf), '320x240'),
      ('leading gap', await edited(src, delayStart), '320x240'),
      ('phone video gap', await edited(phone, moveSecondHalf), '240x320'),
      ('phone video leading gap', await edited(phone, delayStart), '240x320'),
      ('trimmed edges at 23.976 fps', await edited(film, trimEdgesInPlace),
          '320x240'),
      ('clips spread 0.41s apart', await edited(src, spreadApart), '320x240'),
    ]) {
      final out = '${dir.path}/${name.replaceAll(' ', '-')}.mkv';
      result = await service.save(source: file, added: [], outputPath: out);
      check('$name save succeeds', result.success, result.errorTail);
      if (!result.success) continue;

      final clips = file.mainVideo!.clips;
      final fps = clips.first.frameRate;
      double onFrame(double t) => (t * fps - 1e-6).ceil() / fps;
      bool near(double a, double b) => (a - b).abs() < 0.5 / fps;
      final gaps = [
        for (var k = 0; k < clips.length; k++)
          if (clips[k].timelineStart >
              (k == 0 ? 0 : clips[k - 1].timelineEnd) + 1e-3)
            (k == 0 ? 0.0 : clips[k - 1].timelineEnd, clips[k].timelineStart),
      ];

      final video = await _streamEnd(service.ffprobePath!, out, 'v:0');
      final end = onFrame(programDuration(clips));
      check('$name: video lasts ${end.toStringAsFixed(3)}s', near(video, end),
          video.toStringAsFixed(3));
      final picture = (await _probeStreams(service.ffprobePath!, out))
          .firstWhere((s) => s['codec_type'] == 'video');
      check('$name: picture is $size as played',
          '${picture['width']}x${picture['height']}' == size,
          '${picture['width']}x${picture['height']}');
      final blacks = await _blackIntervals(service.ffmpegPath!, out);
      check(
          '$name: black on the frames of each gap, half a frame at most off',
          blacks.length == gaps.length &&
              Iterable<int>.generate(gaps.length).every((i) =>
                  near(blacks[i].$1, onFrame(gaps[i].$1)) &&
                  near(blacks[i].$2, onFrame(gaps[i].$2))),
          'black $blacks, gaps $gaps');
      final own = file.byType(TrackType.audio).first.durationSeconds;
      final audio = await _streamEnd(service.ffprobePath!, out, 'a:0');
      check('$name: audio keeps its own ${own.toStringAsFixed(2)}s',
          (audio - own).abs() < 0.1, audio.toStringAsFixed(3));
      final under = await _meanVolume(service.ffmpegPath!, out,
          gaps.first.$1 + 0.1, gaps.first.$2 - 0.1, 'anull');
      check('$name: audio plays under the black', under > -30,
          '${under.toStringAsFixed(1)}dB');
    }
  } finally {
    await dir.delete(recursive: true);
  }

  if (failures > 0) {
    stdout.writeln('\n$failures check(s) failed');
    exit(1);
  }
  stdout.writeln('\nAll e2e checks passed');
}

Future<void> _run(String bin, List<String> args) async {
  final result = await Process.run(bin, args);
  if (result.exitCode != 0) {
    throw Exception('command failed: $bin ${args.join(' ')}\n${result.stderr}');
  }
}

Future<List<Map<String, dynamic>>> _probeStreams(
    String ffprobe, String path) async {
  final result = await Process.run(ffprobe, [
    '-v', 'quiet', '-print_format', 'json', '-show_streams', path,
  ]);
  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  return (json['streams'] as List).cast<Map<String, dynamic>>();
}

Future<double> _mediaDuration(String ffprobe, String path) async {
  final result = await Process.run(ffprobe, [
    '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0', path,
  ]);
  return double.tryParse((result.stdout as String).trim()) ?? 0;
}

Future<double> _streamEnd(String ffprobe, String path, String stream) async {
  final result = await Process.run(ffprobe, [
    '-v', 'quiet', '-select_streams', stream,
    '-show_entries', 'packet=pts_time,duration_time', '-of', 'csv=p=0', path,
  ]);
  var end = 0.0;
  for (final line in const LineSplitter().convert(result.stdout as String)) {
    final fields = line.split(',');
    final pts = double.tryParse(fields.first) ?? 0.0;
    final duration =
        fields.length > 1 ? double.tryParse(fields[1]) ?? 0.0 : 0.0;
    if (pts + duration > end) end = pts + duration;
  }
  return end;
}

Future<List<(double, double)>> _blackIntervals(
    String ffmpeg, String path) async {
  final result = await Process.run(ffmpeg, [
    '-hide_banner', '-i', path, '-map', '0:v:0',
    '-vf', 'blackdetect=d=0:pix_th=0.1',
    '-f', 'null', '-',
  ]);
  return RegExp(r'black_start:([\d.]+) black_end:([\d.]+)')
      .allMatches(result.stderr as String)
      .map((m) => (double.parse(m.group(1)!), double.parse(m.group(2)!)))
      .toList();
}

/// Mean volume (dB) of [path] between [from] and [to] after [filter].
Future<double> _meanVolume(String ffmpeg, String path, double from, double to,
    String filter) async {
  final result = await Process.run(ffmpeg, [
    '-hide_banner',
    '-ss', '$from', '-to', '$to', '-i', path,
    '-map', '0:a:0',
    '-af', '$filter,volumedetect',
    '-f', 'null', '-',
  ]);
  final match = RegExp(r'mean_volume: (-?[\d.]+) dB')
      .firstMatch(result.stderr as String);
  return match == null ? -99 : double.parse(match.group(1)!);
}
