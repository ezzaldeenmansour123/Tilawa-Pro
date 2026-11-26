// Unit tests for the tasmee' UI redesign (2026-11-26): quiz question
// selection, daily/streak/juz computations, the detailed mistake log
// (3-correct-in-a-row rule) and the new SessionResult word-key fields.
//
// Pure Dart (no engine, no WebView, no device). Run in CI: flutter test.
//
// NOTE: the "words" used here are synthetic tokens ('w1', 'w2', ...),
// NOT Quranic text — they only exercise the counting/marking math.
// Real ayah text always comes from the engine's ref-v2.json at runtime
// (or the app's own Quran DB for display prompts).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/features/memorization/hifz_store.dart';
import 'package:tilawa_pro/features/recitation/models.dart';
import 'package:tilawa_pro/features/recitation/progress_store.dart';
import 'package:tilawa_pro/features/recitation/session_logic.dart';
import 'package:tilawa_pro/features/recitation/speech_engine.dart';
import 'package:tilawa_pro/features/recitation/tasmee_progress.dart';

PositionEvent _pos(RefWord word,
        {double conf = 0.9, TrackState state = TrackState.locked}) =>
    PositionEvent(
      timeMs: 0,
      observed: [word],
      confidence: conf,
      state: state,
    );

CheckerEvent _checker(String id, RefWord loc, CheckerState state,
        {ErrorClass cls = ErrorClass.wrongWord}) =>
    CheckerEvent(
      id: id,
      timeMs: 0,
      state: state,
      errorClass: cls,
      location: loc,
    );

SessionResult _result({
  List<RefWord> matched = const [],
  List<(RefWord, ErrorClass, String)> errors = const [],
  List<RefWord> uncertain = const [],
  DateTime? endedAt,
}) {
  final tracker = WordTracker();
  for (final w in matched) {
    tracker.observe(_pos(w));
  }
  for (final (loc, cls, id) in errors) {
    tracker.applyChecker(_checker(id, loc, CheckerState.confirmed, cls: cls));
  }
  for (final w in uncertain) {
    tracker.applyChecker(
        _checker('u-${w.ayah}-${w.word}', w, CheckerState.uncertain));
  }
  final end = endedAt ?? DateTime.utc(2026, 11, 26, 12, 0);
  return computeSessionResult(
    passage: const Passage(surah: 1, fromAyah: 1, toAyah: 2),
    words: const [
      ['w1', 'w2', 'w3'],
      ['w4', 'w5'],
    ],
    tracker: tracker,
    mode: RecitationMode.lookUp,
    tier: 'lite',
    segments: 1,
    startedAt: end.subtract(const Duration(minutes: 1)),
    endedAt: end,
  );
}

