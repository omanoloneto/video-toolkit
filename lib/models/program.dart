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

/// Tempo do arquivo original no instante [t] do programa; null quando ali
/// toca um vídeo inserido (ou já passou do fim).
double? sourceTimeAt(List<VideoClip> clips, String sourcePath, double t) {
  final clip = clipAt(clips, t);
  if (clip == null || clip.path != sourcePath) return null;
  return clip.sourceStart + (t - clip.timelineStart);
}

/// O trecho que começa onde [clip] termina.
VideoClip? clipAfter(List<VideoClip> clips, VideoClip clip) {
  VideoClip? next;
  for (final c in clips) {
    if (identical(c, clip) || c.timelineStart < clip.timelineEnd - 0.001) {
      continue;
    }
    if (next == null || c.timelineStart < next.timelineStart) next = c;
  }
  return next;
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
        ))
        ..sort((a, b) => a.timelineStart.compareTo(b.timelineStart));
    }
  }
}
