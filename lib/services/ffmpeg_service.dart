import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/program.dart';
import '../models/tracks.dart';
import 'subtitle_retime.dart';

class FfmpegRunResult {
  FfmpegRunResult({required this.exitCode, required this.stderr});

  final int exitCode;
  final String stderr;

  bool get success => exitCode == 0;

  /// Last lines of stderr, usually where ffmpeg puts the actual error.
  String get errorTail {
    final lines =
        stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.skip(lines.length > 12 ? lines.length - 12 : 0).join('\n');
  }
}

/// Everything needed to emit one audio lane into the output.
class _AudioLaneDesc {
  _AudioLaneDesc({
    required this.segments,
    required this.ownPath,
    required this.ownTypeIndex,
    required this.ownDuration,
    required this.channelLayout,
    required this.codec,
    required this.title,
    required this.language,
    required this.displayName,
    required this.merge,
  });

  final List<AudioSegment> segments;
  final String ownPath;
  final int ownTypeIndex;
  final double ownDuration;
  final String? channelLayout;
  final String codec;
  final String title;
  final String? language;
  final String displayName;
  final bool? merge;

  bool get merges =>
      merge ??
      audioLaneIsFragmentary(
        segments: segments,
        ownPath: ownPath,
        ownTypeIndex: ownTypeIndex,
        durationSeconds: ownDuration,
      );
}

/// Os dois caminhos apontam pro mesmo arquivo (mesmo escrito diferente:
/// APFS ignora maiúsculas, /tmp é link).
Future<bool> isSameFile(String a, String b) async {
  if (p.equals(p.normalize(a), p.normalize(b))) return true;
  try {
    if (!await File(a).exists() || !await File(b).exists()) return false;
    return await FileSystemEntity.identical(a, b);
  } on FileSystemException {
    return false;
  }
}

/// Como sai a imagem ao salvar.
enum VideoFormat {
  /// Copia sem recodificar; só dá quando o vídeo não foi cortado.
  keep,

  /// O menor arquivo pra mesma qualidade (medido: metade do original).
  av1,

  /// Quase o mesmo tamanho do AV1, toca em mais aparelhos, bem mais lento.
  hevc,
}

/// Um vídeo pronto pra ser inserido no programa.
class InsertableVideo {
  InsertableVideo({required this.clip, required this.audioDuration});

  final VideoClip clip;

  /// 0 quando o arquivo não tem áudio.
  final double audioDuration;
}

class SaveArgsResult {
  SaveArgsResult({
    required this.args,
    required this.warnings,
    required this.hasStreams,
  });

  /// Full ffmpeg argument list; the output path is the last element.
  final List<String> args;

  /// Human-readable issues the user should confirm before saving.
  final List<String> warnings;

  /// False when every track was removed — nothing would be written.
  final bool hasStreams;
}

class FfmpegService {
  String? ffmpegPath;
  String? ffprobePath;

  bool get available => ffmpegPath != null && ffprobePath != null;

  /// GUI apps often don't inherit the shell PATH, so look in the usual
  /// install locations directly before falling back to which/where.
  Future<bool> locate() async {
    ffmpegPath = await _find('ffmpeg');
    ffprobePath = await _find('ffprobe');
    return available;
  }

