import 'dart:math' as math;

import 'tracks.dart';

/// Tira [from, to) da linha do tempo: o que vinha depois anda pra trás.
void rippleDelete<T extends TimelinePiece>(
    List<T> pieces, double from, double to) {
  final length = to - from;
  if (length <= 0) return;
  final kept = <T>[];
  for (final piece in pieces) {
    final start = piece.timelineStart, end = piece.timelineEnd;
    if (end <= from) {
      kept.add(piece);
    } else if (start >= to) {
      piece.timelineStart = start - length;
      kept.add(piece);
    } else {
      if (start < from) {
        kept.add(piece.slice(
          sourceStart: piece.sourceStart,
          sourceEnd: piece.sourceStart + (from - start),
          timelineStart: start,
        ) as T);
      }
      if (end > to) {
        kept.add(piece.slice(
          sourceStart: piece.sourceStart + (to - start),
          sourceEnd: piece.sourceEnd,
          timelineStart: from,
        ) as T);
      }
    }
  }
  pieces
    ..clear()
    ..addAll(kept);
}

/// Abre um vão de [length] em [at]: o que vinha depois anda pra frente.
void rippleInsert<T extends TimelinePiece>(
    List<T> pieces, double at, double length) {
  if (length <= 0) return;
  final result = <T>[];
  for (final piece in pieces) {
    final start = piece.timelineStart, end = piece.timelineEnd;
    if (end <= at) {
      result.add(piece);
    } else if (start >= at) {
      piece.timelineStart = start + length;
      result.add(piece);
    } else {
      result
        ..add(piece.slice(
          sourceStart: piece.sourceStart,
          sourceEnd: piece.sourceStart + (at - start),
          timelineStart: start,
        ) as T)
        ..add(piece.slice(
          sourceStart: piece.sourceStart + (at - start),
          sourceEnd: piece.sourceEnd,
          timelineStart: at + length,
        ) as T);
    }
  }
  pieces
    ..clear()
    ..addAll(result);
}

double programDuration(List<VideoClip> clips) =>
    clips.fold(0.0, (end, clip) => math.max(end, clip.timelineEnd));

/// O trecho no instante [t] do programa; null depois do fim.
VideoClip? clipAt(List<VideoClip> clips, double t) {
  for (final clip in clips) {
    if (t >= clip.timelineStart && t < clip.timelineEnd) return clip;
  }
  return null;
}

/// O programa ainda é o vídeo original inteiro.
bool programUntouched(MediaFileInfo file) {
  final video = file.mainVideo;
  if (video == null) return true;
  if (video.clips.length != 1) return false;
  final clip = video.clips.single;
  return clip.path == file.path &&
      clip.sourceStart.abs() < 0.005 &&
      clip.timelineStart.abs() < 0.005 &&
      clip.sourceEnd >= video.durationSeconds - 0.05;
}

/// A faixa de áudio que os players abrem no arquivo salvo: a primeira
/// marcada como padrão entre as do arquivo que ficam ou, sem marca, a
/// primeira na ordem do salvar. Null sem áudio.
Object? defaultAudioLane(MediaFileInfo file, List<ExternalTrack> added) {
  final own =
      file.tracks.where((t) => t.type == TrackType.audio && !t.removed);
  return own.where((t) => t.isDefault).firstOrNull ??
      own.firstOrNull ??
      added.where((t) => t.type == TrackType.audio).firstOrNull;
}

/// Menor trecho que arrastar uma borda deixa.
const double kMinPieceDuration = 0.05;

// bordas a menos de um arredondamento do double são a mesma borda
const double _kRounding = 1e-6;

/// Até onde a borda esquerda de [segment] vai quando arrastada pra [wanted]:
/// não passa do começo da origem, do zero nem do fim do vizinho à esquerda,
/// e o trecho não fica menor que [kMinPieceDuration].
double clampSegmentStart<T extends TimelinePiece>(
    List<T> lane, T segment, double wanted) {
  var lower = math.max(0.0, segment.timelineStart - segment.sourceStart);
  for (final other in lane) {
    if (!identical(other, segment) &&
        other.timelineEnd <= segment.timelineStart + _kRounding) {
      lower = math.max(lower, other.timelineEnd);
    }
  }
  return _clampEdge(wanted, lower, segment.timelineEnd - kMinPieceDuration,
      segment.timelineStart);
}

/// Até onde a borda direita de [segment] vai quando arrastada pra [wanted]:
/// não passa do fim da origem nem do começo do vizinho à direita, e o trecho
/// não fica menor que [kMinPieceDuration].
double clampSegmentEnd<T extends TimelinePiece>(
    List<T> lane, T segment, double wanted) {
  var upper = segment.timelineStart +
      (segment.sourceDuration - segment.sourceStart);
  for (final other in lane) {
    if (!identical(other, segment) &&
        other.timelineStart >= segment.timelineEnd - _kRounding) {
      upper = math.min(upper, other.timelineStart);
    }
  }
  return _clampEdge(wanted, segment.timelineStart + kMinPieceDuration, upper,
      segment.timelineEnd);
}

