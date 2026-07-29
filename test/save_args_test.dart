import 'package:audio_video_editor/models/tracks.dart';
import 'package:audio_video_editor/services/ffmpeg_service.dart';
import 'package:flutter_test/flutter_test.dart';

const kSource = '/tmp/video.mkv';

MediaTrack _video() => MediaTrack(
      streamIndex: 0,
      type: TrackType.video,
      typeIndex: 0,
      codec: 'H264',
      details: '',
      originalTitle: 'V',
      durationSeconds: 600,
    );

MediaTrack _audio(int streamIndex, int typeIndex, {double duration = 600}) {
  final track = MediaTrack(
    streamIndex: streamIndex,
    type: TrackType.audio,
    typeIndex: typeIndex,
    codec: 'AAC',
    details: '',
    originalTitle: 'A$typeIndex',
    durationSeconds: duration,
    channelLayout: 'stereo',
    language: 'por',
  );
  track.segments.add(AudioSegment(
    source: AudioSource(path: kSource, audioTypeIndex: typeIndex),
    sourceStart: 0,
    sourceEnd: duration,
    timelineStart: 0,
  ));
  return track;
}

MediaFileInfo _file(List<MediaTrack> tracks) => MediaFileInfo(
      path: kSource,
      formatName: 'matroska',
      durationSeconds: 600,
      sizeBytes: 0,
      tracks: tracks,
    );

