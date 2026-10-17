import 'dart:convert';
import 'dart:math' as math;

import '../models/program.dart';
import '../models/tracks.dart';

/// Idioma da faixa de áudio do programa montado: com `alang` nele, o player
/// escolhe essa faixa sozinho ao carregar.
const kMonitorLanguage = 'zxx';

const _minLength = 1e-4;

/// Faixas de áudio na ordem em que saem ao salvar: as do arquivo (sem as
/// removidas) e depois as adicionadas.
List<Object> audioLanesInOrder(MediaFileInfo file, List<ExternalTrack> added) =>
    [
      ...file.tracks.where((t) => t.type == TrackType.audio && !t.removed),
      ...added.where((t) => t.type == TrackType.audio),
    ];

/// As faixas que tocam junto com [lane] no arquivo salvo: a mescla inteira
/// quando [lane] entra nela, senão só ela.
List<Object> audioOutputOf(
    Object lane, MediaFileInfo file, List<ExternalTrack> added) {
  final merging = audioLanesInOrder(file, added)
      .where((l) => audioLaneMerges(l, file.path))
      .toList();
  return merging.contains(lane) ? merging : [lane];
}

/// O que a prévia toca.
sealed class PreviewPlan {
  const PreviewPlan();
}

/// O próprio arquivo: nada que se ouve ou vê foi editado. [audioTrack] é o
/// id do áudio no mpv (os áudios do arquivo contados a partir de 1); null
/// toca sem som.
final class SourcePreview extends PreviewPlan {
  const SourcePreview(this.path, this.audioTrack);

  final String path;
  final int? audioTrack;

  @override
  bool operator ==(Object other) =>
      other is SourcePreview &&
      other.path == path &&
      other.audioTrack == audioTrack;

  @override
  int get hashCode => Object.hash(path, audioTrack);
}

/// O programa montado, como texto de um EDL do mpv. Sem [hasAudio], toca
/// sem som.
final class EdlPreview extends PreviewPlan {
  const EdlPreview(this.edl, {required this.hasAudio});

  final String edl;
  final bool hasAudio;

  @override
  bool operator ==(Object other) =>
      other is EdlPreview && other.edl == edl && other.hasAudio == hasAudio;

  @override
  int get hashCode => Object.hash(edl, hasAudio);
}

/// Ainda falta extrair áudio (ou o silêncio) pra montar a prévia. [missing]
/// vazio: só falta o silêncio.
final class PendingPreview extends PreviewPlan {
  const PendingPreview(this.missing);

  final Set<AudioSource> missing;

  @override
  bool operator ==(Object other) =>
      other is PendingPreview &&
      other.missing.length == missing.length &&
      other.missing.containsAll(missing);

  @override
  int get hashCode => Object.hashAllUnordered(missing);
}

/// O que a prévia toca ouvindo [monitor]: uma faixa de áudio ou, com null
/// (ou uma faixa que saiu), a que os players tocam do arquivo salvo. [audioFile] dá a
/// cópia de cada origem com só aquele áudio e [silenceFile] um silêncio de
/// [silenceLength] segundos; null enquanto ainda não existem.
PreviewPlan buildPreviewPlan({
  required MediaFileInfo file,
  required List<ExternalTrack> added,
  required Object? monitor,
  required String? Function(AudioSource source) audioFile,
  required String? silenceFile,
  double silenceLength = 600,
}) {
  if (silenceLength.isNaN || silenceLength < _minLength) {
    throw ArgumentError.value(
        silenceLength, 'silenceLength', 'must be at least $_minLength');
  }
  final output = _monitoredOutput(file, added, monitor);
  final clips = file.mainVideo?.clips;
  final spans = _audioSpans(
    output.expand(_segmentsOf).toList(),
    clips == null ? double.infinity : programDuration(clips),
  );
  final hasAudio = spans.isNotEmpty;
  if (programUntouched(file)) {
    if (!hasAudio) return SourcePreview(file.path, null);
    final lane = _untouchedLane(output, file.path);
    if (lane != null) return SourcePreview(file.path, lane.typeIndex + 1);
  }

  final lines = [
    '# mpv EDL v0',
    if (clips != null) ..._videoGroup(clips, file.path),
  ];
  if (hasAudio) {
    final missing = <AudioSource>{};
    var silenceMissing = false;
    final entries = <_Entry>[];
    for (final (:segment, :from, :to) in spans) {
      if (segment != null) {
        final copy = audioFile(segment.source);
        if (copy == null) {
          missing.add(segment.source);
        } else {
          _append(entries, copy,
              segment.sourceStart + (from - segment.timelineStart), to - from);
        }
      } else if (silenceFile == null) {
        silenceMissing = true;
      } else {
        for (var left = to - from; left >= _minLength; left -= silenceLength) {
          _append(entries, silenceFile, 0, math.min(left, silenceLength));
        }
      }
    }
    if (missing.isNotEmpty || silenceMissing) return PendingPreview(missing);
    lines.addAll([
      '!new_stream',
      '!no_chapters',
      '!track_meta,lang=$kMonitorLanguage',
      for (final entry in entries) _line(entry),
    ]);
  }
  return EdlPreview('${lines.join('\n')}\n', hasAudio: hasAudio);
}

