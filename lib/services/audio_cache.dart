import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import '../models/tracks.dart';
import 'ffmpeg_service.dart';

/// Blocos da forma de onda por segundo (5 ms cada).
const kWaveformBucketsPerSecond = 200.0;

/// Duração do silêncio que tapa os vãos da prévia.
const kSilenceSeconds = 600.0;

/// Duração do vídeo preto que tapa os vãos da imagem na prévia: vão mais
/// longo usa vários pedaços dele.
const kBlackSeconds = 10.0;

// o player busca pelo quadro: com quadro raro, cair no meio de um vão pula o
// som até o quadro seguinte
const _blackFrameRate = 25;

const _waveformSampleRate = 8000;
const _folderPrefix = 'vt-preview-';

typedef _Frame = ({int width, int height, int sarNum, int sarDen});

/// Pico do áudio (0..1) por bloco fixo de tempo: a forma de onda.
class Waveform {
  Waveform(this.peaks, {this.bucketsPerSecond = kWaveformBucketsPerSecond});

  /// Maior |amostra| de cada bloco, de 0 a 1.
  final Float32List peaks;
  final double bucketsPerSecond;

  /// Segundos cobertos.
  double get duration => peaks.length / bucketsPerSecond;

  /// Pico da faixa inteira: base pra normalizar o desenho.
  late final double maxPeak = peaks.fold(0.0, math.max);

  /// Maior pico dos blocos que tocam [from, to), em segundos da origem; 0
  /// fora dos dados. Com [to] <= [from], o bloco em [from]. Roda a cada
  /// coluna desenhada: não aloca nada.
  double peakBetween(double from, double to) {
    final count = peaks.length;
    final first = (from * bucketsPerSecond).clamp(0, count).floor();
    if (to <= from) return from >= 0 && first < count ? peaks[first] : 0;
    final end = (to * bucketsPerSecond).clamp(0, count).ceil();
    var peak = 0.0;
    for (var i = first; i < end; i++) {
      if (peaks[i] > peak) peak = peaks[i];
    }
    return peak;
  }
}

/// Junta pedaços de PCM s16le mono (como chegam do pipe, podendo partir no
/// meio de uma amostra) em picos por bloco.
class PeakBuilder {
  PeakBuilder({
    required int sampleRate,
    double bucketsPerSecond = kWaveformBucketsPerSecond,
  })  : assert(sampleRate > 0 && bucketsPerSecond > 0),
        _samplesPerBucket = sampleRate / bucketsPerSecond,
        _bucketEnd = (sampleRate / bucketsPerSecond).ceil();

  final double _samplesPerBucket;
  var _peaks = Float32List(1024);
  var _count = 0;
  var _samples = 0;
  int _bucketEnd;
  var _loudest = 0;
  int? _lowByte;

  void add(List<int> bytes) {
    var i = 0;
    final low = _lowByte;
    if (low != null && bytes.isNotEmpty) {
      _sample(low | (bytes[0] << 8));
      _lowByte = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      _sample(bytes[i] | (bytes[i + 1] << 8));
    }
    if (i < bytes.length) _lowByte = bytes[i];
  }

  /// Os picos, com o último bloco mesmo incompleto.
  Float32List finish() {
    if (_samples > (_count * _samplesPerBucket).ceil()) _closeBucket();
    return _peaks.sublist(0, _count);
  }

  void _sample(int raw) {
    final level = raw < 0x8000 ? raw : 0x10000 - raw;
    if (level > _loudest) _loudest = level;
    _samples++;
    while (_samples >= _bucketEnd) {
      _closeBucket();
    }
  }

  void _closeBucket() {
    if (_count == _peaks.length) {
      _peaks = Float32List(_count * 2)..setAll(0, _peaks);
    }
    _peaks[_count++] = math.min(_loudest / 32768, 1.0);
    _loudest = 0;
    _bucketEnd = ((_count + 1) * _samplesPerBucket).ceil();
  }
}

/// Áudio derivado dos arquivos em edição: cada faixa copiada sozinha (o
/// player da prévia só aceita uma faixa por arquivo num grupo de áudio), a
/// forma de onda dela pra linha do tempo e o que tapa os vãos da prévia: um
/// silêncio no som e um vídeo preto na imagem.
class AudioCache {
  AudioCache(this._ffmpeg);

  final FfmpegService _ffmpeg;

