import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;

import '../models/tracks.dart';
import '../theme/app_themes.dart';
import '../theme/theme_icons.dart';

/// What is currently selected on the timeline: a lane (track) and,
/// optionally, one audio segment inside it.
class TimelineSelection {
  const TimelineSelection({required this.lane, this.segment});

  /// A [MediaTrack] or [ExternalTrack].
  final Object lane;
  final AudioSegment? segment;

  bool sameAs(Object lane, [AudioSegment? segment]) =>
      identical(this.lane, lane) && identical(this.segment, segment);
}

String formatTimelineTime(double seconds) {
  final negative = seconds < 0;
  // Round to deciseconds first so 59.97 becomes 1:00.0, never "00:60.0".
  final deciseconds = (seconds.abs() * 10).round();
  final h = deciseconds ~/ 36000;
  final m = (deciseconds % 36000) ~/ 600;
  final s = (deciseconds % 600) / 10;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toStringAsFixed(1).padLeft(4, '0');
  final body = h >= 1 ? '$h:$mm:$ss' : '$mm:$ss';
  return negative ? '−$body' : body;
}

String formatOffset(double offset) =>
    '${offset >= 0 ? '+' : '−'}${offset.abs().toStringAsFixed(2)}s';

/// Parses "90", "1:30", "1:02:03.5" into seconds.
double? parseTimelineTime(String input) {
  final text = input.trim().replaceAll(',', '.').replaceAll('−', '-');
  if (text.isEmpty) return null;
  final negative = text.startsWith('-');
  final parts = (negative ? text.substring(1) : text).split(':');
  if (parts.length > 3) return null;
  var seconds = 0.0;
  for (final part in parts) {
    final value = double.tryParse(part);
    if (value == null || !value.isFinite) return null;
    seconds = seconds * 60 + value;
  }
  if (!seconds.isFinite) return null;
  return negative ? -seconds : seconds;
}

class TimelinePanel extends StatefulWidget {
  const TimelinePanel({
    super.key,
    required this.file,
    required this.added,
    required this.selection,
    required this.playhead,
    required this.onScrub,
    required this.onSelectionChanged,
    required this.onModelChanged,
    required this.onLaneEmptied,
    required this.onEditSubtitleOffset,
  });

  final MediaFileInfo file;
  final List<ExternalTrack> added;
  final TimelineSelection? selection;

  /// Current playhead position in seconds — owned by the parent so the
  /// video preview and the timeline stay in sync.
  final double playhead;

  /// Called when the user moves the playhead (ruler click/drag, jump box).
  final ValueChanged<double> onScrub;

  final ValueChanged<TimelineSelection?> onSelectionChanged;

  /// Called after this panel mutates segments/offsets directly.
  final VoidCallback onModelChanged;

  /// Called when the last segment of an audio lane was deleted.
  final void Function(Object lane) onLaneEmptied;
  final void Function(Object subtitleRef) onEditSubtitleOffset;

  @override
  State<TimelinePanel> createState() => TimelinePanelState();
}

class TimelinePanelState extends State<TimelinePanel> {
  static const _headerWidth = 170.0;
  static const _rulerHeight = 26.0;
  static const _laneHeight = 40.0;
  static const _laneGap = 4.0;
  static const _snapPixels = 8.0;

  double? _pps; // pixels per second; null until fitted to the viewport
  final _scrollController = ScrollController();
  final _headersVController = ScrollController();
  final _lanesVController = ScrollController();
  final _jumpController = TextEditingController();
  bool _syncingVerticals = false;

  // Geometry of the latest build, used to auto-scroll to the playhead.
  double _lastPps = 1;
  double _lastViewStart = 0;

  // Active segment drag bookkeeping (single pointer on desktop).
  double _dragStartValue = 0;
  double _dragAccumPx = 0;

  double get _playhead => widget.playhead;

  /// Clip rounding from the active theme (clamped: clips are only 34px tall).
  double get _radius =>
      AppThemeScope.specOf(context).cornerRadius.clamp(0.0, 6.0);

  @override
  void initState() {
    super.initState();
    _linkVerticals(_headersVController, _lanesVController);
    _linkVerticals(_lanesVController, _headersVController);
  }

