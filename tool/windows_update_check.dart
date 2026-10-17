// Roda no Windows (CI): o script de atualização troca uma instalação falsa
// pela versão do zip e reabre o app.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:video_toolkit/services/updater.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('Só faz sentido no Windows.');
    exit(2);
  }
  final root = await Directory.systemTemp.createTemp("vt d'app ");
  final install = Directory(p.join(root.path, 'Video Toolkit'));
  final fresh = Directory(p.join(root.path, 'fresh'));
  final work = Directory(p.join(root.path, 'work'));
  final marker = File(p.join(root.path, 'reaberto.txt'));
  for (final dir in [install, fresh, work]) {
    await Directory(p.join(dir.path, 'data', 'flutter_assets'))
        .create(recursive: true);
  }

  await File(p.join(install.path, 'app.dll')).writeAsString('old');
  await File(p.join(install.path, 'data', 'flutter_assets', 'a.txt'))
      .writeAsString('old');
  await File(p.join(install.path, 'data', 'mantido.txt'))
      .writeAsString('fica');

  final launcher = p.join(install.path, 'video_toolkit.cmd');
  await File(p.join(fresh.path, 'app.dll')).writeAsString('new');
  await File(p.join(fresh.path, 'data', 'flutter_assets', 'a.txt'))
      .writeAsString('new');
  await File(p.join(fresh.path, 'video_toolkit.cmd'))
      .writeAsString('@echo %1 > "${marker.path}"\r\n');

  final zip = p.join(work.path, 'VideoToolkit-windows.zip');
  final zipped = await Process.run('powershell.exe', [
    '-NoProfile',
    '-Command',
    "Compress-Archive -Path '${p.join(fresh.path, '*')}' "
        "-DestinationPath '$zip'",
  ]);
  _check(zipped.exitCode == 0, 'zip: ${zipped.stderr}');

  final running = await Process.start(
      'powershell.exe', ['-NoProfile', '-Command', 'Start-Sleep -Seconds 4']);
  final script = File(p.join(work.path, 'atualizar.ps1'));
  await script.writeAsString(windowsUpdateScript(
    processId: running.pid,
    zip: zip,
    installDir: install.path,
    executable: launcher,
    workDir: work.path,
    args: [r"C:\Meus Vídeos\it's ep 1.mkv"],
  ));
  final started = DateTime.now();
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
  ]);
  stdout.writeln(result.stdout);
  stderr.writeln(result.stderr);

  for (var i = 0; i < 50 && !await marker.exists(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _check(DateTime.now().difference(started) >= const Duration(seconds: 3),
      'o script não esperou o app fechar');
  _check(await File(p.join(install.path, 'app.dll')).readAsString() == 'new',
      'app.dll não foi trocado');
  _check(
      await File(p.join(install.path, 'data', 'flutter_assets', 'a.txt'))
              .readAsString() ==
          'new',
      'subpasta data não foi trocada');
  _check(
      await File(p.join(install.path, 'data', 'mantido.txt')).exists(),
      'arquivo que não veio no zip sumiu');
  _check(await marker.exists(), 'o app não foi reaberto');
  _check((await marker.readAsString()).contains("it's ep 1.mkv"),
      'o arquivo aberto não chegou inteiro');
  _check(!await work.exists(), 'a pasta temporária ficou');
  stdout.writeln('Atualização no Windows: ok');
  await root.delete(recursive: true);
}

void _check(bool ok, String message) {
  if (ok) return;
  stderr.writeln('FALHOU: $message');
  exit(1);
}