void main() {
  final service = FfmpegService();

  group('buildSaveArgs', () {
    test('untouched tracks are stream-copied without filters', () {
      final args = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0), _audio(2, 1)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = args.args.join(' ');
      expect(joined,
          contains('-map 0:0 -map 0:a:0 -map 0:a:1 -map 0:t? -c copy'));
      expect(joined, isNot(contains('-filter_complex')));
      expect(joined, isNot(contains('aac')));
    });

    test('merged lane becomes a filter graph re-encoded to AAC', () {
      // First 3 minutes come from audio 1, the rest from audio 2 —
      // the user's "mesclar áudios" scenario.
      final a1 = _audio(1, 0);
      final a2 = _audio(2, 1);
      a1.segments.single.sourceEnd = 180;
      a1.segments.add(AudioSegment(
        source: const AudioSource(path: kSource, audioTypeIndex: 1),
        sourceStart: 180,
        sourceEnd: 600,
        timelineStart: 180,
      ));
      a2.removed = true;

      final args = service.buildSaveArgs(
        source: _file([_video(), a1, a2]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = args.args.join(' ');
      final filter = args.args[args.args.indexOf('-filter_complex') + 1];

      expect(filter, contains('[0:a:0]atrim=start=0.000:end=180.000'));
      expect(filter, contains('[0:a:1]atrim=start=180.000:end=600.000'));
      expect(filter, contains('adelay=180000:all=1'));
      expect(filter, contains('amix=inputs=2:duration=longest:normalize=0'));
      expect(filter, contains('aformat=channel_layouts=stereo'));
      expect(joined, contains('-map [lane0]'));
      expect(joined, contains('-c:a:0 aac'));
      // Removed track produced no output.
      expect(joined, isNot(contains('-map 0:a:1 ')));
    });

    test('single trimmed segment uses filter graph too', () {
      final a1 = _audio(1, 0);
      a1.segments.single
        ..sourceStart = 60
        ..sourceEnd = 300
        ..timelineStart = 30;

      final args = service.buildSaveArgs(
        source: _file([_video(), a1]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = args.args[args.args.indexOf('-filter_complex') + 1];
      expect(filter, contains('atrim=start=60.000:end=300.000'));
      expect(filter, contains('adelay=30000:all=1'));
      expect(filter, contains('anull[lane0]'));
    });

    test('whole-track delay keeps stream copy via -itsoffset', () {
      final a1 = _audio(1, 0);
      a1.segments.single.timelineStart = 2.5;

      final args = service.buildSaveArgs(
        source: _file([_video(), a1]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = args.args.join(' ');
      expect(joined, contains('-itsoffset 2.500 -i $kSource'));
      expect(joined, contains('-map 1:a:0'));
      expect(joined, isNot(contains('-filter_complex')));
    });

    test('trim-only start keeps stream copy via -ss', () {
      final a1 = _audio(1, 0);
      a1.segments.single.sourceStart = 4;

      final args = service.buildSaveArgs(
        source: _file([_video(), a1]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = args.args.join(' ');
      expect(joined, contains('-ss 4.000 -i $kSource'));
      expect(joined, isNot(contains('-filter_complex')));
    });

    test('subtitle offset uses a flagged duplicate input', () {
      final sub = MediaTrack(
        streamIndex: 2,
        type: TrackType.subtitle,
        typeIndex: 0,
        codec: 'SUBRIP',
        details: '',
        originalTitle: 'Legenda',
        durationSeconds: 600,
      )..offsetSeconds = 2;

      final args = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0), sub]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = args.args.join(' ');
      expect(joined, contains('-itsoffset 2.000 -i $kSource'));
      expect(joined, contains('-map 1:2'));
    });

    test('external audio and mp4 subtitle conversion', () {
      final external = ExternalTrack(
        path: '/tmp/extra.mp3',
        type: TrackType.audio,
        codec: 'MP3',
        details: '',
        title: 'Extra',
        durationSeconds: 300,
        channelLayout: 'stereo',
      );
      external.segments.add(AudioSegment(
        source: const AudioSource(path: '/tmp/extra.mp3', audioTypeIndex: 0),
        sourceStart: 0,
        sourceEnd: 300,
        timelineStart: 0,
      ));
      final subtitle = ExternalTrack(
        path: '/tmp/sub.srt',
        type: TrackType.subtitle,
        codec: 'SUBRIP',
        details: '',
        title: 'Legenda PT',
        durationSeconds: 0,
      );

      final args = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0)]),
        added: [external, subtitle],
        outputPath: '/tmp/out.mp4',
      );
      final joined = args.args.join(' ');
      expect(joined, contains('-map 1:a:0'));
      expect(joined, contains('-map 2:s:0'));
      expect(joined, contains('-c:s:0 mov_text'));
      expect(joined, contains('-movflags +faststart'));
      expect(joined, isNot(contains('-filter_complex')));
    });
  });

  group('splitSegment', () {
    AudioSegment seg({
      double sourceStart = 0,
      double sourceEnd = 100,
      double timelineStart = 0,
    }) =>
        AudioSegment(
          source: const AudioSource(path: kSource, audioTypeIndex: 0),
          sourceStart: sourceStart,
          sourceEnd: sourceEnd,
          timelineStart: timelineStart,
        );

    test('splits the given segment at t', () {
      final segments = [seg()];
      expect(splitSegment(segments, segments.single, 30), isTrue);
      expect(segments, hasLength(2));
      expect(segments[0].sourceStart, 0);
      expect(segments[0].sourceEnd, 30);
      expect(segments[0].timelineStart, 0);
      expect(segments[1].sourceStart, 30);
      expect(segments[1].sourceEnd, 100);
      expect(segments[1].timelineStart, 30);
    });

    test('accounts for timeline offset and source trim', () {
      final segments = [seg(sourceStart: 10, sourceEnd: 110, timelineStart: 50)];
      expect(splitSegment(segments, segments.single, 80), isTrue);
      expect(segments[0].sourceEnd, 40); // 10 + (80 - 50)
      expect(segments[1].sourceStart, 40);
      expect(segments[1].timelineStart, 80);
    });

    test('does nothing outside the segment', () {
      final segments = [seg()];
      expect(splitSegment(segments, segments.single, 150), isFalse);
      expect(segments, hasLength(1));
    });

    test('splits the requested segment, not an overlapping earlier one', () {
      final overlapping = seg(); // 0..100 on the timeline
      final target = seg(timelineStart: 20); // 20..120, overlaps
      final segments = [overlapping, target];
      expect(splitSegment(segments, target, 50), isTrue);
      expect(overlapping.sourceEnd, 100); // untouched
      expect(target.sourceEnd, 30); // 0 + (50 - 20)
      expect(segments, hasLength(3));
      expect(segments[2].timelineStart, 50);
    });
  });

  group('auto-merge', () {
    test('fragmentary lanes are merged into one output track', () {
      // User workflow: keep the first 3 minutes of audio 1 and the rest of
      // audio 2 — both lanes were cut, so they auto-merge on save.
      final a1 = _audio(1, 0);
      final a2 = _audio(2, 1);
      a1.segments.single.sourceEnd = 180;
      a2.segments.single
        ..sourceStart = 180
        ..timelineStart = 180;

      final result = service.buildSaveArgs(
        source: _file([_video(), a1, a2]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');
      final filter =
          result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, contains('[0:a:0]atrim=start=0.000:end=180.000'));
      expect(filter, contains('[0:a:1]atrim=start=180.000:end=600.000'));
      expect(filter, contains('adelay=180000:all=1'));
      expect(filter, contains('amix=inputs=2'));
      expect(RegExp(r'-map \[lane').allMatches(joined).length, 1);
      expect(joined, isNot(contains('-map 0:a:')));
      expect(result.warnings.any((w) => w.contains('mescladas')), isTrue);
    });

    test('whole lanes (delayed or untouched) stay out of the merge', () {
      final a1 = _audio(1, 0)..segments.single.sourceEnd = 180;
      final a2 = _audio(2, 1)
        ..segments.single.sourceStart = 180
        ..segments.single.timelineStart = 180;
      final untouched = _audio(3, 2);
      final delayed = ExternalTrack(
        path: '/tmp/dub.mp3',
        type: TrackType.audio,
        codec: 'MP3',
        details: '',
        title: 'Dublagem',
        durationSeconds: 600,
        channelLayout: 'stereo',
      );
      delayed.segments.add(AudioSegment(
        source: const AudioSource(path: '/tmp/dub.mp3', audioTypeIndex: 0),
        sourceStart: 0,
        sourceEnd: 600,
        timelineStart: 2,
      ));

      final result = service.buildSaveArgs(
        source: _file([_video(), a1, a2, untouched]),
        added: [delayed],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');

      // merged lane + untouched copy + delayed external copy = 3 audio outs
      expect(RegExp(r'-map \[lane').allMatches(joined).length, 1);
      expect(joined, contains('-map 0:a:2'));
      expect(joined, contains('-itsoffset 2.000 -i /tmp/dub.mp3'));
    });
  });

  group('container compatibility', () {
    MediaTrack subTrack(String codec) => MediaTrack(
          streamIndex: 2,
          type: TrackType.subtitle,
          typeIndex: 0,
          codec: codec,
          details: '',
          originalTitle: 'Legenda',
          durationSeconds: 600,
        );

    test('bitmap subtitle is dropped with a warning when saving MP4', () {
      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0), subTrack('HDMV_PGS_SUBTITLE')]),
        added: [],
        outputPath: '/tmp/out.mp4',
      );
      final joined = result.args.join(' ');
      expect(joined, isNot(contains('-map 0:2')));
      expect(joined, isNot(contains('mov_text')));
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single, contains('Legenda'));
    });

    test('bitmap subtitle is copied untouched into MKV', () {
      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0), subTrack('HDMV_PGS_SUBTITLE')]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');
      expect(joined, contains('-map 0:2'));
      expect(joined, isNot(contains('-c:s:0')));
      expect(result.warnings, isEmpty);
    });

    test('exotic text subtitle is converted to SRT for MKV', () {
      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0), subTrack('MICRODVD')]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      expect(result.args.join(' '), contains('-c:s:0 srt'));
    });

    test('MKV output keeps attachments (fonts)', () {
      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      expect(result.args.join(' '), contains('-map 0:t?'));
    });

    test('MP4 output does not map attachments', () {
      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mp4',
      );
      expect(result.args.join(' '), isNot(contains('-map 0:t?')));
    });

    test('hasStreams is false when everything was removed', () {
      final video = _video()..removed = true;
      final audio = _audio(1, 0)..removed = true;
      final result = service.buildSaveArgs(
        source: _file([video, audio]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      expect(result.hasStreams, isFalse);
    });

    test('edited external audio goes through the filter graph', () {
      final external = ExternalTrack(
        path: '/tmp/extra.mp3',
        type: TrackType.audio,
        codec: 'MP3',
        details: '',
        title: 'Extra',
        durationSeconds: 300,
        channelLayout: 'stereo',
      );
      external.segments.add(AudioSegment(
        source: const AudioSource(path: '/tmp/extra.mp3', audioTypeIndex: 0),
        sourceStart: 10,
        sourceEnd: 200,
        timelineStart: 5,
      ));

      final result = service.buildSaveArgs(
        source: _file([_video(), _audio(1, 0)]),
        added: [external],
        outputPath: '/tmp/out.mkv',
      );
      final filter =
          result.args[result.args.indexOf('-filter_complex') + 1];
      expect(filter, contains('[1:a:0]atrim=start=10.000:end=200.000'));
      expect(filter, contains('adelay=5000:all=1'));
      expect(result.args.join(' '), contains('-c:a:1 aac'));
    });
  });
}
