import 'dart:typed_data';

import 'package:video_toolkit/models/program.dart';
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/audio_cache.dart';
import 'package:video_toolkit/widgets/timeline_panel.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
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

MediaTrack _subtitle() => MediaTrack(
      streamIndex: 9,
      type: TrackType.subtitle,
      typeIndex: 0,
      codec: 'SRT',
      details: '',
      originalTitle: 'Legenda',
      durationSeconds: 100,
    );

(double, double, double) _range(TimelinePiece p) =>
    (p.sourceStart, p.sourceEnd, p.timelineStart);

class _CountingWaveform extends Waveform {
  _CountingWaveform(super.peaks);

  final starts = <double>[];

  @override
  double peakBetween(double from, double to) {
    starts.add(from);
    return super.peakBetween(from, to);
  }
}

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
  Future<void> useDesktopSurface(WidgetTester tester,
      [Size size = const Size(1600, 900)]) async {
    tester.view.physicalSize = size;
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

  final ruler = find.byKey(const ValueKey('timeline-ruler'));

  ScrollPosition timelineScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
          find.ancestor(of: ruler, matching: find.byType(Scrollable)))
      .position;

  Future<void> zoomIn(WidgetTester tester, int times) async {
    final button = find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == 'Aumentar zoom');
    for (var i = 0; i < times; i++) {
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Future<void> swipe(WidgetTester tester, Offset at, double dx) async {
    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await gesture.panZoomStart(at);
    for (var pan = 20.0; pan <= dx; pan += 20) {
      await gesture.panZoomUpdate(at, pan: Offset(-pan, 0));
    }
    await gesture.panZoomEnd();
    await tester.pump(const Duration(milliseconds: 500));
  }

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

  testWidgets('a two-finger swipe over a video clip scrolls the timeline',
      (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(10, 50, 10), _clip(60, 100, 60)]);
    final file = _file([video, _audio(0)]);
    final first = video.clips.first;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));
    await zoomIn(tester, 4);

    final clipBox = find.byKey(ValueKey<Object>(first));
    final before = tester.getTopLeft(clipBox);
    await swipe(tester, before + const Offset(100, 17), 200);

    expect(_range(first), (10.0, 50.0, 10.0));
    expect(tester.getTopLeft(clipBox).dx, closeTo(before.dx - 200, 1));

    // clicar e arrastar no trackpad chega como mouse e ainda move o trecho
    await tester.dragFrom(tester.getTopLeft(clipBox) + const Offset(100, 17),
        const Offset(100, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(first.timelineStart, greaterThan(10));
  });

  testWidgets('a two-finger swipe over an edge handle scrolls the timeline',
      (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(10, 50, 10), _clip(60, 100, 60)]);
    final file = _file([video, _audio(0)]);
    final first = video.clips.first;

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));
    await zoomIn(tester, 4);

    final before = tester.getTopLeft(ruler).dx;
    await swipe(tester, tester.getCenter(handle(first, 'trim-start')), 200);

    expect(_range(first), (10.0, 50.0, 10.0));
    expect(tester.getTopLeft(ruler).dx, closeTo(before - 200, 1));

    await tester.dragFrom(tester.getCenter(handle(first, 'trim-start')),
        const Offset(50, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(first.sourceStart, greaterThan(10));
    expect(first.timelineEnd, closeTo(50, 1e-9));
  });

  testWidgets('a two-finger swipe over an audio segment scrolls the timeline',
      (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final seg = audio.segments.single..timelineStart = 10;
    final file = _file([audio]);

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));
    await zoomIn(tester, 4);

    final body = find.byKey(ValueKey<Object>(seg));
    final before = tester.getTopLeft(ruler).dx;
    await swipe(tester, tester.getTopLeft(body) + const Offset(100, 17), 200);

    expect(_range(seg), (0.0, 100.0, 10.0));
    expect(tester.getTopLeft(ruler).dx, closeTo(before - 200, 1));

    await tester.dragFrom(tester.getTopLeft(body) + const Offset(100, 17),
        const Offset(100, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(seg.timelineStart, greaterThan(10));
  });

  testWidgets('a two-finger swipe over a subtitle scrolls the timeline',
      (tester) async {
    await useDesktopSurface(tester);
    final subtitle = _subtitle();
    final file = _file([_video(), subtitle]);

    await tester.pumpWidget(_wrap(
      file: file,
      selection: null,
      onSelectionChanged: (_) {},
    ));
    await zoomIn(tester, 4);

    final grab =
        Offset(800, tester.getCenter(find.byKey(ValueKey<Object>(subtitle))).dy);
    final before = tester.getTopLeft(ruler).dx;
    await swipe(tester, grab, 200);

    expect(subtitle.offsetSeconds, 0);
    expect(tester.getTopLeft(ruler).dx, closeTo(before - 200, 1));

    await tester.dragFrom(grab, const Offset(100, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(subtitle.offsetSeconds, greaterThan(0));
  });

  testWidgets('an edge dragged across an overlapping segment and back ends '
      'where it started', (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final first = audio.segments.single
      ..sourceStart = 10
      ..sourceEnd = 50
      ..timelineStart = 10;
    final over =
        first.slice(sourceStart: 60, sourceEnd: 70, timelineStart: 20);
    audio.segments.add(over);

    await tester.pumpWidget(_wrap(
      file: _file([audio]),
      selection: null,
      onSelectionChanged: (_) {},
    ));
    final pps =
        tester.getSize(find.byKey(ValueKey<Object>(first))).width / 40;

    Future<void> dragAndBack(String edge, double seconds) async {
      final grab = tester.getCenter(handle(first, edge));
      final gesture = await tester.startGesture(
          Offset(grab.dx.roundToDouble(), grab.dy.roundToDouble()),
          kind: PointerDeviceKind.mouse);
      final step = Offset((seconds * pps / 10).roundToDouble(), 0);
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(step);
        await tester.pump();
      }
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(-step);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await dragAndBack('trim-start', 30);
    expect(_range(first), (10.0, 50.0, 10.0));
    await dragAndBack('trim-end', -35);
    expect(_range(first), (10.0, 50.0, 10.0));
    expect(_range(over), (60.0, 70.0, 20.0));
  });

  testWidgets('a clip trimmed to the minimum next to its neighbour can be '
      'grabbed and grown back', (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 40, 0), _clip(40, 100, 40)]);
    final [first, second] = video.clips;
    TimelineSelection? selection;

    await tester.pumpWidget(_wrap(
      file: _file([video]),
      selection: null,
      onSelectionChanged: (s) => selection = s,
    ));

    await tester.drag(handle(first, 'trim-start'), const Offset(2000, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(first.duration, closeTo(kMinPieceDuration, 1e-9));
    expect(first.timelineEnd, closeTo(40, 1e-9));

    await tester.tap(find.text('Vídeo 1'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(selection?.clip, isNull);

    await tester.dragFrom(
        tester.getTopLeft(find.byKey(ValueKey<Object>(first))) +
            const Offset(2, 17),
        const Offset(-100, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));

    expect(selection?.clip, same(first));
    expect(first.timelineStart, lessThan(39));
    expect(first.timelineEnd, closeTo(40, 1e-9));
    expect(_range(second), (40.0, 100.0, 40.0));
  });

  testWidgets('the selected neighbour of a clip trimmed to the minimum keeps '
      'its left edge', (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 40, 0), _clip(40, 100, 40)]);
    final [first, second] = video.clips;
    TimelineSelection? selection;

    await tester.pumpWidget(_wrap(
      file: _file([video]),
      selection: null,
      onSelectionChanged: (s) => selection = s,
    ));
    final pps =
        tester.getSize(find.byKey(ValueKey<Object>(second))).width / 60;

    await tester.drag(handle(first, 'trim-start'), const Offset(2000, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(ValueKey<Object>(second)));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.dragFrom(tester.getCenter(handle(second, 'trim-start')),
        const Offset(100, 0),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));

    expect(selection?.clip, same(second));
    expect(second.timelineStart, closeTo(40 + 100 / pps, 1e-6));
    expect(second.sourceStart, closeTo(second.timelineStart, 1e-9));
    expect(first.duration, closeTo(kMinPieceDuration, 1e-9));
    expect(first.timelineEnd, closeTo(40, 1e-9));
  });

  testWidgets('a second finger dragging another clip leaves the first one '
      'whole', (tester) async {
    await useDesktopSurface(tester);
    final video = _video([_clip(0, 40, 0), _clip(60, 100, 60)]);
    final [first, second] = video.clips;

    await tester.pumpWidget(_wrap(
      file: _file([video]),
      selection: null,
      onSelectionChanged: (_) {},
    ));

    Future<void> slide(TestGesture finger, double dx, int times) async {
      for (var i = 0; i < times; i++) {
        await finger.moveBy(Offset(dx, 0));
        await tester.pump();
      }
    }

    final one = await tester
        .startGesture(tester.getCenter(find.byKey(ValueKey<Object>(first))));
    await slide(one, 10, 4);
    final two = await tester
        .startGesture(tester.getCenter(find.byKey(ValueKey<Object>(second))));
    await slide(two, 10, 4);
    await slide(one, 5, 1);
    await one.up();
    await two.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect((first.sourceStart, first.sourceEnd), (0.0, 40.0));
    expect((second.sourceStart, second.sourceEnd), (60.0, 100.0));
    expect(second.timelineStart, greaterThan(60));
    expect(first.timelineEnd, lessThanOrEqualTo(second.timelineStart));
  });

  testWidgets('trimming the end of the last clip while scrolled to the end '
      'keeps the edge under the pointer', (tester) async {
    await useDesktopSurface(tester);
    final video = _video();
    final clip = video.clips.single;

    await tester.pumpWidget(_wrap(
      file: _file([video]),
      selection: null,
      onSelectionChanged: (_) {},
    ));
    await zoomIn(tester, 4);
    final position = timelineScroll(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    final extent = position.maxScrollExtent;

    final box = find.byKey(ValueKey<Object>(clip));
    final edge = tester.getTopRight(box).dx;
    final gesture = await tester.startGesture(
        tester.getCenter(handle(clip, 'trim-end')),
        kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
    }

    expect(clip.timelineEnd, lessThan(100));
    expect(tester.getTopRight(box).dx, closeTo(edge - 300, 1));
    expect(position.maxScrollExtent, extent);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(position.maxScrollExtent, lessThan(extent));
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

  testWidgets('the waveform draws only the columns on screen and follows the '
      'scroll', (tester) async {
    await useDesktopSurface(tester);
    final audio = _audio(0);
    final waveform = _CountingWaveform(Float32List.fromList(
        List.generate(100 * 200, (i) => (i % 200) / 200)));

    await tester.pumpWidget(_wrap(
      file: _file([audio]),
      selection: null,
      onSelectionChanged: (_) {},
      waveformOf: (_) => waveform,
    ));
    await zoomIn(tester, 8);
    waveform.starts.clear();
    await zoomIn(tester, 1);

    final seg = find.byKey(ValueKey<Object>(audio.segments.single));
    expect(tester.getSize(seg).width, 50000);
    final position = timelineScroll(tester);
    final viewport = position.viewportDimension;
    expect(waveform.starts, isNotEmpty);
    expect(waveform.starts.length, lessThan(viewport + 40));
    expect(waveform.starts.last, lessThan((viewport + 20) / 500));

    waveform.starts.clear();
    position.jumpTo(10000);
    await tester.pump();
    expect(waveform.starts, isNotEmpty);
    expect(waveform.starts.length, lessThan(viewport + 40));
    expect(waveform.starts.first, closeTo(20, 0.05));
    expect(waveform.starts.last, closeTo(20 + viewport / 500, 0.05));
  });

  testWidgets('widening the window draws the waveform it uncovers',
      (tester) async {
    await useDesktopSurface(tester, const Size(1000, 900));
    final audio = _audio(0);
    final waveform = _CountingWaveform(Float32List.fromList(
        List.generate(100 * 200, (i) => (i % 200) / 200)));

    await tester.pumpWidget(_wrap(
      file: _file([audio]),
      selection: null,
      onSelectionChanged: (_) {},
      waveformOf: (_) => waveform,
    ));
    await zoomIn(tester, 6);
    final position = timelineScroll(tester);
    position.jumpTo(3000);
    await tester.pump();
    final pps = tester
            .getSize(find.byKey(ValueKey<Object>(audio.segments.single)))
            .width /
        100;

    waveform.starts.clear();
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pump();

    expect(position.pixels, 3000);
    expect(waveform.starts, isNotEmpty);
    expect(waveform.starts.last,
        greaterThan((3000 + position.viewportDimension) / pps));
  });

  test('parseTimelineTime handles the common formats', () {
    expect(parseTimelineTime('90'), 90);
    expect(parseTimelineTime('1:30'), 90);
    expect(parseTimelineTime('1:02:03.5'), 3723.5);
    expect(parseTimelineTime('-2'), -2);
    expect(parseTimelineTime('abc'), isNull);
    expect(parseTimelineTime(''), isNull);
  });

  test('visibleColumns keeps only the columns of a piece on screen', () {
    ({int from, int to}) columns(double left, double width, double offset,
            {double margin = 0}) =>
        visibleColumns(
          left: left,
          width: width,
          scrollOffset: offset,
          viewport: 1000,
          margin: margin,
        );

    expect(columns(100, 5000, 0), (from: 0, to: 900));
    expect(columns(100, 5000, 4124), (from: 4024, to: 5000));
    expect(columns(100, 5000, 1000, margin: 8), (from: 892, to: 1908));
    expect(columns(0, 500, 507, margin: 8), (from: 499, to: 500));
    expect(columns(200, 300.5, 0), (from: 0, to: 301));
    expect(columns(200, 300, 150, margin: 8), (from: 0, to: 300));
    expect(columns(3000, 500, 0), (from: 0, to: 0));
    expect(columns(0, 500, 1000), (from: 0, to: 0));
    expect(columns(0, 500, 508, margin: 8), (from: 0, to: 0));
  });

  test('formatTimelineTime formats mm:ss and h:mm:ss', () {
    expect(formatTimelineTime(0), '00:00.0');
    expect(formatTimelineTime(90), '01:30.0');
    expect(formatTimelineTime(3661.5), '1:01:01.5');
  });
}
