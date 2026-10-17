import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';

const kSource = '/tmp/episode.mkv';
const kSong = '/tmp/song.flac';

VideoClip _clip(double start, double end, double at) => VideoClip(
      path: kSource,
      streamTypeIndex: 0,
      width: 1432,
      height: 1080,
      rate: '2997/100',
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
      sourceDuration: 600,
    );

AudioSegment _segment(double start, double end, double at) => AudioSegment(
      source: const AudioSource(path: kSong, audioTypeIndex: 0),
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
      sourceDuration: 600,
    );

MediaTrack _video() => MediaTrack(
      streamIndex: 0,
      type: TrackType.video,
      typeIndex: 0,
      codec: 'H264',
      details: '',
      originalTitle: '',
      durationSeconds: 600,
    )..clips.add(_clip(0, 600, 0));

MediaTrack _audio(int typeIndex, {double duration = 600}) => MediaTrack(
      streamIndex: typeIndex + 1,
      type: TrackType.audio,
      typeIndex: typeIndex,
      codec: 'FLAC',
      details: '',
      originalTitle: '',
      durationSeconds: duration,
      channelLayout: 'stereo',
    )..segments.add(AudioSegment(
        source: AudioSource(path: kSource, audioTypeIndex: typeIndex),
        sourceStart: 0,
        sourceEnd: duration,
        timelineStart: 0,
        sourceDuration: duration,
      ));

MediaTrack _subtitle() => MediaTrack(
      streamIndex: 3,
      type: TrackType.subtitle,
      typeIndex: 0,
      codec: 'ASS',
      details: '',
      originalTitle: '',
      durationSeconds: 600,
    );

ExternalTrack _song(AudioSegment segment) => ExternalTrack(
      path: kSong,
      type: TrackType.audio,
      codec: 'FLAC',
      details: '',
      title: 'song',
      durationSeconds: 600,
    )..segments.add(segment);

MediaFileInfo _file(List<MediaTrack> tracks) => MediaFileInfo(
      path: kSource,
      formatName: 'matroska',
      durationSeconds: 600,
      sizeBytes: 0,
      tracks: tracks,
    );

MediaFileInfo _program() =>
    _file([_video(), _audio(0), _audio(1), _subtitle()]);

MediaFileInfo _splitAt(double t) {
  final file = _program();
  final clips = file.mainVideo!.clips;
  splitSegment(clips, clips.single, t);
  return file;
}

List<(double, double, double)> _ranges(List<TimelinePiece> pieces) => [
      for (final p in pieces) (p.sourceStart, p.sourceEnd, p.timelineStart),
    ];

List<List<TimelinePiece>> _lanes(
        MediaFileInfo file, List<ExternalTrack> added) =>
    [
      for (final t in file.tracks) ...[t.clips, t.segments, t.pieces],
      for (final t in added) ...[t.segments, t.pieces],
    ];

List<List<(double, double, double)>> _timeline(MediaFileInfo file,
        [List<ExternalTrack> added = const []]) =>
    [for (final lane in _lanes(file, added)) _ranges(lane)];

