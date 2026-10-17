import 'dart:math' as math;

import '../models/tracks.dart';

enum SubtitleText { srt, ass }

/// Passa cada fala de [text] pelos [pieces]: a fala vai pra onde o pedaço
/// dela foi parar, divide quando um corte passa no meio e some quando o
/// trecho dela saiu.
String retimeSubtitle(
    String text, SubtitleText format, List<SubtitlePiece> pieces) {
  final normalized = text.replaceAll('\r\n', '\n').replaceFirst('﻿', '');
  return switch (format) {
    SubtitleText.srt => _retimeSrt(normalized, pieces),
    SubtitleText.ass => _retimeAss(normalized, pieces),
  };
}

List<(double, double)> _mapCue(
    double start, double end, List<SubtitlePiece> pieces) {
  final out = <(double, double)>[];
  for (final piece in pieces) {
    final from = math.max(start, piece.sourceStart);
    final to = math.min(end, piece.sourceEnd);
    if (to - from < 0.01) continue;
    final shift = piece.timelineStart - piece.sourceStart;
    final mappedEnd = to + shift;
    if (mappedEnd <= 0) continue;
    out.add((math.max(0, from + shift), mappedEnd));
  }
  out.sort((a, b) => a.$1.compareTo(b.$1));
  return out;
}

// ------------------------------------------------------------------- srt

final _srtTime = RegExp(
    r'(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})(.*)');

double _srtSeconds(String h, String m, String s, String ms) =>
    int.parse(h) * 3600 +
    int.parse(m) * 60 +
    int.parse(s) +
    int.parse(ms.padRight(3, '0')) / 1000;

String _srtStamp(double seconds) {
  final total = (seconds * 1000).round();
  final h = total ~/ 3600000;
  final m = (total % 3600000) ~/ 60000;
  final s = (total % 60000) ~/ 1000;
  final ms = total % 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)},${ms.toString().padLeft(3, '0')}';
}

String _retimeSrt(String text, List<SubtitlePiece> pieces) {
  final cues = <(double, double, String, String)>[];
  for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
    final lines = block.split('\n');
    final timeLine = lines.indexWhere(_srtTime.hasMatch);
    if (timeLine == -1) continue;
    final match = _srtTime.firstMatch(lines[timeLine])!;
    final start = _srtSeconds(
        match.group(1)!, match.group(2)!, match.group(3)!, match.group(4)!);
    final end = _srtSeconds(
        match.group(5)!, match.group(6)!, match.group(7)!, match.group(8)!);
    final body = lines.skip(timeLine + 1).join('\n').trimRight();
    for (final (from, to) in _mapCue(start, end, pieces)) {
      cues.add((from, to, match.group(9)!, body));
    }
  }
  cues.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  for (var i = 0; i < cues.length; i++) {
    final (from, to, extra, body) = cues[i];
    out
      ..writeln(i + 1)
      ..writeln('${_srtStamp(from)} --> ${_srtStamp(to)}$extra')
      ..writeln(body)
      ..writeln();
  }
  return out.toString();
}

// ------------------------------------------------------------------- ass

final _assTime = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$');

double? _assSeconds(String value) {
  final match = _assTime.firstMatch(value.trim());
  if (match == null) return null;
  final fraction = match.group(4) ?? '0';
  return int.parse(match.group(1)!) * 3600 +
      int.parse(match.group(2)!) * 60 +
      int.parse(match.group(3)!) +
      int.parse(fraction) / math.pow(10, fraction.length);
}

String _assStamp(double seconds) {
  final total = (seconds * 100).round();
  final h = total ~/ 360000;
  final m = (total % 360000) ~/ 6000;
  final s = (total % 6000) ~/ 100;
  final cs = total % 100;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}.${two(cs)}';
}

String _retimeAss(String text, List<SubtitlePiece> pieces) {
  var inEvents = false;
  var fields = const [
    'layer', 'start', 'end', 'style', 'name', 'marginl', 'marginr',
    'marginv', 'effect', 'text',
  ];
  final out = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('[')) {
      inEvents = trimmed.toLowerCase().startsWith('[events]');
      out.add(line);
      continue;
    }
    if (inEvents && trimmed.toLowerCase().startsWith('format:')) {
      fields = trimmed
          .substring('format:'.length)
          .split(',')
          .map((f) => f.trim().toLowerCase())
          .toList();
      out.add(line);
      continue;
    }
    if (!inEvents || !trimmed.startsWith('Dialogue:')) {
      out.add(line);
      continue;
    }
    final startIndex = fields.indexOf('start');
    final endIndex = fields.indexOf('end');
    final values = _splitAssFields(
        trimmed.substring('Dialogue:'.length).trimLeft(), fields.length);
    final start = startIndex < 0 ? null : _assSeconds(values[startIndex]);
    final end = endIndex < 0 ? null : _assSeconds(values[endIndex]);
    if (start == null || end == null) {
      out.add(line);
      continue;
    }
    for (final (from, to) in _mapCue(start, end, pieces)) {
      final copy = [...values];
      copy[startIndex] = _assStamp(from);
      copy[endIndex] = _assStamp(to);
      out.add('Dialogue: ${copy.join(',')}');
    }
  }
  return out.join('\n');
}

// o campo Text (o último) pode ter vírgula: só as n-1 primeiras separam
List<String> _splitAssFields(String body, int count) {
  final values = <String>[];
  var rest = body;
  for (var i = 0; i < count - 1; i++) {
    final comma = rest.indexOf(',');
    if (comma == -1) break;
    values.add(rest.substring(0, comma));
    rest = rest.substring(comma + 1);
  }
  values.add(rest);
  while (values.length < count) {
    values.add('');
  }
  return values;
}