  /// Sobe quando uma cópia, uma forma de onda, o silêncio ou um vídeo preto
  /// fica pronto (ou falha).
  final ValueNotifier<int> revision = ValueNotifier(0);

  final _seen = <AudioSource>{};
  final _queued = <AudioSource>[];
  final _copies = <AudioSource, String>{};
  final _waveforms = <AudioSource, Waveform>{};
  final _failed = <AudioSource>{};
  final _running = <Process>{};
  Future<Directory?>? _folder;
  var _nextName = 0;
  var _silenceStarted = false;
  String? _silence;
  final _blackStarted = <_Frame>{};
  final _blacks = <_Frame, String>{};
  var _disposed = false;

  /// Começa o trabalho das faixas ainda não vistas. Faixas de um mesmo
  /// arquivo pedidas no mesmo frame saem numa execução só (um vídeo grande é
  /// lido uma vez); a forma de onda vem da cópia, assim que ela fica pronta.
  void prefetch(Iterable<AudioSource> sources) {
    if (_disposed) return;
    final idle = _queued.isEmpty;
    for (final source in sources) {
      if (_seen.add(source)) _queued.add(source);
    }
    if (idle && _queued.isNotEmpty) scheduleMicrotask(_startQueued);
  }

  /// A cópia só com essa faixa; null enquanto não fica pronta (e já pede).
  String? extracted(AudioSource source) {
    final copy = _copies[source];
    if (copy == null) prefetch([source]);
    return copy;
  }

  /// Null enquanto não fica pronta (e já pede).
  Waveform? waveform(AudioSource source) {
    final waveform = _waveforms[source];
    if (waveform == null) prefetch([source]);
    return waveform;
  }

  /// FLAC mudo, estéreo de 48 kHz, com [kSilenceSeconds]; null até ficar
  /// pronto (a primeira chamada começa).
  String? silence() {
    if (!_silenceStarted && !_disposed) {
      _silenceStarted = true;
      unawaited(_makeSilence());
    }
    return _silence;
  }

  /// Vídeo preto H.264 de [kBlackSeconds] a 25 quadros por segundo, com o
  /// tamanho de quadro (arredondado pra cima até par) e a proporção de pixel
  /// dados: trocar pra ele não muda o tamanho da imagem no player. Null até
  /// ficar pronto (a primeira chamada pra esse quadro começa; se falhar, não
  /// tenta de novo).
  String? blackVideo({
    required int width,
    required int height,
    required int sarNum,
    required int sarDen,
  }) {
    final frame = (
      width: width + width % 2,
      height: height + height % 2,
      sarNum: sarNum,
      sarDen: sarDen,
    );
    if (!_disposed && _blackStarted.add(frame)) {
      unawaited(_makeBlack(frame));
    }
    return _blacks[frame];
  }

  /// A cópia falhou: quem pediu segue sem ela em vez de esperar.
  bool failed(AudioSource source) => _failed.contains(source);

