import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../models/program.dart';
import '../models/tracks.dart';
import '../services/audio_cache.dart';
import '../services/ffmpeg_service.dart';
import '../services/preview_plan.dart';
import '../theme/app_themes.dart';
import '../theme/theme_icons.dart';
import '../widgets/editor_keyboard.dart';
import '../widgets/preview_panel.dart';
import '../widgets/properties_panel.dart';
import '../widgets/save_dialog.dart';
import '../widgets/timeline_panel.dart';

const kLogoAsset = 'assets/logo.png';

Duration _durationOf(double seconds) =>
    Duration(milliseconds: (seconds * 1000).round());

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

  // depois de um seek, o player ainda manda posições antigas por um instante
  double _seekTarget = 0;
  DateTime? _seekGuard;

  // a prévia toca o programa montado (lista de cortes) a partir de cópias
  // das faixas de áudio; recarrega só quando o que se vê ou ouve muda
  AudioCache? _audio;
  PreviewPlan? _shownPlan;
  Timer? _previewTimer;
  int _previewRun = 0;
  // o mpv recusa seek enquanto abre um programa: o cursor mexido nesse meio
  // tempo vai quando ele termina de abrir
  Future<void>? _opening;
  final _warnedFiles = <String>{};

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
    _previewTimer?.cancel();
    _releaseAudio();
    super.dispose();
  }

  void _releaseAudio() {
    final audio = _audio;
    _audio = null;
    if (audio == null) return;
    audio.revision.removeListener(_onAudioReady);
    audio.dispose();
  }

  void _onAudioReady() {
    // o cache avisa de dentro do build às vezes (ao pedir uma forma de onda)
    scheduleMicrotask(() {
      if (!mounted) return;
      setState(() {});
      _applyPreview();
    });
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
      _releaseAudio();
      final audio = AudioCache(_ffmpeg)..revision.addListener(_onAudioReady);
      _audio = audio;
      audio.prefetch([
        for (final track in info.tracks.where((t) => t.type == TrackType.audio))
          AudioSource(path: info.path, audioTypeIndex: track.typeIndex),
      ]);
      audio.silence();
      setState(() {
        _file = info;
        _added.clear();
        _selection = null;
        _playhead = 0;
        _monitorLane = null;
        _warnedFiles.clear();
      });
      await _initPlayer();
    } catch (e) {
      _showError('Não foi possível ler o arquivo', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ------------------------------------------------------------- playback

  Future<void> _initPlayer() async {
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    final old = _player;
    if (mounted) {
      setState(() {
        _player = null;
        _videoController = null;
        _isPlaying = false;
      });
    }
    _shownPlan = null;
    await old?.dispose();

    final player = Player();
    final controller = VideoController(player);
    final native = player.platform;
    if (native is NativePlayer) {
      // a faixa ouvida vem marcada com esse idioma na lista de cortes
      await native.setProperty('alang', kMonitorLanguage);
      // trechos de formatos diferentes não reiniciam a saída de som
      await native.setProperty('audio-samplerate', '48000');
      await native.setProperty('audio-channels', 'stereo');
    }

    _positionSub = player.stream.position.listen((pos) {
      // While playing, the player drives the playhead; user scrubs drive
      // the player via _onScrub instead.
      if (!mounted || !_isPlaying) return;
      final seconds = pos.inMilliseconds / 1000;
      final guard = _seekGuard;
      if (guard != null &&
          DateTime.now().isBefore(guard) &&
          (seconds - _seekTarget).abs() > 0.5) {
        return;
      }
      _seekGuard = null;
      setState(() => _playhead = seconds);
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
    await _applyPreview();
  }

  List<VideoClip>? get _clips => _file?.mainVideo?.clips;

  /// Onde a imagem acaba: o programa editado ou o próprio arquivo.
  double get _contentEnd {
    final clips = _clips;
    return clips == null ? _file?.durationSeconds ?? 0 : programDuration(clips);
  }

  void _seekPlayer(double seconds) {
    _seekTarget = seconds;
    _seekGuard = DateTime.now().add(const Duration(milliseconds: 600));
    if (_opening == null) _player?.seek(_durationOf(seconds));
  }

  /// O player toca o programa montado: o instante dele é o da linha do tempo.
  void _onScrub(double t) {
    setState(() => _playhead = t);
    _seekPlayer(t);
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    if (_isPlaying) {
      await player.pause();
      return;
    }
    // no fim volta ao começo antes de recarregar: o programa novo já abre ali
    if (_playhead >= _contentEnd - 0.05) _onScrub(0);
    // quem acabou de editar ouve a edição, não a versão de antes
    if (_previewTimer?.isActive ?? false) await _applyPreview();
    final opening = _opening;
    if (opening != null) await opening;
    if (!identical(player, _player)) return;
    // acabado, o play do media_kit volta ao instante em que a entrada abriu
    if (player.state.completed) await player.seek(_durationOf(_playhead));
    await player.play();
  }

  void _stepSeconds(double delta) {
    _onScrub((_playhead + delta).clamp(0.0, _contentEnd));
  }

  void _setMonitorLane(Object? lane) {
    setState(() => _monitorLane = lane);
    _applyPreview();
  }

  void _schedulePreview() {
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 300), _applyPreview);
  }

  /// Põe no player o programa como está agora; não recarrega o que não mudou.
  Future<void> _applyPreview() async {
    _previewTimer?.cancel();
    final player = _player;
    final file = _file;
    final audio = _audio;
    if (player == null || file == null || audio == null) return;
    final frame = programFrame(file);
    final silenced = <AudioSource>{};
    final plan = buildPreviewPlan(
      file: file,
      added: _added,
      monitor: _monitorLane,
      audioFile: audio.extracted,
      unavailable: (source) {
        final failed = audio.failed(source);
        if (failed) silenced.add(source);
        return failed;
      },
      silenceFile: audio.silence(),
      blackFile: frame == null
          ? null
          : audio.blackVideo(
              width: frame.width,
              height: frame.height,
              sarNum: frame.sarNum,
              sarDen: frame.sarDen,
            ),
      blackLength: kBlackSeconds,
    );
    _warnSilenced(silenced);
    // uma montagem mais nova cancela a que ainda está gravando a lista
    final run = ++_previewRun;
    if (plan == _shownPlan) return;
    final String? media;
    final String audioId;
    switch (plan) {
      case SourcePreview(:final path, :final audioTrack):
        media = path;
        audioId = audioTrack?.toString() ?? 'no';
      case EdlPreview(:final edl, :final hasAudio):
        media = await audio.writeEdl(edl);
        audioId = hasAudio ? 'auto' : 'no';
      case PendingPreview():
        return;
    }
    if (media == null ||
        run != _previewRun ||
        !mounted ||
        !identical(player, _player)) {
      return;
    }
    _shownPlan = plan;
    final native = player.platform;
    if (native is NativePlayer) await native.setProperty('aid', audioId);
    if (run != _previewRun || !identical(player, _player)) return;
    final at = _playhead;
    _seekTarget = at;
    _seekGuard = DateTime.now().add(const Duration(milliseconds: 1500));
    final opening = _openAt(player, media, at);
    _opening = opening;
    try {
      await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
    if (identical(player, _player) && _seekTarget != at) {
      _seekPlayer(_seekTarget);
    }
  }

  /// Abre [media] em [at] e espera o mpv carregar: o open do media_kit volta
  /// antes. Arquivo que não abre não segura a prévia.
  Future<void> _openAt(Player player, String media, double at) async {
    await player.open(Media(media, start: _durationOf(at)), play: _isPlaying);
    if (player.state.duration > Duration.zero) return;
    await player.stream.duration
        .timeout(const Duration(seconds: 5), onTimeout: (sink) => sink.close())
        .firstWhere((d) => d > Duration.zero, orElse: () => Duration.zero);
  }

  void _warnSilenced(Set<AudioSource> sources) {
    final files =
        {for (final source in sources) source.path}.difference(_warnedFiles);
    if (files.isEmpty) return;
    _warnedFiles.addAll(files);
    _showError(
        'Prévia sem parte do áudio',
        'Não deu pra preparar o áudio de ${files.map(p.basename).join(', ')} '
            'para a prévia: esses trechos tocam em silêncio. O vídeo salvo '
            'não é afetado.');
  }

  void _forgetMonitor(Object lane) {
    if (identical(_monitorLane, lane)) _setMonitorLane(null);
    _schedulePreview();
  }

  // ------------------------------------------------------------ video edits

  Future<void> _insertVideo() async {
    final file = _file;
    if (file?.mainVideo == null) return;
    final picked = await _guard(() => FilePicker.pickFiles(
          dialogTitle: 'Inserir vídeo no cursor',
          type: FileType.custom,
          allowedExtensions: ['mp4', 'mkv', 'mov', 'm4v', 'webm', 'avi'],
        ));
    final path = picked?.files.single.path;
    if (path == null || file == null) return;
    setState(() => _loading = true);
    try {
      final insertable = await _ffmpeg.probeVideoClip(path);
      if (insertable == null) {
        _showError('Vídeo inválido', '"${p.basename(path)}" não tem imagem.');
        return;
      }
      final at = _playhead.clamp(0.0, _contentEnd);
      setState(() {
        ProgramEdit(file, _added).insert(
          insertable.clip,
          at: at,
          audio: insertable.audioDuration > 0
              ? AudioSource(path: path, audioTypeIndex: 0)
              : null,
          audioDuration: insertable.audioDuration,
        );
        _selection =
            TimelineSelection(lane: file.mainVideo!, clip: insertable.clip);
      });
      _onScrub(at);
      _schedulePreview();
      _showInfo('${p.basename(path)} entrou em ${formatTimelineTime(at)}');
    } catch (e) {
      _showError('Não foi possível ler "${p.basename(path)}"', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Tira o trecho do vídeo e, junto, o áudio e a legenda desse pedaço.
  Future<void> _deleteVideoClip(VideoClip clip) async {
    final file = _file;
    final clips = _clips;
    if (file == null || clips == null) return;
    if (clips.length == 1) {
      _showError('Não dá pra remover',
          'O vídeo precisa de pelo menos um trecho. Divida antes (S) e '
              'remova só o pedaço que não quer.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Remover trecho do vídeo'),
        content: Text(
            'Sai de ${formatTimelineTime(clip.timelineStart)} a '
            '${formatTimelineTime(clip.timelineEnd)}. O áudio e as legendas '
            'desse pedaço também saem, e tudo o que vem depois anda junto.'),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    late List<Object> emptied;
    setState(() {
      emptied =
          ProgramEdit(file, _added).cut(clip.timelineStart, clip.timelineEnd);
      for (final lane in emptied) {
        if (lane is MediaTrack) lane.removed = true;
        if (lane is ExternalTrack) _added.remove(lane);
      }
      _selection = null;
    });
    emptied.forEach(_forgetMonitor);
    _onScrub(math.min(clip.timelineStart, _contentEnd));
    _schedulePreview();
  }

  void _removeExternal(ExternalTrack track) {
    setState(() {
      _added.remove(track);
      if (identical(_selection?.lane, track)) _selection = null;
    });
    _forgetMonitor(track);
  }

  List<MonitorOption> _monitorOptions() {
    final file = _file;
    if (file == null) return const [];
    return [
      const MonitorOption(lane: null, label: 'Áudio padrão'),
      for (final lane in audioLanesInOrder(file, _added))
        MonitorOption(
          lane: lane,
          label: audioOutputOf(lane, file, _added).length > 1
              ? '${_laneName(lane)} (mescla)'
              : _laneName(lane),
        ),
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
        _schedulePreview();
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
    _forgetMonitor(lane);
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
    _schedulePreview();
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
    FfmpegRunResult result;
    try {
      result = await _ffmpeg.exportAudioTrack(
        sourcePath: file.path,
        audioTypeIndex: track.typeIndex,
        outputPath: outputPath,
      );
    } catch (e) {
      result = FfmpegRunResult(exitCode: -1, stderr: e.toString());
    }
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

    // salvar por cima do original muda o arquivo que o editor descreve
    final replacesSource = await isSameFile(outputPath, file.path);
    if (!mounted) return;
    final format = await showSaveDialog(
      context,
      videoEdited: !programUntouched(file),
      warningsFor: (format) => _ffmpeg.saveWarnings(
        source: file,
        added: _added,
        outputPath: outputPath,
        videoFormat: format,
      ),
    );
    if (format == null) return;

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

    FfmpegRunResult result;
    try {
      result = await _ffmpeg.save(
        source: file,
        added: _added,
        outputPath: outputPath,
        videoFormat: format,
        onProgress: (v) => progress.value = v,
      );
    } catch (e) {
      result = FfmpegRunResult(exitCode: -1, stderr: e.toString());
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (!result.success) {
      _showError('Falha ao salvar o vídeo', result.errorTail);
      return;
    }
    if (replacesSource) {
      await _loadFile(file.path);
      _showInfo('Vídeo salvo e reaberto com as alterações');
    } else {
      _showInfo('Vídeo salvo em ${p.basename(outputPath)}');
    }
  }

  // ------------------------------------------------------------------- ui

  void _showInfo(String message) {
    if (!mounted) return;
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
                Image.asset(kLogoAsset,
                    width: 18, height: 18, filterQuality: FilterQuality.medium),
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
          Image.asset(kLogoAsset,
              width: 72, height: 72, filterQuality: FilterQuality.medium),
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

  KeyEventResult _handleKey(KeyEvent event) {
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
    final clips = _clips;
    if (clips != null && identical(sel.lane, _file?.mainVideo)) {
      final clip = clips.where((c) => c.containsTimeline(_playhead)).firstOrNull;
      if (clip == null || !splitSegment(clips, clip, _playhead)) return false;
      setState(() =>
          _selection = TimelineSelection(lane: sel.lane, clip: clip));
      return true;
    }
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
    _schedulePreview();
    return true;
  }

  /// Del/Backspace: deletes the selected segment, or removes the selected
  /// track entirely when no segment is selected.
  bool _deleteSelected() {
    final sel = _selection;
    if (sel == null) return false;
    if (sel.clip != null) {
      _deleteVideoClip(sel.clip!);
      return true;
    }
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
      _removeExternal(lane);
      return true;
    }
    return false;
  }

  void _onTimelineModelChanged() {
    setState(() {});
    _schedulePreview();
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
            sourceDuration: track.durationSeconds,
          ));
        }
      } else {
        track.removed = true;
        if (identical(_selection?.lane, track)) _selection = null;
      }
    });
    if (track.removed) _forgetMonitor(track);
    _schedulePreview();
  }

  Widget _buildEditor(FluentThemeData theme) {
    final file = _file!;
    return EditorKeyboard(
      onKey: _handleKey,
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
                        durationSeconds: _contentEnd,
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
                        onRemoveExternal: _removeExternal,
                        onDeleteSegment: _deleteSegment,
                        onDeleteVideoClip: _deleteVideoClip,
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
                    onDeleteVideoClip: _deleteVideoClip,
                    waveformOf: (source) => _audio?.waveform(source),
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
        _buildSection(theme, 'Vídeo', ThemeIcons.of(context).video, TrackType.video,
            onAdd: file.mainVideo == null ? null : _insertVideo,
            addTooltip: 'Inserir vídeo no cursor'),
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
      {VoidCallback? onAdd, String addTooltip = 'Adicionar arquivo'}) {
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
                  message: addTooltip,
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
      if (identical(track, _file!.mainVideo) && !programUntouched(_file!))
        'editado',
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
              onPressed: () => _removeExternal(track),
            ),
          ),
        ],
      ),
    );
  }
}