void main() {
  group('buildQuizQuestions', () {
    test('errors first, then last passage, then presets', () {
      final built = buildQuizQuestions(
        errorAyahs: [(2, 255, 3), (1, 2, 1)],
        lastPassage: const Passage(surah: 112, fromAyah: 1, toAyah: 4),
        wordCountOf: (_, __) => 5,
      );
      expect(built.questions.length, 5);
      expect(built.questions[0], (surah: 2, ayah: 255));
      expect(built.questions[1], (surah: 1, ayah: 2));
      expect(built.questions[2], (surah: 112, ayah: 1));
      expect(
          built.sources,
          {
            QuizQuestionSource.errorAyahs,
            QuizQuestionSource.lastPassage,
          });
    });

    test('no history falls back to Al-Fatiha', () {
      final built = buildQuizQuestions(
        errorAyahs: [],
        lastPassage: null,
        wordCountOf: (_, __) => 4,
      );
      expect(built.questions.length, 5);
      expect(built.questions.first, (surah: 1, ayah: 1));
      expect(built.sources, {QuizQuestionSource.presets});
    });

    test('one-word ayahs are skipped, duplicates removed', () {
      final built = buildQuizQuestions(
        errorAyahs: [(2, 255, 2), (2, 255, 2), (1, 2, 1)],
        lastPassage: const Passage(surah: 1, fromAyah: 1, toAyah: 2),
        wordCountOf: (s, a) => (s == 2 && a == 255) ? 1 : 4,
      );
      // 2:255 (1 word) is skipped, the duplicate 1:2 is kept once, and
      // the list is topped up from the ready-made passages to 5.
      expect(
          built.questions,
          [
            (surah: 1, ayah: 2),
            (surah: 1, ayah: 1),
            (surah: 1, ayah: 3),
            (surah: 1, ayah: 4),
            (surah: 1, ayah: 5),
          ]);
      expect(
          built.sources,
          {
            QuizQuestionSource.errorAyahs,
            QuizQuestionSource.lastPassage,
            QuizQuestionSource.presets,
          });
    });
  });

  group('dailyReviewedAyahs + combinedStreakDays', () {
    final now = DateTime(2026, 11, 26, 12, 0);
    final sessions = [
      StoredSession(
          result: _result(
        matched: [const RefWord(surah: 1, ayah: 1, word: 1)],
        endedAt: DateTime(2026, 11, 26, 10, 0),
      )),
      StoredSession(
          result: _result(
        matched: [const RefWord(surah: 1, ayah: 2, word: 1)],
        endedAt: DateTime(2026, 11, 25, 10, 0),
      )),
    ];
    final reviews = [
      HifzReview(
        id: 'r1',
        ayahId: 1001,
        planId: 'p',
        rating: HifzRating.easy,
        at: DateTime(2026, 11, 26, 9, 0),
        intervalBefore: 1,
        intervalAfter: 3,
      ),
    ];

    test('distinct ayahs per day, sessions + reviews de-duplicated', () {
      final daily = dailyReviewedAyahs(
        sessions: sessions,
        reviews: reviews,
        now: now,
        ayahIdOf: (s, a) => s * 1000 + a,
      );
      expect(daily.length, 7);
      // Today: session ayah 1:1 (id 1001) + review ayah 1001 -> 1.
      expect(daily[6], 1);
      // Yesterday: session ayah 1:2 -> 1.
      expect(daily[5], 1);
      expect(daily.sublist(0, 5), [0, 0, 0, 0, 0]);
    });

    test('streak counts back from today while a day is active', () {
      expect(
          combinedStreakDays(
            sessions: sessions,
            reviews: reviews,
            quizDates: [],
            now: now,
          ),
          2);
      expect(
          combinedStreakDays(
            sessions: [],
            reviews: [],
            quizDates: [tasmeeDayKey(now)],
            now: now,
          ),
          1);
      expect(
          combinedStreakDays(
            sessions: [],
            reviews: [],
            quizDates: [],
            now: now,
          ),
          0);
    });
  });

  group('juzProgress', () {
    test('completed juz + most advanced incomplete juz', () {
      final j = juzProgress(
        totalByJuz: {1: 100, 2: 50, 3: 80},
        memorizedByJuz: {1: 100, 2: 30},
      );
      expect(j.completed, [1]);
      expect(j.currentJuz, 2);
      expect(j.currentMemorized, 30);
      expect(j.currentTotal, 50);
    });

    test('nothing memorized -> no current juz', () {
      final j = juzProgress(totalByJuz: {1: 100}, memorizedByJuz: {});
      expect(j.completed, isEmpty);
      expect(j.currentJuz, isNull);
    });
  });

  group('SessionResult word keys', () {
    test('matched + needs-review keys round-trip through JSON', () {
      final r = _result(
        matched: [const RefWord(surah: 1, ayah: 1, word: 1)],
        uncertain: [const RefWord(surah: 1, ayah: 2, word: 2)],
      );
      final restored = SessionResult.fromJson(r.toJson());
      expect(restored.matchedWordKeys, contains('1:1:1'));
      expect(restored.needsReviewWordKeys, contains('1:2:2'));
    });

    test('old JSON without the keys loads as empty lists', () {
      final json = _result().toJson()
        ..remove('matchedWordKeys')
        ..remove('needsReviewWordKeys');
      final restored = SessionResult.fromJson(json);
      expect(restored.matchedWordKeys, isEmpty);
      expect(restored.needsReviewWordKeys, isEmpty);
    });
  });

  group('ProgressStore mistakes (3-correct-in-a-row)', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pro-mistakes-test-');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('error recorded, then cleared after 3 correct repetitions', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      // Session 1: confirmed wrong-word error at 1:2:1.
      await store.recordSession(_result(errors: [
        (const RefWord(surah: 1, ayah: 2, word: 1), ErrorClass.wrongWord, 'e1'),
      ]));
      expect(store.openMistakes.length, 1);
      expect(store.openMistakes.first.count, 1);
      expect(store.openMistakes.first.correctStreak, 0);
      // Sessions 2-4: the same word matched, no error there.
      for (var i = 0; i < 3; i++) {
        await store.recordSession(_result(matched: [
          const RefWord(surah: 1, ayah: 2, word: 1),
        ]));
      }
      expect(store.openMistakes, isEmpty);
      expect(store.clearedMistakes.length, 1);
      expect(store.clearedMistakes.first.correctStreak, 3);
    });

    test('a recurrence resets the streak and reopens a cleared mistake',
        () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      await store.recordSession(_result(errors: [
        (const RefWord(surah: 1, ayah: 2, word: 1), ErrorClass.wrongWord, 'e1'),
      ]));
      for (var i = 0; i < 3; i++) {
        await store.recordSession(_result(matched: [
          const RefWord(surah: 1, ayah: 2, word: 1),
        ]));
      }
      expect(store.clearedMistakes.length, 1);
      // The error recurs.
      await store.recordSession(_result(errors: [
        (const RefWord(surah: 1, ayah: 2, word: 1), ErrorClass.wrongWord, 'e1'),
      ]));
      expect(store.openMistakes.length, 1);
      expect(store.openMistakes.first.count, 2);
      expect(store.openMistakes.first.correctStreak, 0);
      // Deleting removes the record.
      await store.deleteMistake(store.openMistakes.first.id);
      expect(store.mistakes, isEmpty);
    });

    test('an unreviewed ayah leaves the streak untouched', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      await store.recordSession(_result(errors: [
        (const RefWord(surah: 1, ayah: 2, word: 1), ErrorClass.wrongWord, 'e1'),
      ]));
      await store.recordSession(_result(matched: [
        const RefWord(surah: 1, ayah: 2, word: 1),
      ]));
      expect(store.openMistakes.first.correctStreak, 1);
      // A session that reviews only ayah 1 (not ayah 2).
      await store.recordSession(_result(matched: [
        const RefWord(surah: 1, ayah: 1, word: 1),
      ]));
      expect(store.openMistakes.first.correctStreak, 1);
    });

    test('quiz completion is recorded once per day', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      expect(store.quizDoneToday, isFalse);
      await store.recordQuizCompletion();
      await store.recordQuizCompletion();
      expect(store.quizDoneToday, isTrue);
      expect(store.quizCompletionDates.length, 1);
    });
  });
}
