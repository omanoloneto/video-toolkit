import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' show Icons;
import 'package:fluent_ui/fluent_ui.dart';

import 'app_themes.dart';

/// Icon set resolved from the active theme: Fluent for the Windows themes,
/// Cupertino for the Mac themes, Material for Ubuntu.
class ThemeIcons {
  const ThemeIcons._({
    required this.video,
    required this.volume,
    required this.cc,
    required this.add,
    required this.delete,
    required this.rename,
    required this.save,
    required this.open,
    required this.play,
    required this.pause,
    required this.rewind,
    required this.forward,
    required this.cut,
    required this.clock,
    required this.download,
    required this.restore,
    required this.timeline,
    required this.merge,
    required this.warning,
    required this.chevronRight,
    required this.select,
    required this.music,
    required this.zoomIn,
    required this.zoomOut,
    required this.fitWindow,
    required this.help,
  });

  final IconData video;
  final IconData volume;
  final IconData cc;
  final IconData add;
  final IconData delete;
  final IconData rename;
  final IconData save;
  final IconData open;
  final IconData play;
  final IconData pause;
  final IconData rewind;
  final IconData forward;
  final IconData cut;
  final IconData clock;
  final IconData download;
  final IconData restore;
  final IconData timeline;
  final IconData merge;
  final IconData warning;
  final IconData chevronRight;
  final IconData select;
  final IconData music;
  final IconData zoomIn;
  final IconData zoomOut;
  final IconData fitWindow;
  final IconData help;

  static const fluent = ThemeIcons._(
    video: FluentIcons.video,
    volume: FluentIcons.volume3,
    cc: FluentIcons.cc,
    add: FluentIcons.add,
    delete: FluentIcons.delete,
    rename: FluentIcons.rename,
    save: FluentIcons.save,
    open: FluentIcons.open_file,
    play: FluentIcons.play,
    pause: FluentIcons.pause,
    rewind: FluentIcons.rewind,
    forward: FluentIcons.fast_forward,
    cut: FluentIcons.cut,
    clock: FluentIcons.clock,
    download: FluentIcons.download,
    restore: FluentIcons.refresh,
    timeline: FluentIcons.timeline,
    merge: FluentIcons.merge_duplicate,
    warning: FluentIcons.warning,
    chevronRight: FluentIcons.chevron_right,
    select: FluentIcons.touch_pointer,
    music: FluentIcons.music_in_collection,
    zoomIn: FluentIcons.calculator_addition,
    zoomOut: FluentIcons.calculator_subtract,
    fitWindow: FluentIcons.back_to_window,
    help: FluentIcons.help,
  );

  static const material = ThemeIcons._(
    video: Icons.videocam_outlined,
    volume: Icons.audiotrack,
    cc: Icons.subtitles_outlined,
    add: Icons.add,
    delete: Icons.delete_outline,
    rename: Icons.edit_outlined,
    save: Icons.save_outlined,
    open: Icons.folder_open_outlined,
    play: Icons.play_arrow,
    pause: Icons.pause,
    rewind: Icons.fast_rewind,
    forward: Icons.fast_forward,
    cut: Icons.content_cut,
    clock: Icons.schedule,
    download: Icons.download_outlined,
    restore: Icons.restore,
    timeline: Icons.timeline,
    merge: Icons.call_merge,
    warning: Icons.warning_amber,
    chevronRight: Icons.chevron_right,
    select: Icons.touch_app_outlined,
    music: Icons.library_music_outlined,
    zoomIn: Icons.zoom_in,
    zoomOut: Icons.zoom_out,
    fitWindow: Icons.fit_screen_outlined,
    help: Icons.help_outline,
  );

  static const cupertino = ThemeIcons._(
    video: CupertinoIcons.videocam,
    volume: CupertinoIcons.speaker_2,
    cc: CupertinoIcons.captions_bubble,
    add: CupertinoIcons.add,
    delete: CupertinoIcons.delete,
    rename: CupertinoIcons.pencil,
    save: CupertinoIcons.floppy_disk,
    open: CupertinoIcons.folder_open,
    play: CupertinoIcons.play_fill,
    pause: CupertinoIcons.pause_fill,
    rewind: CupertinoIcons.backward_fill,
    forward: CupertinoIcons.forward_fill,
    cut: CupertinoIcons.scissors,
    clock: CupertinoIcons.clock,
    download: CupertinoIcons.arrow_down_to_line,
    restore: CupertinoIcons.arrow_counterclockwise,
    timeline: CupertinoIcons.chart_bar,
    merge: CupertinoIcons.arrow_merge,
    warning: CupertinoIcons.exclamationmark_triangle,
    chevronRight: CupertinoIcons.chevron_right,
    select: CupertinoIcons.hand_point_right,
    music: CupertinoIcons.music_note_2,
    zoomIn: CupertinoIcons.zoom_in,
    zoomOut: CupertinoIcons.zoom_out,
    fitWindow: CupertinoIcons.arrow_down_right_arrow_up_left,
    help: CupertinoIcons.question_circle,
  );

  static ThemeIcons of(BuildContext context) =>
      switch (AppThemeScope.specOf(context).iconFamily) {
        IconFamily.fluent => fluent,
        IconFamily.material => material,
        IconFamily.cupertino => cupertino,
      };
}
