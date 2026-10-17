import 'package:fluent_ui/fluent_ui.dart';
import 'package:path/path.dart' as p;

import '../models/tracks.dart';
import '../theme/theme_icons.dart';
import 'timeline_panel.dart';

/// Right-side panel showing details and actions for the current selection
/// (a track lane or a single audio segment).
class PropertiesPanel extends StatefulWidget {
  const PropertiesPanel({
    super.key,
    required this.file,
    required this.selection,
    required this.onModelChanged,
    required this.onExportAudio,
    required this.onToggleRemoved,
    required this.onRemoveExternal,
    required this.onDeleteSegment,
    required this.onDeleteVideoClip,
  });

  final MediaFileInfo file;
  final TimelineSelection? selection;
  final VoidCallback onModelChanged;
  final void Function(MediaTrack track) onExportAudio;
  final void Function(MediaTrack track) onToggleRemoved;
  final void Function(ExternalTrack track) onRemoveExternal;
  final void Function(Object lane, AudioSegment segment) onDeleteSegment;
  final void Function(VideoClip clip) onDeleteVideoClip;

  @override
  State<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<PropertiesPanel> {
  final _titleController = TextEditingController();
  final _startController = TextEditingController();
  final _startFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(PropertiesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSel = oldWidget.selection;
    final newSel = widget.selection;
    final identityChanged = !identical(oldSel?.lane, newSel?.lane) ||
        !identical(oldSel?.segment, newSel?.segment);
    if (identityChanged) {
      _syncControllers();
    } else if (!_startFocus.hasFocus) {
      // Keep the start field in sync while the segment is dragged around.
      final seg = newSel?.segment;
      if (seg != null) {
        final text = seg.timelineStart.toStringAsFixed(2);
        if (_startController.text != text) _startController.text = text;
      }
    }
  }

  void _syncControllers() {
    final sel = widget.selection;
    _titleController.text = switch (sel?.lane) {
      MediaTrack(:final title) => title,
      ExternalTrack(:final title) => title,
      _ => '',
    };
    _startController.text =
        sel?.segment?.timelineStart.toStringAsFixed(2) ?? '';
  }

  @override
  void dispose() {
    _titleController.dispose();
    _startController.dispose();
    _startFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final sel = widget.selection;

    if (sel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ThemeIcons.of(context).select, size: 32,
                  color: theme.resources.textFillColorTertiary),
              const SizedBox(height: 12),
              Text('Selecione uma faixa ou um trecho',
                  style: theme.typography.bodyStrong,
                  textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(
                'Clique em uma faixa na lista ou em um trecho na linha do tempo.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: theme.resources.textFillColorSecondary,
                    fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: sel.clip != null
          ? _clipProps(theme, sel.clip!)
          : sel.segment != null
              ? _segmentProps(theme, sel.lane, sel.segment!)
              : _laneProps(theme, sel.lane),
    );
  }

  // ---------------------------------------------------------------- helpers

  Widget _header(FluentThemeData theme, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 15, color: theme.accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                style: theme.typography.bodyStrong,
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(FluentThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(
                    color: theme.resources.textFillColorSecondary,
                    fontSize: 12)),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  String _laneDisplayName(Object lane) => switch (lane) {
        MediaTrack(:final title, :final type, :final typeIndex) =>
          title.isNotEmpty
              ? title
              : switch (type) {
                  TrackType.video => 'Vídeo ${typeIndex + 1}',
                  TrackType.audio => 'Áudio ${typeIndex + 1}',
                  TrackType.subtitle => 'Legenda ${typeIndex + 1}',
                },
        ExternalTrack(:final title) => title,
        _ => '?',
      };

  // ------------------------------------------------------------------ clip

  List<Widget> _clipProps(FluentThemeData theme, VideoClip clip) {
    final inserted = clip.path != widget.file.path;
    return [
      _header(theme, ThemeIcons.of(context).video,
          inserted ? 'Vídeo inserido' : 'Trecho do vídeo'),
      _infoRow(theme, 'Origem',
          inserted ? p.basename(clip.path) : 'Este arquivo'),
      _infoRow(
          theme,
          'Trecho da origem',
          '${formatTimelineTime(clip.sourceStart)} – '
              '${formatTimelineTime(clip.sourceEnd)}'),
      _infoRow(theme, 'Duração', formatTimelineTime(clip.duration)),
      _infoRow(
          theme,
          'Na linha do tempo',
          '${formatTimelineTime(clip.timelineStart)} – '
              '${formatTimelineTime(clip.timelineEnd)}'),
      _infoRow(theme, 'Imagem', '${clip.width}×${clip.height}'),
      const SizedBox(height: 16),
      Button(
        onPressed: () => widget.onDeleteVideoClip(clip),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ThemeIcons.of(context).delete, size: 13),
          const SizedBox(width: 6),
          const Text('Remover trecho'),
        ]),
      ),
      const SizedBox(height: 8),
      Text(
        'O áudio e as legendas desse pedaço saem junto, e o que vem '
        'depois anda pra trás.',
        style: TextStyle(
            color: theme.resources.textFillColorSecondary, fontSize: 12),
      ),
    ];
  }

  // ---------------------------------------------------------------- segment

