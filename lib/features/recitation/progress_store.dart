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

import 'models.dart';
import 'session_logic.dart';
import 'speech_engine.dart';

/// Correct repetitions in a row that clear one mistake
/// (the rule shown on the «أخطائي» screen).
const int kMistakeClearStreak = 3;

/// One confirmed tasmee' mistake, tracked per word + error class until
/// it is cleared by [kMistakeClearStreak] correct repetitions in a row.
/// Stored in the same progress.json as the session history (no DB schema
/// change): a mistake is identified by "surah:ayah:word:class".
class StoredMistake {
  StoredMistake({
    required this.surah,
    required this.ayah,
    required this.word,
    required this.errorClass,
    required this.firstSeen,
    required this.lastSeen,
    this.count = 1,
    this.correctStreak = 0,
    this.cleared = false,
  });

  static String idFor(int surah, int ayah, int word, ErrorClass cls) =>
      '$surah:$ayah:$word:${cls.name}';

  String get id => idFor(surah, ayah, word, errorClass);

  final int surah;
  final int ayah;
  final int word;
  final ErrorClass errorClass;
  final DateTime firstSeen;

  /// Last session that touched this mistake (error recurrence or a
  /// correct repetition).
  DateTime lastSeen;

  /// How many sessions confirmed this error (recurrences included).
  int count;

  /// Correct repetitions in a row (resets to 0 on any recurrence).
  int correctStreak;

  bool cleared;

  Map<String, dynamic> toJson() => {
        'surah': surah,
        'ayah': ayah,
        'word': word,
        'errorClass': errorClass.name,
        'firstSeen': firstSeen.toIso8601String(),
        'lastSeen': lastSeen.toIso8601String(),
        'count': count,
        'correctStreak': correctStreak,
        'cleared': cleared,
      };

  factory StoredMistake.fromJson(Map<String, dynamic> j) {
    ErrorClass classFrom(String? s) => switch (s) {
          'omittedWord' => ErrorClass.omittedWord,
          'addedWord' => ErrorClass.addedWord,
          'skippedPassage' => ErrorClass.skippedPassage,
          _ => ErrorClass.wrongWord,
        };
    DateTime dateOrNow(dynamic v) {
      final d = v is String ? DateTime.tryParse(v) : null;
      return d ?? DateTime.now();
    }

    return StoredMistake(
      surah: (j['surah'] as num).toInt(),
      ayah: (j['ayah'] as num).toInt(),
      word: (j['word'] as num?)?.toInt() ?? 1,
      errorClass: classFrom(j['errorClass'] as String?),
      firstSeen: dateOrNow(j['firstSeen']),
      lastSeen: dateOrNow(j['lastSeen']),
      count: (j['count'] as num?)?.toInt() ?? 1,
      correctStreak: (j['correctStreak'] as num?)?.toInt() ?? 0,
      cleared: j['cleared'] as bool? ?? false,
    );
  }
}

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
    _updateMistakes(result);
    await _save();
  }

  /// Updates the detailed mistake log from one finished session:
  /// - every confirmed error is recorded (new) or counted (recurrence,
  ///   which also resets its correct streak and reopens it if cleared);
  /// - an open mistake whose word was MATCHED in this session (and had no
  ///   confirmed error at that word) gains one correct repetition;
  ///   [kMistakeClearStreak] in a row clears it;
  /// - a mistake in an ayah this session never reviewed is untouched.
  void _updateMistakes(SessionResult result) {
    final mistakes = this.mistakes;
    final byId = <String, StoredMistake>{
      for (final m in mistakes) m.id: m
    };
    final matchedKeys = result.matchedWordKeys.toSet();
    final sessionErrorIds = <String>{};
    for (final e in result.errors) {
      final id = StoredMistake.idFor(
          e.location.surah, e.location.ayah, e.location.word, e.errorClass);
      sessionErrorIds.add(id);
      final existing = byId[id];
      if (existing == null) {
        final nm = StoredMistake(
          surah: e.location.surah,
          ayah: e.location.ayah,
          word: e.location.word,
          errorClass: e.errorClass,
          firstSeen: result.endedAt,
          lastSeen: result.endedAt,
        );
        mistakes.add(nm);
        byId[id] = nm;
      } else {
        existing.count += 1;
        existing.correctStreak = 0;
        existing.lastSeen = result.endedAt;
        existing.cleared = false;
      }
    }
    for (final m in mistakes) {
      if (m.cleared) continue;
      if (m.surah != result.surah) continue;
      if (!result.reviewedAyahs.contains(m.ayah)) continue;
      if (sessionErrorIds.contains(m.id)) continue;
      if (matchedKeys.contains('${m.surah}:${m.ayah}:${m.word}')) {
        m.correctStreak += 1;
        m.lastSeen = result.endedAt;
        if (m.correctStreak >= kMistakeClearStreak) m.cleared = true;
      }
    }
    _data['mistakes'] = mistakes.map((m) => m.toJson()).toList();
  }

  /// All recorded mistakes, newest first (open and cleared).
  List<StoredMistake> get mistakes {
    final list = _data['mistakes'] as List?;
    if (list == null) return [];
    final out = <StoredMistake>[];
    for (final e in list) {
      try {
        if (e is Map<String, dynamic>) out.add(StoredMistake.fromJson(e));
      } catch (_) {
        // Skip one corrupt entry; keep the rest.
      }
    }
    out.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return out;
  }

  /// Mistakes not yet cleared (correct streak < [kMistakeClearStreak]).
  List<StoredMistake> get openMistakes =>
      mistakes.where((m) => !m.cleared).toList();

  /// Mistakes cleared by [kMistakeClearStreak] correct repetitions.
  List<StoredMistake> get clearedMistakes =>
      mistakes.where((m) => m.cleared).toList();

  /// Deletes one mistake record (explicit user action from «أخطائي»).
  Future<void> deleteMistake(String id) async {
    if (!_loaded) await load();
    final kept = mistakes.where((m) => m.id != id).toList();
    _data['mistakes'] = kept.map((m) => m.toJson()).toList();
    await _save();
  }

  // ── Quiz completions ───────────────────────────────────────────────

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Dates (yyyy-MM-dd) on which a full 5-question quiz was completed.
  List<String> get quizCompletionDates {
    final list = _data['quizCompletions'] as List?;
    if (list == null) return [];
    return list.whereType<String>().toList();
  }

  /// True when a full quiz was completed today (used by «مراجعة يومية»).
  bool get quizDoneToday =>
      quizCompletionDates.contains(_dateKey(DateTime.now()));

  /// Records today's full-quiz completion (once per day).
  Future<void> recordQuizCompletion() async {
    if (!_loaded) await load();
    final dates = quizCompletionDates;
    final today = _dateKey(DateTime.now());
    if (!dates.contains(today)) {
      dates.add(today);
      _data['quizCompletions'] = dates;
      await _save();
    }
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
