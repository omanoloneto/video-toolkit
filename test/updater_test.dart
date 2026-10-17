import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/services/updater.dart';

Map<String, dynamic> _release(String tag, Map<String, String> assets) => {
      'tag_name': tag,
      'draft': false,
      'assets': [
        for (final MapEntry(key: name, value: url) in assets.entries)
          {'name': name, 'browser_download_url': url},
      ],
    };

const _base = 'https://github.com/omanoloneto/video-toolkit/releases/download';

void main() {
  group('isNewerVersion', () {
    test('compares each number, not the text', () {
      expect(isNewerVersion('1.10.0', '1.9.3'), isTrue);
      expect(isNewerVersion('1.1.0', '1.1.0'), isFalse);
      expect(isNewerVersion('1.0.9', '1.1.0'), isFalse);
      expect(isNewerVersion('2.0', '1.9.9'), isTrue);
    });

    test('ignores pre-release and build suffixes', () {
      expect(isNewerVersion('1.2.0+7', '1.2.0'), isFalse);
      expect(isNewerVersion('1.2.1-beta', '1.2.0'), isTrue);
    });
  });

  group('parseRelease', () {
    final full = _release('v1.1.0', {
      'VideoToolkit-macos.zip': '$_base/v1.1.0/VideoToolkit-macos.zip',
      'VideoToolkit-windows.zip': '$_base/v1.1.0/VideoToolkit-windows.zip',
      'video-toolkit-linux-amd64.deb':
          '$_base/v1.1.0/video-toolkit-linux-amd64.deb',
      'SHA256SUMS.txt': '$_base/v1.1.0/SHA256SUMS.txt',
    });

    test('picks the file of each system and drops the v of the tag', () {
      for (final (os, name) in [
        ('macos', 'VideoToolkit-macos.zip'),
        ('windows', 'VideoToolkit-windows.zip'),
        ('linux', 'video-toolkit-linux-amd64.deb'),
      ]) {
        final release = parseRelease(full, os)!;
        expect(release.version, '1.1.0');
        expect(release.assetName, name);
        expect(release.asset.toString(), '$_base/v1.1.0/$name');
        expect(release.checksums.toString(), '$_base/v1.1.0/SHA256SUMS.txt');
      }
    });

    test('an old release without fixed names or checksums is not offered', () {
      final old = _release('v1.0.0', {
        'VideoToolkit-1.0.0-macos.zip': '$_base/v1.0.0/VideoToolkit-1.0.0-macos.zip',
      });
      expect(parseRelease(old, 'macos'), isNull);
      final noSums = _release('v1.1.0', {
        'VideoToolkit-macos.zip': '$_base/v1.1.0/VideoToolkit-macos.zip',
      });
      expect(parseRelease(noSums, 'macos'), isNull);
    });

    test('links outside GitHub are refused', () {
      final evil = _release('v9.0.0', {
        'VideoToolkit-macos.zip': 'https://example.com/VideoToolkit-macos.zip',
        'SHA256SUMS.txt': '$_base/v9.0.0/SHA256SUMS.txt',
      });
      expect(parseRelease(evil, 'macos'), isNull);
      final plain = _release('v9.0.0', {
        'VideoToolkit-macos.zip': 'http://github.com/x/VideoToolkit-macos.zip',
        'SHA256SUMS.txt': '$_base/v9.0.0/SHA256SUMS.txt',
      });
      expect(parseRelease(plain, 'macos'), isNull);
    });

    test('the local test server is accepted only when asked', () {
      final local = _release('v9.0.0', {
        'VideoToolkit-macos.zip': 'http://127.0.0.1:8000/VideoToolkit-macos.zip',
        'SHA256SUMS.txt': 'http://127.0.0.1:8000/SHA256SUMS.txt',
      });
      expect(parseRelease(local, 'macos'), isNull);
      expect(parseRelease(local, 'macos', allowLoopback: true)?.version, '9.0.0');
    });

    test('no release for an unknown system', () {
      expect(parseRelease(full, 'android'), isNull);
    });
  });

  test('checksumFor reads sha256sum output, binary marker included', () {
    final hash = 'A' * 64;
    final sums = '${'b' * 64}  outro.zip\n$hash *VideoToolkit-macos.zip\n';
    expect(checksumFor(sums, 'VideoToolkit-macos.zip'), 'a' * 64);
    expect(checksumFor(sums, 'nada.zip'), isNull);
  });

  test('macBundleOf finds the .app around the executable', () {
    expect(
        macBundleOf(
            '/Users/x/Applications/Video Toolkit.app/Contents/MacOS/Video Toolkit'),
        '/Users/x/Applications/Video Toolkit.app');
    expect(macBundleOf('/usr/lib/video-toolkit/video_toolkit'), isNull);
  });

  test('the Windows script waits, copies, relaunches and escapes quotes', () {
    final script = windowsUpdateScript(
      processId: 4242,
      zip: r"C:\Users\Ana D'Ávila\AppData\Local\Temp\vt\VideoToolkit-windows.zip",
      installDir: r"C:\Users\Ana D'Ávila\Video Toolkit",
      executable: r"C:\Users\Ana D'Ávila\Video Toolkit\video_toolkit.exe",
      workDir: r"C:\Users\Ana D'Ávila\AppData\Local\Temp\vt",
      args: [r"C:\Meus Vídeos\it's 1.mkv"],
    );
    expect(script, contains('Wait-Process -Id 4242'));
    expect(script, contains(r"-Destination 'C:\Users\Ana D''Ávila\Video Toolkit'"));
    expect(script,
        contains(r"""-FilePath 'C:\Users\Ana D''Ávila\Video Toolkit\video_toolkit.exe' -ArgumentList @('"C:\Meus Vídeos\it''s 1.mkv"')"""));
    expect(script, contains("Start-Process 'https://omanoloneto.pro/video-toolkit/'"));
  });

  group('Updater over HTTP', () {
    late HttpServer server;
    late List<int> payload;
    var sums = '';

    setUp(() async {
      payload = List.generate(300000, (i) => i % 251);
      sums = '${sha256.convert(payload)}  VideoToolkit-macos.zip\n';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        switch (request.uri.path) {
          case '/latest':
            response.write(jsonEncode(_release('v2.0.0', {
              'VideoToolkit-macos.zip':
                  'http://127.0.0.1:${server.port}/VideoToolkit-macos.zip',
              'SHA256SUMS.txt': 'http://127.0.0.1:${server.port}/SHA256SUMS.txt',
            })));
          case '/VideoToolkit-macos.zip':
            response.contentLength = payload.length;
            response.add(payload);
          case '/SHA256SUMS.txt':
            response.write(sums);
          default:
            response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Updater updater() => Updater(
          os: 'macos',
          executable: '/tmp/X.app/Contents/MacOS/X',
          environment: {
            'VIDEO_TOOLKIT_RELEASES_API': 'http://127.0.0.1:${server.port}/latest',
          },
        );

    test('finds the newer version and downloads it checked', () async {
      final release = await updater().newerThan('1.1.0');
      expect(release?.version, '2.0.0');
      expect(await updater().newerThan('2.0.0'), isNull);

      final progress = <double>[];
      final file = await updater().download(release!, onProgress: progress.add);
      addTearDown(() => file.parent.delete(recursive: true));
      expect(await file.readAsBytes(), payload);
      expect(progress.last, 1.0);
    });

    test('a file that does not match the checksum is thrown away', () async {
      sums = '${'0' * 64}  VideoToolkit-macos.zip\n';
      final release = (await updater().newerThan('1.0.0'))!;
      await expectLater(updater().download(release),
          throwsA(isA<UpdateException>()));
    });
  });
}