/// Onde [piece] começa quando arrastado inteiro pra [wanted]: não passa do
/// zero nem entra nos vizinhos de [lane]; sem espaço, fica onde está.
double clampMove<T extends TimelinePiece>(
    List<T> lane, T piece, double wanted) {
  var lower = 0.0, upper = double.infinity;
  for (final other in lane) {
    if (identical(other, piece)) continue;
    if (other.timelineEnd <= piece.timelineStart + _kRounding) {
      lower = math.max(lower, other.timelineEnd);
    }
    if (other.timelineStart >= piece.timelineEnd - _kRounding) {
      upper = math.min(upper, other.timelineStart);
    }
  }
  return _clampEdge(
      wanted, lower, upper - piece.duration, piece.timelineStart);
}

// limite que o trecho já não cumpria não empurra a borda: sem espaço, ela
// fica onde está
double _clampEdge(double wanted, double lower, double upper, double current) =>
    wanted.clamp(math.min(lower, current), math.max(upper, current));

/// Arrasta a borda esquerda de [segment] pra [wanted] (ver
/// [clampSegmentStart]); o resto do trecho não sai do lugar.
void trimSegmentStart<T extends TimelinePiece>(
    List<T> lane, T segment, double wanted) {
  final start = clampSegmentStart(lane, segment, wanted);
  segment
    ..sourceStart = math.max(
        0.0, segment.sourceStart + (start - segment.timelineStart))
    ..timelineStart = start;
}

/// Arrasta a borda direita de [segment] pra [wanted] (ver [clampSegmentEnd]).
void trimSegmentEnd<T extends TimelinePiece>(
    List<T> lane, T segment, double wanted) {
  segment.sourceEnd = math.min(
      segment.sourceDuration,
      segment.sourceEnd +
          (clampSegmentEnd(lane, segment, wanted) - segment.timelineEnd));
}

/// Edições do programa: o vídeo é cortado ou ganha trecho e todas as outras
/// faixas andam junto, pra nada sair de sincronia.
class ProgramEdit {
  ProgramEdit(this.file, this.added);

  final MediaFileInfo file;
  final List<ExternalTrack> added;

  Iterable<Object> get _audioLanes => [
        ...file.tracks.where((t) => t.type == TrackType.audio),
        ...added.where((t) => t.type == TrackType.audio),
      ];

  // cortar em cascata divide as faixas; sem congelar, a mescla automática
  // juntaria idiomas diferentes numa faixa só
  void _freezeMerges() {
    for (final lane in _audioLanes) {
      final merges = audioLaneMerges(lane, file.path);
      if (lane is MediaTrack) lane.merge ??= merges;
      if (lane is ExternalTrack) lane.merge ??= merges;
    }
  }

  void _ripple(void Function<T extends TimelinePiece>(List<T>) apply) {
    final video = file.mainVideo;
    if (video != null) apply(video.clips);
    for (final track in file.tracks) {
      if (track.type == TrackType.audio) apply(track.segments);
      if (track.type == TrackType.subtitle) apply(track.pieces);
    }
    for (final track in added) {
      if (track.type == TrackType.audio) apply(track.segments);
      if (track.type == TrackType.subtitle) apply(track.pieces);
    }
  }

  /// Faixas que ficaram vazias (quem chamou remove).
  List<Object> _emptied() => [
        ...file.tracks.where((t) =>
            (t.type == TrackType.audio && t.segments.isEmpty) ||
            (t.type == TrackType.subtitle && t.pieces.isEmpty)),
        ...added.where((t) =>
            (t.type == TrackType.audio && t.segments.isEmpty) ||
            (t.type == TrackType.subtitle && t.pieces.isEmpty)),
      ];

  /// Tira [from, to) do programa inteiro; devolve as faixas que esvaziaram.
  List<Object> cut(double from, double to) {
    final video = file.mainVideo;
    // cortar até o fim do vídeo leva junto o áudio e a legenda que sobram
    // depois dele (o áudio costuma ser uns milissegundos mais longo)
    final end = video != null && to >= programDuration(video.clips) - 0.001
        ? double.infinity
        : to;
    _freezeMerges();
    _ripple(<T extends TimelinePiece>(List<T> pieces) =>
        rippleDelete(pieces, from, pieces is List<VideoClip> ? to : end));
    return _emptied();
  }

  /// Põe [clip] em [at]. O áudio do arquivo inserido ([audio]) entra nesse
  /// vão em todas as faixas de áudio do vídeo original.
  void insert(
    VideoClip clip, {
    required double at,
    AudioSource? audio,
    double audioDuration = 0,
  }) {
    final video = file.mainVideo;
    if (video == null) return;
    final position = at.clamp(0.0, programDuration(video.clips));
    _freezeMerges();
    _ripple(<T extends TimelinePiece>(List<T> pieces) =>
        rippleInsert(pieces, position, clip.duration));
    clip.timelineStart = position;
    video.clips
      ..add(clip)
      ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
    if (audio == null || audioDuration <= 0) return;
    for (final track in file.tracks.where((t) => t.type == TrackType.audio)) {
      track.segments
        ..add(AudioSegment(
          source: audio,
          sourceStart: clip.sourceStart,
          sourceEnd: math.min(clip.sourceEnd, audioDuration),
          timelineStart: position,
          sourceDuration: audioDuration,
        ))
        ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
    }
  }
}
