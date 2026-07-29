import 'package:fluent_ui/fluent_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../theme/theme_icons.dart';
import 'timeline_panel.dart';

/// One selectable "listen to this lane" entry in the monitor dropdown.
class MonitorOption {
  const MonitorOption({required this.lane, required this.label});

  /// MediaTrack | ExternalTrack (audio lanes only); null = player default.
  final Object? lane;
  final String label;
}

/// Center panel: video preview with transport controls and a selector for
/// which audio lane to listen to while aligning dialogue.
class PreviewPanel extends StatelessWidget {
  const PreviewPanel({
    super.key,
    required this.controller,
    required this.isPlaying,
    required this.playhead,
    required this.durationSeconds,
    required this.onTogglePlay,
    required this.onStepSeconds,
    required this.monitorOptions,
    required this.monitorLane,
    required this.onMonitorChanged,
  });

  final VideoController? controller;
  final bool isPlaying;
  final double playhead;
  final double durationSeconds;
  final VoidCallback onTogglePlay;

  /// Seek relative to the current playhead (e.g. -5 / +5 seconds).
  final void Function(double seconds) onStepSeconds;

  final List<MonitorOption> monitorOptions;
  final Object? monitorLane;
  final ValueChanged<Object?> onMonitorChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return Column(
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: controller == null
                ? Icon(ThemeIcons.of(context).video, size: 48,
                    color: theme.resources.textFillColorTertiary)
                : Video(
                    controller: controller!,
                    controls: NoVideoControls,
                    fill: Colors.black,
                  ),
          ),
        ),
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: theme.resources.solidBackgroundFillColorBase,
          child: Row(
            children: [
              Tooltip(
                message: 'Voltar 5 s',
                child: IconButton(
                  icon: Icon(ThemeIcons.of(context).rewind, size: 14),
                  onPressed:
                      controller == null ? null : () => onStepSeconds(-5),
                ),
              ),
              Tooltip(
                message: isPlaying ? 'Pausar (espaço)' : 'Reproduzir (espaço)',
                child: IconButton(
                  icon: Icon(
                      isPlaying ? ThemeIcons.of(context).pause : ThemeIcons.of(context).play,
                      size: 18),
                  onPressed: controller == null ? null : onTogglePlay,
                ),
              ),
              Tooltip(
                message: 'Avançar 5 s',
                child: IconButton(
                  icon: Icon(ThemeIcons.of(context).forward, size: 14),
                  onPressed:
                      controller == null ? null : () => onStepSeconds(5),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${formatTimelineTime(playhead)} / ${formatTimelineTime(durationSeconds)}',
                style: theme.typography.caption,
              ),
              const Spacer(),
              Icon(ThemeIcons.of(context).volume, size: 13,
                  color: theme.resources.textFillColorSecondary),
              const SizedBox(width: 6),
              SizedBox(
                width: 190,
                child: ComboBox<int>(
                  isExpanded: true,
                  value: monitorOptions
                      .indexWhere((o) => identical(o.lane, monitorLane))
                      .clamp(0, monitorOptions.length - 1),
                  items: [
                    for (var i = 0; i < monitorOptions.length; i++)
                      ComboBoxItem(
                        value: i,
                        child: Text(monitorOptions[i].label,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: controller == null
                      ? null
                      : (i) {
                          if (i != null) {
                            onMonitorChanged(monitorOptions[i].lane);
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
