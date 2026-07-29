enum TrackType { video, audio, subtitle }

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

/// A piece of audio placed on the output timeline: the range
/// [sourceStart, sourceEnd) of [source] starts playing at [timelineStart].
class AudioSegment {
  AudioSegment({
    required this.source,
    required this.sourceStart,
    required this.sourceEnd,
    required this.timelineStart,
  });

  final AudioSource source;
  double sourceStart;
  double sourceEnd;
  double timelineStart;

  double get duration => sourceEnd - sourceStart;
  double get timelineEnd => timelineStart + duration;

  bool containsTimeline(double t) => t > timelineStart && t < timelineEnd;

  AudioSegment copy() => AudioSegment(
        source: source,
        sourceStart: sourceStart,
        sourceEnd: sourceEnd,
        timelineStart: timelineStart,
      );
}

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
bool splitSegment(List<AudioSegment> segments, AudioSegment segment, double t) {
  final index = segments.indexWhere((s) => identical(s, segment));
  if (index == -1 || !segment.containsTimeline(t)) return false;
  final local = t - segment.timelineStart;
  final right = AudioSegment(
    source: segment.source,
    sourceStart: segment.sourceStart + local,
    sourceEnd: segment.sourceEnd,
    timelineStart: t,
  );
  segment.sourceEnd = segment.sourceStart + local;
  segments.insert(index + 1, right);
  return true;
}

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
  }) : title = originalTitle;

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

  /// Timeline shift applied on save — subtitle tracks only; audio tracks
  /// use [segments] instead. Positive = starts later.
  double offsetSeconds = 0;

  /// Audio only: the pieces of this track laid on the output timeline.
  final List<AudioSegment> segments = [];

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
  });

  final String path;
  final TrackType type;
  final String codec;
  final String details;
  final double durationSeconds;
  final String? channelLayout;
  String title;
  String? language;

  /// Timeline shift applied on save — subtitle tracks only; audio tracks
  /// use [segments] instead. Positive = starts later.
  double offsetSeconds = 0;

  /// Audio only.
  final List<AudioSegment> segments = [];
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
}
