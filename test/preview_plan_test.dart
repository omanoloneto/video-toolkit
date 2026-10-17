import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/preview_plan.dart';

const kSource = '/v/episode.mkv';
const kOpening = '/v/opening.mp4';
const kDub = '/v/dub.mp3';
const kSilence = '/c/silence.flac';
const kBlack = '/c/black.mkv';

AudioSegment _segment(
        String path, int typeIndex, double start, double end, double at) =>
    AudioSegment(
      source: AudioSource(path: path, audioTypeIndex: typeIndex),
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
    );

VideoClip _clip(String path, double start, double end, double at) => VideoClip(
      path: path,
      streamTypeIndex: 0,
      width: 1920,
      height: 1080,
      rate: '24000/1001',
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
    );

MediaTrack _video({String path = kSource}) => MediaTrack(
      streamIndex: 0,
      type: TrackType.video,
      typeIndex: 0,
      codec: 'H264',
      details: '',
      originalTitle: '',
      durationSeconds: 20,
    )..clips.add(_clip(path, 0, 20, 0));

MediaTrack _audio(int typeIndex, {String path = kSource}) => MediaTrack(
      streamIndex: typeIndex + 1,
      type: TrackType.audio,
      typeIndex: typeIndex,
      codec: 'FLAC',
      details: '',
      originalTitle: '',
      durationSeconds: 20,
    )..segments.add(_segment(path, typeIndex, 0, 20, 0));

ExternalTrack _dub(double duration, {bool? merge}) => ExternalTrack(
      path: kDub,
      type: TrackType.audio,
      codec: 'MP3',
      details: '',
      title: 'Dublagem',
      durationSeconds: duration,
    )
      ..merge = merge
      ..segments.add(_segment(kDub, 0, 0, duration, 0));

MediaFileInfo _file(List<MediaTrack> tracks, {String path = kSource}) =>
    MediaFileInfo(
      path: path,
      formatName: 'matroska',
      durationSeconds: 20,
      sizeBytes: 0,
      tracks: tracks,
    );

String? _copy(AudioSource source) => switch (source.path) {
      kSource => '/c/${source.audioTypeIndex}.mka',
      kOpening => '/c/op.mka',
      _ => '/c/dub.mka',
    };

PreviewPlan _plan(
  MediaFileInfo file, {
  List<ExternalTrack> added = const [],
  Object? monitor,
  String? Function(AudioSource source) audioFile = _copy,
  String? silenceFile = kSilence,
  String? blackFile = kBlack,
  double silenceLength = 600,
  double blackLength = 600,
}) =>
    buildPreviewPlan(
      file: file,
      added: added,
      monitor: monitor,
      audioFile: audioFile,
      silenceFile: silenceFile,
      blackFile: blackFile,
      silenceLength: silenceLength,
      blackLength: blackLength,
    );

void _expectEdl(PreviewPlan plan, List<String> lines, {bool hasAudio = true}) {
  expect(plan, isA<EdlPreview>());
  final edl = plan as EdlPreview;
  expect(edl.edl.split('\n'), [...lines, '']);
  expect(edl.hasAudio, hasAudio);
}

const _audioGroup = ['!new_stream', '!no_chapters', '!track_meta,lang=zxx'];
const _wholeVideo = [
  '# mpv EDL v0',
  '!no_chapters',
  '%14%/v/episode.mkv,0.000000,20.000000,layout=this',
];

