# Video Toolkit

**A desktop track editor for MP4 and MKV files — cut, merge, retime and remux
audio, video and subtitle tracks without re-encoding the video.**

[![Release](https://img.shields.io/github/v/release/omanoloneto/video-toolkit)](https://github.com/omanoloneto/video-toolkit/releases)
[![Build](https://github.com/omanoloneto/video-toolkit/actions/workflows/release.yml/badge.svg)](https://github.com/omanoloneto/video-toolkit/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20·%20Windows%20·%20Linux-lightgrey)

Video Toolkit gives you an NLE-style workspace — track list, video preview,
properties panel and a zoomable timeline — for the kind of surgery media
players can't do and full video editors make painful: swapping dub tracks,
fixing audio sync, stitching the good half of one track onto the other,
attaching subtitles, and exporting audio — all while the video stream is
copied bit-for-bit.

![Video Toolkit — dark theme](docs/screenshots/editor-dark.png)

<details>
<summary>More screenshots</summary>

![Video Toolkit — Aero theme](docs/screenshots/editor-aero.png)

</details>

## Features

- **Track management** — list every video, audio and subtitle track with
  codec, language and channel details; add external audio (`mp3`, `aac`,
  `m4a`, `ac3`, `eac3`, `flac`, `wav`, `opus`, `ogg`, `dts`, `mka`) and
  subtitle files (`srt`, `ass`, `ssa`, `vtt`, `sub`); remove, restore and
  rename tracks; export any audio track losslessly.
- **Timeline editing** — split audio tracks into segments, delete pieces,
  drag them along a zoomable timeline with playhead snapping, or type exact
  times (`90`, `1:30`, `1:02:03.5`).
- **Auto-merge on save** — tracks that were cut apart are automatically
  mixed into a single output track at their timeline positions (e.g. the
  first 3 minutes of track 1 followed by the rest of track 2). Untouched or
  merely delayed tracks stay separate.
- **Built-in preview** — video playback powered by
  [media_kit](https://pub.dev/packages/media_kit)/libmpv (plays MKV
  natively), synced with the timeline playhead. Choose which audio track to
  monitor — including external files — with segment shifts applied live,
  which makes dialogue syncing fast.
- **Lossless by default** — video is always stream-copied. Untouched audio
  is copied too (pure delays use `-itsoffset`, head trims use `-ss`); only
  edited audio lanes are re-encoded (AAC 256k) through an ffmpeg filter
  graph (`atrim` → `asetpts` → `aresample` → `adelay` → `amix`).
- **Safe saving** — output is always rendered to a temporary file and moved
  into place afterwards, so overwriting the source can never corrupt it.
  Container incompatibilities (e.g. image-based subtitles into MP4) are
  detected and confirmed before anything runs.
- **10 themes** — looks inspired by Windows 98 / XP / Vista / 7 (Aero) /
  8 / 10 / 11, classic and modern macOS, and Ubuntu. Each theme swaps
  colors, corner radii, button styles and the icon family (Fluent, Cupertino
  or Material); glass themes enable real window translucency on macOS.
- **Desktop-first** — landscape-only layout, native macOS menu bar with
  shortcuts, keyboard-driven editing.

## Download

Grab the latest build from the
[Releases page](https://github.com/omanoloneto/video-toolkit/releases):

| Platform | File | Notes |
| --- | --- | --- |
| macOS | `VideoToolkit-<version>-macos.zip` | Unzip, drag to Applications. The build is not notarized, so macOS blocks it on first launch — see [Opening on macOS](#opening-on-macos). |
| Windows | `VideoToolkit-<version>-windows.zip` | Unzip anywhere, run `video_toolkit.exe`. |
| Linux (Debian/Ubuntu) | `video-toolkit_<version>_amd64.deb` | `sudo apt install ./video-toolkit_<version>_amd64.deb` |

**FFmpeg is required on every platform** — Video Toolkit drives `ffmpeg` and
`ffprobe` under the hood:

```sh
# macOS            # Windows                # Debian/Ubuntu
brew install ffmpeg  winget install ffmpeg    sudo apt install ffmpeg
```

The `.deb` package already declares FFmpeg as a dependency.

### Opening on macOS

Release builds are ad-hoc signed, not notarized. Since macOS 15 the old
right-click → Open trick is gone and macOS refuses to run a downloaded copy.
Allow it once, either way:

- **System Settings → Privacy & Security**, scroll to the message about
  Video Toolkit and click **Open Anyway**; or
- remove the download quarantine in Terminal:

  ```sh
  xattr -dr com.apple.quarantine "/Applications/Video Toolkit.app"
  ```

Builds you compile yourself (`flutter build macos`) are never quarantined.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| `Space` | Play / pause the preview |
| `S` | Split the selected track's segment at the playhead |
| `Delete` / `Backspace` | Delete the selected segment (or the whole selected track) |
| `⌘O` | Open a video (macOS menu bar) |
| `⌘S` | Save (macOS menu bar) |

## How saving works

Everything is delegated to FFmpeg as an external process — the app builds a
single command per save:

1. **Untouched tracks** are mapped with `-c copy` (bit-perfect remux).
2. **Whole-track shifts** stay on the copy path: positive delays become
   `-itsoffset`, head trims become `-ss` on a duplicate input.
3. **Edited lanes** (split / trimmed / merged) are assembled with
   `-filter_complex`: each segment is `atrim`-ed, re-timed and `adelay`-ed
   to its timeline position, then all segments are mixed with `amix` and
   encoded to AAC.
4. Subtitles are converted when the target container demands it (`srt` →
   `mov_text` for MP4, exotic text formats → `srt` for MKV); image-based
   subtitles that cannot exist in MP4 are dropped with an explicit warning.
   MKV outputs also keep font attachments so ASS subtitles render correctly.

## Building from source

Requirements: [Flutter](https://flutter.dev) (stable channel) and FFmpeg.

```sh
git clone https://github.com/omanoloneto/video-toolkit.git
cd video-toolkit
flutter pub get

# run in debug
flutter run -d macos      # or -d windows / -d linux

# release build (the app also accepts a video path as CLI argument)
flutter build macos --release
open "build/macos/Build/Products/Release/Video Toolkit.app" --args ~/movie.mkv
```

Platform notes:

- **macOS** — the App Sandbox is disabled in the entitlements so the app can
  execute FFmpeg and read arbitrary files. Window translucency uses
  `macos_window_utils` (NSVisualEffectView).
- **Linux** — needs the usual Flutter desktop toolchain plus
  `libgtk-3-dev` and `libmpv-dev`.
- **Windows** — Visual Studio C++ workload, per standard Flutter setup.

Releases for all three platforms are produced by the GitHub Actions workflow
in [.github/workflows/release.yml](.github/workflows/release.yml), triggered
by pushing a `v*` tag.

## Tests

```sh
flutter test            # unit + widget tests (ffmpeg command assembly, timeline, themes)
dart run tool/e2e.dart  # end-to-end against a real ffmpeg: generates media,
                        # saves through the app's pipeline and verifies the
                        # output content (stream counts, durations, which
                        # audio plays before/after a cut)
```

## Project layout

```
lib/
  models/tracks.dart          # tracks, audio segments, split/merge rules
  services/ffmpeg_service.dart# probing + ffmpeg command construction
  screens/editor_screen.dart  # app shell, menu bar, playback state
  widgets/timeline_panel.dart # timeline: lanes, clips, ruler, playhead
  widgets/preview_panel.dart  # video preview + audio monitoring
  widgets/properties_panel.dart
  theme/app_themes.dart       # the 10 theme definitions
  theme/theme_icons.dart      # Fluent / Cupertino / Material icon sets
tool/e2e.dart                 # real-ffmpeg end-to-end checks
assets/icon/                  # icon source art
```

The theme choice is persisted to `~/.video_toolkit/theme.txt`.

## License

[MIT](LICENSE)
