import 'dart:math' as math;

import 'tracks.dart';

/// Tira [from, to) da linha do tempo: o que vinha depois anda pra trás.
/// Sobra menor que [tolerance] nas pontas do corte sai junto, sem virar lasca.
void rippleDelete<T extends TimelinePiece>(
    List<T> pieces, double from, double to,
    {double tolerance = 0}) {
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
      if (start < from - tolerance) {
        kept.add(piece.slice(
          sourceStart: piece.sourceStart,
          sourceEnd: piece.sourceStart + (from - start),
          timelineStart: start,
        ) as T);
      }
      if (end > to + tolerance) {
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
/// Pedaço que começa ou termina a menos de [tolerance] de [at] não é dividido.
void rippleInsert<T extends TimelinePiece>(
    List<T> pieces, double at, double length,
    {double tolerance = 0}) {
  if (length <= 0) return;
  final result = <T>[];
  for (final piece in pieces) {
    final start = piece.timelineStart, end = piece.timelineEnd;
    if (end <= at + tolerance) {
      result.add(piece);
    } else if (start >= at - tolerance) {
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

/// Menor trecho que arrastar uma borda deixa.
const double kMinPieceDuration = 0.05;

// cortes em instantes que o double não guarda exatos deixam as faixas a um
// arredondamento da borda do vídeo: a menos disso é a mesma borda, e pedaço
// mais curto que isso é lasca sem material
const double _kRounding = 1e-6;

/// Até onde a borda esquerda de [segment] vai quando arrastada pra [wanted]:
/// não passa do começo da origem, do zero nem do fim do vizinho à esquerda,
/// e o trecho não fica menor que [kMinPieceDuration].
double clampSegmentStart(
    List<AudioSegment> lane, AudioSegment segment, double wanted) {
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
double clampSegmentEnd(
    List<AudioSegment> lane, AudioSegment segment, double wanted) {
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

// limite que o trecho já não cumpria não empurra a borda: sem espaço, ela
// fica onde está
double _clampEdge(double wanted, double lower, double upper, double current) =>
    wanted.clamp(math.min(lower, current), math.max(upper, current));

/// Arrasta a borda esquerda de [segment] pra [wanted] (ver
/// [clampSegmentStart]); o som do resto do trecho não sai do lugar.
void trimSegmentStart(
    List<AudioSegment> lane, AudioSegment segment, double wanted) {
  final start = clampSegmentStart(lane, segment, wanted);
  segment
    ..sourceStart = math.max(
        0.0, segment.sourceStart + (start - segment.timelineStart))
    ..timelineStart = start;
}

/// Arrasta a borda direita de [segment] pra [wanted] (ver [clampSegmentEnd]).
void trimSegmentEnd(
    List<AudioSegment> lane, AudioSegment segment, double wanted) {
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
  List<Object> emptiedLanes() => [
        ...file.tracks.where((t) =>
            (t.type == TrackType.audio && t.segments.isEmpty) ||
            (t.type == TrackType.subtitle && t.pieces.isEmpty)),
        ...added.where((t) =>
            (t.type == TrackType.audio && t.segments.isEmpty) ||
            (t.type == TrackType.subtitle && t.pieces.isEmpty)),
      ];

  /// Tira [from, to) do programa inteiro; devolve as faixas que esvaziaram.
  List<Object> cut(double from, double to) {
    final end = _lanesCutEnd(to);
    _freezeMerges();
    _ripple(<T extends TimelinePiece>(List<T> pieces) =>
        rippleDelete(pieces, from, pieces is List<VideoClip> ? to : end));
    return emptiedLanes();
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

  // cortar até o fim do vídeo leva junto o áudio e a legenda que sobram
  // depois dele (o áudio costuma ser uns milissegundos mais longo)
  double _lanesCutEnd(double to) {
    final video = file.mainVideo;
    return video != null && to >= programDuration(video.clips) - 0.001
        ? double.infinity
        : to;
  }

  void _cutLanes(double from, double to) {
    final end = _lanesCutEnd(to);
    _ripple(<T extends TimelinePiece>(List<T> pieces) {
      if (pieces is! List<VideoClip>) {
        rippleDelete(pieces, from, end, tolerance: _kRounding);
      }
    });
  }

  // esticar de volta sobre um corte devolve também o áudio e a legenda; lasca
  // sem material não tem o que devolver
  void _openLanes(
      double at, double length, void Function(TimelinePiece) bringBack) {
    _ripple(<T extends TimelinePiece>(List<T> pieces) {
      if (pieces is List<VideoClip>) return;
      rippleInsert(pieces, at, length, tolerance: _kRounding);
      for (final piece in pieces) {
        if (piece.duration > _kRounding) bringBack(piece);
      }
    });
  }

  /// Arrasta a borda esquerda de [clip] por [delta] segundos da origem:
  /// positivo tira do começo, negativo traz de volta o que vinha antes. O
  /// trecho não sai do lugar e o que vem depois anda junto. Devolve o quanto
  /// andou de fato.
  double trimClipStart(VideoClip clip, double delta) {
    final applied = _clampEdge(
        delta, -clip.sourceStart, clip.duration - kMinPieceDuration, 0);
    final clips = file.mainVideo?.clips;
    if (applied.abs() < _kRounding ||
        clips == null ||
        !clips.contains(clip)) {
      return 0;
    }
    final edge = clip.timelineStart;
    _freezeMerges();
    if (applied > 0) {
      _cutLanes(edge, edge + applied);
    } else {
      final length = -applied;
      _openLanes(edge, length, (piece) {
        if ((piece.timelineStart - edge - length).abs() < 1e-3) {
          final back = math.min(length, piece.sourceStart);
          piece
            ..sourceStart -= back
            ..timelineStart -= back;
        }
      });
    }
    for (final other in clips) {
      if (other.timelineStart > clip.timelineStart) {
        other.timelineStart -= applied;
      }
    }
    clip.sourceStart += applied;
    return applied;
  }

  /// Arrasta a borda direita de [clip] por [delta] segundos da origem:
  /// positivo traz de volta o que vinha depois, negativo tira do fim. O que
  /// vem depois anda junto. Devolve o quanto andou de fato.
  double trimClipEnd(VideoClip clip, double delta) {
    final applied = _clampEdge(delta, kMinPieceDuration - clip.duration,
        clip.sourceDuration - clip.sourceEnd, 0);
    final clips = file.mainVideo?.clips;
    if (applied.abs() < _kRounding ||
        clips == null ||
        !clips.contains(clip)) {
      return 0;
    }
    final edge = clip.timelineEnd;
    _freezeMerges();
    if (applied < 0) {
      _cutLanes(edge + applied, edge);
    } else {
      _openLanes(edge, applied, (piece) {
        if ((piece.timelineEnd - edge).abs() < 1e-3) {
          piece.sourceEnd =
              math.min(piece.sourceEnd + applied, piece.sourceDuration);
        }
      });
    }
    for (final other in clips) {
      if (other.timelineStart > clip.timelineStart) {
        other.timelineStart += applied;
      }
    }
    clip.sourceEnd = math.min(clip.sourceEnd + applied, clip.sourceDuration);
    return applied;
  }
}

/// O programa como estava ao pegar uma borda: a cada passo do arrasto ele
/// volta pra cá e o movimento inteiro é aplicado de novo, sem acumular erro.
class ProgramSnapshot {
  ProgramSnapshot.take(MediaFileInfo file, List<ExternalTrack> added) {
    ProgramEdit(file, added)._ripple(_keep);
    for (final track in file.tracks.where((t) => t.type == TrackType.audio)) {
      final merge = track.merge;
      _undo.add(() => track.merge = merge);
    }
    for (final track in added.where((t) => t.type == TrackType.audio)) {
      final merge = track.merge;
      _undo.add(() => track.merge = merge);
    }
  }

  final _undo = <void Function()>[];

  void _keep<T extends TimelinePiece>(List<T> pieces) {
    final kept = [
      for (final p in pieces) (p, p.sourceStart, p.sourceEnd, p.timelineStart),
    ];
    _undo.add(() {
      pieces.clear();
      for (final (piece, sourceStart, sourceEnd, timelineStart) in kept) {
        pieces.add(piece
          ..sourceStart = sourceStart
          ..sourceEnd = sourceEnd
          ..timelineStart = timelineStart);
      }
    });
  }

  /// Volta o programa a como estava; o que foi criado depois some.
  void restore() {
    for (final undo in _undo) {
      undo();
    }
  }
}
