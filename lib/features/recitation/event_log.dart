// Local JSONL event log for one recitation session.
//
// Every line is one JSON object:
//   {"seq": n, "wallMs": <epoch ms>, "audioMs": <session audio clock ms|null>,
//    "type": "capabilities"|"position"|"checker"|"meta", "payload": {...}}
//
// - `wallMs` is the wall clock (for latency: time from the user speaking to
//   the UI reacting). `audioMs` is the engine's session clock (for aligning
//   events with the recited audio).
// - `meta` lines record session facts: passage, tier, backend, model load
//   time, mic permission outcome, and the test conditions the user entered
//   (quiet room / background noise / speed). They are what make a log
//   scoreable later by tools/score_sessions.py.
// - Logs stay on the device. Export is a local file share only — no upload.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class EventLog {
  EventLog._(this.file, this.sessionId);
  final File file;
  final String sessionId;
  int _seq = 0;

  static Future<EventLog> create({
    required String sessionId,
    required Map<String, dynamic> sessionMeta,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final logs = Directory('${dir.path}/recitation-logs');
    await logs.create(recursive: true);
    final file = File('${logs.path}/$sessionId.jsonl');
    final log = EventLog._(file, sessionId);
    await log.append('meta', sessionMeta, audioMs: null);
    return log;
  }

  static Future<List<File>> listLogs() async {
    final dir = await getApplicationSupportDirectory();
    final logs = Directory('${dir.path}/recitation-logs');
    if (!await logs.exists()) return [];
    final files = await logs
        .list()
        .where((e) => e is File && e.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> append(
    String type,
    Map<String, dynamic> payload, {
    required int? audioMs,
  }) async {
    final line = jsonEncode({
      'seq': _seq++,
      'wallMs': DateTime.now().millisecondsSinceEpoch,
      'audioMs': audioMs,
      'type': type,
      'payload': payload,
    });
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  /// Reads a log file back (used by the in-app log viewer + tests).
  static Future<List<Map<String, dynamic>>> read(File file) async {
    final lines = await file.readAsLines();
    return lines
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }
}

/// Pure helpers over a decoded log (unit-tested in test/event_log_test.dart).
class LogMetrics {
  /// Median wall-clock delay from the first `position` event that observes a
  /// word to the moment it was written — approximated per event by
  /// (wallMs of the position event) minus (wallMs of session start meta).
  /// NOTE: true "speech-to-highlight" latency needs the audio clock: the
  /// engine emits `timeMs` (audio ms) on each event; the wall clock of the
  /// first audio sample is recorded in the session-start meta as
  /// `sessionStartedWallMs`. Latency(word) = event.wallMs - (startWall +
  /// event.audioMs). This function computes exactly that.
  static List<int> highlightLatenciesMs(
    List<Map<String, dynamic>> events,
  ) {
    // NOTE: a plain firstWhere(orElse: () => {}) fails at RUNTIME here:
    // the caller's list literal infers Map<String, Object> elements, so the
    // reified orElse type must be () => Map<String, Object> — a plain {}
    // literal is Map<String, dynamic> and is rejected. An explicit loop
    // has no such trap.
    Map<String, dynamic>? meta;
    for (final e in events) {
      if (e['type'] == 'meta') {
        meta = e;
        break;
      }
    }
    if (meta == null) return [];
    final startWall =
        (meta['payload']?['sessionStartedWallMs'] as num?)?.toInt();
    if (startWall == null) return [];
    final out = <int>[];
    for (final e in events) {
      if (e['type'] != 'position') continue;
      final audioMs = (e['audioMs'] as num?)?.toInt();
      final wallMs = (e['wallMs'] as num?)?.toInt();
      if (audioMs == null || wallMs == null) continue;
      out.add(wallMs - (startWall + audioMs));
    }
    return out;
  }

  static double median(List<int> values) {
    if (values.isEmpty) return double.nan;
    final s = List<int>.from(values)..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd
        ? s[mid].toDouble()
        : (s[mid - 1] + s[mid]) / 2.0;
  }

  static double percentile(List<int> values, double p) {
    if (values.isEmpty) return double.nan;
    final s = List<int>.from(values)..sort();
    final idx = ((p / 100) * (s.length - 1)).round().clamp(0, s.length - 1);
    return s[idx].toDouble();
  }
}
