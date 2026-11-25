// Local progress persistence for the Pro recitation flow.
//
// One JSON file in the app support directory (path_provider — already a
// project dependency). No accounts, no cloud, no uploads: everything stays
// on the device, and a session survives an app restart.
//
// Stored:
// - last passage reviewed (surah / fromAyah / toAyah / mode / tier) + date,
//   so the setup screen can offer "استئناف" (resume later);
// - the last 50 session results (for the setup screen's history summary);
// - error counts per ayah ("surah:ayah" -> times a confirmed error was
//   found there), so repeated-error ayahs can be surfaced;
// - last review date per ayah.
//
// The store is constructed with an explicit [Directory] so unit tests can
// point it at a temp dir; [ProgressStore.create] wires the real app dir.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'session_logic.dart';
import 'speech_engine.dart';

/// One stored session result + its error locations (for resume/history).
class StoredSession {
  StoredSession({required this.result});
  final SessionResult result;

  Map<String, dynamic> toJson() => result.toJson();

  factory StoredSession.fromJson(Map<String, dynamic> j) =>
      StoredSession(result: SessionResult.fromJson(j));
}

class ProgressStore {
  ProgressStore({required this.dir});

  /// Real app storage: <support>/recitation-progress/progress.json
  static Future<ProgressStore> create() async {
    final support = await getApplicationSupportDirectory();
    return ProgressStore(dir: Directory('${support.path}/recitation-progress'));
  }

  final Directory dir;

  File get _file => File('${dir.path}/progress.json');

  Map<String, dynamic> _data = {};
  bool _loaded = false;

  /// Loads the file if present; missing/corrupt files start empty
  /// (a corrupt progress file must never block the app — it is not
  /// user content, it is derived data that can be rebuilt).
  Future<void> load() async {
    _loaded = true;
    try {
      if (!await _file.exists()) {
        _data = {};
        return;
      }
      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);
      _data = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      _data = {};
    }
  }

  Future<void> _save() async {
    if (!_loaded) return;
    await dir.create(recursive: true);
    await _file.writeAsString(jsonEncode(_data));
  }

  // ── Last passage (resume) ──────────────────────────────────────────

  /// The last passage the user worked on, or null when nothing was saved.
  Passage? get lastPassage {
    final p = _data['lastPassage'] as Map<String, dynamic>?;
    if (p == null) return null;
    try {
      return Passage(
        surah: (p['surah'] as num).toInt(),
        fromAyah: (p['fromAyah'] as num).toInt(),
        toAyah: (p['toAyah'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  RecitationMode get lastMode => switch (_data['lastMode'] as String?) {
        'fromMemory' => RecitationMode.fromMemory,
        'exam' => RecitationMode.exam,
        _ => RecitationMode.lookUp,
      };

  String get lastTier => (_data['lastTier'] as String?) ?? 'lite';

  DateTime? get lastDate {
    final s = _data['lastDate'] as String?;
    if (s == null) return null;
    return DateTime.tryParse(s);
  }

  // ── Sessions ───────────────────────────────────────────────────────

  List<StoredSession> get sessions {
    final list = _data['sessions'] as List?;
    if (list == null) return [];
    final out = <StoredSession>[];
    for (final e in list) {
      try {
        if (e is Map<String, dynamic>) out.add(StoredSession.fromJson(e));
      } catch (_) {
        // Skip one corrupt entry; keep the rest.
      }
    }
    return out;
  }

  /// Records a finished session: updates last-passage, history (kept to
  /// the newest 50), per-ayah error counts and per-ayah review dates.
  Future<void> recordSession(SessionResult result) async {
    if (!_loaded) await load();
    _data['lastPassage'] = {
      'surah': result.surah,
      'fromAyah': result.fromAyah,
      'toAyah': result.toAyah,
    };
    _data['lastMode'] = result.mode.name;
    _data['lastTier'] = result.tier;
    _data['lastDate'] = result.endedAt.toIso8601String();
    final list = sessions.map((s) => s.toJson()).toList()
      ..insert(0, result.toJson());
    _data['sessions'] = list.take(50).toList();
    final errors =
        (_data['errorAyahCounts'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    for (final e in result.errors) {
      final key = '${e.location.surah}:${e.location.ayah}';
      errors[key] = ((errors[key] as num?)?.toInt() ?? 0) + 1;
    }
    _data['errorAyahCounts'] = errors;
    final dates =
        (_data['reviewDates'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    for (final ayah in result.reviewedAyahs) {
      dates['${result.surah}:$ayah'] = result.endedAt.toIso8601String();
    }
    _data['reviewDates'] = dates;
    await _save();
  }

  /// Ayahs with repeated confirmed errors, most frequent first.
  /// Each entry is (surah, ayah, count).
  List<(int surah, int ayah, int count)> topErrorAyahs({int limit = 10}) {
    final errors =
        (_data['errorAyahCounts'] as Map<String, dynamic>?) ?? const {};
    final parsed = <(int, int, int)>[];
    for (final entry in errors.entries) {
      final parts = entry.key.split(':');
      if (parts.length != 2) continue;
      final s = int.tryParse(parts[0]);
      final a = int.tryParse(parts[1]);
      final c = (entry.value as num?)?.toInt();
      if (s == null || a == null || c == null) continue;
      parsed.add((s, a, c));
    }
    parsed.sort((x, y) => y.$3.compareTo(x.$3));
    return parsed.take(limit).toList();
  }

  /// Last review date of one ayah, or null when never reviewed.
  DateTime? reviewDateOf(int surah, int ayah) {
    final dates =
        (_data['reviewDates'] as Map<String, dynamic>?) ?? const {};
    final s = dates['$surah:$ayah'] as String?;
    return s == null ? null : DateTime.tryParse(s);
  }

  /// Clears all stored progress (used only from an explicit user action).
  Future<void> clear() async {
    _data = {};
    await _save();
  }
}