void main() {
  group('audio segment edges', () {
    test('the left edge stops where the source begins', () {
      final segment = _segment(10, 100, 50);
      trimSegmentStart([segment], segment, 0);
      expect(_ranges([segment]), [(0.0, 100.0, 40.0)]);
      expect(segment.timelineEnd, 140);
    });

    test('the left edge stops at the start of the timeline', () {
      final segment = _segment(50, 100, 20);
      trimSegmentStart([segment], segment, -10);
      expect(_ranges([segment]), [(30.0, 100.0, 0.0)]);
    });

    test('the right edge stops where the source ends', () {
      final segment = _segment(100, 500, 50);
      trimSegmentEnd([segment], segment, 700);
      expect(_ranges([segment]), [(100.0, 600.0, 50.0)]);
    });

    test('edges stop at the closest neighbour and leave it alone', () {
      final lane = [
        _segment(0, 40, 0),
        _segment(0, 50, 50),
        _segment(200, 300, 150),
        _segment(0, 10, 400),
      ];
      expect(clampSegmentStart(lane, lane[2], 0), 100);
      expect(clampSegmentEnd(lane, lane[2], 1000), 400);

      trimSegmentStart(lane, lane[2], 0);
      trimSegmentEnd(lane, lane[2], 1000);

      expect(_ranges(lane), [
        (0.0, 40.0, 0.0),
        (0.0, 50.0, 50.0),
        (150.0, 450.0, 100.0),
        (0.0, 10.0, 400.0),
      ]);
    });

    test('a neighbour that already overlaps does not block', () {
      final lane = [_segment(0, 120, 0), _segment(100, 300, 100)];
      expect(clampSegmentStart(lane, lane[1], 50), 50);
      expect(clampSegmentEnd(lane, lane[0], 200), 200);
    });

    test('a segment never gets shorter than the minimum', () {
      final lane = [_segment(0, 100, 0), _segment(0, 100, 200)];
      trimSegmentStart(lane, lane[0], 150);
      trimSegmentEnd(lane, lane[1], 0);
      expect(lane[0].duration, closeTo(kMinPieceDuration, 1e-9));
      expect(lane[0].timelineEnd, closeTo(100, 1e-9));
      expect(lane[1].duration, closeTo(kMinPieceDuration, 1e-9));
      expect(lane[1].timelineStart, 200);
    });

    test('with no room the edges stay where they are', () {
      final lane = [
        _segment(0, 100, 0),
        _segment(0, 0.02, 100),
        _segment(0, 50, 100.02),
      ];
      final squeezed = lane[1];
      for (final wanted in [0.0, 100.01, 200.0]) {
        expect(clampSegmentStart(lane, squeezed, wanted), 100);
        expect(clampSegmentEnd(lane, squeezed, wanted),
            closeTo(100.02, 1e-9));
      }

      trimSegmentStart(lane, squeezed, 50);
      trimSegmentEnd(lane, squeezed, 150);

      expect(squeezed.sourceStart, 0);
      expect(squeezed.timelineStart, 100);
      expect(squeezed.sourceEnd, closeTo(0.02, 1e-9));
    });
  });

  group('video clip edges', () {
    test('shrinking the tail pulls audio, subtitles and later clips back', () {
      final file = _splitAt(300);
      final [first, second] = file.mainVideo!.clips;
      final song = _song(_segment(0, 600, 0));

      expect(ProgramEdit(file, [song]).trimClipEnd(first, -50), -50);

      expect(file.mainVideo!.clips, [same(first), same(second)]);
      expect(_ranges(file.mainVideo!.clips),
          [(0.0, 250.0, 0.0), (300.0, 600.0, 250.0)]);
      for (final segments in [
        for (final audio in file.byType(TrackType.audio)) audio.segments,
        song.segments,
      ]) {
        expect(_ranges(segments), [(0.0, 250.0, 0.0), (300.0, 600.0, 250.0)]);
      }
      expect(_ranges(file.tracks.last.pieces),
          [(0.0, 250.0, 0.0), (300.0, double.infinity, 250.0)]);
    });

    test('shrinking the tail at the program end takes the audio tail along',
        () {
      final video = _video();
      final longer = _audio(0, duration: 600.4);
      final sub = _subtitle();
      final file = _file([video, longer, sub]);
      final clip = video.clips.single;

      expect(ProgramEdit(file, []).trimClipEnd(clip, -100), -100);

      expect(video.clips, [same(clip)]);
      expect(_ranges(video.clips), [(0.0, 500.0, 0.0)]);
      expect(_ranges(longer.segments), [(0.0, 500.0, 0.0)]);
      expect(_ranges(sub.pieces), [(0.0, 500.0, 0.0)]);
    });

    test('stretching the tail back over a cut brings audio and subtitles back',
        () {
      for (final (from, to, stretch) in [
        (300.0, 400.0, 40.0),
        (500.0, 600.0, 50.0),
      ]) {
        final edited = _program();
        final edit = ProgramEdit(edited, []);
        edit.cut(from, to);
        final clip = edited.mainVideo!.clips.first;

        expect(edit.trimClipEnd(clip, stretch), stretch);

        expect(edited.mainVideo!.clips.first, same(clip));
        final cutLess = _program();
        ProgramEdit(cutLess, []).cut(from + stretch, to);
        expect(_timeline(edited), _timeline(cutLess), reason: 'cut $from-$to');
      }
    });

    test('shrinking the head removes the same range everywhere', () {
      final file = _splitAt(300);
      final [first, second] = file.mainVideo!.clips;

      expect(ProgramEdit(file, []).trimClipStart(second, 50), 50);

      expect(file.mainVideo!.clips, [same(first), same(second)]);
      final cut = _program();
      ProgramEdit(cut, []).cut(300, 350);
      expect(_timeline(file), _timeline(cut));
    });

    test('stretching the head back over a cut brings audio and subtitles back',
        () {
      for (final (from, to, stretch) in [
        (100.0, 200.0, 30.0),
        (0.0, 90.0, 30.0),
      ]) {
        final edited = _program();
        final edit = ProgramEdit(edited, []);
        edit.cut(from, to);
        final clip = clipAt(edited.mainVideo!.clips, from)!;

        expect(edit.trimClipStart(clip, -stretch), -stretch);

        expect(clipAt(edited.mainVideo!.clips, from), same(clip));
        final cutLess = _program();
        ProgramEdit(cutLess, []).cut(from, to - stretch);
        expect(_timeline(edited), _timeline(cutLess), reason: 'cut $from-$to');
      }
    });

    test('a trim returns how far the edge could actually go', () {
      final file = _program();
      final edit = ProgramEdit(file, []);
      edit.cut(500, 600);
      final clip = file.mainVideo!.clips.single;

      expect(edit.trimClipEnd(clip, 1000), 100);
      expect(edit.trimClipStart(clip, -1000), 0);
      expect(edit.trimClipStart(clip, 1000),
          closeTo(600 - kMinPieceDuration, 1e-9));
      expect(clip.duration, closeTo(kMinPieceDuration, 1e-9));
      expect(edit.trimClipEnd(clip, -1000), closeTo(0, 1e-9));
      expect(edit.trimClipStart(clip, -1000),
          closeTo(kMinPieceDuration - 600, 1e-9));

      expect(file.mainVideo!.clips, [same(clip)]);
      expect(_ranges(file.mainVideo!.clips), [(0.0, 600.0, 0.0)]);
      expect(_ranges(file.tracks[1].segments), [(0.0, 600.0, 0.0)]);
    });

    test('lanes emptied by a trim are reported', () {
      final file = _splitAt(300);
      final jingle = _song(_segment(0, 30, 260));
      final edit = ProgramEdit(file, [jingle]);
      edit.trimClipEnd(file.mainVideo!.clips.first, -50);
      expect(edit.emptiedLanes(), [jingle]);
    });
  });

  group('ProgramSnapshot', () {
    test('restoring after several trims gives the exact program back', () {
      final file = _splitAt(300);
      final [first, second] = file.mainVideo!.clips;
      final song = _song(_segment(0, 600, 0));
      final added = [song];
      final jpn = file.tracks[1];
      final por = file.tracks[2]..merge = true;
      final members = [for (final lane in _lanes(file, added)) [...lane]];
      final timeline = _timeline(file, added);
      final snapshot = ProgramSnapshot.take(file, added);

      ProgramEdit(file, added)
        ..trimClipEnd(first, -50)
        ..trimClipStart(second, -30)
        ..trimClipEnd(second, -120)
        ..trimClipStart(first, 20);
      expect(jpn.merge, isFalse);
      snapshot.restore();

      expect(_lanes(file, added), members);
      expect(_timeline(file, added), timeline);
      expect(jpn.merge, isNull);
      expect(por.merge, isTrue);
      expect(song.merge, isNull);
    });

    test('a drag replayed from the snapshot never drifts', () {
      final dragged = _splitAt(300);
      final clip = dragged.mainVideo!.clips.first;
      final snapshot = ProgramSnapshot.take(dragged, []);
      final edit = ProgramEdit(dragged, []);
      for (final delta in [-10.0, 25.0, -42.5, 60.0, -40.0]) {
        snapshot.restore();
        edit.trimClipEnd(clip, delta);
      }

      final once = _splitAt(300);
      ProgramEdit(once, []).trimClipEnd(once.mainVideo!.clips.first, -40);
      expect(_timeline(dragged), _timeline(once));
    });
  });
}