  /// Keeps the lane-header column and the lane area scrolled together.
  void _linkVerticals(ScrollController from, ScrollController to) {
    from.addListener(() {
      if (_syncingVerticals || !from.hasClients || !to.hasClients) return;
      if ((to.offset - from.offset).abs() < 0.5) return;
      _syncingVerticals = true;
      to.jumpTo(from.offset);
      _syncingVerticals = false;
    });
  }

  @override
  void didUpdateWidget(TimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.file, widget.file)) {
      _pps = null;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _headersVController.dispose();
    _lanesVController.dispose();
    _jumpController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ lanes

  List<_Lane> _lanes(BuildContext context) {
    final theme = FluentTheme.of(context);
    final file = widget.file;
    final lanes = <_Lane>[];
    const subtitleColor = Color(0xFF0F7B0F);

    for (final track in file.tracks.where((t) => !t.removed)) {
      switch (track.type) {
        case TrackType.video:
          lanes.add(_Lane(
            ref: track,
            type: TrackType.video,
            label: track.title.isNotEmpty
                ? track.title
                : 'Vídeo ${track.typeIndex + 1}',
            color: const Color(0xFF6B6B6B),
            duration: track.durationSeconds > 0
                ? track.durationSeconds
                : file.durationSeconds,
          ));
        case TrackType.audio:
          lanes.add(_Lane(
            ref: track,
            type: TrackType.audio,
            label: track.title.isNotEmpty
                ? track.title
                : 'Áudio ${track.typeIndex + 1}',
            color: theme.accentColor,
            segments: track.segments,
            fragmentary: audioLaneIsFragmentary(
              segments: track.segments,
              ownPath: file.path,
              ownTypeIndex: track.typeIndex,
              durationSeconds: track.durationSeconds,
            ),
          ));
        case TrackType.subtitle:
          lanes.add(_Lane(
            ref: track,
            type: TrackType.subtitle,
            label: track.title.isNotEmpty
                ? track.title
                : 'Legenda ${track.typeIndex + 1}',
            color: subtitleColor,
            duration: track.durationSeconds > 0
                ? track.durationSeconds
                : file.durationSeconds,
            offset: track.offsetSeconds,
          ));
      }
    }
    for (final track in widget.added) {
      if (track.type == TrackType.audio) {
        lanes.add(_Lane(
          ref: track,
          type: TrackType.audio,
          label: track.title,
          color: theme.accentColor,
          segments: track.segments,
          isExternal: true,
          fragmentary: audioLaneIsFragmentary(
            segments: track.segments,
            ownPath: track.path,
            ownTypeIndex: 0,
            durationSeconds: track.durationSeconds,
          ),
        ));
      } else {
        lanes.add(_Lane(
          ref: track,
          type: TrackType.subtitle,
          label: track.title,
          color: subtitleColor,
          duration: track.durationSeconds > 0
              ? track.durationSeconds
              : file.durationSeconds,
          offset: track.offsetSeconds,
          isExternal: true,
        ));
      }
    }
    return lanes;
  }

  ({double start, double end}) _viewRange(List<_Lane> lanes) {
    var start = 0.0;
    var end = widget.file.durationSeconds;
    for (final lane in lanes) {
      if (lane.segments != null) {
        for (final seg in lane.segments!) {
          end = math.max(end, seg.timelineEnd);
        }
      } else {
        start = math.min(start, lane.offset);
        end = math.max(end, lane.offset + lane.duration);
      }
    }
    return (start: start, end: end + math.max(2, (end - start) * 0.02));
  }

  // ------------------------------------------------------------- operations

  AudioSegment? get _selectedSegment => widget.selection?.segment;
  Object? get _selectedLane => widget.selection?.lane;

  List<AudioSegment>? _segmentsOf(Object? lane) => switch (lane) {
        MediaTrack(type: TrackType.audio, :final segments) => segments,
        ExternalTrack(type: TrackType.audio, :final segments) => segments,
        _ => null,
      };

  /// The segment the split action would cut: the selected one when the
  /// playhead is inside it, else the selected lane's segment under the
  /// playhead.
  AudioSegment? get _splitTarget {
    final segments = _segmentsOf(_selectedLane);
    if (segments == null) return null;
    final sel = _selectedSegment;
    if (sel != null && sel.containsTimeline(_playhead)) return sel;
    return segments.where((s) => s.containsTimeline(_playhead)).firstOrNull;
  }

  bool get _canSplit => _splitTarget != null;

  void _split() {
    final lane = _selectedLane;
    final seg = _splitTarget;
    final segments = _segmentsOf(lane);
    if (lane == null || seg == null || segments == null) return;
    if (splitSegment(segments, seg, _playhead)) {
      widget.onSelectionChanged(TimelineSelection(lane: lane, segment: seg));
      widget.onModelChanged();
    }
  }

  void _deleteSelectedSegment() {
    final lane = _selectedLane;
    final seg = _selectedSegment;
    final segments = _segmentsOf(lane);
    if (lane == null || seg == null || segments == null) return;
    segments.remove(seg);
    widget.onSelectionChanged(
        segments.isEmpty ? null : TimelineSelection(lane: lane));
    if (segments.isEmpty) widget.onLaneEmptied(lane);
    widget.onModelChanged();
  }

  void _setPlayhead(double t) {
    widget.onScrub(t.isFinite ? math.max(t, 0.0) : 0.0);
  }

  /// Centers the horizontal viewport on time [t] (used by the jump box).
  void _scrollToTime(double t) {
    if (!_scrollController.hasClients) return;
    final x = (t - _lastViewStart) * _lastPps;
    final viewport = _scrollController.position.viewportDimension;
    _scrollController.jumpTo((x - viewport / 2)
        .clamp(0.0, _scrollController.position.maxScrollExtent));
  }

  void _zoomBy(double factor, double fitPps) {
    final current = _pps ?? fitPps;
    final lower = math.min(fitPps * 0.5, 500.0);
    final upper = math.max(fitPps, 500.0);
    setState(() {
      _pps = (current * factor).clamp(lower, upper);
    });
  }

  String _sourceName(AudioSource source) {
    if (source.path == widget.file.path) {
      return 'Áudio ${source.audioTypeIndex + 1}';
    }
    return p.basenameWithoutExtension(source.path);
  }

  Future<void> _editSegment(Object lane, AudioSegment seg) async {
    final controller =
        TextEditingController(text: seg.timelineStart.toStringAsFixed(2));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Trecho de áudio'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Origem: ${_sourceName(seg.source)} '
                '(${formatTimelineTime(seg.sourceStart)} – '
                '${formatTimelineTime(seg.sourceEnd)})'),
            const SizedBox(height: 12),
            InfoLabel(
              label: 'Início na linha do tempo (segundos ou mm:ss)',
              child: TextBox(
                controller: controller,
                autofocus: true,
                onSubmitted: (v) => Navigator.pop(context, v),
              ),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final parsed = parseTimelineTime(result);
    if (parsed == null || parsed < 0) return;
    seg.timelineStart = parsed;
    widget.onModelChanged();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final lanes = _lanes(context);
    final range = _viewRange(lanes);
    final span = math.max(range.end - range.start, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(theme, span),
        Divider(
            style: DividerThemeData(
                horizontalMargin: EdgeInsets.zero,
                thickness: 1,
                decoration: BoxDecoration(
                    color: theme.resources.dividerStrokeColorDefault))),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport = constraints.maxWidth - _headerWidth;
              final fitPps = math.max(viewport / span, 0.01);
              final pps = _pps ?? fitPps;
              final contentWidth = math.max(span * pps + 24, viewport);
              double xOf(double t) => (t - range.start) * pps;
              _lastPps = pps;
              _lastViewStart = range.start;

              final laneRows = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final lane in lanes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: _laneGap),
                      child:
                          _buildLaneRow(theme, lane, xOf, pps, contentWidth),
                    ),
                ],
              );

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _headerWidth,
                    child: Column(
                      children: [
                        const SizedBox(height: _rulerHeight),
                        Expanded(
                          child: ScrollConfiguration(
                            behavior: ScrollConfiguration.of(context)
                                .copyWith(scrollbars: false),
                            child: SingleChildScrollView(
                              controller: _headersVController,
                              child: _buildHeaders(theme, lanes),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: contentWidth,
                        child: Stack(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildRuler(theme, range, span, pps),
                                Expanded(
                                  child: SingleChildScrollView(
                                    controller: _lanesVController,
                                    child: laneRows,
                                  ),
                                ),
                              ],
                            ),
                            Positioned(
                              left: xOf(_playhead) - 0.75,
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: Container(
                                    width: 1.5, color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(FluentThemeData theme, double span) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Tooltip(
            message: 'Dividir no cursor (S)',
            child: Button(
              onPressed: _canSplit ? _split : null,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(ThemeIcons.of(context).cut, size: 13),
                SizedBox(width: 6),
                Text('Dividir'),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Excluir trecho selecionado (Del)',
            child: Button(
              onPressed:
                  _selectedSegment != null ? _deleteSelectedSegment : null,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(ThemeIcons.of(context).delete, size: 13),
                SizedBox(width: 6),
                Text('Excluir trecho'),
              ]),
            ),
          ),
          const SizedBox(width: 16),
          Icon(ThemeIcons.of(context).timeline, size: 14,
              color: theme.resources.textFillColorSecondary),
          const SizedBox(width: 6),
          Text(formatTimelineTime(_playhead),
              style: theme.typography.bodyStrong),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: TextBox(
              controller: _jumpController,
              placeholder: 'ir para (mm:ss)',
              onSubmitted: (value) {
                final t = parseTimelineTime(value);
                if (t != null && t >= 0) {
                  _setPlayhead(t);
                  _scrollToTime(t);
                  _jumpController.clear();
                }
              },
            ),
          ),
          const Spacer(),
          Tooltip(
            message: 'Reduzir zoom',
            child: IconButton(
              icon: Icon(ThemeIcons.of(context).zoomOut, size: 14),
              onPressed: () => _zoomBy(1 / 1.5, _fitPps(span)),
            ),
          ),
          Tooltip(
            message: 'Ajustar à janela',
            child: IconButton(
              icon: Icon(ThemeIcons.of(context).fitWindow, size: 14),
              onPressed: () => setState(() => _pps = null),
            ),
          ),
          Tooltip(
            message: 'Aumentar zoom',
            child: IconButton(
              icon: Icon(ThemeIcons.of(context).zoomIn, size: 14),
              onPressed: () => _zoomBy(1.5, _fitPps(span)),
            ),
          ),
        ],
      ),
    );
  }

  double _fitPps(double span) {
    final box = context.findRenderObject() as RenderBox?;
    final width = (box?.size.width ?? 900) - _headerWidth;
    return math.max(width / span, 0.01);
  }

  Widget _buildHeaders(FluentThemeData theme, List<_Lane> lanes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final lane in lanes)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                widget.onSelectionChanged(TimelineSelection(lane: lane.ref)),
            child: Container(
              height: _laneHeight,
              margin: const EdgeInsets.only(bottom: _laneGap),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: identical(_selectedLane, lane.ref)
                    ? theme.accentColor.withValues(alpha: 0.12)
                    : theme.resources.subtleFillColorTertiary,
                borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(_radius)),
              ),
              child: Row(
                children: [
                  Icon(
                    switch (lane.type) {
                      TrackType.video => ThemeIcons.of(context).video,
                      TrackType.audio => ThemeIcons.of(context).volume,
                      TrackType.subtitle => ThemeIcons.of(context).cc,
                    },
                    size: 13,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      lane.label,
                      style: theme.typography.caption,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (lane.fragmentary)
                    Tooltip(
                      message: 'Faixa editada — será mesclada com as outras '
                          'faixas editadas ao salvar',
                      child: Icon(ThemeIcons.of(context).merge, size: 11,
                          color: theme.accentColor),
                    ),
                  if (lane.isExternal)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(ThemeIcons.of(context).add, size: 10,
                          color: theme.resources.textFillColorSecondary),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRuler(FluentThemeData theme,
      ({double start, double end}) range, double span, double pps) {
    return GestureDetector(
      key: const ValueKey('timeline-ruler'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) =>
          _setPlayhead(range.start + d.localPosition.dx / pps),
      onHorizontalDragUpdate: (d) =>
          _setPlayhead(range.start + d.localPosition.dx / pps),
      child: SizedBox(
        height: _rulerHeight,
        width: double.infinity,
        child: CustomPaint(
          painter: _RulerPainter(
            viewStart: range.start,
            span: span,
            pps: pps,
            playhead: _playhead,
            lineColor: theme.resources.textFillColorTertiary,
            textColor: theme.resources.textFillColorSecondary,
            textStyle: theme.typography.caption ?? const TextStyle(fontSize: 10),
          ),
        ),
      ),
    );
  }

  Widget _buildLaneRow(FluentThemeData theme, _Lane lane,
      double Function(double) xOf, double pps, double contentWidth) {
    final children = <Widget>[
      Container(
        width: contentWidth,
        height: _laneHeight,
        decoration: BoxDecoration(
          color: theme.resources.subtleFillColorSecondary,
          borderRadius: BorderRadius.circular(_radius),
        ),
      ),
      Positioned(
        left: xOf(0),
        top: 0,
        bottom: 0,
        child: IgnorePointer(
          child: Container(
              width: 1, color: theme.resources.textFillColorTertiary),
        ),
      ),
    ];

    if (lane.segments != null) {
      final segments = lane.segments!;
      for (final seg in segments) {
        children.add(_buildSegmentClip(theme, lane, seg, segments, xOf, pps));
      }
    } else {
      children.add(_buildBarClip(theme, lane, xOf, pps));
    }

    return SizedBox(
      height: _laneHeight,
      width: contentWidth,
      child: Stack(clipBehavior: Clip.hardEdge, children: children),
    );
  }

  Widget _buildSegmentClip(
    FluentThemeData theme,
    _Lane lane,
    AudioSegment seg,
    List<AudioSegment> segments,
    double Function(double) xOf,
    double pps,
  ) {
    final selected = widget.selection?.sameAs(lane.ref, seg) ?? false;
    final width = math.max(seg.duration * pps, 12.0);
    final label =
        '${_sourceName(seg.source)}  ${formatTimelineTime(seg.timelineStart)}'
        ' – ${formatTimelineTime(seg.timelineEnd)}';

    return Positioned(
      left: xOf(seg.timelineStart),
      top: 3,
      bottom: 3,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onSelectionChanged(
              TimelineSelection(lane: lane.ref, segment: seg)),
          onDoubleTap: () => _editSegment(lane.ref, seg),
          onHorizontalDragStart: (_) {
            widget.onSelectionChanged(
                TimelineSelection(lane: lane.ref, segment: seg));
            // Freeze the fit-derived scale: the drag itself can change the
            // timeline span, and a scale that shifts mid-drag feeds back
            // into the position math.
            _pps ??= pps;
            _dragStartValue = seg.timelineStart;
            _dragAccumPx = 0;
          },
          onHorizontalDragUpdate: (details) {
            _dragAccumPx += details.delta.dx;
            var next =
                math.max(0.0, _dragStartValue + _dragAccumPx / pps);
            next = _snap(next, seg, segments, pps);
            seg.timelineStart = next;
            widget.onModelChanged();
          },
          onHorizontalDragEnd: (_) {
            seg.timelineStart = (seg.timelineStart * 100).round() / 100;
            widget.onModelChanged();
          },
          child: Container(
            key: ValueKey<Object>(seg),
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: lane.color.withValues(alpha: selected ? 1.0 : 0.8),
              borderRadius: BorderRadius.circular(_radius),
              border: selected
                  ? Border.all(color: Colors.white, width: 1.5)
                  : null,
            ),
            alignment: Alignment.centerLeft,
            child: width > 90
                ? Text(
                    label,
                    style: theme.typography.caption?.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  )
                : null,
          ),
        ),
      ),
    );
  }

  /// Snaps a candidate timelineStart to 0, the playhead, or neighbouring
  /// segment edges when within a few pixels.
  double _snap(double candidate, AudioSegment seg,
      List<AudioSegment> segments, double pps) {
    final threshold = _snapPixels / pps;
    final targets = <double>[
      0,
      _playhead,
      _playhead - seg.duration,
      for (final other in segments)
        if (!identical(other, seg)) ...[
          other.timelineEnd,
          other.timelineStart - seg.duration,
        ],
    ];
    for (final target in targets) {
      if (target >= 0 && (candidate - target).abs() < threshold) {
        return target;
      }
    }
    return candidate;
  }

  Widget _buildBarClip(FluentThemeData theme, _Lane lane,
      double Function(double) xOf, double pps) {
    final isSubtitle = lane.type == TrackType.subtitle;
    final selected = widget.selection?.sameAs(lane.ref) ?? false;
    final width = math.max(lane.duration * pps, 12.0);

    Widget bar = Container(
      key: ValueKey<Object>(lane.ref),
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: lane.color.withValues(alpha: isSubtitle ? 0.8 : 0.5),
        borderRadius: BorderRadius.circular(_radius),
        border:
            selected ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
      alignment: Alignment.centerLeft,
      child: width > 60 && lane.offset != 0
          ? Text(
              formatOffset(lane.offset),
              style: theme.typography.caption?.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w600),
              softWrap: false,
            )
          : null,
    );

    if (isSubtitle) {
      bar = MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          onTap: () =>
              widget.onSelectionChanged(TimelineSelection(lane: lane.ref)),
          onDoubleTap: () => widget.onEditSubtitleOffset(lane.ref),
          onHorizontalDragStart: (_) {
            widget
                .onSelectionChanged(TimelineSelection(lane: lane.ref));
            _pps ??= pps;
            _dragStartValue = lane.offset;
            _dragAccumPx = 0;
          },
          onHorizontalDragUpdate: (details) {
            _dragAccumPx += details.delta.dx;
            final next = (_dragStartValue + _dragAccumPx / pps)
                .clamp(-3600.0, 3600.0);
            _setSubtitleOffset(lane.ref, next);
          },
          onHorizontalDragEnd: (_) {
            _setSubtitleOffset(
                lane.ref, (_currentSubtitleOffset(lane.ref) * 100).round() / 100);
          },
          child: bar,
        ),
      );
    } else {
      bar = GestureDetector(
        onTap: () =>
            widget.onSelectionChanged(TimelineSelection(lane: lane.ref)),
        child: bar,
      );
    }

    return Positioned(
      left: xOf(lane.offset),
      top: 3,
      bottom: 3,
      child: bar,
    );
  }

  double _currentSubtitleOffset(Object ref) => switch (ref) {
        MediaTrack(:final offsetSeconds) => offsetSeconds,
        ExternalTrack(:final offsetSeconds) => offsetSeconds,
        _ => 0,
      };

  void _setSubtitleOffset(Object ref, double value) {
    if (ref is MediaTrack) ref.offsetSeconds = value;
    if (ref is ExternalTrack) ref.offsetSeconds = value;
    widget.onModelChanged();
  }
}

