// End-to-end check of FfmpegService against a real ffmpeg install.
// Run with: dart run tool/e2e.dart
//
// Recreates the app's "mesclar áudios" scenario on generated media:
// audio 1 keeps its first 3 seconds, audio 2 fills the rest, merged
// into a single output track.
import 'dart:convert';
import 'dart:io';

import 'package:audio_video_editor/models/tracks.dart';
import 'package:audio_video_editor/services/ffmpeg_service.dart';

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
