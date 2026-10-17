import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';

const kSource = '/tmp/episode.mkv';
const kSong = '/tmp/song.flac';

VideoClip _clip(double start, double end, double at,
        {double sourceDuration = 600}) =>
    VideoClip(
      path: kSource,
      streamTypeIndex: 0,
      width: 1432,
      height: 1080,
      rate: '2997/100',
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
      sourceDuration: sourceDuration,
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

MediaTrack _audio(int typeIndex) => MediaTrack(
      streamIndex: typeIndex + 1,
      type: TrackType.audio,
      typeIndex: typeIndex,
      codec: 'FLAC',
      details: '',
      originalTitle: '',
      durationSeconds: 600,
      channelLayout: 'stereo',
    )..segments.add(AudioSegment(
        source: AudioSource(path: kSource, audioTypeIndex: typeIndex),
        sourceStart: 0,
        sourceEnd: 600,
        timelineStart: 0,
        sourceDuration: 600,
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

// áudio e legendas, cada pedaço com o próprio objeto
List<(TimelinePiece, double, double, double)> _besideVideo(
        MediaFileInfo file) =>
    [
      for (final track in file.tracks)
        for (final p in <TimelinePiece>[...track.segments, ...track.pieces])
          (p, p.sourceStart, p.sourceEnd, p.timelineStart),
    ];

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

    test('edges at inexact times never pass the source limits', () {
      final head = _segment(0.1, 100, 1.6);
      trimSegmentStart([head], head, 0);
      expect(head.sourceStart, 0);

      final tail = _segment(0.3, 100, 0.2);
      trimSegmentEnd([tail], tail, 1000);
      expect(tail.sourceEnd, 600);
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
    test('the left edge trims only its clip and leaves a gap at its head',
        () {
      final file = _splitAt(300);
      final clips = file.mainVideo!.clips;
      final [first, second] = clips;
      final lanes = _besideVideo(file);

      trimSegmentStart(clips, second, 350);

      expect(clips, [same(first), same(second)]);
      expect(_ranges(clips), [(0.0, 300.0, 0.0), (350.0, 600.0, 350.0)]);
      expect(_besideVideo(file), lanes);
    });

    test('the right edge trims only its clip and leaves a gap at its tail',
        () {
      final file = _splitAt(300);
      final clips = file.mainVideo!.clips;
      final [first, second] = clips;
      final lanes = _besideVideo(file);

      trimSegmentEnd(clips, first, 250);

      expect(clips, [same(first), same(second)]);
      expect(_ranges(clips), [(0.0, 250.0, 0.0), (300.0, 600.0, 300.0)]);
      expect(_besideVideo(file), lanes);
    });

    test('stretching stops at the neighbours', () {
      // vão de 50 entre os dois trechos
      List<VideoClip> lane() => [_clip(0, 100, 0), _clip(200, 300, 150)];

      final tail = lane();
      trimSegmentEnd(tail, tail[0], 1000);
      expect(_ranges(tail), [(0.0, 150.0, 0.0), (200.0, 300.0, 150.0)]);

      final head = lane();
      trimSegmentStart(head, head[1], 0);
      expect(_ranges(head), [(0.0, 100.0, 0.0), (150.0, 300.0, 100.0)]);
    });

    test('stretching stops at the source limits and at the timeline start',
        () {
      final head = _clip(30, 100, 50);
      trimSegmentStart([head], head, 0);
      expect(_ranges([head]), [(0.0, 100.0, 20.0)]);

      final early = _clip(50, 100, 20);
      trimSegmentStart([early], early, -10);
      expect(_ranges([early]), [(30.0, 100.0, 0.0)]);

      final tail = _clip(0, 0.7, 0, sourceDuration: 3.4);
      trimSegmentEnd([tail], tail, 10);
      expect(tail.sourceEnd, 3.4);
    });

    test('a clip never gets shorter than the minimum', () {
      final clips = [_clip(0, 100, 0), _clip(200, 300, 200)];
      final [first, second] = clips;
      trimSegmentStart(clips, first, 150);
      trimSegmentEnd(clips, second, 0);
      expect(first.duration, closeTo(kMinPieceDuration, 1e-9));
      expect(first.timelineEnd, closeTo(100, 1e-9));
      expect(second.duration, closeTo(kMinPieceDuration, 1e-9));
      expect(second.timelineStart, 200);
    });
  });

  group('moving a video clip', () {
    test('a clip moves between its neighbours and stops at them', () {
      final clips = [_clip(0, 40, 0), _clip(60, 100, 60), _clip(200, 250, 150)];
      final moved = clips[1];
      expect(clampMove(clips, moved, 45), 45);
      expect(clampMove(clips, moved, 100), 100);
      expect(clampMove(clips, moved, 20), 40);
      expect(clampMove(clips, moved, 140), 110);
    });

    test('a clip never goes before zero', () {
      final clips = [_clip(10, 50, 30), _clip(60, 100, 100)];
      expect(clampMove(clips, clips.first, -20), 0);
    });

    test('with no room a clip stays where it is', () {
      final clips = [_clip(0, 40, 0), _clip(60, 100, 40), _clip(200, 250, 80)];
      for (final wanted in [-10.0, 20.0, 41.0, 500.0]) {
        expect(clampMove(clips, clips[1], wanted), 40);
      }
    });

    test('a clip dragged past a neighbour stops exactly against it', () {
      // 10.4 s que o double não guarda exatos: encostado, passa um fio
      final clips = [
        _clip(0, 10.1, 0),
        _clip(20.2, 30.6, 15),
        _clip(100, 140, 42.6),
      ];
      final [left, moved, right] = clips;

      moved.timelineStart = clampMove(clips, moved, 1000);
      expect(moved.timelineStart, right.timelineStart - moved.duration);
      expect(moved.timelineEnd, closeTo(right.timelineStart, 1e-9));
      expect(clampMove(clips, moved, 1000), moved.timelineStart);

      moved.timelineStart = clampMove(clips, moved, -1000);
      expect(moved.timelineStart, left.timelineEnd);
      expect(clampMove(clips, moved, -1000), left.timelineEnd);
    });
  });
}
