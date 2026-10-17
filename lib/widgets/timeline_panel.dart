import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:path/path.dart' as p;

import '../models/program.dart';
import '../models/tracks.dart';
import '../services/media_cache.dart';
import '../theme/app_themes.dart';
import '../theme/theme_icons.dart';

/// What is currently selected on the timeline: a lane (track) and,
/// optionally, one audio segment inside it.
class TimelineSelection {
  const TimelineSelection({required this.lane, this.segment, this.clip});

  /// A [MediaTrack] or [ExternalTrack].
  final Object lane;
  final AudioSegment? segment;

  /// Trecho do vídeo principal.
  final VideoClip? clip;

  bool sameAs(Object lane, [AudioSegment? segment]) =>
      identical(this.lane, lane) &&
      identical(this.segment, segment) &&
      clip == null;
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

({int from, int to}) visibleColumns({
  required double left,
  required double width,
  required double scrollOffset,
  required double viewport,
  double margin = 0,
}) {
  final from = math.max(0, (scrollOffset - margin - left).floor());
  final to = math.min(width, scrollOffset + viewport + margin - left).ceil();
  return to > from ? (from: from, to: to) : (from: 0, to: 0);
}

// dois dedos no trackpad rolam a linha do tempo; o clique do trackpad chega
// como mouse e continua arrastando o trecho
const _pieceDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

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
    required this.onDeleteVideoClip,
    this.waveformOf = _noWaveform,
  });

  static Waveform? _noWaveform(AudioSource source) => null;

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

  /// Remove o trecho do programa inteiro (quem chama confirma).
  final void Function(VideoClip clip) onDeleteVideoClip;

  /// Forma de onda da origem de um trecho de áudio, quando já calculada.
  final Waveform? Function(AudioSource source) waveformOf;

  @override
  State<TimelinePanel> createState() => TimelinePanelState();
}

class TimelinePanelState extends State<TimelinePanel> {
  static const _headerWidth = 170.0;
  static const _rulerHeight = 26.0;
  static const _laneHeight = 40.0;
  static const _laneGap = 4.0;
  static const _snapPixels = 8.0;
  static const _edgeZone = 6.0;
  static const _minPieceWidth = 12.0;

  double? _pps; // pixels per second; null until fitted to the viewport
  final _scrollController = ScrollController();
  final _headersVController = ScrollController();
  final _lanesVController = ScrollController();
  final _jumpController = TextEditingController();
  bool _syncingVerticals = false;

  // Geometry of the latest build, used to auto-scroll to the playhead.
  double _lastPps = 1;
  double _lastViewStart = 0;
  double _lastViewEnd = 0;

