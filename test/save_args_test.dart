import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/ffmpeg_service.dart';
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

MediaTrack _audio(int streamIndex, int typeIndex,
    {double duration = 600, bool isDefault = false}) {
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
    isDefault: isDefault,
  );
  track.segments.add(AudioSegment(
    source: AudioSource(path: kSource, audioTypeIndex: typeIndex),
    sourceStart: 0,
    sourceEnd: duration,
    timelineStart: 0,
  ));
  return track;
}

VideoClip _clip(String path, double start, double end,
        {int width = 1432,
        int height = 1080,
        String rate = '2997/100',
        int sarNum = 1,
        int sarDen = 1}) =>
    VideoClip(
      path: path,
      streamTypeIndex: 0,
      width: width,
      height: height,
      rate: rate,
      sarNum: sarNum,
      sarDen: sarDen,
      sourceStart: start,
      sourceEnd: end,
      timelineStart: 0,
    );

MediaTrack _programVideo() =>
    _video()..clips.add(_clip(kSource, 0, 600));

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
      expect(filter, contains('asetpts=N/SR/TB[lane0]'));
    });

    test('a piece keeps its place in the source, even in a late stream', () {
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
      expect(filter, contains('[0:a:0]atrim=start=60.000:end=300.000,'
          'asetpts=PTS-60.000/TB,aresample=48000:first_pts=0,'
          'aformat=channel_layouts=stereo,adelay=30000:all=1[l0s0]'));
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
      expect(joined, isNot(contains('-copypriorss')));
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

    test('a copy from a -ss input drops what came before the cut', () {
      final file = _file([_programVideo(), _audio(1, 0)]);
      ProgramEdit(file, []).cut(0, 90);

      final joined = service
          .buildSaveArgs(source: file, added: [], outputPath: '/tmp/out.mkv')
          .args
          .join(' ');
      expect(joined, contains('-ss 90.000 -i $kSource'));
      expect(joined, contains('-map 1:a:0'));
      expect(joined, contains('-copypriorss:a:0 0'));
    });

    test('a subtitle moved earlier drops the cues before the start', () {
      final sub = MediaTrack(
        streamIndex: 2,
        type: TrackType.subtitle,
        typeIndex: 0,
        codec: 'SUBRIP',
        details: '',
        originalTitle: 'Legenda',
        durationSeconds: 600,
      )..offsetSeconds = -2;
      final external = ExternalTrack(
        path: '/tmp/sub.srt',
        type: TrackType.subtitle,
        codec: 'SUBRIP',
        details: '',
        title: 'Legenda PT',
        durationSeconds: 0,
      )..offsetSeconds = -1.5;

      final joined = service
          .buildSaveArgs(
            source: _file([_video(), _audio(1, 0), sub]),
            added: [external],
            outputPath: '/tmp/out.mkv',
          )
          .args
          .join(' ');
      expect(joined, contains('-ss 2.000 -i $kSource'));
      expect(joined, contains('-map 1:2'));
      expect(joined, contains('-copypriorss:s:0 0'));
      expect(joined, contains('-ss 1.500 -i /tmp/sub.srt'));
      expect(joined, contains('-copypriorss:s:1 0'));
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

    test('a whole song marked to merge fills the gap of a cut track', () {
      // Abertura inteira no começo, a dublagem cortada depois dela.
      final dub = _audio(1, 0)
        ..segments.single.sourceStart = 90
        ..segments.single.timelineStart = 90;
      final opening = ExternalTrack(
        path: '/tmp/abertura.mp3',
        type: TrackType.audio,
        codec: 'MP3',
        details: '',
        title: 'Abertura',
        durationSeconds: 84,
        channelLayout: 'stereo',
      )..merge = true;
      opening.segments.add(AudioSegment(
        source: const AudioSource(path: '/tmp/abertura.mp3', audioTypeIndex: 0),
        sourceStart: 0,
        sourceEnd: 84,
        timelineStart: 0,
      ));

      final result = service.buildSaveArgs(
        source: _file([_video(), dub]),
        added: [opening],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(RegExp(r'-map \[lane').allMatches(joined).length, 1);
      expect(joined, isNot(contains('-map 2:a:0')));
      expect(filter, contains('[1:a:0]atrim=start=0.000:end=84.000'));
      expect(filter,
          contains('amix=inputs=2:duration=longest:normalize=0,asetpts=N/SR/TB'));
      expect(result.warnings.single, contains('"Abertura"'));
    });

    test('a cut track marked to stay separate keeps its own track', () {
      final a1 = _audio(1, 0)..segments.single.sourceEnd = 180;
      final a2 = _audio(2, 1)
        ..segments.single.sourceStart = 180
        ..segments.single.timelineStart = 180
        ..merge = false;

      final result = service.buildSaveArgs(
        source: _file([_video(), a1, a2]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, isNot(contains('amix')));
      expect(RegExp(r'-map \[lane').allMatches(result.args.join(' ')).length,
          2);
      expect(result.warnings, isEmpty);
    });
  });

  group('default audio', () {
    ExternalTrack dub({bool? merge, double at = 0}) => ExternalTrack(
          path: '/tmp/dub.mp3',
          type: TrackType.audio,
          codec: 'MP3',
          details: '',
          title: 'Dublagem',
          durationSeconds: 600,
          channelLayout: 'stereo',
        )
          ..merge = merge
          ..segments.add(AudioSegment(
            source: const AudioSource(path: '/tmp/dub.mp3', audioTypeIndex: 0),
            sourceStart: at,
            sourceEnd: 600,
            timelineStart: at,
          ));

    String saved(List<MediaTrack> tracks,
            {List<ExternalTrack> added = const []}) =>
        service
            .buildSaveArgs(
              source: _file(tracks),
              added: added,
              outputPath: '/tmp/out.mkv',
            )
            .args
            .join(' ');

    test('is the flagged track left, else the first, as in the preview', () {
      final first = _audio(1, 0);
      final flagged = _audio(2, 1, isDefault: true);
      final added = dub();

      expect(defaultAudioLane(_file([_video(), first, flagged]), [added]),
          same(flagged));
      flagged.removed = true;
      expect(defaultAudioLane(_file([_video(), first, flagged]), [added]),
          same(first));
      expect(defaultAudioLane(_file([_video()]), [added]), same(added));
      expect(defaultAudioLane(_file([_video()]), []), isNull);
    });

    test('an edited default track is still the one players open', () {
      // a faixa que passa pelo filtro perde a marca do original
      final edited = _audio(2, 1, isDefault: true)
        ..segments.single.sourceEnd = 300;

      final joined = saved([_video(), _audio(1, 0), edited]);
      expect(joined, contains('-map 0:a:0 -map [lane0]'));
      expect(joined, contains('-disposition:a:0 -default'));
      expect(joined, contains('-disposition:a:1 +default'));
    });

    test('without a flagged track the first one left is the default', () {
      final removed = _audio(1, 0, isDefault: true)..removed = true;

      final joined = saved([_video(), removed, _audio(2, 1), _audio(3, 2)],
          added: [dub()]);
      expect(joined, contains('-disposition:a:0 +default'));
      expect(joined, contains('-disposition:a:1 -default'));
      expect(joined, contains('-disposition:a:2 -default'));
      expect(joined, isNot(contains('-disposition:a:3')));
    });

    test('a default track that merges makes the merged track the default', () {
      final cut = _audio(2, 1, isDefault: true)
        ..segments.single.sourceEnd = 180;

      final joined = saved([_video(), _audio(1, 0), cut],
          added: [dub(merge: true, at: 180)]);
      expect(RegExp(r'-map \[lane').allMatches(joined).length, 1);
      expect(joined, contains('-disposition:a:0 -default'));
      expect(joined, contains('-disposition:a:1 +default'));
      expect(joined, isNot(contains('-disposition:a:2')));
    });

    test('a cut subtitle keeps the default flag of its track', () {
      final flagged = MediaTrack(
        streamIndex: 2,
        type: TrackType.subtitle,
        typeIndex: 0,
        codec: 'ASS',
        details: '',
        originalTitle: 'Placas',
        durationSeconds: 600,
        isDefault: true,
      );
      final plain = MediaTrack(
        streamIndex: 3,
        type: TrackType.subtitle,
        typeIndex: 1,
        codec: 'ASS',
        details: '',
        originalTitle: 'Completa',
        durationSeconds: 600,
      );
      final file = _file([_programVideo(), _audio(1, 0), flagged, plain]);
      ProgramEdit(file, []).cut(0, 90);

      final joined = service
          .buildSaveArgs(
            source: file,
            added: [],
            outputPath: '/tmp/out.mkv',
            subtitleFiles: {
              flagged: '/tmp/placas.ass',
              plain: '/tmp/completa.ass',
            },
          )
          .args
          .join(' ');
      expect(joined, contains('-disposition:s:0 +default'));
      expect(joined, isNot(contains('-disposition:s:1')));
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

  group('program edits', () {
    test('a cut program is rebuilt clip by clip and re-encoded in AV1', () {
      final video = _programVideo();
      final file = _file([video, _audio(1, 0)]);
      ProgramEdit(file, []).cut(0, 90);

      final result = service.buildSaveArgs(
        source: file,
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(joined, contains('-ss 90.000 -i $kSource'));
      expect(filter, contains('[1:v:0]trim=duration=510.000,setpts=PTS-STARTPTS,'
          'setsar=1/1,fps=2997/100,tpad=stop=-1:stop_mode=clone,'
          'trim=end_frame=15285[pv0]'));
      expect(filter, contains('[pv0]concat=n=1:v=1:a=0[program]'));
      expect(joined, contains('-map [program]'));
      expect(joined, contains('-c:v:0 libsvtav1 -preset:v:0 8 -crf:v:0 30'));
      expect(joined, contains('-map_chapters -1'));
      expect(result.warnings.first, contains('AV1'));
    });

    test('an inserted video is fitted into the program frame', () {
      final video = _programVideo();
      final file = _file([video, _audio(1, 0)]);
      ProgramEdit(file, []).insert(
        _clip('/tmp/abertura.mp4', 0, 84, width: 1920, height: 1080),
        at: 0,
        audio: const AudioSource(path: '/tmp/abertura.mp4', audioTypeIndex: 0),
        audioDuration: 84,
      );

      final result = service.buildSaveArgs(
        source: file,
        added: [],
        outputPath: '/tmp/out.mkv',
        videoFormat: VideoFormat.hevc,
      );
      final joined = result.args.join(' ');
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, contains(
          'scale=1432:806,pad=1432:1080:0:137,setsar=1/1,fps=2997/100,'
          'tpad=stop=-1:stop_mode=clone,trim=end_frame=2518[pv0]'));
      expect(filter, contains('[pv0][pv1]concat=n=2:v=1:a=0[program]'));
      expect(filter, contains('[3:a:0]atrim=start=0.000:end=84.000'));
      expect(joined, contains('-c:v:0 libx265'));
    });

    test('a gap before the first clip is black inside the clip chain', () {
      final video = _video()
        ..clips.add(_clip(kSource, 0, 600, sarNum: 32, sarDen: 27)
          ..timelineStart = 2.5);

      final result = service.buildSaveArgs(
        source: _file([video, _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, contains('[1:v:0]trim=duration=600.000,'
          'setpts=PTS-STARTPTS,setsar=32/27,fps=2997/100,'
          'tpad=start=75:color=black:stop=-1:stop_mode=clone,'
          'trim=end_frame=18057[pv0]'));
      expect(filter, isNot(contains('color=c=')));
      expect(filter, contains('[pv0]concat=n=1:v=1:a=0[program]'));
    });

    test('a gap between two clips is black and the audio stays whole', () {
      final video = _programVideo();
      splitSegment(video.clips, video.clips.single, 300);
      video.clips.last.timelineStart = 310;

      final result = service.buildSaveArgs(
        source: _file([video, _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final joined = result.args.join(' ');
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(joined, contains('-ss 300.000 -i $kSource'));
      expect(filter, contains('fps=2997/100,tpad=stop=-1:stop_mode=clone,'
          'trim=end_frame=8991[pv0]'));
      expect(filter, contains('[2:v:0]trim=duration=300.000,'
          'setpts=PTS-STARTPTS,setsar=1/1,fps=2997/100,'
          'tpad=start=300:color=black:stop=-1:stop_mode=clone,'
          'trim=end_frame=9291[pv1]'));
      expect(filter, contains('[pv0][pv1]concat=n=2:v=1:a=0[program]'));
      expect(joined, contains('-map 0:a:0'));
    });

    test('gaps are counted on the program frames, so they never add up', () {
      final video = _video()
        ..clips.addAll([
          for (var i = 0; i < 4; i++)
            _clip(kSource, 3.0 * i, 3.0 * (i + 1), rate: '25/1')
              ..timelineStart = 3.41 * i,
        ]);

      final result = service.buildSaveArgs(
        source: _file([video, _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, contains('fps=25/1,tpad=stop=-1:stop_mode=clone,'
          'trim=end_frame=75[pv0]'));
      expect(filter, contains('fps=25/1,tpad=start=11:color=black:'
          'stop=-1:stop_mode=clone,trim=end_frame=86[pv1]'));
      expect(filter, contains('fps=25/1,tpad=start=10:color=black:'
          'stop=-1:stop_mode=clone,trim=end_frame=85[pv2]'));
      expect(filter, contains('fps=25/1,tpad=start=10:color=black:'
          'stop=-1:stop_mode=clone,trim=end_frame=85[pv3]'));
    });

    test('a gap between two program frames leaves no black', () {
      final video = _video()
        ..clips.addAll([
          _clip(kSource, 0, 3.01, rate: '25/1'),
          _clip(kSource, 3.03, 6, rate: '25/1')..timelineStart = 3.03,
        ]);

      final result = service.buildSaveArgs(
        source: _file([video, _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, isNot(contains('tpad=start')));
      expect(filter, contains('trim=end_frame=76[pv0]'));
      expect(filter, contains('trim=end_frame=74[pv1]'));
    });

    test('clips less than 1 ms apart touch, with no black between them', () {
      final video = _programVideo();
      splitSegment(video.clips, video.clips.single, 300);
      video.clips.last.timelineStart = 300.0009;

      final result = service.buildSaveArgs(
        source: _file([video, _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      final filter = result.args[result.args.indexOf('-filter_complex') + 1];

      expect(filter, isNot(contains('tpad=start')));
      expect(filter, contains('trim=end_frame=8991[pv0]'));
      expect(filter, contains('trim=end_frame=8992[pv1]'));
      expect(filter, contains('[pv0][pv1]concat=n=2:v=1:a=0[program]'));
    });

    test('compacting an untouched file keeps it whole but shrinks it', () {
      final flac = MediaTrack(
        streamIndex: 1,
        type: TrackType.audio,
        typeIndex: 0,
        codec: 'FLAC',
        details: '',
        originalTitle: '',
        durationSeconds: 600,
      )..segments.add(AudioSegment(
          source: const AudioSource(path: kSource, audioTypeIndex: 0),
          sourceStart: 0,
          sourceEnd: 600,
          timelineStart: 0,
        ));

      final result = service.buildSaveArgs(
        source: _file([_programVideo(), flac]),
        added: [],
        outputPath: '/tmp/out.mkv',
        videoFormat: VideoFormat.av1,
      );
      final joined = result.args.join(' ');

      expect(joined, isNot(contains('-filter_complex')));
      expect(joined, contains('-map 0:0'));
      expect(joined, contains('-c:v:0 libsvtav1'));
      expect(joined, contains('-c:a:0 aac -b:a:0 256k'));
      expect(joined, isNot(contains('-map_chapters')));
      expect(result.warnings.last, contains('AAC 256'));
    });

    test('keeping the format of an untouched file copies everything', () {
      final result = service.buildSaveArgs(
        source: _file([_programVideo(), _audio(1, 0)]),
        added: [],
        outputPath: '/tmp/out.mkv',
      );
      expect(result.args.join(' '), isNot(contains('libsvtav1')));
      expect(result.warnings, isEmpty);
    });

    test('a cut subtitle comes from its rewritten file', () {
      final sub = MediaTrack(
        streamIndex: 2,
        type: TrackType.subtitle,
        typeIndex: 0,
        codec: 'ASS',
        details: '',
        originalTitle: 'Kyoshiro',
        durationSeconds: 600,
        language: 'por',
      );
      final file = _file([_programVideo(), _audio(1, 0), sub]);
      ProgramEdit(file, []).cut(0, 90);

      expect(FfmpegService.subtitlesToRetime(file, []), [sub]);
      final result = service.buildSaveArgs(
        source: file,
        added: [],
        outputPath: '/tmp/out.mkv',
        subtitleFiles: {sub: '/tmp/cortada.ass'},
      );
      final joined = result.args.join(' ');
      expect(joined, contains('-i /tmp/cortada.ass'));
      expect(RegExp(r'-map \d+:s:0').hasMatch(joined), isTrue);
      expect(joined, contains('language=por'));
    });

    test('a cut bitmap subtitle is dropped with a warning', () {
      final pgs = MediaTrack(
        streamIndex: 2,
        type: TrackType.subtitle,
        typeIndex: 0,
        codec: 'HDMV_PGS_SUBTITLE',
        details: '',
        originalTitle: 'PGS',
        durationSeconds: 600,
      );
      final file = _file([_programVideo(), _audio(1, 0), pgs]);
      ProgramEdit(file, []).cut(0, 90);

      expect(FfmpegService.subtitlesToRetime(file, []), isEmpty);
      final warnings = service.saveWarnings(
          source: file, added: [], outputPath: '/tmp/out.mkv');
      expect(warnings.any((w) => w.contains('"PGS"')), isTrue);
    });
  });
}
