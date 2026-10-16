import 'package:video_toolkit/models/tracks.dart';
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

Widget _wrap({
  required MediaFileInfo file,
  required TimelineSelection? selection,
  required ValueChanged<TimelineSelection?> onSelectionChanged,
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
