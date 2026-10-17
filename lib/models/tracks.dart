enum TrackType { video, audio, subtitle }

/// Algo posto na linha do tempo: o trecho [sourceStart, sourceEnd) da origem
/// começa em [timelineStart].
abstract class TimelinePiece {
  TimelinePiece({
    required this.sourceStart,
    required this.sourceEnd,
    required this.timelineStart,
    this.sourceDuration = double.infinity,
  });

  double sourceStart;
  double sourceEnd;
  double timelineStart;

  /// Quanto a origem tem: até onde dá pra esticar o trecho.
  final double sourceDuration;

  double get duration => sourceEnd - sourceStart;
  double get timelineEnd => timelineStart + duration;

  bool containsTimeline(double t) => t > timelineStart && t < timelineEnd;

  /// Mesma origem, outro recorte: usado ao dividir e ao cortar em cascata.
  TimelinePiece slice({
    required double sourceStart,
    required double sourceEnd,
    required double timelineStart,
  });
}

/// Identifies the audio stream that feeds a segment: a file on disk plus
/// the audio stream index within it (`path:a:audioTypeIndex`).
class AudioSource {
  const AudioSource({required this.path, required this.audioTypeIndex});

  final String path;
  final int audioTypeIndex;

  @override
  bool operator ==(Object other) =>
      other is AudioSource &&
      other.path == path &&
      other.audioTypeIndex == audioTypeIndex;

  @override
  int get hashCode => Object.hash(path, audioTypeIndex);
}

/// A piece of audio placed on the output timeline.
class AudioSegment extends TimelinePiece {
  AudioSegment({
    required this.source,
    required super.sourceStart,
    required super.sourceEnd,
    required super.timelineStart,
    super.sourceDuration,
  });

  final AudioSource source;

  @override
  AudioSegment slice({
    required double sourceStart,
    required double sourceEnd,
    required double timelineStart,
  }) =>
      AudioSegment(
        source: source,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        timelineStart: timelineStart,
        sourceDuration: sourceDuration,
      );

  AudioSegment copy() => slice(
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        timelineStart: timelineStart,
      );
}

/// Pedaço de uma legenda na linha do tempo. A faixa inteira é um pedaço sem
/// fim: a duração das legendas nem sempre é conhecida.
class SubtitlePiece extends TimelinePiece {
  SubtitlePiece({
    required super.sourceStart,
    required super.sourceEnd,
    required super.timelineStart,
    super.sourceDuration,
  });

  @override
  SubtitlePiece slice({
    required double sourceStart,
    required double sourceEnd,
    required double timelineStart,
  }) =>
      SubtitlePiece(
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        timelineStart: timelineStart,
        sourceDuration: sourceDuration,
      );
}

/// Trecho de imagem do programa: o vídeo [streamTypeIndex] de [path].
class VideoClip extends TimelinePiece {
  VideoClip({
    required this.path,
    required this.streamTypeIndex,
    required this.width,
    required this.height,
    required this.rate,
    this.sarNum = 1,
    this.sarDen = 1,
    required super.sourceStart,
    required super.sourceEnd,
    required super.timelineStart,
    super.sourceDuration,
  });

  final String path;
  final int streamTypeIndex;
  final int width;
  final int height;

  /// Taxa de quadros como o FFmpeg escreve ("30000/1001"): decimal arredonda.
  final String rate;
  final int sarNum;
  final int sarDen;

  double get sar => sarNum / sarDen;

  double get frameRate {
    final parts = rate.split('/');
    final num = double.tryParse(parts.first) ?? 0;
    final den = parts.length > 1 ? double.tryParse(parts[1]) ?? 1 : 1;
    return den == 0 ? 0 : num / den;
  }

  @override
  VideoClip slice({
    required double sourceStart,
    required double sourceEnd,
    required double timelineStart,
  }) =>
      VideoClip(
        path: path,
        streamTypeIndex: streamTypeIndex,
        width: width,
        height: height,
        rate: rate,
        sarNum: sarNum,
        sarDen: sarDen,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        timelineStart: timelineStart,
        sourceDuration: sourceDuration,
      );
}

/// Se a faixa de áudio entra na mescla ao salvar: a escolha feita na tela
/// ou, sem escolha, automático (entra quando foi cortada).
bool audioLaneMerges(Object lane, String sourcePath) => switch (lane) {
      final MediaTrack t when t.type == TrackType.audio => t.merge ??
          audioLaneIsFragmentary(
            segments: t.segments,
            ownPath: sourcePath,
            ownTypeIndex: t.typeIndex,
            durationSeconds: t.durationSeconds,
          ),
      final ExternalTrack t when t.type == TrackType.audio => t.merge ??
          audioLaneIsFragmentary(
            segments: t.segments,
            ownPath: t.path,
            ownTypeIndex: 0,
            durationSeconds: t.durationSeconds,
          ),
      _ => false,
    };

/// True when an audio lane was cut apart: split into pieces, trimmed, or
/// fed by another source. Fragmentary lanes are automatically merged into
/// a single output track on save; whole lanes (even delayed ones) stay as
/// separate tracks.
bool audioLaneIsFragmentary({
  required List<AudioSegment> segments,
  required String ownPath,
  required int ownTypeIndex,
  required double durationSeconds,
}) {
  if (segments.isEmpty) return false;
  if (segments.length > 1) return true;
  final s = segments.single;
  if (s.source != AudioSource(path: ownPath, audioTypeIndex: ownTypeIndex)) {
    return true;
  }
  return s.sourceStart > 0.005 || s.sourceEnd < durationSeconds - 0.05;
}

