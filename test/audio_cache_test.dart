import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/audio_cache.dart';
import 'package:video_toolkit/services/ffmpeg_service.dart';

Uint8List _pcm(List<int> samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

Float32List _peaksOf(List<int> samples, {int sampleRate = 8000}) =>
    (PeakBuilder(sampleRate: sampleRate)..add(_pcm(samples))).finish();

Future<void> _until(AudioCache cache, bool Function() ready) async {
  final done = Completer<void>();
  void check() {
    if (!done.isCompleted && ready()) done.complete();
  }

  cache.revision.addListener(check);
  check();
  try {
    await done.future.timeout(const Duration(seconds: 30));
  } finally {
    cache.revision.removeListener(check);
  }
}

Future<Map<String, dynamic>> _probe(String ffprobe, String path) async {
  final result = await Process.run(ffprobe, [
    '-v', 'error',
    '-print_format', 'json',
    '-show_streams',
    '-show_format',
    path,
  ]);
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

void main() {
  group('PeakBuilder', () {
    test('samples split between chunks read the same as one chunk', () {
      final samples = [
        for (var i = 0; i < 1000; i++) (i * 7919) % 65536 - 32768,
      ];
      final bytes = _pcm(samples);
      final split = PeakBuilder(sampleRate: 8000);
      const sizes = [1, 3, 2, 7, 5];
      for (var start = 0, k = 0; start < bytes.length; k++) {
        final end = math.min(start + sizes[k % sizes.length], bytes.length);
        split.add(bytes.sublist(start, end));
        start = end;
      }
      final whole = _peaksOf(samples);
      expect(whole, hasLength(25));
      expect(split.finish(), whole);
    });

    test('known samples land in their buckets, edges included', () {
      // um valor por bloco, colado na borda: cair do lado errado muda a lista
      List<int> onEdges(int length, List<int> indexes) {
        const values = [3277, -16384, 4096, -32768];
        final samples = List.filled(length, 0);
        for (var k = 0; k < indexes.length; k++) {
          samples[indexes[k]] = values[k];
        }
        return samples;
      }

      final expected = [closeTo(0.1, 1e-4), 0.5, 0.125, 1];
      expect(_peaksOf(onEdges(160, [39, 40, 119, 120])), expected);
      // 110,25 amostras por bloco: a borda arredonda pra cima
      expect(
        _peaksOf(onEdges(441, [110, 111, 330, 331]), sampleRate: 22050),
        expected,
      );
    });

    test('keeps the last partial bucket', () {
      final perBucket = (8000 / kWaveformBucketsPerSecond).round();
      final peaks = _peaksOf(List.filled(perBucket + 1, 0)..[perBucket] = 8192);
      expect(peaks, [0, 0.25]);
      expect(_peaksOf(const []), isEmpty);
    });
  });

  group('Waveform', () {
    // 4 blocos por segundo: bordas exatas em binário
    final waveform = Waveform(
      Float32List.fromList([0.25, 0.5, 0.125, 1, 0.75]),
      bucketsPerSecond: 4,
    );

    test('covers its buckets and knows its loudest one', () {
      expect(waveform.duration, 1.25);
      expect(waveform.maxPeak, 1);
    });

    test('peakBetween is 0 outside the data', () {
      expect(waveform.peakBetween(-1, -0.25), 0);
      expect(waveform.peakBetween(1.25, 3), 0);
      expect(waveform.peakBetween(2, 2), 0);
      expect(waveform.peakBetween(-0.1, -0.1), 0);
    });

    test('peakBetween reads a single bucket', () {
      expect(waveform.peakBetween(0.25, 0.5), 0.5);
      expect(waveform.peakBetween(0.3, 0.4), 0.5);
      expect(waveform.peakBetween(0.3, 0.3), 0.5);
      expect(waveform.peakBetween(0.6, 0.1), 0.125);
    });

    test('peakBetween spans buckets', () {
      expect(waveform.peakBetween(0, 0.75), 0.5);
      expect(waveform.peakBetween(0.1, 0.6), 0.5);
      expect(waveform.peakBetween(0.5, 1.25), 1);
      expect(waveform.peakBetween(-1, 0.1), 0.25);
      expect(waveform.peakBetween(1.1, 9), 0.75);
    });

    test('an empty waveform is silent', () {
      final empty = Waveform(Float32List(0));
      expect(empty.duration, 0);
      expect(empty.maxPeak, 0);
      expect(empty.peakBetween(0, 1), 0);
      expect(empty.peakBetween(0, 0), 0);
    });
  });

  group('AudioCache', () {
    test('without ffmpeg everything fails instead of waiting', () async {
      final cache = AudioCache(FfmpegService());
      const sources = [
        AudioSource(path: '/videos/movie.mkv', audioTypeIndex: 0),
        AudioSource(path: '/videos/movie.mkv', audioTypeIndex: 1),
      ];
      cache.prefetch(sources);
      await _until(cache, () => sources.every(cache.failed));
      for (final source in sources) {
        expect(cache.extracted(source), isNull);
        expect(cache.waveform(source), isNull);
      }

      final before = cache.revision.value;
      expect(cache.silence(), isNull);
      await _until(cache, () => cache.revision.value > before);
      expect(cache.silence(), isNull);

      String? black() =>
          cache.blackVideo(width: 64, height: 48, sarNum: 1, sarDen: 1);
      final beforeBlack = cache.revision.value;
      expect(black(), isNull);
      await _until(cache, () => cache.revision.value > beforeBlack);
      final failed = cache.revision.value;
      expect(black(), isNull);
      // pedir de novo não tenta outra vez
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cache.revision.value, failed);

      await cache.dispose();
      await cache.dispose();
    });

    test('copies each stream alone, draws its waveform and makes the silence',
        () async {
      final ffmpeg = FfmpegService();
      if (!await ffmpeg.locate()) {
        markTestSkipped('needs ffmpeg and ffprobe installed');
        return;
      }
      final ffprobe = ffmpeg.ffprobePath!;
      final dir = await Directory.systemTemp.createTemp('vt-audio-cache-');
      addTearDown(() => dir.delete(recursive: true));

      final movie = p.join(dir.path, 'movie.mkv');
      final made = await Process.run(ffmpeg.ffmpegPath!, [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=duration=4:size=64x48:rate=10',
        '-f', 'lavfi',
        '-i', "aevalsrc='if(lt(t,2),0.5*sin(2*PI*440*t),0)':s=48000:d=4",
        '-f', 'lavfi',
        '-i', "aevalsrc='if(gte(t,2),0.5*sin(2*PI*660*t),0)':s=48000:d=4",
        '-itsoffset', '1',
        '-f', 'lavfi', '-i', "aevalsrc='0.5*sin(2*PI*880*t)':s=48000:d=3",
        '-map', '0', '-map', '1', '-map', '2', '-map', '3',
        '-c:v', 'mpeg4', '-c:a:0', 'aac', '-c:a:1', 'flac', '-c:a:2', 'aac',
        movie,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      final cache = AudioCache(ffmpeg);
      addTearDown(cache.dispose);
      final toneFirst = AudioSource(path: movie, audioTypeIndex: 0);
      final toneLast = AudioSource(path: movie, audioTypeIndex: 1);
      final delayed = AudioSource(path: movie, audioTypeIndex: 2);
      final missing =
          AudioSource(path: p.join(dir.path, 'missing.mkv'), audioTypeIndex: 0);
      cache.prefetch([toneFirst, toneLast, delayed, missing]);
      expect(cache.silence(), isNull);
      await _until(
        cache,
        () =>
            cache.failed(missing) &&
            cache.silence() != null &&
            [toneFirst, toneLast, delayed].every(
                (s) => cache.extracted(s) != null && cache.waveform(s) != null),
      );

      expect(cache.extracted(missing), isNull);
      for (final (source, codec) in [
        (toneFirst, 'aac'),
        (toneLast, 'flac'),
        (delayed, 'aac'),
      ]) {
        expect(cache.failed(source), isFalse);
        final streams = (await _probe(ffprobe, cache.extracted(source)!))[
            'streams'] as List;
        expect(streams, hasLength(1));
        expect(streams.single, containsPair('codec_type', 'audio'));
        expect(streams.single, containsPair('codec_name', codec));
      }

      final first = cache.waveform(toneFirst)!;
      final last = cache.waveform(toneLast)!;
      expect(first.duration, closeTo(4, 0.1));
      expect(last.duration, closeTo(4, 0.1));
      expect(first.maxPeak, greaterThan(0.3));
      expect(first.peakBetween(0.25, 1.75), greaterThan(0.3));
      expect(first.peakBetween(2.25, 3.75), lessThan(0.01));
      expect(last.peakBetween(0.25, 1.75), lessThan(0.01));
      expect(last.peakBetween(2.25, 3.75), greaterThan(0.3));

      final startsLate = cache.waveform(delayed)!;
      expect(startsLate.duration, closeTo(4, 0.1));
      expect(startsLate.peakBetween(0.25, 0.75), lessThan(0.01));
      expect(startsLate.peakBetween(1.25, 3.75), greaterThan(0.3));

      final silence = await _probe(ffprobe, cache.silence()!);
      final duration = (silence['format'] as Map)['duration'] as String;
      expect(double.parse(duration), closeTo(kSilenceSeconds, 1));
      expect(
        (silence['streams'] as List).single,
        allOf(
          containsPair('codec_name', 'flac'),
          containsPair('sample_rate', '48000'),
          containsPair('channels', 2),
        ),
      );

      final folder = p.dirname(cache.extracted(toneFirst)!);
      expect(p.basename(folder), startsWith('vt-preview-'));
      expect(p.dirname(cache.silence()!), folder);
      await cache.dispose();
      expect(Directory(folder).existsSync(), isFalse);
      expect(cache.extracted(toneFirst), isNull);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('makes one black video per frame, with its size and pixel shape',
        () async {
      final ffmpeg = FfmpegService();
      if (!await ffmpeg.locate()) {
        markTestSkipped('needs ffmpeg and ffprobe installed');
        return;
      }
      final cache = AudioCache(ffmpeg);
      addTearDown(cache.dispose);
      String? wide() =>
          cache.blackVideo(width: 63, height: 47, sarNum: 4, sarDen: 3);
      String? square() =>
          cache.blackVideo(width: 64, height: 48, sarNum: 1, sarDen: 1);
      expect(wide(), isNull);
      expect(square(), isNull);
      await _until(cache, () => wide() != null && square() != null);

      expect(wide(), isNot(square()));
      // o quadro ímpar arredonda pra cima: é o mesmo vídeo do par
      expect(cache.blackVideo(width: 64, height: 48, sarNum: 4, sarDen: 3),
          wide());
      for (final (path, sar) in [(wide()!, '4:3'), (square()!, '1:1')]) {
        final black = await _probe(ffmpeg.ffprobePath!, path);
        final duration = (black['format'] as Map)['duration'] as String;
        expect(double.parse(duration), closeTo(kBlackSeconds, 1));
        expect(
          (black['streams'] as List).single,
          allOf(
            containsPair('codec_name', 'h264'),
            containsPair('width', 64),
            containsPair('height', 48),
            containsPair('sample_aspect_ratio', sar),
            containsPair('pix_fmt', 'yuv420p'),
            containsPair('avg_frame_rate', '1/1'),
          ),
          reason: path,
        );
      }

      final folder = p.dirname(wide()!);
      expect(p.basename(folder), startsWith('vt-preview-'));
      expect(p.dirname(square()!), folder);
      await cache.dispose();
      expect(Directory(folder).existsSync(), isFalse);
      expect(square(), isNull);
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
