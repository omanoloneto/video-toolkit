import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Onde se baixa o app à mão: o caminho quando atualizar sozinho não dá.
final kDownloadPage = Uri.parse('https://omanoloneto.pro/video-toolkit/');

final _releasesApi = Uri.parse(
    'https://api.github.com/repos/omanoloneto/video-toolkit/releases/latest');

const kChecksumsAsset = 'SHA256SUMS.txt';

/// O arquivo de cada sistema numa versão publicada (nomes fixos desde a
/// 1.1.0); null num sistema sem versão publicada.
String? releaseAssetName(String os) => switch (os) {
      'macos' => 'VideoToolkit-macos.zip',
      'windows' => 'VideoToolkit-windows.zip',
      'linux' => 'video-toolkit-linux-amd64.deb',
      _ => null,
    };

class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Uma versão publicada que serve neste sistema.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.assetName,
    required this.asset,
    required this.checksums,
  });

  final String version;
  final String assetName;
  final Uri asset;
  final Uri checksums;
}

/// [candidate] é mais nova que [current] ("1.10.0" > "1.9.3"); o que vem
/// depois de "-" ou "+" não conta.
bool isNewerVersion(String candidate, String current) {
  List<int> parts(String v) => v
      .split(RegExp(r'[-+]'))
      .first
      .split('.')
      .map((n) => int.tryParse(n) ?? 0)
      .toList();
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Lê a resposta da API de releases; null quando falta o arquivo deste
/// sistema ou a lista de SHA-256, ou quando um link sai do GitHub.
AppRelease? parseRelease(Map<String, dynamic> json, String os,
    {bool allowLoopback = false}) {
  final name = releaseAssetName(os);
  final tag = json['tag_name'];
  if (name == null || tag is! String || json['draft'] == true) return null;
  Uri? urlOf(String asset) {
    for (final entry in (json['assets'] as List? ?? const [])) {
      if (entry is Map && entry['name'] == asset) {
        final url = Uri.tryParse('${entry['browser_download_url']}');
        return url != null && _trusted(url, allowLoopback) ? url : null;
      }
    }
    return null;
  }

  final asset = urlOf(name), checksums = urlOf(kChecksumsAsset);
  if (asset == null || checksums == null) return null;
  return AppRelease(
    version: tag.startsWith('v') ? tag.substring(1) : tag,
    assetName: name,
    asset: asset,
    checksums: checksums,
  );
}

// o arquivo baixado vira o próprio app: só do GitHub (ou da máquina, no
// teste de ponta a ponta que aponta a API pra um servidor local)
bool _trusted(Uri url, bool allowLoopback) =>
    (url.scheme == 'https' && url.host == 'github.com') ||
    (allowLoopback &&
        url.scheme == 'http' &&
        (url.host == '127.0.0.1' || url.host == 'localhost'));

/// O SHA-256 de [name] numa lista no formato do sha256sum.
String? checksumFor(String sums, String name) {
  for (final line in const LineSplitter().convert(sums)) {
    final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (match != null && match.group(2) == name) {
      return match.group(1)!.toLowerCase();
    }
  }
  return null;
}

/// O .app que contém [executable] (".../X.app/Contents/MacOS/X").
String? macBundleOf(String executable) {
  final macos = p.dirname(executable);
  final contents = p.dirname(macos);
  final bundle = p.dirname(contents);
  if (p.basename(macos) != 'MacOS' ||
      p.basename(contents) != 'Contents' ||
      !bundle.endsWith('.app')) {
    return null;
  }
  return bundle;
}

/// Script do Windows: espera o app fechar (o .exe aberto não pode ser
/// trocado), copia a versão nova por cima e abre ela; se algo der errado,
/// abre a página de download.
String windowsUpdateScript({
  required int processId,
  required String zip,
  required String installDir,
  required String executable,
  required String workDir,
  List<String> args = const [],
}) {
  String q(String value) => "'${value.replaceAll("'", "''")}'";
  // o Start-Process junta os argumentos sem aspas: caminho com espaço
  // chegaria partido no app
  final launchArgs = args.isEmpty
      ? ''
      : ' -ArgumentList @(${args.map((a) => q('"$a"')).join(', ')})';
  return '''
\$ErrorActionPreference = 'Stop'
\$log = Join-Path \$env:TEMP 'video-toolkit-update.log'
try {
  try { Wait-Process -Id $processId -Timeout 120 } catch { }
  \$staging = Join-Path ${q(workDir)} 'novo'
  Expand-Archive -LiteralPath ${q(zip)} -DestinationPath \$staging -Force
  Copy-Item -Path (Join-Path \$staging '*') -Destination ${q(installDir)} -Recurse -Force
  Start-Process -FilePath ${q(executable)}$launchArgs
} catch {
  \$_ | Out-File -FilePath \$log -Append
  Start-Process ${q(kDownloadPage.toString())}
}
Remove-Item -LiteralPath ${q(workDir)} -Recurse -Force -ErrorAction SilentlyContinue
''';
}

/// Procura, baixa e instala a versão nova do app publicada no GitHub.
class Updater {
  Updater({
    HttpClient? client,
    Uri? releasesApi,
    String? os,
    String? executable,
    Map<String, String>? environment,
  })  : _client = client ?? HttpClient(),
        _os = os ?? Platform.operatingSystem,
        _executable = executable ?? Platform.resolvedExecutable,
        _api = releasesApi ??
            _overridden(environment ?? Platform.environment) ??
            _releasesApi;

  final HttpClient _client;
  final String _os;
  final String _executable;
  final Uri _api;

  // teste de ponta a ponta: aponta a API pra um servidor na própria máquina
  static Uri? _overridden(Map<String, String> environment) {
    final value = environment['VIDEO_TOOLKIT_RELEASES_API'];
    final uri = value == null ? null : Uri.tryParse(value);
    return uri != null && _trusted(uri, true) && uri.scheme == 'http'
        ? uri
        : null;
  }

  bool get _loopback => _api.scheme == 'http';

  /// A versão publicada, quando é mais nova que [current] e tem arquivo pra
  /// este sistema.
  Future<AppRelease?> newerThan(String current) async {
    if (releaseAssetName(_os) == null) return null;
    final body = await _getText(_api, accept: 'application/vnd.github+json');
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final release = parseRelease(json, _os, allowLoopback: _loopback);
    if (release == null || !isNewerVersion(release.version, current)) {
      return null;
    }
    return release;
  }

  /// Baixa o arquivo e confere o SHA-256 publicado na mesma versão. Devolve o
  /// arquivo numa pasta temporária só dele.
  Future<File> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final expected =
        checksumFor(await _getText(release.checksums), release.assetName);
    if (expected == null) {
      throw UpdateException(
          'A versão ${release.version} não traz o SHA-256 do arquivo.');
    }
    final dir = await Directory.systemTemp.createTemp('vt-update-');
    final file = File(p.join(dir.path, release.assetName));
    try {
      final response = await _get(release.asset);
      final total = response.contentLength;
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(_stall)) {
          if (cancelled?.call() ?? false) {
            throw UpdateException('Atualização cancelada.');
          }
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      hasher.close();
      if (digest.value.toString() != expected) {
        throw UpdateException('O arquivo baixado não confere com o SHA-256 '
            'publicado. Tente de novo mais tarde.');
      }
      return file;
    } catch (_) {
      await dir.delete(recursive: true).catchError((_) => dir);
      rethrow;
    }
  }

  /// Instala [asset] por cima deste app e abre a versão nova. Quem chama
  /// fecha o app em seguida (no Windows a troca só acontece depois disso).
  Future<void> install(File asset, {List<String> relaunchArgs = const []}) =>
      switch (_os) {
        'macos' => _installMac(asset, relaunchArgs),
        'windows' => _installWindows(asset, relaunchArgs),
        'linux' => _installLinux(asset, relaunchArgs),
        _ => throw UpdateException('Sistema sem atualização automática.'),
      };

  Future<void> _installMac(File zip, List<String> args) async {
    final bundle = macBundleOf(_executable);
    if (bundle == null) {
      throw UpdateException('O app não está rodando de dentro de um .app.');
    }
    final parent = p.dirname(bundle);
    await _requireWritable(parent);
    final unpacked = Directory(p.join(zip.parent.path, 'novo'));
    await _run('ditto', ['-x', '-k', zip.path, unpacked.path]);
    final fresh = Directory(p.join(unpacked.path, p.basename(bundle)));
    if (!await fresh.exists()) {
      throw UpdateException('O pacote baixado não tem ${p.basename(bundle)}.');
    }
    await _run('codesign', ['--verify', '--deep', '--strict', fresh.path]);
    final aside = p.join(parent,
        '.${p.basename(bundle)}.antigo-${DateTime.now().millisecondsSinceEpoch}');
    await Directory(bundle).rename(aside);
    try {
      await fresh.rename(bundle);
    } on FileSystemException {
      try {
        await _run('ditto', [fresh.path, bundle]);
      } catch (_) {
        await Directory(bundle).delete(recursive: true).catchError((_) =>
            Directory(bundle));
        await Directory(aside).rename(bundle);
        rethrow;
      }
    }
    // a cópia velha ainda é a que está aberta: some depois que ela fecha
    await Process.start('/bin/sh', ['-c', 'sleep 10; rm -rf "\$1"', 'sh', aside],
        mode: ProcessStartMode.detached);
    await Process.start(
        'open', ['-n', bundle, if (args.isNotEmpty) ...['--args', ...args]],
        mode: ProcessStartMode.detached);
  }

  Future<void> _installWindows(File zip, List<String> args) async {
    final dir = p.dirname(_executable);
    await _requireWritable(dir);
    final script = File(p.join(zip.parent.path, 'atualizar.ps1'));
    await script.writeAsString(windowsUpdateScript(
      processId: pid,
      zip: zip.path,
      installDir: dir,
      executable: _executable,
      workDir: zip.parent.path,
      args: args,
    ));
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ],
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> _installLinux(File deb, List<String> args) async {
    // só o .deb sabe se atualizar; quem roda de outra pasta baixa na página
    if (!_executable.startsWith('/usr/lib/video-toolkit/')) {
      throw UpdateException('Instalação fora do pacote .deb.');
    }
    final result =
        await Process.run('pkexec', ['apt-get', 'install', '-y', deb.path]);
    if (result.exitCode != 0) {
      throw UpdateException(result.exitCode == 126
          ? 'A instalação precisa da senha de administrador.'
          : 'O apt não instalou a versão nova.');
    }
    await Process.start(_executable, args, mode: ProcessStartMode.detached);
  }

  Future<void> _requireWritable(String dir) async {
    final probe = File(p.join(dir, '.video-toolkit-update-probe'));
    try {
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException {
      throw UpdateException('Sem permissão pra trocar o app em $dir.');
    }
  }

  Future<String> _getText(Uri url, {String? accept}) async {
    final response = await _get(url, accept: accept);
    return response.transform(utf8.decoder).join();
  }

  Future<HttpClientResponse> _get(Uri url, {String? accept}) async {
    final request = await _client.getUrl(url).timeout(_timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'video-toolkit-updater');
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
    final response = await request.close().timeout(_timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw UpdateException('O servidor respondeu ${response.statusCode}.');
    }
    return response;
  }

  static const _timeout = Duration(seconds: 20);
  static const _stall = Duration(seconds: 30);

  static Future<void> _run(String command, List<String> args) async {
    final result = await Process.run(command, args);
    if (result.exitCode != 0) {
      throw UpdateException('$command falhou: ${result.stderr}'.trim());
    }
  }
}

/// Abre [url] no navegador do sistema.
Future<void> openInBrowser(Uri url) async {
  final (command, args) = switch (Platform.operatingSystem) {
    'macos' => ('open', [url.toString()]),
    'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url.toString()]),
    _ => ('xdg-open', [url.toString()]),
  };
  try {
    await Process.start(command, args, mode: ProcessStartMode.detached);
  } on ProcessException {
    // sem navegador configurado: o endereço continua escrito na tela
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
