import 'dart:typed_data';

import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/audio_cache.dart';
import 'package:video_toolkit/widgets/timeline_panel.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const kSource = '/tmp/video.mkv';

MediaTrack _audio(int typeIndex, {double duration = 100}) {
  final track = MediaTrack(
    streamIndex: typeIndex + 1,
    type: TrackType.audio,
    typeIndex: typeIndex,
    codec: 'AAC',
    details: '',
    originalTitle: 'Faixa $typeIndex',
    durationSeconds: duration,
  );
  track.segments.add(AudioSegment(
    source: AudioSource(path: kSource, audioTypeIndex: typeIndex),
    sourceStart: 0,
    sourceEnd: duration,
    timelineStart: 0,
    sourceDuration: duration,
  ));
  return track;
}

MediaFileInfo _file(List<MediaTrack> tracks) => MediaFileInfo(
      path: kSource,
      formatName: 'matroska',
      durationSeconds: 100,
      sizeBytes: 0,
      tracks: tracks,
    );

VideoClip _clip(double start, double end, double at) => VideoClip(
      path: kSource,
      streamTypeIndex: 0,
      width: 1280,
      height: 720,
      rate: '25',
      sourceStart: start,
      sourceEnd: end,
      timelineStart: at,
      sourceDuration: 100,
    );

MediaTrack _video([List<VideoClip>? clips]) => MediaTrack(
      streamIndex: 0,
      type: TrackType.video,
      typeIndex: 0,
      codec: 'H264',
      details: '',
      originalTitle: '',
      durationSeconds: 100,
    )..clips.addAll(clips ?? [_clip(0, 100, 0)]);

(double, double, double) _range(TimelinePiece p) =>
    (p.sourceStart, p.sourceEnd, p.timelineStart);

Widget _wrap({
  required MediaFileInfo file,
  required TimelineSelection? selection,
  required ValueChanged<TimelineSelection?> onSelectionChanged,
  ValueChanged<VideoClip>? onDeleteVideoClip,
  Waveform? Function(AudioSource source)? waveformOf,
}) {
  var playhead = 0.0;
  return FluentApp(
    home: StatefulBuilder(
      builder: (context, setState) => SizedBox(
        width: 1200,
        height: 300,
        child: TimelinePanel(
          file: file,
          added: const [],
          selection: selection,
          playhead: playhead,
          onScrub: (t) => setState(() => playhead = t),
          onSelectionChanged: (s) {
            selection = s;
            onSelectionChanged(s);
            setState(() {});
          },
          onModelChanged: () => setState(() {}),
          onLaneEmptied: (_) {},
          onEditSubtitleOffset: (_) {},
          onDeleteVideoClip: onDeleteVideoClip ?? (_) {},
          waveformOf: waveformOf ?? (_) => null,
        ),
      ),
    ),
  );
}

