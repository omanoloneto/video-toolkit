import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/models/tracks.dart';
import 'package:video_toolkit/services/subtitle_retime.dart';

SubtitlePiece _piece(double start, double end, double at) =>
    SubtitlePiece(sourceStart: start, sourceEnd: end, timelineStart: at);

const _srt = '''1
00:00:05,000 --> 00:00:07,000
Abertura

2
00:01:40,000 --> 00:01:42,500
Primeira fala
em duas linhas

3
00:01:59,000 --> 00:02:02,000
Atravessa o corte
''';

const _ass = '''[Script Info]
Title: Teste

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,20

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,Abertura
Dialogue: 0,0:01:40.00,0:01:42.50,Default,,0,0,0,,Olá, tudo bem?
Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,nota
''';

void main() {
  // tira a abertura (0–90 s) e um trecho de 2:00 a 2:10
  final pieces = [_piece(90, 120, 0), _piece(130, double.infinity, 30)];

  test('SRT: drops removed cues, shifts the rest and splits at the cut', () {
    final out = retimeSubtitle(_srt, SubtitleText.srt, pieces);
    expect(out, '''1
00:00:10,000 --> 00:00:12,500
Primeira fala
em duas linhas

2
00:00:29,000 --> 00:00:30,000
Atravessa o corte

''');
  });

  test('ASS: retimes Dialogue lines and keeps commas in the text', () {
    final out = retimeSubtitle(_ass, SubtitleText.ass, pieces);
    expect(out, contains('[V4+ Styles]\nFormat: Name, Fontname, Fontsize'));
    expect(out, isNot(contains('Abertura')));
    expect(out,
        contains('Dialogue: 0,0:00:10.00,0:00:12.50,Default,,0,0,0,,Olá, tudo bem?'));
    expect(out, contains('Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,nota'));
  });

  test('an inserted gap pushes cues forward and splits the one across it', () {
    final gap = [_piece(0, 100, 0), _piece(100, double.infinity, 184)];
    final out = retimeSubtitle(_srt, SubtitleText.srt, gap);
    expect(out, contains('00:00:05,000 --> 00:00:07,000\nAbertura'));
    expect(out, contains('00:03:04,000 --> 00:03:06,500\nPrimeira fala'));
  });

  test('a negative shift clips cues at zero instead of going negative', () {
    final out = retimeSubtitle(_srt, SubtitleText.srt, [_piece(0, double.infinity, -6)]);
    expect(out, startsWith('1\n00:00:00,000 --> 00:00:01,000\nAbertura'));
  });
}
