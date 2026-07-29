import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../models/tracks.dart';
import '../services/ffmpeg_service.dart';
import '../theme/app_themes.dart';
import '../theme/theme_icons.dart';
import '../widgets/preview_panel.dart';
import '../widgets/properties_panel.dart';
import '../widgets/timeline_panel.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.initialPath});

  /// Optional video to load on startup (command-line argument).
  final String? initialPath;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _ffmpeg = FfmpegService();
  bool _ffmpegChecked = false;
  bool _loading = false;

  MediaFileInfo? _file;
  final List<ExternalTrack> _added = [];
  TimelineSelection? _selection;

  // ---- preview/playback state
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  bool _isPlaying = false;
  double _playhead = 0;
  Object? _monitorLane;

  @override
  void initState() {
    super.initState();
    _checkFfmpeg();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _checkFfmpeg() async {
    await _ffmpeg.locate();
    if (!mounted) return;
    setState(() => _ffmpegChecked = true);
    final initial = widget.initialPath;
    if (_ffmpeg.available && initial != null) {
      await _loadFile(initial);
    }
  }

  Future<void> _loadFile(String path) async {
    setState(() => _loading = true);
    try {
      final info = await _ffmpeg.probe(path);
      setState(() {
        _file = info;
        _added.clear();
        _selection = null;
        _playhead = 0;
        _monitorLane = null;
      });
      await _initPlayer(path);
    } catch (e) {
      _showError('Não foi possível ler o arquivo', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ------------------------------------------------------------- playback

  Future<void> _initPlayer(String path) async {
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await _player?.dispose();

    final player = Player();
    final controller = VideoController(player);
    await player.open(Media(path), play: false);

    _positionSub = player.stream.position.listen((pos) {
      // While playing, the player drives the playhead; user scrubs drive
      // the player via _onScrub instead.
      if (mounted && _isPlaying) {
        setState(() => _playhead = pos.inMilliseconds / 1000);
      }
    });
    _playingSub = player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });

    if (!mounted) {
      player.dispose();
      return;
    }
    setState(() {
      _player = player;
      _videoController = controller;
    });
  }

  void _onScrub(double t) {
    setState(() => _playhead = t);
    _player?.seek(Duration(milliseconds: (t * 1000).round()));
    _syncAudioDelay();
  }

  void _togglePlay() {
    final player = _player;
    if (player == null) return;
    _syncAudioDelay();
    player.playOrPause();
  }

  void _stepSeconds(double delta) {
    _onScrub((_playhead + delta).clamp(0.0, double.infinity));
  }

  Future<void> _setMonitorLane(Object? lane) async {
    final player = _player;
    if (player == null) return;
    setState(() => _monitorLane = lane);

    if (lane == null) {
      await player.setAudioTrack(AudioTrack.auto());
    } else if (lane is ExternalTrack) {
      await player.setAudioTrack(AudioTrack.uri(lane.path, title: lane.title));
    } else if (lane is MediaTrack) {
      final real = player.state.tracks.audio
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList();
      if (lane.typeIndex < real.length) {
        await player.setAudioTrack(real[lane.typeIndex]);
      }
    }
    _syncAudioDelay();
  }

  /// Approximates the edited timeline while previewing: applies the shift
  /// (timelineStart - sourceStart) of the monitored lane's segment under
  /// the playhead as mpv's audio-delay.
  void _syncAudioDelay() {
    final player = _player;
    if (player == null) return;
    final segments = switch (_monitorLane) {
      MediaTrack(:final segments) => segments,
      ExternalTrack(:final segments) => segments,
      _ => null,
    };
    var delay = 0.0;
    if (segments != null && segments.isNotEmpty) {
      final seg = segments
              .where((s) =>
                  s.timelineStart <= _playhead && _playhead < s.timelineEnd)
              .firstOrNull ??
          segments.first;
      delay = seg.timelineStart - seg.sourceStart;
    }
    final platform = player.platform;
    if (platform is NativePlayer) {
      platform.setProperty('audio-delay', delay.toStringAsFixed(3));
    }
  }

  List<MonitorOption> _monitorOptions() {
    return [
      const MonitorOption(lane: null, label: 'Áudio padrão'),
      ...?_file?.tracks
          .where((t) => t.type == TrackType.audio && !t.removed)
          .map((t) => MonitorOption(lane: t, label: _laneName(t))),
      ..._added
          .where((t) => t.type == TrackType.audio)
          .map((t) => MonitorOption(lane: t, label: t.title)),
    ];
  }

  // ---------------------------------------------------------------- actions

  /// Runs a file picker call, surfacing errors in a dialog instead of
  /// swallowing them (e.g. plugin/entitlement failures).
  Future<T?> _guard<T>(Future<T?> Function() action) async {
    try {
      return await action();
    } catch (e) {
      _showError('Falha ao abrir o seletor de arquivos', e.toString());
      return null;
    }
  }

  Future<void> _openFile() async {
    final result = await _guard(() => FilePicker.pickFiles(
          dialogTitle: 'Selecionar vídeo',
          type: FileType.custom,
          allowedExtensions: ['mp4', 'mkv'],
        ));
    final path = result?.files.single.path;
    if (path == null) return;
    await _loadFile(path);
  }

  Future<void> _addExternal(TrackType type) async {
    final isAudio = type == TrackType.audio;
    final result = await _guard(() => FilePicker.pickFiles(
          dialogTitle:
              isAudio ? 'Adicionar faixa de áudio' : 'Adicionar legenda',
          type: FileType.custom,
          allowedExtensions: isAudio
              ? ['mp3', 'aac', 'm4a', 'ac3', 'eac3', 'flac', 'wav', 'opus', 'ogg', 'dts', 'mka']
              : ['srt', 'ass', 'ssa', 'vtt', 'sub'],
          allowMultiple: true,
        ));
    if (result == null) return;

    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      try {
        final track = await _ffmpeg.probeExternal(path, type);
        if (track == null) {
          _showError('Faixa inválida',
              '"${p.basename(path)}" não contém uma faixa de ${isAudio ? 'áudio' : 'legenda'}.');
          continue;
        }
        setState(() => _added.add(track));
      } catch (e) {
        _showError('Não foi possível ler "${p.basename(path)}"', e.toString());
      }
    }
  }

  // ------------------------------------------------------------- timeline

  void _onLaneEmptied(Object lane) {
    setState(() {
      if (lane is MediaTrack) lane.removed = true;
      if (lane is ExternalTrack) _added.remove(lane);
    });
  }

  void _deleteSegment(Object lane, AudioSegment segment) {
    final segments = switch (lane) {
      MediaTrack(:final segments) => segments,
      ExternalTrack(:final segments) => segments,
      _ => null,
    };
    if (segments == null) return;
    setState(() {
      segments.remove(segment);
      _selection =
          segments.isEmpty ? null : TimelineSelection(lane: lane);
    });
    if (segments.isEmpty) _onLaneEmptied(lane);
  }

  String _laneName(Object lane) => switch (lane) {
        MediaTrack(:final title, :final typeIndex) =>
          title.isNotEmpty ? title : 'Áudio ${typeIndex + 1}',
        ExternalTrack(:final title) => title,
        _ => '?',
      };

  Future<void> _editSubtitleOffset(Object ref) async {
    final current = switch (ref) {
      MediaTrack(:final offsetSeconds) => offsetSeconds,
      ExternalTrack(:final offsetSeconds) => offsetSeconds,
      _ => 0.0,
    };
    final controller = TextEditingController(
        text: current.toStringAsFixed(2).replaceFirst('-', '−'));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Deslocamento da legenda'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Em segundos. Positivo atrasa; negativo adianta.'),
            const SizedBox(height: 8),
            TextBox(
              controller: controller,
              placeholder: 'ex.: 1.5 ou -2',
              autofocus: true,
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, '0'),
            child: const Text('Zerar'),
          ),
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
    if (parsed == null) {
      _showError('Valor inválido', 'Use um número em segundos, ex.: 1.5 ou -2');
      return;
    }
    setState(() {
      if (ref is MediaTrack) ref.offsetSeconds = parsed.clamp(-3600, 3600);
      if (ref is ExternalTrack) ref.offsetSeconds = parsed.clamp(-3600, 3600);
    });
  }

  // --------------------------------------------------------------- ffmpeg

  Future<void> _exportAudio(MediaTrack track) async {
    final file = _file!;
    final ext = FfmpegService.audioExportExtension(track.codec);
    final base = p.basenameWithoutExtension(file.path);
    final name =
        track.title.isNotEmpty ? track.title : 'faixa_${track.typeIndex + 1}';
    final safeName = name.replaceAll(RegExp(r'[/\\:]'), '_');

    final outputPath = await _guard(() => FilePicker.saveFile(
          dialogTitle: 'Exportar faixa de áudio',
          fileName: '${base}_$safeName.$ext',
          type: FileType.custom,
          allowedExtensions: [ext],
        ));
    if (outputPath == null) return;

    setState(() => _loading = true);
    final result = await _ffmpeg.exportAudioTrack(
      sourcePath: file.path,
      audioTypeIndex: track.typeIndex,
      outputPath: outputPath,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (result.success) {
      _showInfo('Faixa exportada para ${p.basename(outputPath)}');
    } else {
      _showError('Falha ao exportar a faixa', result.errorTail);
    }
  }

  Future<void> _save() async {
    final file = _file!;
    _player?.pause();
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    final base = p.basenameWithoutExtension(file.path);

    final outputPath = await _guard(() => FilePicker.saveFile(
          dialogTitle: 'Salvar vídeo',
          fileName: '${base}_editado.$ext',
          type: FileType.custom,
          allowedExtensions: ['mp4', 'mkv'],
        ));
    if (outputPath == null) return;

    final warnings = _ffmpeg.saveWarnings(
        source: file, added: _added, outputPath: outputPath);
    if (warnings.isNotEmpty && mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => ContentDialog(
          title: const Text('Avisos antes de salvar'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final w in warnings) Text('• $w')],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final progress = ValueNotifier<double>(0);
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ContentDialog(
        title: const Text('Salvando vídeo...'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProgressBar(value: value > 0 ? value * 100 : null),
              const SizedBox(height: 8),
              Text('${(value * 100).round()}%'),
            ],
          ),
        ),
      ),
    );

    final result = await _ffmpeg.save(
      source: file,
      added: _added,
      outputPath: outputPath,
      onProgress: (v) => progress.value = v,
    );

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (result.success) {
      _showInfo('Vídeo salvo em ${p.basename(outputPath)}');
    } else {
      _showError('Falha ao salvar o vídeo', result.errorTail);
    }
  }

  // ------------------------------------------------------------------- ui

  void _showInfo(String message) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: Text(message),
        severity: InfoBarSeverity.success,
        onClose: close,
      ),
    );
  }

  void _showError(String title, String detail) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(detail, style: const TextStyle(fontSize: 13)),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    // Paint the theme background ourselves — there is no ScaffoldPage here.
    final content = ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          _buildTopBar(theme),
          Container(
              height: 1, color: theme.resources.dividerStrokeColorDefault),
          Expanded(
            child: !_ffmpegChecked
                ? const Center(child: ProgressRing())
                : !_ffmpeg.available
                    ? _buildFfmpegMissing()
                    : _file == null
                        ? _buildEmptyState()
                        : _buildEditor(theme),
          ),
        ],
      ),
    );
    // The native menu bar only exists on macOS; elsewhere the theme picker
    // lives in the top bar instead.
    if (!Platform.isMacOS) return content;
    return PlatformMenuBar(menus: _buildMenuBar(), child: content);
  }

  /// Native macOS menu bar: Arquivo, Temas, Ajuda.
  List<PlatformMenu> _buildMenuBar() {
    final scope = AppThemeScope.of(context);
    return [
      PlatformMenu(
        label: 'Video Toolkit',
        menus: [
          if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.about))
            const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about),
          if (PlatformProvidedMenuItem.hasMenu(
              PlatformProvidedMenuItemType.quit))
            const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit),
        ],
      ),
      PlatformMenu(
        label: 'Arquivo',
        menus: [
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Abrir vídeo…',
                shortcut:
                    const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
                onSelected: _loading ? null : _openFile,
              ),
              PlatformMenuItem(
                label: 'Salvar…',
                shortcut:
                    const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
                onSelected: _file == null || _loading ? null : _save,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              PlatformMenuItem(
                label: 'Adicionar faixa de áudio…',
                onSelected: _file == null
                    ? null
                    : () => _addExternal(TrackType.audio),
              ),
              PlatformMenuItem(
                label: 'Adicionar legenda…',
                onSelected: _file == null
                    ? null
                    : () => _addExternal(TrackType.subtitle),
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: 'Temas',
        menus: [
          PlatformMenuItemGroup(
            members: [
              for (final t in appThemes)
                PlatformMenuItem(
                  label: '${t.id == scope.spec.id ? '✓' : '　'} ${t.name}',
                  onSelected: () => scope.setTheme(t),
                ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: 'Ajuda',
        menus: [
          PlatformMenuItem(
            label: 'Sobre o Video Toolkit',
            onSelected: () => _showError(
              'Video Toolkit',
              'Editor de faixas de áudio, vídeo e legendas para arquivos '
                  'MP4/MKV, usando FFmpeg.\n\n'
                  'Atalhos: espaço = play/pause · S = dividir · '
                  'Del = excluir · ⌘O abrir · ⌘S salvar.',
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildTopBar(FluentThemeData theme) {
    final spec = AppThemeScope.specOf(context);
    final gradient = spec.topBarGradient.length > 1
        ? spec.topBarGradient
        : [spec.topBarGradient.first, spec.topBarGradient.first];

    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            for (final c in gradient)
              spec.translucent ? c.withValues(alpha: 0.78) : c,
          ],
        ),
      ),
      child: Row(
        children: [
          // Left cluster inside an Expanded so all leftover space stays
          // here and the buttons hug the right edge of the window.
          Expanded(
            child: Row(
              children: [
                Icon(ThemeIcons.of(context).video,
                    size: 16, color: spec.topBarText),
                const SizedBox(width: 8),
                Text('Video Toolkit',
                    style: theme.typography.bodyStrong
                        ?.copyWith(color: spec.topBarText)),
                if (_file != null) ...[
                  const SizedBox(width: 12),
                  Icon(ThemeIcons.of(context).chevronRight, size: 10,
                      color: spec.topBarText.withValues(alpha: 0.6)),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      p.basename(_file!.path),
                      style: theme.typography.body?.copyWith(
                          color: spec.topBarText.withValues(alpha: 0.9)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!Platform.isMacOS) ...[
            // Without a native menu bar, themes are picked here.
            Tooltip(
              message: 'Tema do aplicativo',
              child: DropDownButton(
                title: Text(spec.name),
                items: [
                  for (final t in appThemes)
                    MenuFlyoutItem(
                      text: Text(t.name),
                      selected: t.id == spec.id,
                      onPressed: () =>
                          AppThemeScope.of(context).setTheme(t),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          Button(
            onPressed: _loading ? null : _openFile,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ThemeIcons.of(context).open, size: 13),
              SizedBox(width: 6),
              Text('Abrir'),
            ]),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _file == null || _loading ? null : _save,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(ThemeIcons.of(context).save, size: 13),
              SizedBox(width: 6),
              Text('Salvar'),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildFfmpegMissing() {
    return Center(
      child: SizedBox(
        width: 420,
        child: Card(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ThemeIcons.of(context).warning, size: 40, color: Colors.orange),
              const SizedBox(height: 16),
              Text('FFmpeg não encontrado',
                  style: FluentTheme.of(context).typography.subtitle),
              const SizedBox(height: 8),
              const Text('Este aplicativo precisa do FFmpeg. Instale com:'),
              const SizedBox(height: 8),
              SelectableText(
                Platform.isMacOS
                    ? 'brew install ffmpeg'
                    : Platform.isWindows
                        ? 'winget install ffmpeg'
                        : 'sudo apt install ffmpeg',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() => _ffmpegChecked = false);
                  _checkFfmpeg();
                },
                child: const Text('Verificar novamente'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = FluentTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ThemeIcons.of(context).video, size: 56,
              color: theme.resources.textFillColorTertiary),
          const SizedBox(height: 16),
          Text('Nenhum vídeo aberto', style: theme.typography.subtitle),
          const SizedBox(height: 8),
          Text('Abra um arquivo .mp4 ou .mkv para editar suas faixas.',
              style: TextStyle(color: theme.resources.textFillColorSecondary)),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _loading ? null : _openFile,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text('Abrir vídeo'),
            ),
          ),
          if (_loading) ...[
            const SizedBox(height: 24),
            const ProgressRing(),
          ],
        ],
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final typing = focusedContext?.widget is EditableText ||
        focusedContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (typing) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      return _splitAtPlayhead()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      return _deleteSelected()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  /// S key: splits the selected lane's segment under the playhead.
  bool _splitAtPlayhead() {
    final sel = _selection;
    if (sel == null) return false;
    final segments = switch (sel.lane) {
      MediaTrack(type: TrackType.audio, :final segments) => segments,
      ExternalTrack(type: TrackType.audio, :final segments) => segments,
      _ => null,
    };
    if (segments == null) return false;

    var seg = sel.segment;
    if (seg == null || !seg.containsTimeline(_playhead)) {
      seg = segments.where((s) => s.containsTimeline(_playhead)).firstOrNull;
    }
    if (seg == null || !splitSegment(segments, seg, _playhead)) return false;
    setState(() {
      _selection = TimelineSelection(lane: sel.lane, segment: seg);
    });
    _syncAudioDelay();
    return true;
  }

  /// Del/Backspace: deletes the selected segment, or removes the selected
  /// track entirely when no segment is selected.
  bool _deleteSelected() {
    final sel = _selection;
    if (sel == null) return false;
    if (sel.segment != null) {
      _deleteSegment(sel.lane, sel.segment!);
      return true;
    }
    final lane = sel.lane;
    if (lane is MediaTrack) {
      if (!lane.removed) _toggleRemoved(lane);
      return true;
    }
    if (lane is ExternalTrack) {
      setState(() {
        _added.remove(lane);
        _selection = null;
      });
      return true;
    }
    return false;
  }

  void _onTimelineModelChanged() {
    setState(() {});
    _syncAudioDelay();
  }

  void _toggleRemoved(MediaTrack track) {
    setState(() {
      if (track.removed) {
        track.removed = false;
        // A lane whose segments were all deleted (or merged away) would
        // otherwise come back empty and be silently dropped on save.
        if (track.type == TrackType.audio &&
            track.segments.isEmpty &&
            _file != null) {
          track.segments.add(AudioSegment(
            source: AudioSource(
                path: _file!.path, audioTypeIndex: track.typeIndex),
            sourceStart: 0,
            sourceEnd: track.durationSeconds,
            timelineStart: 0,
          ));
        }
      } else {
        track.removed = true;
        if (identical(_selection?.lane, track)) _selection = null;
      }
    });
  }

  Widget _buildEditor(FluentThemeData theme) {
    final file = _file!;
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                        width: 280, child: _buildTracksPanel(theme, file)),
                    Container(
                        width: 1,
                        color: theme.resources.dividerStrokeColorDefault),
                    Expanded(
                      child: PreviewPanel(
                        controller: _videoController,
                        isPlaying: _isPlaying,
                        playhead: _playhead,
                        durationSeconds: file.durationSeconds,
                        onTogglePlay: _togglePlay,
                        onStepSeconds: _stepSeconds,
                        monitorOptions: _monitorOptions(),
                        monitorLane: _monitorLane,
                        onMonitorChanged: _setMonitorLane,
                      ),
                    ),
                    Container(
                        width: 1,
                        color: theme.resources.dividerStrokeColorDefault),
                    SizedBox(
                      width: 300,
                      child: PropertiesPanel(
                        file: file,
                        selection: _selection,
                        onModelChanged: _onTimelineModelChanged,
                        onExportAudio: _exportAudio,
                        onToggleRemoved: _toggleRemoved,
                        onRemoveExternal: (track) => setState(() {
                          _added.remove(track);
                          if (identical(_selection?.lane, track)) {
                            _selection = null;
                          }
                        }),
                        onDeleteSegment: _deleteSegment,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                  height: 1,
                  color: theme.resources.dividerStrokeColorDefault),
              SizedBox(
                height: 290,
                child: ColoredBox(
                  color: AppThemeScope.specOf(context).translucent
                      ? theme.cardColor.withValues(alpha: 0.45)
                      : theme.resources.solidBackgroundFillColorBase,
                  child: TimelinePanel(
                    file: file,
                    added: _added,
                    selection: _selection,
                    playhead: _playhead,
                    onScrub: _onScrub,
                    onSelectionChanged: (s) => setState(() => _selection = s),
                    onModelChanged: _onTimelineModelChanged,
                    onLaneEmptied: _onLaneEmptied,
                    onEditSubtitleOffset: _editSubtitleOffset,
                  ),
                ),
              ),
            ],
          ),
          if (_loading)
            Container(
              color: const Color(0x66000000),
              child: const Center(child: ProgressRing()),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ tracks panel

  Widget _buildTracksPanel(FluentThemeData theme, MediaFileInfo file) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _buildFileCard(theme, file),
        const SizedBox(height: 12),
        _buildSection(theme, 'Vídeo', ThemeIcons.of(context).video, TrackType.video),
        _buildSection(theme, 'Áudio', ThemeIcons.of(context).volume, TrackType.audio,
            onAdd: () => _addExternal(TrackType.audio)),
        _buildSection(theme, 'Legendas', ThemeIcons.of(context).cc, TrackType.subtitle,
            onAdd: () => _addExternal(TrackType.subtitle)),
      ],
    );
  }

  Widget _buildFileCard(FluentThemeData theme, MediaFileInfo file) {
    final durationText = formatTimelineTime(file.durationSeconds);
    final sizeText =
        '${(file.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return Card(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Icon(ThemeIcons.of(context).video, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.basename(file.path),
                    style: theme.typography.bodyStrong,
                    overflow: TextOverflow.ellipsis),
                Text(
                  '${file.formatName.split(',').first.toUpperCase()} · $durationText · $sizeText',
                  style: theme.typography.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _audioEdited(Object track) {
    final (segments, ownPath, ownTypeIndex, duration) = switch (track) {
      MediaTrack(:final segments, :final typeIndex, :final durationSeconds) =>
        (segments, _file!.path, typeIndex, durationSeconds),
      ExternalTrack(:final segments, :final path, :final durationSeconds) =>
        (segments, path, 0, durationSeconds),
      _ => (null, '', 0, 0.0),
    };
    if (segments == null) return false;
    if (segments.length != 1) return true;
    final s = segments.single;
    return s.source != AudioSource(path: ownPath, audioTypeIndex: ownTypeIndex) ||
        s.sourceStart.abs() > 0.005 ||
        s.sourceEnd < duration - 0.05 ||
        s.timelineStart.abs() > 0.005;
  }

  Widget _buildSection(
      FluentThemeData theme, String title, IconData icon, TrackType type,
      {VoidCallback? onAdd}) {
    final tracks = _file!.byType(type);
    final external = _added.where((t) => t.type == type).toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13),
              const SizedBox(width: 6),
              Text(title, style: theme.typography.bodyStrong),
              const SizedBox(width: 6),
              Text('${tracks.length + external.length}',
                  style: theme.typography.caption),
              const Spacer(),
              if (onAdd != null)
                Tooltip(
                  message: 'Adicionar arquivo',
                  child: IconButton(
                    icon: Icon(ThemeIcons.of(context).add, size: 12),
                    onPressed: onAdd,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          if (tracks.isEmpty && external.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 4),
              child: Text('Nenhuma faixa',
                  style: TextStyle(
                      color: theme.resources.textFillColorTertiary,
                      fontSize: 12)),
            ),
          ...tracks.map((t) => _buildTrackRow(theme, t)),
          ...external.map((t) => _buildExternalRow(theme, t)),
        ],
      ),
    );
  }

  Widget _trackRowShell({
    required FluentThemeData theme,
    required Object ref,
    required bool removed,
    required Widget child,
  }) {
    final selected = identical(_selection?.lane, ref);
    return GestureDetector(
      onTap: () =>
          setState(() => _selection = TimelineSelection(lane: ref)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.accentColor.withValues(alpha: 0.12)
              : theme.resources.subtleFillColorTertiary,
          borderRadius: BorderRadius.circular(
              AppThemeScope.specOf(context).cornerRadius.clamp(0.0, 8.0)),
          border: selected
              ? Border.all(color: theme.accentColor.withValues(alpha: 0.6))
              : null,
        ),
        child: Opacity(opacity: removed ? 0.45 : 1, child: child),
      ),
    );
  }

  Widget _buildTrackRow(FluentThemeData theme, MediaTrack track) {
    final flags = <String>[
      if (track.titleChanged) 'renomeada',
      if (track.type == TrackType.audio && _audioEdited(track)) 'editada',
      if (track.type == TrackType.subtitle && track.offsetSeconds != 0)
        'deslocada ${formatOffset(track.offsetSeconds)}',
    ];
    return _trackRowShell(
      theme: theme,
      ref: track,
      removed: track.removed,
      child: Row(
        children: [
          Icon(
            switch (track.type) {
              TrackType.video => ThemeIcons.of(context).video,
              TrackType.audio => ThemeIcons.of(context).volume,
              TrackType.subtitle => ThemeIcons.of(context).cc,
            },
            size: 13,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title.isEmpty ? 'Sem título' : track.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: track.title.isEmpty ? FontStyle.italic : null,
                    decoration:
                        track.removed ? TextDecoration.lineThrough : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    track.codec,
                    if (track.language != null)
                      track.language!.toUpperCase(),
                    ...flags,
                  ].join(' · '),
                  style: theme.typography.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Tooltip(
            message: track.removed ? 'Restaurar' : 'Remover',
            child: IconButton(
              icon: Icon(
                  track.removed ? ThemeIcons.of(context).restore : ThemeIcons.of(context).delete,
                  size: 13),
              onPressed: () => _toggleRemoved(track),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExternalRow(FluentThemeData theme, ExternalTrack track) {
    return _trackRowShell(
      theme: theme,
      ref: track,
      removed: false,
      child: Row(
        children: [
          Icon(
            track.type == TrackType.audio
                ? ThemeIcons.of(context).volume
                : ThemeIcons.of(context).cc,
            size: 13,
            color: const Color(0xFF0F7B0F),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title.isEmpty ? 'Sem título' : track.title,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
                Text(
                  ['nova', track.codec, p.basename(track.path)].join(' · '),
                  style: theme.typography.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Tooltip(
            message: 'Remover',
            child: IconButton(
              icon: Icon(ThemeIcons.of(context).delete, size: 13),
              onPressed: () => setState(() {
                _added.remove(track);
                if (identical(_selection?.lane, track)) _selection = null;
              }),
            ),
          ),
        ],
      ),
    );
  }
}
