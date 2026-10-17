import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_toolkit/services/ffmpeg_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vt-service-');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  group('isSameFile', () {
    test('matches the same path written differently', () async {
      final file = File(p.join(dir.path, 'movie.mkv'))..writeAsStringSync('x');
      final messy = p.join(dir.path, 'sub', '..', 'movie.mkv');
      expect(await isSameFile(messy, file.path), isTrue);
    });

    test('matches the source through a linked folder', () async {
      final real = Directory(p.join(dir.path, 'real'))..createSync();
      final file = File(p.join(real.path, 'movie.mkv'))..writeAsStringSync('x');
      Link(p.join(dir.path, 'alias')).createSync(real.path);
      expect(await isSameFile(p.join(dir.path, 'alias', 'movie.mkv'), file.path),
          isTrue);
    }, skip: Platform.isWindows ? 'symlinks need admin rights' : false);

    test('a link named in the dialog is not the source: saving replaces the link',
        () async {
      final file = File(p.join(dir.path, 'movie.mkv'))..writeAsStringSync('x');
      final link = Link(p.join(dir.path, 'alias.mkv'))..createSync(file.path);
      expect(await isSameFile(link.path, file.path), isFalse);
    }, skip: Platform.isWindows ? 'symlinks need admin rights' : false);

    test('different or missing files are not the source', () async {
      final a = File(p.join(dir.path, 'a.mkv'))..writeAsStringSync('x');
      final b = File(p.join(dir.path, 'b.mkv'))..writeAsStringSync('x');
      expect(await isSameFile(a.path, b.path), isFalse);
      expect(await isSameFile(p.join(dir.path, 'new.mkv'), a.path), isFalse);
    });
  });

  test('a missing ffmpeg becomes a failed result instead of a crash', () async {
    final service = FfmpegService()
      ..ffmpegPath = p.join(dir.path, 'no-such-ffmpeg');
    final result = await service.exportAudioTrack(
      sourcePath: p.join(dir.path, 'movie.mkv'),
      audioTypeIndex: 0,
      outputPath: p.join(dir.path, 'out.m4a'),
    );
    expect(result.success, isFalse);
    expect(result.stderr, contains('FFmpeg'));
  });
}