  static List<String> get _searchDirs => Platform.isWindows
      ? [r'C:\ffmpeg\bin', r'C:\Program Files\ffmpeg\bin']
      : ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];

  Future<String?> _find(String name) async {
    final executable = Platform.isWindows ? '$name.exe' : name;
    for (final dir in _searchDirs) {
      final candidate = p.join(dir, executable);
      if (await File(candidate).exists()) return candidate;
    }
    try {
      final result = await Process.run(
          Platform.isWindows ? 'where' : 'which', [name]);
      final out = (result.stdout as String).trim().split('\n').first.trim();
      if (result.exitCode == 0 && out.isNotEmpty) return out;
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------- probing

  Future<MediaFileInfo> probe(String path) async {
    final json = await _probeJson(path);
    final format = json['format'] as Map<String, dynamic>? ?? {};
    final streams = (json['streams'] as List? ?? []).cast<Map<String, dynamic>>();

    final formatDuration =
        double.tryParse(format['duration'] as String? ?? '') ?? 0;
    final tracks = <MediaTrack>[];
    final typeCounters = <TrackType, int>{};

    for (final stream in streams) {
      final type = _trackType(stream['codec_type'] as String?);
      if (type == null) continue;
      final typeIndex = typeCounters.update(type, (v) => v + 1,
          ifAbsent: () => 0);
      final track = _toTrack(stream, type, typeIndex, formatDuration);
      if (type == TrackType.audio) {
        track.segments.add(AudioSegment(
          source: AudioSource(path: path, audioTypeIndex: typeIndex),
          sourceStart: 0,
          sourceEnd: track.durationSeconds,
          timelineStart: 0,
        ));
      }
      if (type == TrackType.video &&
          !tracks.any((t) => t.clips.isNotEmpty)) {
        final clip =
            _clipOf(stream, path, typeIndex, track.durationSeconds);
        if (clip != null) track.clips.add(clip);
      }
      tracks.add(track);
    }

    return MediaFileInfo(
      path: path,
      formatName: format['format_name'] as String? ?? '',
      durationSeconds: formatDuration,
      sizeBytes: int.tryParse(format['size'] as String? ?? '') ?? 0,
      tracks: tracks,
    );
  }

  /// Probes an external audio/subtitle file; returns null when the file
  /// has no stream of the expected type.
  Future<ExternalTrack?> probeExternal(String path, TrackType expected) async {
    final json = await _probeJson(path);
    final format = json['format'] as Map<String, dynamic>? ?? {};
    final streams = (json['streams'] as List? ?? []).cast<Map<String, dynamic>>();
    final formatDuration =
        double.tryParse(format['duration'] as String? ?? '') ?? 0;

    for (final stream in streams) {
      if (_trackType(stream['codec_type'] as String?) != expected) continue;
      final probed = _toTrack(stream, expected, 0, formatDuration);
      final track = ExternalTrack(
        path: path,
        type: expected,
        codec: probed.codec,
        details: probed.details,
        durationSeconds: probed.durationSeconds,
        channelLayout: probed.channelLayout,
        title: probed.originalTitle.isNotEmpty
            ? probed.originalTitle
            : p.basenameWithoutExtension(path),
        language: probed.language,
      );
      if (expected == TrackType.audio) {
        track.segments.add(AudioSegment(
          source: AudioSource(path: path, audioTypeIndex: 0),
          sourceStart: 0,
          sourceEnd: track.durationSeconds,
          timelineStart: 0,
        ));
      }
      return track;
    }
    return null;
  }

  /// Lê um vídeo pra inserir no programa; null quando não tem imagem.
  Future<InsertableVideo?> probeVideoClip(String path) async {
    final json = await _probeJson(path);
    final format = json['format'] as Map<String, dynamic>? ?? {};
    final streams = (json['streams'] as List? ?? []).cast<Map<String, dynamic>>();
    final formatDuration =
        double.tryParse(format['duration'] as String? ?? '') ?? 0;

    VideoClip? clip;
    var videoIndex = -1;
    var audioDuration = 0.0;
    for (final stream in streams) {
      final type = _trackType(stream['codec_type'] as String?);
      final tags = (stream['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      final duration = _streamDuration(stream, tags, formatDuration);
      if (type == TrackType.video) {
        videoIndex++;
        clip ??= _clipOf(stream, path, videoIndex, duration);
      } else if (type == TrackType.audio && audioDuration == 0) {
        audioDuration = duration;
      }
    }
    if (clip == null) return null;
    return InsertableVideo(clip: clip, audioDuration: audioDuration);
  }

  // capa de MP4 (attached_pic) também é stream de vídeo, mas não é o filme
  VideoClip? _clipOf(Map<String, dynamic> stream, String path, int typeIndex,
      double duration) {
    final disposition =
        (stream['disposition'] as Map?)?.cast<String, dynamic>() ?? {};
    final width = stream['width'] as int?, height = stream['height'] as int?;
    if (disposition['attached_pic'] == 1 ||
        width == null ||
        height == null ||
        duration <= 0) {
      return null;
    }
    final (sarNum, sarDen) = _parseRatio(stream['sample_aspect_ratio'] as String?);
    final rate = [stream['avg_frame_rate'], stream['r_frame_rate']]
            .whereType<String>()
            .firstWhere((r) => (_parseFps(r) ?? 0) > 0, orElse: () => '') ;
    return VideoClip(
      path: path,
      streamTypeIndex: typeIndex,
      width: width,
      height: height,
      rate: rate.isEmpty ? '30' : rate,
      sarNum: sarNum,
      sarDen: sarDen,
      sourceStart: 0,
      sourceEnd: duration,
      timelineStart: 0,
    );
  }

  (int, int) _parseRatio(String? ratio) {
    final parts = (ratio ?? '').split(':');
    final num = parts.isNotEmpty ? int.tryParse(parts.first) : null;
    final den = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (num == null || den == null || num <= 0 || den <= 0) return (1, 1);
    return (num, den);
  }

  Future<Map<String, dynamic>> _probeJson(String path) async {
    final result = await Process.run(ffprobePath!, [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_streams',
      '-show_format',
      path,
    ]);
    if (result.exitCode != 0) {
      throw Exception('ffprobe falhou ao ler o arquivo:\n${result.stderr}');
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }

  TrackType? _trackType(String? codecType) => switch (codecType) {
        'video' => TrackType.video,
        'audio' => TrackType.audio,
        'subtitle' => TrackType.subtitle,
        _ => null,
      };

  MediaTrack _toTrack(Map<String, dynamic> stream, TrackType type,
      int typeIndex, double fallbackDuration) {
    final tags = (stream['tags'] as Map?)?.cast<String, dynamic>() ?? {};
    final disposition =
        (stream['disposition'] as Map?)?.cast<String, dynamic>() ?? {};

    final details = <String>[];
    String? channelLayout;
    if (type == TrackType.video) {
      final w = stream['width'], h = stream['height'];
      if (w != null && h != null) details.add('${w}x$h');
      final fps = _parseFps(stream['avg_frame_rate'] as String?);
      if (fps != null) details.add('${fps.toStringAsFixed(fps % 1 == 0 ? 0 : 3)} fps');
    } else if (type == TrackType.audio) {
      final layout = stream['channel_layout'] as String?;
      final channels = stream['channels'] as int?;
      channelLayout = layout ??
          switch (channels) {
            1 => 'mono',
            2 => 'stereo',
            6 => '5.1',
            8 => '7.1',
            _ => null,
          };
      if (layout != null) {
        details.add(layout);
      } else if (channels != null) {
        details.add('$channels canais');
      }
      final rate = int.tryParse(stream['sample_rate'] as String? ?? '');
      if (rate != null) details.add('${(rate / 1000).toStringAsFixed(1)} kHz');
      final bitrate = int.tryParse(stream['bit_rate'] as String? ?? '');
      if (bitrate != null) details.add('${(bitrate / 1000).round()} kb/s');
    }

    return MediaTrack(
      streamIndex: stream['index'] as int,
      type: type,
      typeIndex: typeIndex,
      codec: (stream['codec_name'] as String? ?? '?').toUpperCase(),
      details: details.join(' · '),
      // MP4 exposes the track name under "name", MKV under "title".
      originalTitle:
          (tags['title'] as String?) ?? (tags['name'] as String?) ?? '',
      language: switch (tags['language'] as String?) {
        null || 'und' => null,
        final lang => lang,
      },
      channelLayout: channelLayout,
      durationSeconds: _streamDuration(stream, tags, fallbackDuration),
      isDefault: disposition['default'] == 1,
    );
  }

  /// Stream duration: plain `duration` field (mp4), the Matroska
  /// `DURATION` tag ("HH:MM:SS.nnnnnnnnn"), or the container duration.
  double _streamDuration(
      Map<String, dynamic> stream, Map<String, dynamic> tags, double fallback) {
    final plain = double.tryParse(stream['duration'] as String? ?? '');
    if (plain != null && plain > 0) return plain;

    final tag = (tags['DURATION'] ?? tags['DURATION-eng']) as String?;
    if (tag != null) {
      final match =
          RegExp(r'^(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(tag.trim());
      if (match != null) {
        return int.parse(match.group(1)!) * 3600 +
            int.parse(match.group(2)!) * 60 +
            double.parse(match.group(3)!);
      }
    }
    return fallback;
  }

  double? _parseFps(String? rate) {
    if (rate == null || !rate.contains('/')) return null;
    final parts = rate.split('/');
    final num = double.tryParse(parts[0]), den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0 || num == 0) return null;
    return num / den;
  }

  // ---------------------------------------------------------------- export

  /// Container extension that can hold the codec with `-c copy`.
  static String audioExportExtension(String codec) {
    final c = codec.toLowerCase();
    if (c.startsWith('pcm')) return 'wav';
    return switch (c) {
      'aac' => 'm4a',
      'mp3' => 'mp3',
      'ac3' => 'ac3',
      'eac3' => 'eac3',
      'flac' => 'flac',
      'opus' => 'opus',
      'vorbis' => 'ogg',
      _ => 'mka',
    };
  }

  Future<FfmpegRunResult> exportAudioTrack({
    required String sourcePath,
    required int audioTypeIndex,
    required String outputPath,
  }) {
    return _run([
      '-y',
      '-i', sourcePath,
      '-map', '0:a:$audioTypeIndex',
      '-vn',
      '-c', 'copy',
      outputPath,
    ]);
  }

  // ---------------------------------------------------------------- saving

  /// Audio codecs that can be copied into MP4 without transcoding.
  static const _mp4AudioCodecs = {'aac', 'mp3', 'ac3', 'eac3', 'alac'};

  /// Image-based subtitle codecs — impossible to convert to mov_text.
  static const _bitmapSubtitleCodecs = {
    'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub',
  };

  /// Subtitle codecs Matroska accepts as-is (bitmap or text).
  static const _mkvSubtitleCodecs = {
    'subrip', 'srt', 'ass', 'ssa', 'webvtt',
    ..._bitmapSubtitleCodecs,
  };

  /// Áudio sem perda: vale encolher quando o arquivo está sendo compactado.
  static const _losslessAudioCodecs = {
    'flac', 'alac', 'truehd', 'mlp', 'wavpack', 'tta', 'ape',
  };

  static bool _isLossless(String codec) {
    final c = codec.toLowerCase();
    return _losslessAudioCodecs.contains(c) || c.startsWith('pcm_');
  }

  static bool _isBitmapSubtitle(String codec) =>
      _bitmapSubtitleCodecs.contains(codec.toLowerCase());

  static String _s3(double v) => v.toStringAsFixed(3);

  static String formatName(VideoFormat format) => switch (format) {
        VideoFormat.keep => 'original',
        VideoFormat.av1 => 'AV1',
        VideoFormat.hevc => 'H.265',
      };

  // ajustes medidos num episódio de anime 1080p: metade do tamanho com
  // VMAF ~96,5 (praticamente igual ao original)
  static List<String> _videoEncoder(VideoFormat format, int index, bool mp4) =>
      switch (format) {
        VideoFormat.keep => const [],
        VideoFormat.av1 => [
            '-c:v:$index', 'libsvtav1',
            '-preset:v:$index', '8',
            '-crf:v:$index', '30',
            '-pix_fmt:v:$index', 'yuv420p10le',
          ],
        VideoFormat.hevc => [
            '-c:v:$index', 'libx265',
            '-preset:v:$index', 'fast',
            '-crf:v:$index', '21',
            '-pix_fmt:v:$index', 'yuv420p10le',
            '-x265-params:v:$index', 'log-level=error',
            if (mp4) ...['-tag:v:$index', 'hvc1'],
          ],
      };

  /// Encaixa o trecho inserido no quadro do programa (mantém a proporção, com
  /// faixas pretas); null quando já tem o mesmo formato.
  static String? _fitFilter(VideoClip clip, VideoClip frame) {
    if (clip.width == frame.width &&
        clip.height == frame.height &&
        (clip.sar - frame.sar).abs() < 1e-6) {
      return null;
    }
    int even(double v) => (v / 2).round() * 2;
    final clipAspect = clip.width * clip.sar / clip.height;
    final frameAspect = frame.width * frame.sar / frame.height;
    final int w, h;
    if (clipAspect >= frameAspect) {
      w = frame.width;
      h = math.min(frame.height, even(frame.width * frame.sar / clipAspect));
    } else {
      h = frame.height;
      w = math.min(frame.width, even(frame.height * clipAspect / frame.sar));
    }
    return 'scale=$w:$h,pad=${frame.width}:${frame.height}'
        ':${(frame.width - w) ~/ 2}:${(frame.height - h) ~/ 2}';
  }

  /// Legendas cortadas pelo programa: as falas vão pra um arquivo novo antes
  /// de salvar. Legenda de imagem não dá.
  static List<Object> subtitlesToRetime(
          MediaFileInfo source, List<ExternalTrack> added) =>
      [
        ...source.tracks.where((t) =>
            t.type == TrackType.subtitle &&
            !t.removed &&
            !subtitleIsWhole(t.pieces) &&
            !_isBitmapSubtitle(t.codec)),
        ...added.where((t) =>
            t.type == TrackType.subtitle &&
            !subtitleIsWhole(t.pieces) &&
            !_isBitmapSubtitle(t.codec)),
      ];

  /// Builds the full ffmpeg argument list for [save]. Pure — no I/O — so
  /// it can be unit-tested. The output path is always the last argument.
  SaveArgsResult buildSaveArgs({
    required MediaFileInfo source,
    required List<ExternalTrack> added,
    required String outputPath,
    VideoFormat videoFormat = VideoFormat.keep,
    Map<Object, String> subtitleFiles = const {},
  }) {
    final isMp4Output = p.extension(outputPath).toLowerCase() == '.mp4';
    final warnings = <String>[];
    final mainVideo = source.mainVideo;
    final edited = !programUntouched(source);
    // cortar o vídeo exige recodificar: corte exato fora do keyframe
    final format = edited && videoFormat == VideoFormat.keep
        ? VideoFormat.av1
        : videoFormat;
    final compact = format != VideoFormat.keep;
    if (compact && mainVideo != null) {
      warnings.add('O vídeo será recodificado em ${formatName(format)} — '
          'salvar pode levar alguns minutos.');
    }
    var compactedAudio = false;

    // ---- input registry: one entry per unique (flags, path) pair.
    final inputArgs = <String>[];
    final inputKeys = <String>[];
    int inputFor(String path, {List<String> flags = const []}) {
      final key = '${flags.join('\u0000')}|$path';
      final existing = inputKeys.indexOf(key);
      if (existing != -1) return existing;
      inputKeys.add(key);
      inputArgs.addAll([...flags, '-i', path]);
      return inputKeys.length - 1;
    }

    inputFor(source.path); // input 0: the plain source file

    // Positive shift delays the input (-itsoffset); negative shift skips
    // its beginning (-ss). Used for subtitles and single-piece audio.
    List<String> offsetFlags(double offset) => offset > 0
        ? ['-itsoffset', _s3(offset)]
        : ['-ss', _s3(-offset)];

    final mapArgs = <String>[];
    final metaArgs = <String>[];
    final codecArgs = <String>[];
    final filterChains = <String>[];
    var outIndex = 0;
    var outVideo = 0;
    var outAudio = 0;
    var outSub = 0;
    var laneCounter = 0;

    void addTitle(String title) {
      metaArgs.addAll(['-metadata:s:$outIndex', 'title=$title']);
    }

    void addLanguage(String? language) {
      if (language != null && language.isNotEmpty) {
        metaArgs.addAll(['-metadata:s:$outIndex', 'language=$language']);
      }
    }

    // One output audio stream per lane. Untouched lanes are stream-copied;
    // split/trimmed/merged lanes go through a filter graph and are
    // re-encoded to AAC.
    void addAudioLane({
      required List<AudioSegment> segments,
      required String ownPath,
      required int ownTypeIndex,
      required double ownDuration,
      required String? channelLayout,
      required String codec,
      required String title,
      required String? language,
    }) {
      if (segments.isEmpty) return;

      var passthroughFlags = const <String>[];
      var isPassthrough = false;
      if (segments.length == 1) {
        final s = segments.first;
        final own = s.source.path == ownPath &&
            s.source.audioTypeIndex == ownTypeIndex;
        final fullEnd = s.sourceEnd >= ownDuration - 0.05;
        final zeroStart = s.sourceStart.abs() < 0.005;
        final zeroTimeline = s.timelineStart.abs() < 0.005;
        if (own && fullEnd && zeroStart && zeroTimeline) {
          isPassthrough = true;
        } else if (own && fullEnd && zeroStart && s.timelineStart > 0) {
          isPassthrough = true;
          passthroughFlags = offsetFlags(s.timelineStart);
        } else if (own && fullEnd && s.sourceStart > 0 && zeroTimeline) {
          isPassthrough = true;
          passthroughFlags = offsetFlags(-s.sourceStart);
        }
      }

      if (isPassthrough) {
        final inputIndex = inputFor(ownPath, flags: passthroughFlags);
        mapArgs.addAll(['-map', '$inputIndex:a:$ownTypeIndex']);
        final shrink = compact && _isLossless(codec);
        if (shrink ||
            (isMp4Output && !_mp4AudioCodecs.contains(codec.toLowerCase()))) {
          codecArgs.addAll(['-c:a:$outAudio', 'aac', '-b:a:$outAudio', '256k']);
          if (shrink) compactedAudio = true;
        }
      } else {
        final ordered = [...segments]
          ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
        final labels = <String>[];
        for (var k = 0; k < ordered.length; k++) {
          final seg = ordered[k];
          final inputIndex = inputFor(seg.source.path);
          final chain = StringBuffer(
              '[$inputIndex:a:${seg.source.audioTypeIndex}]'
              'atrim=start=${_s3(seg.sourceStart)}:end=${_s3(seg.sourceEnd)},'
              'asetpts=PTS-STARTPTS,aresample=48000');
          if (channelLayout != null) {
            chain.write(',aformat=channel_layouts=$channelLayout');
          }
          final delayMs = (seg.timelineStart * 1000).round();
          if (delayMs > 0) chain.write(',adelay=$delayMs:all=1');
          final label = 'l${laneCounter}s$k';
          chain.write('[$label]');
          filterChains.add(chain.toString());
          labels.add(label);
        }
        final laneLabel = 'lane$laneCounter';
        // FFmpeg 9: amix cujo primeiro trecho começa atrasado (adelay) sai com
        // timestamps inválidos e o arquivo fica com duração "infinita"
        const retime = 'asetpts=N/SR/TB';
        if (labels.length == 1) {
          filterChains.add('[${labels.single}]$retime[$laneLabel]');
        } else {
          filterChains.add(
              '${labels.map((l) => '[$l]').join()}amix=inputs=${labels.length}'
              ':duration=longest:normalize=0,$retime[$laneLabel]');
        }
        mapArgs.addAll(['-map', '[$laneLabel]']);
        codecArgs.addAll(['-c:a:$outAudio', 'aac', '-b:a:$outAudio', '256k']);
        laneCounter++;
      }

      addTitle(title);
      addLanguage(language);
      outAudio++;
      outIndex++;
    }

    // MP4 only carries mov_text; bitmap subtitles cannot be converted to
    // text and must be skipped (a single bad stream aborts the whole save).
    // MKV copies bitmap and common text codecs; anything else becomes SRT.
    void addSubtitleCodecOverride(String codec) {
      final c = codec.toLowerCase();
      if (isMp4Output) {
        if (c != 'mov_text') codecArgs.addAll(['-c:s:$outSub', 'mov_text']);
      } else if (!_mkvSubtitleCodecs.contains(c)) {
        codecArgs.addAll(['-c:s:$outSub', 'srt']);
      }
    }

    bool skipSubtitle(String codec, String title) {
      if (isMp4Output && _bitmapSubtitleCodecs.contains(codec.toLowerCase())) {
        warnings.add('A legenda "$title" (${codec.toUpperCase()}) é de imagem '
            'e não pode ser convertida para MP4 — será descartada.');
        return true;
      }
      return false;
    }

    // ---- audio auto-merge: lanes that were cut apart (fragmentary) are
    // combined into a single output track, mixed at their timeline
    // positions. Whole lanes — untouched or merely delayed — stay separate.
    final laneDescs = <_AudioLaneDesc>[
      for (final track
          in source.tracks.where((t) => t.type == TrackType.audio && !t.removed))
        _AudioLaneDesc(
          segments: track.segments,
          ownPath: source.path,
          ownTypeIndex: track.typeIndex,
          ownDuration: track.durationSeconds,
          channelLayout: track.channelLayout,
          codec: track.codec,
          title: track.title,
          language: track.language,
          displayName: track.title.isNotEmpty
              ? track.title
              : 'Áudio ${track.typeIndex + 1}',
          merge: track.merge,
        ),
      for (final track in added.where((t) => t.type == TrackType.audio))
        _AudioLaneDesc(
          segments: track.segments,
          ownPath: track.path,
          ownTypeIndex: 0,
          ownDuration: track.durationSeconds,
          channelLayout: track.channelLayout,
          codec: track.codec,
          title: track.title,
          language: track.language,
          displayName: track.title,
          merge: track.merge,
        ),
    ];

    final merging = laneDescs.where((d) => d.merges).toList();
    final autoMerge = merging.length >= 2;
    var mergedSegments = const <AudioSegment>[];
    if (autoMerge) {
      mergedSegments = merging.expand((d) => d.segments).toList()
        ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
      warnings.add('As faixas '
          '${merging.map((d) => '"${d.displayName}"').join(', ')} serão '
          'mescladas em uma única faixa de áudio, na posição em que estão na '
          'linha do tempo.');
      for (var i = 1; i < mergedSegments.length; i++) {
        if (mergedSegments[i - 1].timelineEnd >
            mergedSegments[i].timelineStart + 0.005) {
          warnings.add('Alguns trechos mesclados se sobrepõem e serão '
              'misturados (tocam ao mesmo tempo).');
          break;
        }
      }
    }

    var laneCursor = 0;
    void emitNextAudioLane() {
      final desc = laneDescs[laneCursor++];
      if (autoMerge && desc.merges) {
        // The merged track takes the slot of the first merging lane;
        // the others contribute their segments and emit nothing.
        if (!identical(desc, merging.first)) return;
        addAudioLane(
          segments: mergedSegments,
          ownPath: desc.ownPath,
          ownTypeIndex: desc.ownTypeIndex,
          ownDuration: desc.ownDuration,
          channelLayout: desc.channelLayout,
          codec: desc.codec,
          title: desc.title,
          language: desc.language,
        );
        return;
      }
      addAudioLane(
        segments: desc.segments,
        ownPath: desc.ownPath,
        ownTypeIndex: desc.ownTypeIndex,
        ownDuration: desc.ownDuration,
        channelLayout: desc.channelLayout,
        codec: desc.codec,
        title: desc.title,
        language: desc.language,
      );
    }

    // Programa editado: cada trecho vira uma entrada com busca própria (-ss)
    // e corte exato no filtro; tudo é encaixado no quadro do vídeo original.
    String programLabel(List<VideoClip> clips) {
      final ordered = [...clips]
        ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
      final frame = ordered.firstWhere((c) => c.path == source.path,
          orElse: () => ordered.first);
      final labels = <String>[];
      for (var k = 0; k < ordered.length; k++) {
        final clip = ordered[k];
        final input = inputFor(clip.path, flags: ['-ss', _s3(clip.sourceStart)]);
        final fit = _fitFilter(clip, frame);
        filterChains.add('[$input:v:${clip.streamTypeIndex}]'
            'trim=duration=${_s3(clip.duration)},setpts=PTS-STARTPTS'
            '${fit == null ? '' : ',$fit'}'
            ',setsar=${frame.sarNum}/${frame.sarDen},fps=${frame.rate}[pv$k]');
        labels.add('pv$k');
      }
      filterChains.add('${labels.map((l) => '[$l]').join()}'
          'concat=n=${labels.length}:v=1:a=0[program]');
      return 'program';
    }

    // legenda cortada pelo programa vem do arquivo reescrito
    bool addRetimedSubtitle(Object lane, String codec, String title,
        String? language, String name) {
      if (subtitleIsWhole(switch (lane) {
        MediaTrack(:final pieces) => pieces,
        ExternalTrack(:final pieces) => pieces,
        _ => const <SubtitlePiece>[],
      })) {
        return false;
      }
      final file = subtitleFiles[lane];
      if (file == null) {
        warnings.add('A legenda "$name" (${codec.toUpperCase()}) não pode ser '
            'cortada junto com o vídeo — será descartada.');
        return true;
      }
      final input = inputFor(file);
      mapArgs.addAll(['-map', '$input:s:0']);
      addSubtitleCodecOverride(
          codec.toLowerCase() == 'ass' || codec.toLowerCase() == 'ssa'
              ? 'ass'
              : 'subrip');
      addTitle(title);
      addLanguage(language);
      outSub++;
      outIndex++;
      return true;
    }

    for (final track in source.tracks.where((t) => !t.removed)) {
      switch (track.type) {
        case TrackType.video:
          final isMain = identical(track, mainVideo);
          if (isMain && edited) {
            mapArgs.addAll(['-map', '[${programLabel(track.clips)}]']);
          } else {
            mapArgs.addAll(['-map', '0:${track.streamIndex}']);
          }
          if (isMain) {
            codecArgs.addAll(_videoEncoder(format, outVideo, isMp4Output));
          }
          addTitle(track.title);
          outVideo++;
          outIndex++;
        case TrackType.audio:
          emitNextAudioLane();
        case TrackType.subtitle:
          final name = track.title.isNotEmpty
              ? track.title
              : 'Legenda ${track.typeIndex + 1}';
          if (skipSubtitle(track.codec, name)) break;
          if (addRetimedSubtitle(
              track, track.codec, track.title, track.language, name)) {
            break;
          }
          var sourceInput = 0;
          if (track.offsetSeconds != 0) {
            sourceInput =
                inputFor(source.path, flags: offsetFlags(track.offsetSeconds));
          }
          mapArgs.addAll(['-map', '$sourceInput:${track.streamIndex}']);
          addSubtitleCodecOverride(track.codec);
          addTitle(track.title);
          outSub++;
          outIndex++;
      }
    }

    for (final _ in added.where((t) => t.type == TrackType.audio)) {
      emitNextAudioLane();
    }

    for (final track in added.where((t) => t.type == TrackType.subtitle)) {
      if (skipSubtitle(track.codec, track.title)) continue;
      if (addRetimedSubtitle(
          track, track.codec, track.title, track.language, track.title)) {
        continue;
      }
      final inputIndex = inputFor(track.path,
          flags: track.offsetSeconds != 0
              ? offsetFlags(track.offsetSeconds)
              : const []);
      mapArgs.addAll(['-map', '$inputIndex:s:0']);
      addSubtitleCodecOverride(track.codec);
      addTitle(track.title);
      addLanguage(track.language);
      outSub++;
      outIndex++;
    }

    final hasStreams = mapArgs.isNotEmpty;
    // Matroska keeps attachments (embedded fonts used by ASS subtitles);
    // MP4 has no equivalent.
    if (hasStreams && !isMp4Output) {
      mapArgs.addAll(['-map', '0:t?']);
    }
    if (compactedAudio) {
      warnings.add('O áudio sem perda (FLAC, PCM...) vira AAC 256 kb/s, '
          'bem menor e sem diferença audível.');
    }

    final args = [
      '-y',
      ...inputArgs,
      if (filterChains.isNotEmpty) ...[
        '-filter_complex',
        filterChains.join(';'),
      ],
      ...mapArgs,
      '-c', 'copy',
      ...codecArgs,
      '-map_metadata', '0',
      // capítulos do original apontariam pro lugar errado depois do corte
      if (edited) ...['-map_chapters', '-1'],
      ...metaArgs,
      if (isMp4Output) ...['-movflags', '+faststart'],
      outputPath,
    ];
    return SaveArgsResult(
        args: args, warnings: warnings, hasStreams: hasStreams);
  }

  /// Warnings the user should confirm before running [save] (e.g. subtitle
  /// tracks that will be dropped for the chosen container).
  List<String> saveWarnings({
    required MediaFileInfo source,
    required List<ExternalTrack> added,
    required String outputPath,
    VideoFormat videoFormat = VideoFormat.keep,
  }) =>
      buildSaveArgs(
        source: source,
        added: added,
        outputPath: outputPath,
        videoFormat: videoFormat,
        subtitleFiles: {
          for (final lane in subtitlesToRetime(source, added)) lane: '',
        },
      ).warnings;

  Future<FfmpegRunResult> save({
    required MediaFileInfo source,
    required List<ExternalTrack> added,
    required String outputPath,
    VideoFormat videoFormat = VideoFormat.keep,
    void Function(double progress)? onProgress,
  }) async {
    final workDir = await Directory.systemTemp.createTemp('vt-save-');
    try {
      final subtitleFiles = <Object, String>{};
      for (final lane in subtitlesToRetime(source, added)) {
        final retimed = await _retimeSubtitleFile(source, lane, workDir.path,
            subtitleFiles.length);
        if (!retimed.success) return retimed.result!;
        subtitleFiles[lane] = retimed.path!;
      }
      return await _render(
        source: source,
        added: added,
        outputPath: outputPath,
        videoFormat: videoFormat,
        subtitleFiles: subtitleFiles,
        onProgress: onProgress,
      );
    } finally {
      try {
        await workDir.delete(recursive: true);
      } on FileSystemException {
        // pasta temporária do sistema; o próprio sistema limpa depois
      }
    }
  }

  /// Extrai a legenda como texto, passa as falas pelos pedaços e grava.
  Future<({bool success, String? path, FfmpegRunResult? result})>
      _retimeSubtitleFile(MediaFileInfo source, Object lane, String dir,
          int n) async {
    final (path, map, codec, pieces, name) = switch (lane) {
      final MediaTrack t => (
          source.path,
          '0:${t.streamIndex}',
          t.codec,
          t.pieces,
          t.title.isNotEmpty ? t.title : 'Legenda ${t.typeIndex + 1}',
        ),
      final ExternalTrack t => (t.path, '0:s:0', t.codec, t.pieces, t.title),
      _ => throw ArgumentError(lane),
    };
    final ass = codec.toLowerCase() == 'ass' || codec.toLowerCase() == 'ssa';
    final extracted = p.join(dir, 'original_$n.${ass ? 'ass' : 'srt'}');
    final run = await _run(
        ['-y', '-i', path, '-map', map, '-c:s', ass ? 'ass' : 'srt', extracted]);
    if (!run.success) {
      return (
        success: false,
        path: null,
        result: FfmpegRunResult(
            exitCode: run.exitCode,
            stderr: 'Não foi possível cortar a legenda "$name":\n${run.stderr}'),
      );
    }
    final text = await File(extracted).readAsString();
    final retimed = p.join(dir, 'cortada_$n.${ass ? 'ass' : 'srt'}');
    await File(retimed).writeAsString(retimeSubtitle(
        text, ass ? SubtitleText.ass : SubtitleText.srt, pieces));
    return (success: true, path: retimed, result: null);
  }

  Future<FfmpegRunResult> _render({
    required MediaFileInfo source,
    required List<ExternalTrack> added,
    required String outputPath,
    required VideoFormat videoFormat,
    required Map<Object, String> subtitleFiles,
    void Function(double progress)? onProgress,
  }) async {
    final built = buildSaveArgs(
      source: source,
      added: added,
      outputPath: outputPath,
      videoFormat: videoFormat,
      subtitleFiles: subtitleFiles,
    );
    if (!built.hasStreams) {
      return FfmpegRunResult(
          exitCode: 1, stderr: 'Nenhuma faixa selecionada para salvar.');
    }

    // Always render to a hidden temp file in the target directory and move
    // it into place afterwards. This makes overwriting the source file safe
    // regardless of path spelling (case-insensitive APFS, /tmp symlinks...)
    // — ffmpeg must never open its own input for writing.
    final tempOutput = p.join(p.dirname(outputPath),
        '.${p.basenameWithoutExtension(outputPath)}.saving${p.extension(outputPath)}');
    final args = [...built.args]..last = tempOutput;

    final video = source.mainVideo;
    final result = await _run(
      args,
      onProgress: onProgress,
      totalDurationSeconds: video == null
          ? source.durationSeconds
          : programDuration(video.clips),
    );

    if (result.success) {
      try {
        await File(tempOutput).rename(outputPath);
        return result;
      } on FileSystemException catch (e) {
        await _deleteQuietly(tempOutput);
        return FfmpegRunResult(
            exitCode: -1,
            stderr: 'Não foi possível gravar ${p.basename(outputPath)}: '
                '${e.osError?.message ?? e.message}');
      }
    }
    await _deleteQuietly(tempOutput);
    return result;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // sobra um arquivo oculto .saving; não vale esconder o erro original
    }
  }

  Future<FfmpegRunResult> _run(
    List<String> args, {
    void Function(double progress)? onProgress,
    double totalDurationSeconds = 0,
  }) async {
    final fullArgs = [
      '-hide_banner',
      '-loglevel', 'error',
      ...args.sublist(0, args.length - 1),
      '-progress', 'pipe:1',
      '-nostats',
      args.last,
    ];

    final Process process;
    try {
      // SVT-AV1 escreve logs de info direto no stderr e enterraria o erro
      process = await Process.start(ffmpegPath!, fullArgs,
          environment: {'SVT_LOG': '1'});
    } on ProcessException catch (e) {
      return FfmpegRunResult(
          exitCode: -1, stderr: 'Não foi possível executar o FFmpeg: ${e.message}');
    }
    final stderrBuffer = StringBuffer();

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (onProgress == null || totalDurationSeconds <= 0) return;
      final match = RegExp(r'^out_time_us=(\d+)').firstMatch(line);
      if (match != null) {
        final seconds = int.parse(match.group(1)!) / 1e6;
        onProgress((seconds / totalDurationSeconds).clamp(0.0, 1.0));
      }
    });
    process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);

    final exitCode = await process.exitCode;
    return FfmpegRunResult(exitCode: exitCode, stderr: stderrBuffer.toString());
  }
}
