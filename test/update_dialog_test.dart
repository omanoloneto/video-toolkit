import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/services/updater.dart';
import 'package:video_toolkit/widgets/update_dialog.dart';

class _FakeUpdater extends Updater {
  _FakeUpdater({this.failDownload = false}) : super(os: 'macos');

  final bool failDownload;
  final installs = <List<String>>[];

  @override
  Future<File> download(AppRelease release,
      {void Function(double progress)? onProgress,
      bool Function()? cancelled}) async {
    onProgress?.call(0.5);
    if (failDownload) {
      throw UpdateException('O arquivo baixado não confere.');
    }
    return File('/tmp/VideoToolkit-macos.zip');
  }

  @override
  Future<void> install(File asset, {List<String> relaunchArgs = const []}) async {
    installs.add(relaunchArgs);
  }
}

final _release = AppRelease(
  version: '1.2.0',
  assetName: 'VideoToolkit-macos.zip',
  asset: Uri.parse('https://github.com/x/VideoToolkit-macos.zip'),
  checksums: Uri.parse('https://github.com/x/SHA256SUMS.txt'),
);

Future<Future<bool>> _open(WidgetTester tester, Updater updater,
    {bool confirmRestart = false}) async {
  late Future<bool> result;
  await tester.pumpWidget(FluentApp(
    home: Builder(
      builder: (context) => Button(
        onPressed: () => result = showUpdateDialog(
          context,
          updater: updater,
          release: _release,
          current: '1.1.0',
          confirmRestart: confirmRestart,
          relaunchArgs: confirmRestart ? ['/v/episodio.mkv'] : const [],
        ),
        child: const Text('abrir'),
      ),
    ),
  ));
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('with nothing open it installs and asks the app to close',
      (tester) async {
    final updater = _FakeUpdater();
    final result = await _open(tester, updater);
    expect(await result, isTrue);
    expect(updater.installs, [<String>[]]);
  });

  testWidgets('with a file open it waits for the restart and reopens it',
      (tester) async {
    final updater = _FakeUpdater();
    final result = await _open(tester, updater, confirmRestart: true);
    expect(find.text('Reiniciar agora'), findsOneWidget);
    expect(updater.installs, isEmpty);

    await tester.tap(find.text('Reiniciar agora'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(updater.installs, [
      ['/v/episodio.mkv'],
    ]);
  });

  testWidgets('"Depois" keeps the running version', (tester) async {
    final updater = _FakeUpdater();
    final result = await _open(tester, updater, confirmRestart: true);
    await tester.tap(find.text('Depois'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(updater.installs, isEmpty);
  });

  testWidgets('a failed download points to the download page', (tester) async {
    final updater = _FakeUpdater(failDownload: true);
    final result = await _open(tester, updater);
    expect(find.text('Não deu pra atualizar sozinho'), findsOneWidget);
    expect(find.textContaining('omanoloneto.pro/video-toolkit/'), findsOneWidget);
    expect(find.text('Abrir a página'), findsOneWidget);

    await tester.tap(find.text('Fechar'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(updater.installs, isEmpty);
  });
}