List<Object> _monitoredOutput(
    MediaFileInfo file, List<ExternalTrack> added, Object? monitor) {
  final lanes = audioLanesInOrder(file, added);
  final lane = lanes.where((l) => identical(l, monitor)).firstOrNull ??
      lanes.whereType<MediaTrack>().where((t) => t.isDefault).firstOrNull ??
      lanes.firstOrNull;
  return lane == null ? const [] : audioOutputOf(lane, file, added);
}

List<AudioSegment> _segmentsOf(Object lane) => switch (lane) {
      MediaTrack(:final segments) => segments,
      ExternalTrack(:final segments) => segments,
      _ => const [],
    };

/// A faixa do arquivo como veio, quando só ela se ouve.
MediaTrack? _untouchedLane(List<Object> output, String sourcePath) {
  final lane = output.singleOrNull;
  if (lane is! MediaTrack || lane.segments.length != 1) return null;
  final s = lane.segments.single;
  final untouched = s.source ==
          AudioSource(path: sourcePath, audioTypeIndex: lane.typeIndex) &&
      s.sourceStart.abs() < 0.005 &&
      s.timelineStart.abs() < 0.005 &&
      s.sourceEnd >= lane.durationSeconds - 0.05;
  return untouched ? lane : null;
}

List<String> _videoGroup(List<VideoClip> clips, String sourcePath) {
  final ordered = [
    for (final clip in clips)
      if (clip.duration >= _minLength) clip,
  ]..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
  final entries = <_Entry>[];
  for (final clip in ordered) {
    _append(entries, clip.path, clip.sourceStart, clip.duration);
  }
  // o original dita as faixas do grupo: as legendas dele aparecem na prévia
  final layout = entries.where((e) => e.path == sourcePath).firstOrNull;
  return [
    '!no_chapters',
    for (final entry in entries)
      _line(entry, layout: identical(entry, layout)),
  ];
}

/// Pedaço da faixa ouvida; sem [segment] é silêncio.
typedef _Span = ({AudioSegment? segment, double from, double to});

/// O que se ouve de 0 até o último som antes de [end]. Onde trechos se
/// sobrepõem toca o que começou por último, e o anterior volta quando ele
/// acaba. Os vãos viram silêncio: vão sem som no grupo tira o mpv de
/// sincronia.
List<_Span> _audioSpans(List<AudioSegment> segments, double end) {
  final bounds = {
    0.0,
    if (end.isFinite) end,
    for (final s in segments) ...[s.timelineStart, s.timelineEnd],
  }.where((t) => t >= 0 && t <= end).toList()
    ..sort();
  final spans = <_Span>[];
  for (var i = 1; i < bounds.length; i++) {
    final from = bounds[i - 1], to = bounds[i];
    AudioSegment? playing;
    for (final s in segments) {
      if (s.timelineStart <= from &&
          s.timelineEnd >= to &&
          (playing == null || s.timelineStart >= playing.timelineStart)) {
        playing = s;
      }
    }
    if (spans.isNotEmpty && identical(spans.last.segment, playing)) {
      spans.last = (segment: playing, from: spans.last.from, to: to);
    } else {
      spans.add((segment: playing, from: from, to: to));
    }
  }
  spans.removeWhere((s) => s.to - s.from < _minLength);
  while (spans.isNotEmpty && spans.last.segment == null) {
    spans.removeLast();
  }
  return spans;
}

typedef _Entry = ({String path, double start, double length});

/// Trechos seguidos do mesmo arquivo viram um só: dividir sem mudar o que
/// toca não recarrega a prévia.
void _append(List<_Entry> entries, String path, double start, double length) {
  final last = entries.lastOrNull;
  if (last != null &&
      last.path == path &&
      (last.start + last.length - start).abs() < 1e-6) {
    entries.last = (path: path, start: last.start, length: last.length + length);
  } else {
    entries.add((path: path, start: start, length: length));
  }
}

// caminho com o tamanho em bytes na frente: aceita vírgula, '=' e acento
String _line(_Entry entry, {bool layout = false}) =>
    '%${utf8.encode(entry.path).length}%${entry.path},'
    '${entry.start.toStringAsFixed(6)},${entry.length.toStringAsFixed(6)}'
    '${layout ? ',layout=this' : ''}';