  List<Widget> _segmentProps(
      FluentThemeData theme, Object lane, AudioSegment seg) {
    final sourceName = seg.source.path == widget.file.path
        ? 'Áudio ${seg.source.audioTypeIndex + 1} (deste arquivo)'
        : p.basename(seg.source.path);

    return [
      _header(theme, ThemeIcons.of(context).music,
          'Trecho de ${_laneDisplayName(lane)}'),
      _infoRow(theme, 'Origem', sourceName),
      _infoRow(
          theme,
          'Trecho da origem',
          '${formatTimelineTime(seg.sourceStart)} – '
              '${formatTimelineTime(seg.sourceEnd)}'),
      _infoRow(theme, 'Duração', formatTimelineTime(seg.duration)),
      _infoRow(
          theme,
          'Na linha do tempo',
          '${formatTimelineTime(seg.timelineStart)} – '
              '${formatTimelineTime(seg.timelineEnd)}'),
      const SizedBox(height: 8),
      InfoLabel(
        label: 'Início na linha do tempo',
        child: TextBox(
          controller: _startController,
          focusNode: _startFocus,
          placeholder: 'segundos ou mm:ss',
          onSubmitted: (value) {
            final parsed = parseTimelineTime(value);
            if (parsed != null && parsed >= 0) {
              seg.timelineStart = parsed;
              widget.onModelChanged();
            }
          },
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Button(
            onPressed: () => widget.onDeleteSegment(lane, seg),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ThemeIcons.of(context).delete, size: 13),
              SizedBox(width: 6),
              Text('Excluir trecho'),
            ]),
          ),
        ],
      ),
    ];
  }

  // ------------------------------------------------------------------ lane

  List<Widget> _laneProps(FluentThemeData theme, Object lane) {
    final children = <Widget>[];

    final (icon, codec, details, language, duration, isAudio, isSubtitle) =
        switch (lane) {
      MediaTrack(
        :final type,
        :final codec,
        :final details,
        :final language,
        :final durationSeconds
      ) =>
        (
          switch (type) {
            TrackType.video => ThemeIcons.of(context).video,
            TrackType.audio => ThemeIcons.of(context).volume,
            TrackType.subtitle => ThemeIcons.of(context).cc,
          },
          codec,
          details,
          language,
          durationSeconds,
          type == TrackType.audio,
          type == TrackType.subtitle,
        ),
      ExternalTrack(
        :final type,
        :final codec,
        :final details,
        :final language,
        :final durationSeconds
      ) =>
        (
          type == TrackType.audio ? ThemeIcons.of(context).volume : ThemeIcons.of(context).cc,
          codec,
          details,
          language,
          durationSeconds,
          type == TrackType.audio,
          type == TrackType.subtitle,
        ),
      _ => (ThemeIcons.of(context).help, '?', '', null, 0.0, false, false),
    };

    final merges = audioLaneMerges(lane, widget.file.path);
    children.addAll([
      _header(theme, icon, _laneDisplayName(lane)),
      InfoLabel(
        label: 'Título da faixa',
        child: TextBox(
          controller: _titleController,
          placeholder: 'Sem título',
          onChanged: (value) {
            if (lane is MediaTrack) lane.title = value;
            if (lane is ExternalTrack) lane.title = value;
            widget.onModelChanged();
          },
        ),
      ),
      const SizedBox(height: 12),
      _infoRow(theme, 'Codec', codec),
      if (details.isNotEmpty) _infoRow(theme, 'Detalhes', details),
      if (language != null) _infoRow(theme, 'Idioma', language.toUpperCase()),
      if (duration > 0)
        _infoRow(theme, 'Duração', formatTimelineTime(duration)),
    ]);

    if (lane is ExternalTrack) {
      children.add(_infoRow(theme, 'Arquivo', lane.path));
    }
    if (isAudio) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Checkbox(
          checked: merges,
          onChanged: (value) {
            if (lane is MediaTrack) lane.merge = value ?? false;
            if (lane is ExternalTrack) lane.merge = value ?? false;
            widget.onModelChanged();
          },
          content: const Text('Mesclar com as outras faixas ao salvar'),
        ),
      ));
    }
    if (isSubtitle) {
      final offset = switch (lane) {
        MediaTrack(:final offsetSeconds) => offsetSeconds,
        ExternalTrack(:final offsetSeconds) => offsetSeconds,
        _ => 0.0,
      };
      children.add(_infoRow(theme, 'Deslocamento',
          offset == 0 ? 'nenhum' : formatOffset(offset)));
    }

    children.add(const SizedBox(height: 16));

    final actions = <Widget>[];
    if (lane is MediaTrack && isAudio) {
      actions.add(Button(
        onPressed: () => widget.onExportAudio(lane),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ThemeIcons.of(context).download, size: 13),
          SizedBox(width: 6),
          Text('Exportar áudio original'),
        ]),
      ));
    }
    if (lane is MediaTrack) {
      actions.add(Button(
        onPressed: () => widget.onToggleRemoved(lane),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(lane.removed ? ThemeIcons.of(context).restore : ThemeIcons.of(context).delete,
              size: 13),
          const SizedBox(width: 6),
          Text(lane.removed ? 'Restaurar faixa' : 'Remover faixa'),
        ]),
      ));
    }
    if (lane is ExternalTrack) {
      actions.add(Button(
        onPressed: () => widget.onRemoveExternal(lane),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ThemeIcons.of(context).delete, size: 13),
          SizedBox(width: 6),
          Text('Excluir faixa'),
        ]),
      ));
    }

    children.add(Wrap(spacing: 8, runSpacing: 8, children: actions));
    return children;
  }
}