/// Splits [segment] (which must belong to [segments]) at timeline instant
/// [t]. Returns true when a split happened. Operates on the specific
/// segment — not just any segment containing [t] — so overlapping segments
/// behave predictably.
bool splitSegment<T extends TimelinePiece>(List<T> segments, T segment, double t) {
  final index = segments.indexWhere((s) => identical(s, segment));
  if (index == -1 || !segment.containsTimeline(t)) return false;
  final local = t - segment.timelineStart;
  final right = segment.slice(
    sourceStart: segment.sourceStart + local,
    sourceEnd: segment.sourceEnd,
    timelineStart: t,
  ) as T;
  segment.sourceEnd = segment.sourceStart + local;
  segments.insert(index + 1, right);
  return true;
}

// deslocamento da legenda: lido do primeiro pedaço; mudar desloca todos
double _subtitleOffset(List<SubtitlePiece> pieces) =>
    pieces.isEmpty ? 0 : pieces.first.timelineStart - pieces.first.sourceStart;

void _shiftSubtitle(List<SubtitlePiece> pieces, double offset) {
  final delta = offset - _subtitleOffset(pieces);
  for (final piece in pieces) {
    piece.timelineStart += delta;
  }
}

/// Legenda ainda inteira: só deslocada, nunca cortada.
bool subtitleIsWhole(List<SubtitlePiece> pieces) =>
    pieces.length == 1 &&
    pieces.single.sourceStart.abs() < 0.005 &&
    pieces.single.sourceEnd == double.infinity;

List<SubtitlePiece> _wholeSubtitle() => [
      SubtitlePiece(
          sourceStart: 0, sourceEnd: double.infinity, timelineStart: 0),
    ];

/// A stream that exists inside the loaded media file.
class MediaTrack {
  MediaTrack({
    required this.streamIndex,
    required this.type,
    required this.typeIndex,
    required this.codec,
    required this.details,
    required this.originalTitle,
    required this.durationSeconds,
    this.language,
    this.channelLayout,
    this.isDefault = false,
  }) : title = originalTitle {
    if (type == TrackType.subtitle) pieces.addAll(_wholeSubtitle());
  }

  /// Absolute stream index in the source file (`-map 0:N`).
  final int streamIndex;
  final TrackType type;

  /// Index among streams of the same type (`-map 0:a:N`).
  final int typeIndex;
  final String codec;

  /// Human-readable summary (resolution, channels, sample rate...).
  final String details;
  final String originalTitle;
  final String? language;

  /// ffmpeg channel layout name (stereo, 5.1...), when known.
  final String? channelLayout;
  final bool isDefault;

  /// Track duration; falls back to the container duration when the
  /// stream itself doesn't declare one.
  final double durationSeconds;

  String title;
  bool removed = false;

  /// Audio only: the pieces of this track laid on the output timeline.
  final List<AudioSegment> segments = [];

  /// Legendas: os pedaços da faixa na linha do tempo.
  final List<SubtitlePiece> pieces = [];

  /// Vídeo principal: os trechos do programa; onde não há trecho, a imagem
  /// fica preta.
  final List<VideoClip> clips = [];

  /// Áudio: null deixa a mescla automática (ver [audioLaneMerges]).
  bool? merge;

  /// Legendas: positivo atrasa.
  double get offsetSeconds => _subtitleOffset(pieces);
  set offsetSeconds(double value) => _shiftSubtitle(pieces, value);

  bool get titleChanged => title != originalTitle;
}

/// An external file the user wants to mux in (audio or subtitle).
class ExternalTrack {
  ExternalTrack({
    required this.path,
    required this.type,
    required this.codec,
    required this.details,
    required this.title,
    required this.durationSeconds,
    this.language,
    this.channelLayout,
  }) {
    if (type == TrackType.subtitle) pieces.addAll(_wholeSubtitle());
  }

  final String path;
  final TrackType type;
  final String codec;
  final String details;
  final double durationSeconds;
  final String? channelLayout;
  String title;
  String? language;

  /// Audio only.
  final List<AudioSegment> segments = [];

  /// Legendas: os pedaços do arquivo na linha do tempo.
  final List<SubtitlePiece> pieces = [];

  /// Áudio: null deixa a mescla automática (ver [audioLaneMerges]).
  bool? merge;

  /// Legendas: positivo atrasa.
  double get offsetSeconds => _subtitleOffset(pieces);
  set offsetSeconds(double value) => _shiftSubtitle(pieces, value);
}

class MediaFileInfo {
  MediaFileInfo({
    required this.path,
    required this.formatName,
    required this.durationSeconds,
    required this.sizeBytes,
    required this.tracks,
  });

  final String path;
  final String formatName;
  final double durationSeconds;
  final int sizeBytes;
  final List<MediaTrack> tracks;

  List<MediaTrack> byType(TrackType type) =>
      tracks.where((t) => t.type == type).toList();

  /// A faixa de vídeo que forma o programa (null em arquivo só de áudio).
  MediaTrack? get mainVideo => tracks
      .where((t) => t.type == TrackType.video && t.clips.isNotEmpty)
      .firstOrNull;
}
