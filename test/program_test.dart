import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';

const kSource = '/tmp/episode.mkv';
const kOpening = '/tmp/opening.mp4';

VideoClip _clip(String path, double start, double end, double at) => VideoClip(
      path: path,
      streamTypeIndex: 0,
      width: 1432,
      height: 1080,
      rate: '2997/100',
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
    );

MediaTrack _video() => MediaTrack(
      streamIndex: 0,
      type: TrackType.video,
      typeIndex: 0,
      codec: 'H264',
      details: '',
      originalTitle: '',
      durationSeconds: 600,
    )..clips.add(_clip(kSource, 0, 600, 0));

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

List<(double, double, double)> _ranges(List<TimelinePiece> pieces) => [
      for (final p in pieces) (p.sourceStart, p.sourceEnd, p.timelineStart),
    ];

void main() {
  group('rippleDelete', () {
    test('cuts the middle of a piece and pulls the rest back', () {
      final pieces = [_clip(kSource, 0, 600, 0)];
      rippleDelete(pieces, 90, 120);
      expect(_ranges(pieces), [(0.0, 90.0, 0.0), (120.0, 600.0, 90.0)]);
    });

    test('drops pieces inside the range and shifts the ones after it', () {
      final pieces = [
        _clip(kSource, 0, 10, 0),
        _clip(kSource, 10, 20, 10),
        _clip(kSource, 20, 30, 20),
      ];
      rippleDelete(pieces, 10, 20);
      expect(_ranges(pieces), [(0.0, 10.0, 0.0), (20.0, 30.0, 10.0)]);
    });

    test('works on a subtitle piece that never ends', () {
      final pieces = [
        SubtitlePiece(
            sourceStart: 0, sourceEnd: double.infinity, timelineStart: 0),
      ];
      rippleDelete(pieces, 0, 90);
      expect(_ranges(pieces), [(90.0, double.infinity, 0.0)]);
    });
  });

  group('rippleInsert', () {
    test('splits the piece under the insertion and pushes the rest', () {
      final pieces = [_clip(kSource, 0, 600, 0)];
      rippleInsert(pieces, 90, 84);
      expect(_ranges(pieces), [(0.0, 90.0, 0.0), (90.0, 600.0, 174.0)]);
    });

    test('inserting at a boundary only pushes', () {
      final pieces = [_clip(kSource, 0, 90, 0), _clip(kSource, 90, 600, 90)];
      rippleInsert(pieces, 90, 10);
      expect(_ranges(pieces), [(0.0, 90.0, 0.0), (90.0, 600.0, 100.0)]);
    });
  });

  group('ProgramEdit', () {
    test('cutting the opening takes audio and subtitles along', () {
      final video = _video();
      final dub = _audio(1);
      final sub = _subtitle();
      final file = _file([video, _audio(0), dub, sub]);

      final emptied = ProgramEdit(file, []).cut(0, 90);

      expect(emptied, isEmpty);
      expect(_ranges(video.clips), [(90.0, 600.0, 0.0)]);
      expect(_ranges(dub.segments), [(90.0, 600.0, 0.0)]);
      expect(_ranges(sub.pieces), [(90.0, double.infinity, 0.0)]);
      expect(programDuration(video.clips), 510);
    });

    test('a ripple cut never merges the languages together', () {
      final jpn = _audio(0);
      final por = _audio(1);
      final file = _file([_video(), jpn, por]);

      ProgramEdit(file, []).cut(100, 200);

      // as duas ficaram em pedaços, mas continuam faixas separadas
      expect(jpn.segments, hasLength(2));
      expect(audioLaneMerges(jpn, kSource), isFalse);
      expect(audioLaneMerges(por, kSource), isFalse);
    });

    test('a lane already chosen to merge keeps merging', () {
      final por = _audio(1)..segments.single.sourceEnd = 300;
      final file = _file([_video(), por]);
      ProgramEdit(file, []).cut(400, 500);
      expect(por.merge, isTrue);
    });

    test('inserting a video with sound fills the gap in every audio track',
        () {
      final video = _video();
      final jpn = _audio(0);
      final por = _audio(1);
      final file = _file([video, jpn, por]);
      final edit = ProgramEdit(file, []);
      edit.cut(0, 90);

      edit.insert(
        _clip(kOpening, 0, 84, 0),
        at: 0,
        audio: const AudioSource(path: kOpening, audioTypeIndex: 0),
        audioDuration: 83.5,
      );

      expect(video.clips.map((c) => c.path), [kOpening, kSource]);
      expect(_ranges(video.clips), [(0.0, 84.0, 0.0), (90.0, 600.0, 84.0)]);
      for (final lane in [jpn, por]) {
        expect(lane.segments.first.source.path, kOpening);
        expect(_ranges(lane.segments), [(0.0, 83.5, 0.0), (90.0, 600.0, 84.0)]);
        expect(audioLaneMerges(lane, kSource), isFalse);
      }
      expect(programUntouched(file), isFalse);
    });

    test('cutting the end of the video takes the audio tail along', () {
      final video = _video();
      final longer = _audio(0)..segments.single.sourceEnd = 600.4;
      final file = _file([video, longer]);
      ProgramEdit(file, []).cut(500, 600);
      expect(_ranges(longer.segments), [(0.0, 500.0, 0.0)]);
      expect(_ranges(video.clips), [(0.0, 500.0, 0.0)]);
    });

    test('lanes emptied by a cut are reported', () {
      final short = _audio(0)..segments.single.sourceEnd = 50;
      final file = _file([_video(), short]);
      expect(ProgramEdit(file, []).cut(0, 60), [short]);
    });
  });

  test('clipAt finds the clip under the playhead', () {
    final clips = [_clip(kOpening, 0, 84, 0), _clip(kSource, 90, 600, 84)];
    expect(clipAt(clips, 10)?.path, kOpening);
    expect(clipAt(clips, 84)?.path, kSource);
    expect(clipAt(clips, 594), isNull);
  });

  test('pieces cut apart remember how much source there is', () {
    final pieces = [
      AudioSegment(
        source: const AudioSource(path: kSource, audioTypeIndex: 0),
        sourceStart: 0,
        sourceEnd: 600,
        timelineStart: 0,
        sourceDuration: 600,
      ),
    ];
    rippleDelete(pieces, 90, 120);
    splitSegment(pieces, pieces.last, 300);
    expect(pieces.map((p) => p.sourceDuration), everyElement(600));
  });

  test('a fresh file is an untouched program', () {
    expect(programUntouched(_file([_video(), _audio(0)])), isTrue);
  });
}