void main() {
  Future<void> useDesktopSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('tapping a segment selects it', (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);
    TimelineSelection? selection;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (s) => selection = s,
    ));

    await tester.tap(find.byKey(ValueKey<Object>(audio.segments.single)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(selection?.lane, same(audio));
    expect(selection?.segment, same(audio.segments.single));
  });

  testWidgets('dragging a segment moves it on the timeline', (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    final seg = audio.segments.single;
    await tester.drag(find.byKey(ValueKey<Object>(seg)), const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 500));

    expect(seg.timelineStart, greaterThan(0));
  });

  testWidgets('split button divides the selected segment at the playhead',
      (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);
    final seg = audio.segments.single;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: TimelineSelection(lane: audio, segment: seg),
      onSelectionChanged: (_) {},
    ));

    // Place the playhead somewhere inside the segment.
    await tester.tapAt(tester.getCenter(
        find.byKey(const ValueKey('timeline-ruler'))));
    await tester.pump();

    await tester.tap(find.text('Dividir'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(audio.segments, hasLength(2));
    expect(audio.segments[0].sourceEnd, audio.segments[1].sourceStart);
    expect(audio.segments[1].timelineStart,
        closeTo(audio.segments[0].timelineEnd, 0.001));
  });

  testWidgets('the merge button of a lane includes or excludes it',
      (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    expect(audioLaneMerges(audio, file.path), isFalse);
    await tester.tap(find.byKey(const ValueKey('merge-Faixa 0')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(audio.merge, isTrue);
    expect(audioLaneMerges(audio, file.path), isTrue);

    await tester.tap(find.byKey(const ValueKey('merge-Faixa 0')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(audio.merge, isFalse);
  });

  testWidgets('video clips can be selected, split and handed over to delete',
      (tester) async {
    await useDesktopSurface(tester);
    final video = _video();
    final file = _file([video, _audio(0)]);
    TimelineSelection? selection;
    VideoClip? deleted;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (s) => selection = s,
      onDeleteVideoClip: (clip) => deleted = clip,
    ));

    final clip = video.clips.single;
    await tester.tap(find.byKey(ValueKey<Object>(clip)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(selection?.clip, same(clip));

    await tester.tapAt(tester.getCenter(
        find.byKey(const ValueKey('timeline-ruler'))));
    await tester.pump();
    await tester.tap(find.text('Dividir'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(video.clips, hasLength(2));
    expect(video.clips[1].timelineStart, closeTo(video.clips[0].timelineEnd, 0.001));

    await tester.tap(find.text('Excluir trecho'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(deleted, same(video.clips.first));
  });

  Finder handle(Object piece, String which) => find.descendant(
        of: find.byKey(ValueKey<Object>(piece)),
        matching: find.byKey(ValueKey(which)),
      );

  testWidgets('the edges of an audio segment shrink it and stop at the source',
      (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);
    final seg = audio.segments.single..sourceEnd = 60;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    await tester.drag(handle(seg, 'trim-start'), const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(seg.sourceStart, greaterThan(0));
    // o resto do áudio não muda de lugar
    expect(seg.timelineStart, closeTo(seg.sourceStart, 1e-9));
    expect(seg.timelineEnd, closeTo(60, 1e-9));

    // esticar a direita para no fim do que a origem tem
    await tester.drag(handle(seg, 'trim-end'), const Offset(2000, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(seg.sourceEnd, closeTo(100, 1e-9));
  });

  testWidgets('dragging the left edge of a video clip leaves the audio alone',
      (tester) async {
    await useDesktopSurface(tester);
    final video = _video();
    final audio = _audio(0);
    final file = _file([video, audio]);
    final clip = video.clips.single;
    final seg = audio.segments.single;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    await tester.drag(handle(clip, 'trim-start'), const Offset(100, 0));
    await tester.pump(const Duration(milliseconds: 500));

    expect(video.clips.single, same(clip));
    expect(clip.sourceStart, greaterThan(0));
    // o resto da imagem não sai do lugar: o começo vira vão
    expect(clip.timelineStart, closeTo(clip.sourceStart, 1e-9));
    expect(clip.timelineEnd, closeTo(100, 1e-9));
    expect(audio.segments.single, same(seg));
    expect(_range(seg), (0.0, 100.0, 0.0));
  });

  testWidgets('dragging the right edge of a video clip leaves a gap at its '
      'tail', (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 50, 0), _clip(50, 100, 50)]);
    final audio = _audio(0);
    final file = _file([video, audio]);
    final [first, second] = video.clips;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    await tester.drag(handle(first, 'trim-end'), const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 500));

    expect(video.clips, [same(first), same(second)]);
    expect(first.timelineStart, 0);
    expect(first.timelineEnd, lessThan(50));
    expect(_range(second), (50.0, 100.0, 50.0));
    expect(_range(audio.segments.single), (0.0, 100.0, 0.0));
  });

  testWidgets('stretching a video clip stops at its neighbour and at the end '
      'of its source', (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 40, 0), _clip(60, 80, 60)]);
    final file = _file([video, _audio(0)]);
    final [first, second] = video.clips;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    await tester.drag(handle(first, 'trim-end'), const Offset(600, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(first.timelineEnd, closeTo(60, 1e-9));
    expect(_range(second), (60.0, 80.0, 60.0));

    await tester.drag(handle(second, 'trim-end'), const Offset(600, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(second.sourceEnd, 100);
    expect(second.timelineStart, 60);
  });

  testWidgets('a video edge snaps to the cuts of the audio', (tester) async {
    await useDesktopSurface(tester);
    final video = _video();
    final audio = _audio(0);
    splitSegment(audio.segments, audio.segments.single, 30);
    final file = _file([video, audio]);
    final clip = video.clips.single;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));

    final pps =
        tester.getSize(find.byKey(ValueKey<Object>(clip))).width / 100;
    await tester.drag(handle(clip, 'trim-start'), Offset(30 * pps + 4, 0));
    await tester.pump(const Duration(milliseconds: 500));

    expect(_range(clip), (30.0, 100.0, 30.0));
  });

  testWidgets('dragging a video clip moves it but not into its neighbour',
      (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 40, 0), _clip(60, 100, 60)]);
    final audio = _audio(0);
    final file = _file([video, audio]);
    final [first, second] = video.clips;
    TimelineSelection? selection;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (s) => selection = s,
    ));

    await tester.drag(
        find.byKey(ValueKey<Object>(second)), const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(selection?.clip, same(second));
    expect(second.timelineStart, inExclusiveRange(40, 60));
    expect((second.sourceStart, second.sourceEnd), (60.0, 100.0));

    await tester.drag(
        find.byKey(ValueKey<Object>(second)), const Offset(-1000, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(second.timelineStart, first.timelineEnd);
    expect(_range(first), (0.0, 40.0, 0.0));
    expect(_range(audio.segments.single), (0.0, 100.0, 0.0));
  });

  testWidgets('audio segments draw the waveform of their source',
      (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final file = _file([audio]);
    final waveform = Waveform(Float32List.fromList(
        List.generate(100 * 200, (i) => (i % 200) / 200)));
    final asked = <AudioSource>[];

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
      waveformOf: (source) {
        asked.add(source);
        return waveform;
      },
    ));

    expect(asked, contains(audio.segments.single.source));
    expect(
      find.descendant(
        of: find.byKey(ValueKey<Object>(audio.segments.single)),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  test('parseTimelineTime handles the common formats', () {
    expect(parseTimelineTime('90'), 90);
    expect(parseTimelineTime('1:30'), 90);
    expect(parseTimelineTime('1:02:03.5'), 3723.5);
    expect(parseTimelineTime('-2'), -2);
    expect(parseTimelineTime('abc'), isNull);
    expect(parseTimelineTime(''), isNull);
  });

  test('formatTimelineTime formats mm:ss and h:mm:ss', () {
    expect(formatTimelineTime(0), '00:00.0');
    expect(formatTimelineTime(90), '01:30.0');
    expect(formatTimelineTime(3661.5), '1:01:01.5');
  });
}