  // um arrasto por vez: o último a começar fica com ele, e um segundo dedo
  // não mistura o trecho dele com o de outro
  Object? _dragOwner;
  double _dragStartValue = 0;
  double _dragAccumPx = 0;
  double? _frozenViewEnd;
  (double, double, double) _dragOrigin = (0, 0, 0);

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
      _frozenViewEnd = null;
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
            clips: track.clips.isEmpty ? null : track.clips,
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
            merges: audioLaneMerges(track, file.path),
          ));
        case TrackType.subtitle:
          lanes.add(_Lane(
            ref: track,
            type: TrackType.subtitle,
            label: track.title.isNotEmpty
                ? track.title
                : 'Legenda ${track.typeIndex + 1}',
            color: subtitleColor,
            offset: track.offsetSeconds,
            pieces: track.pieces,
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
          merges: audioLaneMerges(track, file.path),
        ));
      } else {
        lanes.add(_Lane(
          ref: track,
          type: TrackType.subtitle,
          label: track.title,
          color: subtitleColor,
          offset: track.offsetSeconds,
          pieces: track.pieces,
          isExternal: true,
        ));
      }
    }
    return lanes;
  }

  /// Onde a imagem acaba: o programa editado, ou o próprio arquivo.
  double get _contentEnd {
    final video = widget.file.mainVideo;
    return video == null
        ? widget.file.durationSeconds
        : programDuration(video.clips);
  }

  ({double start, double end}) _viewRange(List<_Lane> lanes) {
    var start = 0.0;
    var end = _contentEnd;
    for (final lane in lanes) {
      final pieces = lane.segments ?? lane.clips ?? lane.pieces;
      if (pieces != null) {
        for (final piece in pieces) {
          start = math.min(start, piece.timelineStart);
          if (piece.timelineEnd.isFinite) {
            end = math.max(end, piece.timelineEnd);
          }
        }
      } else {
        start = math.min(start, lane.offset);
        end = math.max(end, lane.offset + lane.duration);
      }
    }
    final padded = end + math.max(2, (end - start) * 0.02);
    return (start: start, end: math.max(padded, _frozenViewEnd ?? padded));
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

  List<VideoClip>? _clipsOf(Object? lane) =>
      lane is MediaTrack && lane.clips.isNotEmpty ? lane.clips : null;

  VideoClip? get _clipSplitTarget => _clipsOf(_selectedLane)
      ?.where((c) => c.containsTimeline(_playhead))
      .firstOrNull;

  bool get _canSplit => _splitTarget != null || _clipSplitTarget != null;

  bool get _canDelete =>
      _selectedSegment != null || widget.selection?.clip != null;

  void _split() {
    final lane = _selectedLane;
    final clip = _clipSplitTarget;
    final clips = _clipsOf(lane);
    if (lane != null && clip != null && clips != null) {
      if (splitSegment(clips, clip, _playhead)) {
        widget.onSelectionChanged(TimelineSelection(lane: lane, clip: clip));
        widget.onModelChanged();
      }
      return;
    }
    final seg = _splitTarget;
    final segments = _segmentsOf(lane);
    if (lane == null || seg == null || segments == null) return;
    if (splitSegment(segments, seg, _playhead)) {
      widget.onSelectionChanged(TimelineSelection(lane: lane, segment: seg));
      widget.onModelChanged();
    }
  }

  void _deleteSelected() {
    final clip = widget.selection?.clip;
    if (clip != null) {
      widget.onDeleteVideoClip(clip);
      return;
    }
    _deleteSelectedSegment();
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

  void _toggleMerge(_Lane lane) {
    final ref = lane.ref;
    if (ref is MediaTrack) ref.merge = !lane.merges;
    if (ref is ExternalTrack) ref.merge = !lane.merges;
    widget.onModelChanged();
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

  // escala e fim da linha do tempo parados até o fim do arrasto, senão o que
  // é arrastado foge do ponteiro
  void _beginDrag(Object owner, double pps, double startValue) {
    _dragOwner = owner;
    _pps ??= pps;
    _frozenViewEnd = _lastViewEnd;
    _dragStartValue = startValue;
    _dragAccumPx = 0;
  }

  void _beginPieceDrag(TimelinePiece piece, double pps, double startValue) {
    _beginDrag(piece, pps, startValue);
    _dragOrigin = (piece.sourceStart, piece.sourceEnd, piece.timelineStart);
  }

  bool _dragBy(Object owner, double dx) {
    if (!identical(owner, _dragOwner)) return false;
    _dragAccumPx += dx;
    return true;
  }

  // cada passo parte do começo do arrasto: passar por cima de outro trecho e
  // voltar não deixa marca
  void _restoreDragOrigin(TimelinePiece piece) {
    final (sourceStart, sourceEnd, timelineStart) = _dragOrigin;
    piece
      ..sourceStart = sourceStart
      ..sourceEnd = sourceEnd
      ..timelineStart = timelineStart;
  }

  void _endDrag(Object owner) {
    if (!identical(owner, _dragOwner)) return;
    setState(() {
      _dragOwner = null;
      _frozenViewEnd = null;
    });
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
              _lastViewEnd = range.end;

              final laneRows = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final lane in lanes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: _laneGap),
                      child: _buildLaneRow(
                          theme, lane, xOf, pps, contentWidth, viewport),
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
              onPressed: _canDelete ? _deleteSelected : null,
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
                  if (lane.type == TrackType.audio)
                    Tooltip(
                      message: lane.merges
                          ? 'Entra na mescla ao salvar — clique para deixar '
                              'separada'
                          : 'Fica separada ao salvar — clique para mesclar '
                              'com as outras',
                      child: IconButton(
                        key: ValueKey('merge-${lane.label}'),
                        icon: Icon(ThemeIcons.of(context).merge,
                            size: 12,
                            color: lane.merges
                                ? theme.accentColor
                                : theme.resources.textFillColorDisabled),
                        onPressed: () => _toggleMerge(lane),
                      ),
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

  Widget _buildLaneRow(
    FluentThemeData theme,
    _Lane lane,
    double Function(double) xOf,
    double pps,
    double contentWidth,
    double viewport,
  ) {
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

    if (lane.clips != null) {
      final clips = lane.clips!;
      for (final clip in _paintOrder(clips, pps, widget.selection?.clip)) {
        children.add(_buildVideoClip(theme, lane, clip, clips, xOf, pps));
      }
    } else if (lane.segments != null) {
      final segments = lane.segments!;
      for (final seg
          in _paintOrder(segments, pps, widget.selection?.segment)) {
        children.add(_buildSegmentClip(
            theme, lane, seg, segments, xOf, pps, viewport));
      }
    } else if (lane.pieces != null) {
      // legenda: cada pedaço que sobrou do corte vira uma barra; um pedaço
      // sem fim vai até o fim do conteúdo
      final end = _contentEnd;
      for (var i = 0; i < lane.pieces!.length; i++) {
        final piece = lane.pieces![i];
        children.add(_buildBarClip(theme, lane, xOf, pps,
            start: piece.timelineStart,
            end: math.min(piece.timelineEnd, end),
            first: i == 0));
      }
    } else {
      children.add(_buildBarClip(theme, lane, xOf, pps,
          start: lane.offset, end: lane.offset + lane.duration, first: true));
    }

    return SizedBox(
      height: _laneHeight,
      width: contentWidth,
      child: Stack(clipBehavior: Clip.hardEdge, children: children),
    );
  }

  // o selecionado por cima de tudo, com as alças ao alcance; o trecho mais
  // estreito que a caixa mínima por cima do vizinho, que o cobriria inteiro
  List<T> _paintOrder<T extends TimelinePiece>(
      List<T> pieces, double pps, Object? selected) {
    int layer(T piece) => identical(piece, selected)
        ? 2
        : piece.duration * pps < _minPieceWidth
            ? 1
            : 0;
    return [
      for (var level = 0; level < 3; level++)
        ...pieces.where((piece) => layer(piece) == level),
    ];
  }

  Widget _buildSegmentClip(
    FluentThemeData theme,
    _Lane lane,
    AudioSegment seg,
    List<AudioSegment> segments,
    double Function(double) xOf,
    double pps,
    double viewport,
  ) {
    final selected = widget.selection?.sameAs(lane.ref, seg) ?? false;
    final width = math.max(seg.duration * pps, _minPieceWidth);
    final label =
        '${_sourceName(seg.source)}  ${formatTimelineTime(seg.timelineStart)}'
        ' – ${formatTimelineTime(seg.timelineEnd)}';
    final waveform = widget.waveformOf(seg.source);
    void select() => widget
        .onSelectionChanged(TimelineSelection(lane: lane.ref, segment: seg));

    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        supportedDevices: _pieceDragDevices,
        onTap: select,
        onDoubleTap: () => _editSegment(lane.ref, seg),
        onHorizontalDragStart: (_) {
          select();
          _beginPieceDrag(seg, pps, seg.timelineStart);
        },
        onHorizontalDragUpdate: (details) {
          if (!_dragBy(seg, details.delta.dx)) return;
          _restoreDragOrigin(seg);
          var next = math.max(0.0, _dragStartValue + _dragAccumPx / pps);
          next = _snap(next, seg, segments, pps);
          seg.timelineStart = next;
          widget.onModelChanged();
        },
        onHorizontalDragEnd: (_) {
          seg.timelineStart = (seg.timelineStart * 100).round() / 100;
          _endDrag(seg);
          widget.onModelChanged();
        },
        child: Container(
          decoration: BoxDecoration(
            color: lane.color.withValues(alpha: selected ? 1.0 : 0.8),
            borderRadius: BorderRadius.circular(_radius),
            border: selected
                ? Border.all(color: Colors.white, width: 1.5)
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (waveform != null)
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _WaveformPainter(
                      waveform: waveform,
                      sourceStart: seg.sourceStart,
                      sourceEnd: seg.sourceEnd,
                      pps: pps,
                      left: xOf(seg.timelineStart),
                      viewport: viewport,
                      scroll: _scrollController,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              if (width > 90)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                  child: Text(
                    label,
                    style: theme.typography.caption?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(blurRadius: 3, color: Color(0xAA000000)),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      key: ValueKey<Object>(seg),
      left: xOf(seg.timelineStart),
      top: 3,
      bottom: 3,
      child: _withEdgeHandles(
        piece: seg,
        lane: segments,
        width: width,
        pps: pps,
        selected: selected,
        body: body,
        select: select,
      ),
    );
  }

  /// As bordas de um trecho esticam ou encolhem só ele, sem passar dos
  /// vizinhos de [lane]; o meio continua com o clique e o arrasto de sempre.
  Widget _withEdgeHandles<T extends TimelinePiece>({
    required T piece,
    required List<T> lane,
    required double width,
    required double pps,
    required bool selected,
    required Widget body,
    required VoidCallback select,
  }) {
    final zone = math.min(_edgeZone, width / 3);
    Widget handle(bool left) => Positioned(
          key: ValueKey(left ? 'trim-start' : 'trim-end'),
          left: left ? 0 : null,
          right: left ? null : 0,
          top: 0,
          bottom: 0,
          width: zone,
          child: _EdgeHandle(
            left: left,
            highlighted: selected,
            onTap: select,
            onStart: () {
              select();
              _beginPieceDrag(
                  piece, pps, left ? piece.timelineStart : piece.timelineEnd);
            },
            onUpdate: (dx) {
              if (!_dragBy(piece, dx)) return;
              _restoreDragOrigin(piece);
              final wanted = _snapEdge(
                  _dragStartValue + _dragAccumPx / pps, pps, piece, lane);
              if (left) {
                trimSegmentStart(lane, piece, wanted);
              } else {
                trimSegmentEnd(lane, piece, wanted);
              }
              widget.onModelChanged();
            },
            onEnd: () {
              _endDrag(piece);
              widget.onModelChanged();
            },
          ),
        );
    return SizedBox(
      width: width,
      child: Stack(
        children: [
          Positioned.fill(child: body),
          handle(true),
          handle(false),
        ],
      ),
    );
  }

  /// Encosta a borda arrastada no zero, no cursor e nas bordas dos outros
  /// trechos de [lane] quando passa perto; o áudio também nos cortes do vídeo
  /// e o vídeo nos cortes de todo áudio. Com o trecho inteiro arrastado
  /// ([length] é a duração dele), vale a borda que chegar mais perto.
  double _snapEdge(double candidate, double pps, TimelinePiece dragged,
      List<TimelinePiece> lane,
      {double length = 0}) {
    final across = dragged is VideoClip
        ? [
            for (final track in widget.file.tracks)
              if (!track.removed) ...track.segments,
            for (final track in widget.added) ...track.segments,
          ]
        : widget.file.mainVideo?.clips ?? const <VideoClip>[];
    final targets = <double>[
      0,
      _playhead,
      for (final piece in [...lane, ...across])
        if (!identical(piece, dragged)) ...[
          piece.timelineStart,
          piece.timelineEnd,
        ],
    ];
    var snapped = candidate;
    var distance = _snapPixels / pps;
    for (final target in targets) {
      for (final edge in [0.0, length]) {
        final d = (candidate + edge - target).abs();
        if (d < distance) {
          snapped = target - edge;
          distance = d;
        }
      }
    }
    return snapped;
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

  Widget _buildVideoClip(FluentThemeData theme, _Lane lane, VideoClip clip,
      List<VideoClip> clips, double Function(double) xOf, double pps) {
    final selected = identical(widget.selection?.clip, clip);
    final inserted = clip.path != widget.file.path;
    final width = math.max(clip.duration * pps, _minPieceWidth);
    final label = inserted
        ? p.basenameWithoutExtension(clip.path)
        : 'Original  ${formatTimelineTime(clip.sourceStart)} – '
            '${formatTimelineTime(clip.sourceEnd)}';
    void select() =>
        widget.onSelectionChanged(TimelineSelection(lane: lane.ref, clip: clip));

    // vídeo não puxa o áudio: borda e arrasto mexem só neste trecho, e o vão
    // que sobra entre os trechos fica preto
    final body = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        supportedDevices: _pieceDragDevices,
        onTap: select,
        onHorizontalDragStart: (_) {
          select();
          _beginPieceDrag(clip, pps, clip.timelineStart);
        },
        onHorizontalDragUpdate: (details) {
          if (!_dragBy(clip, details.delta.dx)) return;
          _restoreDragOrigin(clip);
          final wanted = _snapEdge(
              _dragStartValue + _dragAccumPx / pps, pps, clip, clips,
              length: clip.duration);
          clip.timelineStart = clampMove(clips, clip, wanted);
          widget.onModelChanged();
        },
        onHorizontalDragEnd: (_) => _endDrag(clip),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: (inserted ? const Color(0xFF7B4FB8) : lane.color)
                .withValues(alpha: selected ? 1.0 : 0.85),
            borderRadius: BorderRadius.circular(_radius),
            border:
                selected ? Border.all(color: Colors.white, width: 1.5) : null,
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
    );

    return Positioned(
      key: ValueKey<Object>(clip),
      left: xOf(clip.timelineStart),
      top: 3,
      bottom: 3,
      child: _withEdgeHandles(
        piece: clip,
        lane: clips,
        width: width,
        pps: pps,
        selected: selected,
        body: body,
        select: select,
      ),
    );
  }

  Widget _buildBarClip(FluentThemeData theme, _Lane lane,
      double Function(double) xOf, double pps,
      {required double start, required double end, required bool first}) {
    final isSubtitle = lane.type == TrackType.subtitle;
    final selected = widget.selection?.sameAs(lane.ref) ?? false;
    final width = math.max((end - start) * pps, _minPieceWidth);

    Widget bar = Container(
      key: first ? ValueKey<Object>(lane.ref) : null,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: lane.color.withValues(alpha: isSubtitle ? 0.8 : 0.5),
        borderRadius: BorderRadius.circular(_radius),
        border:
            selected ? Border.all(color: Colors.white, width: 1.5) : null,
      ),
      alignment: Alignment.centerLeft,
      child: first && width > 60 && lane.offset != 0
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
          supportedDevices: _pieceDragDevices,
          onTap: () =>
              widget.onSelectionChanged(TimelineSelection(lane: lane.ref)),
          onDoubleTap: () => widget.onEditSubtitleOffset(lane.ref),
          onHorizontalDragStart: (_) {
            widget
                .onSelectionChanged(TimelineSelection(lane: lane.ref));
            _beginDrag(lane.ref, pps, lane.offset);
          },
          onHorizontalDragUpdate: (details) {
            if (!_dragBy(lane.ref, details.delta.dx)) return;
            final next = (_dragStartValue + _dragAccumPx / pps)
                .clamp(-3600.0, 3600.0);
            _setSubtitleOffset(lane.ref, next);
          },
          onHorizontalDragEnd: (_) {
            _endDrag(lane.ref);
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
      left: xOf(start),
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

/// Alça na borda de um trecho: o cursor vira seta dupla e arrastar estica ou
/// encolhe.
class _EdgeHandle extends StatefulWidget {
  const _EdgeHandle({
    required this.left,
    required this.highlighted,
    required this.onTap,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final bool left;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  @override
  State<_EdgeHandle> createState() => _EdgeHandleState();
}

class _EdgeHandleState extends State<_EdgeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  void _finish() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final alpha = _hovered || _dragging
        ? 0.95
        : widget.highlighted
            ? 0.6
            : 0.0;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        supportedDevices: _pieceDragDevices,
        onTap: widget.onTap,
        onHorizontalDragStart: (_) {
          setState(() => _dragging = true);
          widget.onStart();
        },
        onHorizontalDragUpdate: (details) => widget.onUpdate(details.delta.dx),
        onHorizontalDragEnd: (_) => _finish(),
        onHorizontalDragCancel: _finish,
        child: Align(
          alignment:
              widget.left ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            width: 3,
            margin: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// Forma de onda do pedaço [sourceStart, sourceEnd) da origem: uma barra por
/// coluna de pixels, só na parte visível.
class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.waveform,
    required this.sourceStart,
    required this.sourceEnd,
    required this.pps,
    required this.left,
    required this.viewport,
    required this.scroll,
    required this.color,
  }) : super(repaint: scroll);

  static const _margin = 8.0;

  final Waveform waveform;
  final double sourceStart;
  final double sourceEnd;
  final double pps;
  final double left;
  final double viewport;
  final ScrollController scroll;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final loudest = waveform.maxPeak;
    if (!scroll.hasClients || loudest <= 0) return;
    final (:from, :to) = visibleColumns(
      left: left,
      width: size.width,
      scrollOffset: scroll.offset,
      viewport: viewport,
      margin: _margin,
    );
    if (to <= from) return;
    final mid = size.height / 2;
    final half = mid - 2;
    final points = Float32List((to - from) * 4);
    var n = 0;
    for (var x = from; x < to; x++) {
      final start = sourceStart + x / pps;
      if (start >= sourceEnd) break;
      final end = math.min(sourceEnd, start + 1 / pps);
      // raiz: a fala baixa aparece sem a alta estourar a faixa
      final level = math.sqrt(waveform.peakBetween(start, end) / loudest);
      final h = math.max(0.5, level * half);
      points[n++] = x + 0.5;
      points[n++] = mid - h;
      points[n++] = x + 0.5;
      points[n++] = mid + h;
    }
    if (n == 0) return;
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.sublistView(points, 0, n),
      Paint()
        ..color = color
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      !identical(old.waveform, waveform) ||
      old.sourceStart != sourceStart ||
      old.sourceEnd != sourceEnd ||
      old.pps != pps ||
      old.left != left ||
      old.viewport != viewport ||
      !identical(old.scroll, scroll) ||
      old.color != color;
}

class _Lane {
  _Lane({
    required this.ref,
    required this.type,
    required this.label,
    required this.color,
    this.segments,
    this.clips,
    this.pieces,
    this.duration = 0,
    this.offset = 0,
    this.isExternal = false,
    this.merges = false,
  });

  final Object ref;
  final TrackType type;
  final String label;
  final Color color;

  /// Audio lanes edit these; other lanes render bars.
  final List<AudioSegment>? segments;

  /// Vídeo principal: os trechos do programa.
  final List<VideoClip>? clips;

  /// Legendas: os pedaços que sobraram dos cortes.
  final List<SubtitlePiece>? pieces;
  final double duration;
  final double offset;
  final bool isExternal;

  /// Audio lane goes into the single merged track when saving.
  final bool merges;
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