void main() {
  group('audio lanes', () {
    test('come out like the save: the file ones not removed, then the added',
        () {
      final first = _audio(0);
      final removed = _audio(1)..removed = true;
      final third = _audio(2);
      final dub = _dub(20);
      final subtitle = ExternalTrack(
        path: '/v/sub.srt',
        type: TrackType.subtitle,
        codec: 'SUBRIP',
        details: '',
        title: 'Legenda',
        durationSeconds: 20,
      );

      expect(
        audioLanesInOrder(
            _file([_video(), first, removed, third]), [subtitle, dub]),
        [first, third, dub],
      );
    });

    test('a lane plays with the whole merge only when two or more merge', () {
      final cut = _audio(0)..segments.single.sourceEnd = 8;
      final whole = _audio(1);
      final dub = _dub(12, merge: true)..segments.single.timelineStart = 8;
      final file = _file([_video(), cut, whole]);

      expect(audioOutputOf(cut, file, [dub]), [cut, dub]);
      expect(audioOutputOf(dub, file, [dub]), [cut, dub]);
      expect(audioOutputOf(whole, file, [dub]), [whole]);

      dub.merge = false;
      expect(audioOutputOf(cut, file, [dub]), [cut]);
    });
  });

  group('the file itself', () {
    test('an untouched file plays with its first audio track', () {
      final file = _file([_video(), _audio(0), _audio(1)]);
      expect(_plan(file), const SourcePreview(kSource, 1));
    });

    test('needs no copy, silence nor black', () {
      final file = _file([_video(), _audio(0)]);
      expect(
          _plan(file,
              audioFile: (_) => null, silenceFile: null, blackFile: null),
          const SourcePreview(kSource, 1));
    });

    test('monitoring the second track picks its mpv id', () {
      final second = _audio(1);
      final file = _file([_video(), _audio(0), second]);
      expect(_plan(file, monitor: second), const SourcePreview(kSource, 2));
    });

    test('with the first track removed the second is the default', () {
      final first = _audio(0)..removed = true;
      final file = _file([_video(), first, _audio(1)]);
      expect(_plan(file), const SourcePreview(kSource, 2));
      // monitorar uma faixa que saiu volta pro padrão
      expect(_plan(file, monitor: first), const SourcePreview(kSource, 2));
    });

    test('a file without audio plays muted', () {
      expect(_plan(_file([_video()])), const SourcePreview(kSource, null));
    });

    test('without a choice it plays the track players pick: the default one',
        () {
      final file = _file([
        _video(),
        _audio(0),
        MediaTrack(
          streamIndex: 2,
          type: TrackType.audio,
          typeIndex: 1,
          codec: 'AAC',
          details: '',
          originalTitle: '',
          durationSeconds: 20,
          isDefault: true,
        )..segments.add(_segment(kSource, 1, 0, 20, 0)),
      ]);
      expect(_plan(file), const SourcePreview(kSource, 2));
    });
  });

  group('program', () {
    test('a cut program plays its clips and the audio follows them', () {
      final second = _audio(1);
      final file = _file([_video(), _audio(0), second]);
      ProgramEdit(file, []).cut(5, 10);

      _expectEdl(_plan(file), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,5.000000,layout=this',
        '%14%/v/episode.mkv,10.000000,10.000000',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,5.000000',
        '%8%/c/0.mka,10.000000,10.000000',
      ]);
      _expectEdl(_plan(file, monitor: second), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,5.000000,layout=this',
        '%14%/v/episode.mkv,10.000000,10.000000',
        ..._audioGroup,
        '%8%/c/1.mka,0.000000,5.000000',
        '%8%/c/1.mka,10.000000,10.000000',
      ]);
    });

    test('splitting without changing what plays keeps the same preview', () {
      final audio = _audio(0);
      final file = _file([_video(), audio]);
      ProgramEdit(file, []).cut(5, 10);
      final before = _plan(file);

      final clips = file.mainVideo!.clips;
      splitSegment(clips, clips.last, 12);
      splitSegment(audio.segments, audio.segments.last, 8);

      expect(clips, hasLength(3));
      expect(audio.segments, hasLength(3));
      expect(_plan(file), before);
    });

    test('an inserted video shows in the image and in the sound', () {
      final file = _file([_video(), _audio(0)]);
      ProgramEdit(file, []).insert(
        _clip(kOpening, 0, 3, 0),
        at: 0,
        audio: const AudioSource(path: kOpening, audioTypeIndex: 0),
        audioDuration: 2.5,
      );

      _expectEdl(_plan(file), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/opening.mp4,0.000000,3.000000',
        '%14%/v/episode.mkv,0.000000,20.000000,layout=this',
        ..._audioGroup,
        '%9%/c/op.mka,0.000000,2.500000',
        '%15%/c/silence.flac,0.000000,0.500000',
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
    });

    test('without audio lanes the edited program plays muted', () {
      final file = _file([_video()]);
      ProgramEdit(file, []).cut(5, 10);

      _expectEdl(
        _plan(file, audioFile: (_) => null, silenceFile: null, blackFile: null),
        [
          '# mpv EDL v0',
          '!no_chapters',
          '%14%/v/episode.mkv,0.000000,5.000000,layout=this',
          '%14%/v/episode.mkv,10.000000,10.000000',
        ],
        hasAudio: false,
      );
    });

    test('paths carry their length in bytes', () {
      const path = '/v/Animação, Ep=1/Episódio.mkv';
      final file =
          _file([_video(path: path), _audio(0, path: path)], path: path);
      ProgramEdit(file, []).cut(5, 10);

      _expectEdl(_plan(file, audioFile: (_) => '/c/a,b=ç.mka'), [
        '# mpv EDL v0',
        '!no_chapters',
        '%33%$path,0.000000,5.000000,layout=this',
        '%33%$path,10.000000,10.000000',
        ..._audioGroup,
        '%13%/c/a,b=ç.mka,0.000000,5.000000',
        '%13%/c/a,b=ç.mka,10.000000,10.000000',
      ]);
    });
  });

  group('video gaps', () {
    MediaTrack videoOf(List<VideoClip> clips) => _video()
      ..clips.clear()
      ..clips.addAll(clips);

    test('a gap before the first clip shows black', () {
      final video = videoOf([_clip(kSource, 0, 20, 2)]);

      _expectEdl(_plan(_file([video, _audio(0)])), [
        '# mpv EDL v0',
        '!no_chapters',
        '%12%/c/black.mkv,0.000000,2.000000',
        '%14%/v/episode.mkv,0.000000,20.000000,layout=this',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
      _expectEdl(
        _plan(_file([video])),
        [
          '# mpv EDL v0',
          '!no_chapters',
          '%12%/c/black.mkv,0.000000,2.000000',
          '%14%/v/episode.mkv,0.000000,20.000000,layout=this',
        ],
        hasAudio: false,
      );
    });

    test('a gap between clips shows black while the sound goes on', () {
      final video =
          videoOf([_clip(kSource, 0, 4, 0), _clip(kSource, 4, 20, 6)]);

      _expectEdl(_plan(_file([video, _audio(0)])), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,4.000000,layout=this',
        '%12%/c/black.mkv,0.000000,2.000000',
        '%14%/v/episode.mkv,4.000000,16.000000',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
    });

    test('a long gap takes several pieces of the black file', () {
      final video =
          videoOf([_clip(kSource, 0, 2, 0), _clip(kSource, 2, 20, 12)]);

      _expectEdl(_plan(_file([video, _audio(0)]), blackLength: 4), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,2.000000,layout=this',
        '%12%/c/black.mkv,0.000000,4.000000',
        '%12%/c/black.mkv,0.000000,4.000000',
        '%12%/c/black.mkv,0.000000,2.000000',
        '%14%/v/episode.mkv,2.000000,18.000000',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
    });

    test('clips that touch need no black', () {
      // menos de um décimo de milissegundo entre eles ainda é encostar
      final video = videoOf(
          [_clip(kSource, 0, 4, 0), _clip(kSource, 10, 20, 4.00005)]);

      _expectEdl(_plan(_file([video, _audio(0)]), blackFile: null), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,4.000000,layout=this',
        '%14%/v/episode.mkv,10.000000,10.000000',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,14.000050',
      ]);
    });

    test('the black file must last at least a tenth of a millisecond', () {
      final video = videoOf([_clip(kSource, 0, 20, 2)]);
      for (final length in [0.0, -600.0, double.nan, 0.00005]) {
        expect(() => _plan(_file([video]), blackLength: length),
            throwsArgumentError,
            reason: 'blackLength $length');
      }
    });
  });

  group('audio', () {
    test('a gap in the lane is filled with silence', () {
      final lane = _audio(0);
      lane.segments
        ..clear()
        ..addAll([
          _segment(kSource, 0, 0, 4, 0),
          _segment(kSource, 0, 5, 20, 5),
        ]);

      _expectEdl(_plan(_file([_video(), lane])), [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,4.000000',
        '%15%/c/silence.flac,0.000000,1.000000',
        '%8%/c/0.mka,5.000000,15.000000',
      ]);
    });

    test('a delayed lane starts in silence and stops with the program', () {
      final lane = _audio(0)..segments.single.timelineStart = 2;

      _expectEdl(_plan(_file([_video(), lane])), [
        ..._wholeVideo,
        ..._audioGroup,
        '%15%/c/silence.flac,0.000000,2.000000',
        '%8%/c/0.mka,0.000000,18.000000',
      ]);
    });

    test('a long gap takes several pieces of the silent file', () {
      final lane = _audio(0);
      lane.segments
        ..clear()
        ..addAll([
          _segment(kSource, 0, 0, 2, 0),
          _segment(kSource, 0, 12, 20, 12),
        ]);

      _expectEdl(_plan(_file([_video(), lane]), silenceLength: 4), [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,2.000000',
        '%15%/c/silence.flac,0.000000,4.000000',
        '%15%/c/silence.flac,0.000000,4.000000',
        '%15%/c/silence.flac,0.000000,2.000000',
        '%8%/c/0.mka,12.000000,8.000000',
      ]);
    });

    test('a piece starting before zero is cut at zero', () {
      final lane = _audio(0)..segments.single.timelineStart = -3;

      _expectEdl(_plan(_file([_video(), lane])), [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,3.000000,17.000000',
      ]);
    });

    test('overlaps play the latest start and the earlier piece resumes', () {
      final lane = _audio(0);
      lane.segments
        ..clear()
        ..addAll([
          _segment(kSource, 0, 0, 10, 0),
          _segment(kSource, 1, 6, 8, 3),
          _segment(kSource, 1, 20, 24, 9),
        ]);

      _expectEdl(_plan(_file([_video(), lane])), [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,3.000000',
        '%8%/c/1.mka,6.000000,2.000000',
        '%8%/c/0.mka,5.000000,4.000000',
        '%8%/c/1.mka,20.000000,4.000000',
      ]);
    });

    test('merged lanes play together in one audio group', () {
      final cut = _audio(0)..segments.single.sourceEnd = 8;
      final whole = _audio(1);
      final dub = _dub(12, merge: true)..segments.single.timelineStart = 8;
      final file = _file([_video(), cut, whole]);
      final merged = [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,8.000000',
        '%10%/c/dub.mka,0.000000,12.000000',
      ];

      _expectEdl(_plan(file, added: [dub]), merged);
      _expectEdl(_plan(file, added: [dub], monitor: dub), merged);
      expect(_plan(file, added: [dub], monitor: whole),
          const SourcePreview(kSource, 2));
    });

    test('an added lane is cut at the end of the program', () {
      final file = _file([_video(), _audio(0)]);
      ProgramEdit(file, []).cut(5, 10);
      final dub = _dub(30);

      _expectEdl(_plan(file, added: [dub], monitor: dub), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000000,5.000000,layout=this',
        '%14%/v/episode.mkv,10.000000,10.000000',
        ..._audioGroup,
        '%10%/c/dub.mka,0.000000,15.000000',
      ]);
    });

    test('an added lane on an untouched program still needs the program', () {
      final dub = _dub(8);

      _expectEdl(
          _plan(_file([_video(), _audio(0)]), added: [dub], monitor: dub), [
        ..._wholeVideo,
        ..._audioGroup,
        '%10%/c/dub.mka,0.000000,8.000000',
      ]);
    });

    test('pieces shorter than a tenth of a millisecond are left out', () {
      final video = _video();
      splitSegment(video.clips, video.clips.single, 0.00005);
      final lane = _audio(0);
      lane.segments
        ..clear()
        ..addAll([
          _segment(kSource, 0, 0, 4, 0),
          _segment(kSource, 0, 4.00005, 20, 4.00005),
        ]);

      _expectEdl(
          _plan(_file([video, lane]), silenceFile: null, blackFile: null), [
        '# mpv EDL v0',
        '!no_chapters',
        '%14%/v/episode.mkv,0.000050,19.999950,layout=this',
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,4.000000',
        '%8%/c/0.mka,4.000050,15.999950',
      ]);
    });

    test('the silent file must last at least a tenth of a millisecond', () {
      final delayed = _audio(0)..segments.single.timelineStart = 1;
      for (final length in [0.0, -600.0, double.nan, 0.00005]) {
        expect(() => _plan(_file([_video(), delayed]), silenceLength: length),
            throwsArgumentError,
            reason: 'silenceLength $length');
      }

      final dub = _dub(8)..segments.single.timelineStart = 0.0002;
      _expectEdl(
          _plan(_file([_video(), _audio(0)]),
              added: [dub], monitor: dub, silenceLength: 0.0001),
          [
            ..._wholeVideo,
            ..._audioGroup,
            '%15%/c/silence.flac,0.000000,0.000100',
            '%15%/c/silence.flac,0.000000,0.000100',
            '%10%/c/dub.mka,0.000000,8.000000',
          ]);
    });

    test('an audio-only file has no image group and is not cut', () {
      final lane = _audio(0)..segments.single.timelineStart = 2;

      _expectEdl(_plan(_file([lane])), [
        '# mpv EDL v0',
        ..._audioGroup,
        '%15%/c/silence.flac,0.000000,2.000000',
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
    });
  });

  group('pending', () {
    test('waits for the copies that are missing', () {
      final dub = _dub(8);
      final plan = _plan(_file([_video(), _audio(0)]),
          added: [dub],
          monitor: dub,
          audioFile: (s) => s.path == kDub ? null : _copy(s));

      expect(plan,
          PendingPreview({const AudioSource(path: kDub, audioTypeIndex: 0)}));
    });

    test('waits for the silent file only when a gap needs it', () {
      final gap = _audio(0)..segments.single.timelineStart = 2;
      expect(_plan(_file([_video(), gap]), silenceFile: null),
          const PendingPreview({}));
      expect(
        _plan(_file([_video(), gap]),
            audioFile: (_) => null, silenceFile: null),
        PendingPreview({const AudioSource(path: kSource, audioTypeIndex: 0)}),
      );

      final file = _file([_video(), _audio(0)]);
      ProgramEdit(file, []).cut(5, 10);
      expect(_plan(file, silenceFile: null), isA<EdlPreview>());
    });

    test('waits for the black file only when a gap needs it', () {
      final gap = _video()..clips.single.timelineStart = 2;
      expect(_plan(_file([gap, _audio(0)]), blackFile: null),
          const PendingPreview({}));
      expect(_plan(_file([gap]), blackFile: null), const PendingPreview({}));
      // as cópias que faltam vêm junto: quem chama avisa se alguma falhou
      expect(
        _plan(_file([gap, _audio(0)]),
            audioFile: (_) => null, blackFile: null),
        PendingPreview({const AudioSource(path: kSource, audioTypeIndex: 0)}),
      );

      final file = _file([_video(), _audio(0)]);
      ProgramEdit(file, []).cut(5, 10);
      expect(_plan(file, blackFile: null), isA<EdlPreview>());
    });

    test('a piece after the end of the program needs no copy', () {
      final lane = _audio(0)..segments.add(_segment(kDub, 0, 0, 5, 25));
      final plan = _plan(_file([_video(), lane]),
          audioFile: (s) => s.path == kDub ? null : _copy(s));

      _expectEdl(plan, [
        ..._wholeVideo,
        ..._audioGroup,
        '%8%/c/0.mka,0.000000,20.000000',
      ]);
    });

    test('compares the missing sources as a set', () {
      const a = AudioSource(path: kSource, audioTypeIndex: 0);
      const b = AudioSource(path: kDub, audioTypeIndex: 0);
      expect(PendingPreview({a, b}), PendingPreview({b, a}));
      expect(PendingPreview({a, b}).hashCode, PendingPreview({b, a}).hashCode);
      expect(PendingPreview({a}), isNot(PendingPreview({a, b})));
    });
  });
}