  /// Mata os FFmpeg em andamento, apaga a pasta temporária e encerra
  /// [revision]. Chamar de novo não faz nada.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    revision.dispose();
    _copies.clear();
    _waveforms.clear();
    _silence = null;
    _blacks.clear();
    final running = [..._running];
    for (final process in running) {
      process.kill(ProcessSignal.sigkill);
    }
    if (running.isNotEmpty) {
      // FFmpeg travado num disco de rede não pode segurar o fechamento
      await Future.wait(running.map((process) => process.exitCode))
          .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    }
    final folder = await _folder;
    if (folder != null) await _deleteQuietly(folder);
  }

  void _startQueued() {
    if (_disposed) return;
    final byFile = <String, List<AudioSource>>{};
    for (final source in _queued) {
      (byFile[source.path] ??= []).add(source);
    }
    _queued.clear();
    for (final streams in byFile.values) {
      unawaited(_copy(streams));
    }
  }

  Future<void> _copy(List<AudioSource> streams) async {
    final folder = await _workFolder();
    final copies = {
      if (folder != null)
        for (final source in streams)
          source: p.join(folder.path, '${_nextName++}.mka'),
    };
    final copied = folder != null &&
        await _run([
          '-y',
          '-i', streams.first.path,
          for (final MapEntry(key: source, value: copy) in copies.entries) ...[
            '-map', '0:a:${source.audioTypeIndex}',
            '-c', 'copy', '-vn', '-sn', '-dn',
            '-map_metadata', '-1', '-map_chapters', '-1',
            copy,
          ],
        ]);
    if (_disposed) return;
    if (copied) {
      _copies.addAll(copies);
      copies.forEach((source, copy) => unawaited(_measure(source, copy)));
    } else {
      _failed.addAll(streams);
    }
    revision.value++;
  }

  Future<void> _measure(AudioSource source, String copy) async {
    final peaks = PeakBuilder(sampleRate: _waveformSampleRate);
    // nos tempos da cópia, como o salvar corta: atraso inicial e vãos viram
    // silêncio em vez de puxar o som pra trás
    final measured = await _run(
      [
        '-copyts',
        '-i', copy,
        '-map', '0:a:0',
        '-af', 'aresample=first_pts=0',
        '-ac', '1',
        '-ar', '$_waveformSampleRate',
        '-f', 's16le',
        'pipe:1',
      ],
      onOutput: peaks.add,
    );
    if (_disposed) return;
    if (measured) _waveforms[source] = Waveform(peaks.finish());
    revision.value++;
  }

  Future<void> _makeSilence() async {
    final path = await _generate('silence.flac', [
      '-f', 'lavfi',
      '-i', 'anullsrc=r=48000:cl=stereo',
      '-t', '$kSilenceSeconds',
      '-c:a', 'flac',
    ]);
    if (_disposed) return;
    _silence = path;
    revision.value++;
  }

  Future<void> _makeBlack(_Frame frame) async {
    final path = await _generate('black-${_nextName++}.mkv', [
      '-f', 'lavfi',
      '-i', 'color=c=black:s=${frame.width}x${frame.height}:r=$_blackFrameRate',
      '-t', '$kBlackSeconds',
      '-vf', 'setsar=${frame.sarNum}/${frame.sarDen}',
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-tune', 'stillimage',
      '-pix_fmt', 'yuv420p',
    ]);
    if (_disposed) return;
    if (path != null) _blacks[frame] = path;
    revision.value++;
  }

  /// Grava [name] na pasta de trabalho com o FFmpeg; null se não deu.
  Future<String?> _generate(String name, List<String> args) async {
    final folder = await _workFolder();
    if (folder == null) return null;
    final path = p.join(folder.path, name);
    return await _run(['-y', ...args, path]) ? path : null;
  }

  Future<bool> _run(
    List<String> args, {
    void Function(List<int> bytes)? onOutput,
  }) async {
    final ffmpeg = _ffmpeg.ffmpegPath;
    if (ffmpeg == null || _disposed) return false;
    final Process process;
    try {
      process = await Process.start(
        ffmpeg,
        ['-hide_banner', '-loglevel', 'error', ...args],
        environment: {'SVT_LOG': '1'},
      );
    } on ProcessException {
      return false;
    }
    _running.add(process);
    if (_disposed) process.kill(ProcessSignal.sigkill);
    try {
      final (code, _, _) = await (
        process.exitCode,
        process.stdout.forEach(onOutput ?? (_) {}),
        process.stderr.drain<void>(),
      ).wait;
      return code == 0;
    } on ParallelWaitError {
      return false;
    } finally {
      _running.remove(process);
    }
  }

  Future<Directory?> _workFolder() async {
    if (_ffmpeg.ffmpegPath == null) return null;
    return _folder ??= _createFolder();
  }

  static Future<Directory?> _createFolder() async {
    try {
      final folder = await Directory.systemTemp.createTemp(_folderPrefix);
      unawaited(_sweepLeftovers(folder));
      return folder;
    } on FileSystemException {
      return null;
    }
  }

  // sobras de sessões que caíram; 12 h poupa a pasta de outra janela aberta
  static Future<void> _sweepLeftovers(Directory own) async {
    final limit = DateTime.now().subtract(const Duration(hours: 12));
    try {
      await for (final entry in own.parent.list(followLinks: false)) {
        if (entry is Directory &&
            entry.path != own.path &&
            p.basename(entry.path).startsWith(_folderPrefix) &&
            (await entry.stat()).modified.isBefore(limit)) {
          await _deleteQuietly(entry);
        }
      }
    } on FileSystemException {
      // sem listar a pasta temporária, a limpeza fica pra próxima sessão
    }
  }

  static Future<void> _deleteQuietly(Directory folder) async {
    try {
      await folder.delete(recursive: true);
    } on FileSystemException {
      // a próxima sessão tenta de novo
    }
  }
}