class _Lane {
  _Lane({
    required this.ref,
    required this.type,
    required this.label,
    required this.color,
    this.segments,
    this.duration = 0,
    this.offset = 0,
    this.isExternal = false,
    this.fragmentary = false,
  });

  final Object ref;
  final TrackType type;
  final String label;
  final Color color;

  /// Audio lanes edit these; video/subtitle lanes render a single bar.
  final List<AudioSegment>? segments;
  final double duration;
  final double offset;
  final bool isExternal;

  /// Lane was cut apart — it will be auto-merged with the other
  /// fragmentary lanes when saving.
  final bool fragmentary;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.viewStart,
    required this.span,
    required this.pps,
    required this.playhead,
    required this.lineColor,
    required this.textColor,
    required this.textStyle,
  });

  final double viewStart;
  final double span;
  final double pps;
  final double playhead;
  final Color lineColor;
  final Color textColor;
  final TextStyle textStyle;

  static const _steps = [
    0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0,
    60.0, 120.0, 300.0, 600.0, 1800.0, 3600.0,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    final step = _steps.firstWhere((s) => s * pps >= 64,
        orElse: () => _steps.last);
    final first = (viewStart / step).floorToDouble() * step;

    for (var t = first; t <= viewStart + span + step; t += step) {
      final x = (t - viewStart) * pps;
      if (x < -60 || x > size.width + 60) continue;
      canvas.drawLine(
          Offset(x, size.height - 8), Offset(x, size.height), paint);

      final label = TextPainter(
        text: TextSpan(
            text: formatTimelineTime(t),
            style: textStyle.copyWith(color: textColor, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x + 3, 1));

      // minor ticks
      final minor = step / 5;
      if (minor * pps >= 7) {
        for (var m = t + minor; m < t + step; m += minor) {
          final mx = (m - viewStart) * pps;
          canvas.drawLine(Offset(mx, size.height - 4),
              Offset(mx, size.height), paint);
        }
      }
    }

    // playhead handle
    final px = (playhead - viewStart) * pps;
    final handle = Path()
      ..moveTo(px - 5, size.height - 10)
      ..lineTo(px + 5, size.height - 10)
      ..lineTo(px, size.height)
      ..close();
    canvas.drawPath(handle, Paint()..color = Colors.red);
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.viewStart != viewStart ||
      old.span != span ||
      old.pps != pps ||
      old.playhead != playhead ||
      old.lineColor != lineColor;
}
