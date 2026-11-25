// Unit tests for the Pro session logic (ported from Tilawa PoC poc-13) + progress store.
//
// Pure Dart (no engine, no WebView, no device). Run in CI: flutter test.
//
// NOTE: the "words" used here are synthetic tokens ('w1', 'w2', ...),
// NOT Quranic text — they only exercise the counting/marking math.
// Real ayah text always comes from the engine's ref-v2.json at runtime.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tilawa_pro/features/recitation/models.dart';
import 'package:tilawa_pro/features/recitation/progress_store.dart';
import 'package:tilawa_pro/features/recitation/session_logic.dart';
import 'package:tilawa_pro/features/recitation/speech_engine.dart';

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

SessionResult _sampleResult() {
  final tracker = WordTracker();
  tracker.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1)));
  tracker.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 2)));
  tracker.applyChecker(_checker(
      'e1', const RefWord(surah: 1, ayah: 2, word: 1), CheckerState.confirmed));
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
    startedAt: DateTime.utc(2026, 11, 25, 12, 0),
    endedAt: DateTime.utc(2026, 11, 25, 12, 1),
  );
}

void main() {
  group('WordTracker.observe', () {
    test('locked + confidence >= 0.6 marks matched', () {
      final t = WordTracker();
      t.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1)));
      expect(t.matched, contains(const RefWord(surah: 1, ayah: 1, word: 1)));
      expect(t.markOf(const RefWord(surah: 1, ayah: 1, word: 1)),
          WordMark.matched);
    });

    test('confidence exactly 0.6 counts (the engine default floor)', () {
      final t = WordTracker();
      t.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1), conf: 0.6));
      expect(t.matched.length, 1);
    });

    test('confidence 0.59 does not mark matched', () {
      final t = WordTracker();
      t.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1), conf: 0.59));
      expect(t.matched, isEmpty);
      expect(t.markOf(const RefWord(surah: 1, ayah: 1, word: 1)),
          WordMark.notReviewed);
    });

    test('acquiring state never marks matched, even at high confidence', () {
      final t = WordTracker();
      t.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1),
          state: TrackState.acquiring, conf: 0.99));
      expect(t.matched, isEmpty);
    });

    test('confidence is recorded even when the word is not matched', () {
      final t = WordTracker();
      t.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1), conf: 0.4));
      expect(t.confidenceByWord[const RefWord(surah: 1, ayah: 1, word: 1)],
          0.4);
    });
  });

  group('WordTracker.applyChecker', () {
    test('confirmed counts as an error', () {
      final t = WordTracker();
      t.applyChecker(_checker(
          'e1', const RefWord(surah: 1, ayah: 2, word: 1), CheckerState.confirmed));
      expect(t.confirmedErrors.length, 1);
      expect(t.markOf(const RefWord(surah: 1, ayah: 2, word: 1)),
          WordMark.error);
    });

    test('same checker id twice is de-duplicated', () {
      final t = WordTracker();
      const loc = RefWord(surah: 1, ayah: 2, word: 1);
      t.applyChecker(_checker('e1', loc, CheckerState.confirmed));
      t.applyChecker(_checker('e1', loc, CheckerState.confirmed));
      expect(t.confirmedErrors.length, 1);
    });

    test('uncertain is needs-review, never an error', () {
      final t = WordTracker();
      t.applyChecker(_checker(
          'e1', const RefWord(surah: 1, ayah: 2, word: 1), CheckerState.uncertain));
      expect(t.confirmedErrors, isEmpty);
      expect(t.needsReview,
          contains(const RefWord(surah: 1, ayah: 2, word: 1)));
      expect(t.markOf(const RefWord(surah: 1, ayah: 2, word: 1)),
          WordMark.needsReview);
    });

    test('suspected is ignored (transient)', () {
      final t = WordTracker();
      t.applyChecker(_checker(
          'e1', const RefWord(surah: 1, ayah: 2, word: 1), CheckerState.suspected));
      expect(t.confirmedErrors, isEmpty);
      expect(t.needsReview, isEmpty);
    });

    test('resolved removes a confirmed error and leaves a note', () {
      final t = WordTracker();
      const loc = RefWord(surah: 1, ayah: 2, word: 1);
      t.applyChecker(_checker('e1', loc, CheckerState.confirmed));
      t.applyChecker(_checker('e1', loc, CheckerState.resolved));
      expect(t.confirmedErrors, isEmpty);
      expect(t.notes.length, 1);
      expect(t.markOf(loc), WordMark.notReviewed);
    });

    test('error mark wins over matched mark', () {
      final t = WordTracker();
      const loc = RefWord(surah: 1, ayah: 1, word: 1);
      t.observe(_pos(loc));
      t.applyChecker(_checker('e1', loc, CheckerState.confirmed));
      expect(t.markOf(loc), WordMark.error);
    });

    test('matched words are de-duplicated across segments', () {
      final t = WordTracker();
      const loc = RefWord(surah: 1, ayah: 1, word: 1);
      t.observe(_pos(loc));
      t.observe(_pos(loc)); // resume re-observes the same word
      expect(t.matched.length, 1);
    });
  });

  group('computeSessionResult', () {
    test('counts reviewed ayahs, match %, error ayahs, re-recite range',
        () {
      final r = _sampleResult();
      expect(r.reviewedAyahs, [1, 2]);
      expect(r.totalWords, 5); // 3 + 2 words of the reviewed ayahs
      expect(r.matchedWords, 2);
      expect(r.matchPercent, closeTo(40.0, 0.001));
      expect(r.errorCount, 1);
      expect(r.errorAyahs, [2]);
      expect(r.needsReviewCount, 0);
      expect(r.reReciteRange?.fromAyah, 2);
      expect(r.reReciteRange?.toAyah, 2);
    });

    test('an ayah with no events is not reviewed and never correct', () {
      final tracker = WordTracker();
      tracker.observe(_pos(const RefWord(surah: 1, ayah: 1, word: 1)));
      final r = computeSessionResult(
        passage: const Passage(surah: 1, fromAyah: 1, toAyah: 3),
        words: const [
          ['w1'],
          ['w2'],
          ['w3'],
        ],
        tracker: tracker,
        mode: RecitationMode.lookUp,
        tier: 'lite',
        segments: 1,
        startedAt: DateTime.utc(2026, 11, 25, 12, 0),
        endedAt: DateTime.utc(2026, 11, 25, 12, 1),
      );
      expect(r.reviewedAyahs, [1]);
      expect(r.totalWords, 1);
      expect(r.matchPercent, 100.0);
    });

    test('no reviewed ayahs gives null match % (never a fake 0)', () {
      final r = computeSessionResult(
        passage: const Passage(surah: 1, fromAyah: 1, toAyah: 1),
        words: const [
          ['w1', 'w2'],
        ],
        tracker: WordTracker(),
        mode: RecitationMode.exam,
        tier: 'lite',
        segments: 1,
        startedAt: DateTime.utc(2026, 11, 25, 12, 0),
        endedAt: DateTime.utc(2026, 11, 25, 12, 1),
      );
      expect(r.reviewedAyahs, isEmpty);
      expect(r.totalWords, 0);
      expect(r.matchPercent, isNull);
      expect(r.reReciteRange, isNull);
    });

    test('SessionResult JSON round-trip preserves the numbers', () {
      final r = _sampleResult();
      final back = SessionResult.fromJson(r.toJson());
      expect(back.matchedWords, r.matchedWords);
      expect(back.totalWords, r.totalWords);
      expect(back.matchPercent, r.matchPercent);
      expect(back.errorAyahs, r.errorAyahs);
      expect(back.errors.length, 1);
      expect(back.errors.first.errorClass, ErrorClass.wrongWord);
      expect(back.confidenceByWord['1:1:1'], 0.9);
    });
  });

  group('micPermissionState', () {
    test('maps every platform status, permanent denial is distinct', () {
      expect(micPermissionState(PermissionStatus.granted),
          MicPermissionState.granted);
      expect(micPermissionState(PermissionStatus.denied),
          MicPermissionState.denied);
      expect(micPermissionState(PermissionStatus.permanentlyDenied),
          MicPermissionState.permanentlyDenied);
      expect(micPermissionState(PermissionStatus.restricted),
          MicPermissionState.restricted);
    });

    test('only granted can start; only permanent denial needs settings', () {
      expect(MicPermissionState.granted.canStart, isTrue);
      expect(MicPermissionState.denied.canStart, isFalse);
      expect(MicPermissionState.permanentlyDenied.canStart, isFalse);
      expect(MicPermissionState.denied.canRequestAgain, isTrue);
      expect(MicPermissionState.permanentlyDenied.canRequestAgain, isFalse);
      expect(MicPermissionState.permanentlyDenied.needsAppSettings, isTrue);
      expect(MicPermissionState.denied.needsAppSettings, isFalse);
    });
  });

  group('RecitationMode', () {
    test('labels exist and only lookUp starts with visible text', () {
      expect(RecitationMode.lookUp.label, 'التسميع بالنظر');
      expect(RecitationMode.fromMemory.label, 'التسميع غيباً');
      expect(RecitationMode.exam.label, 'الاختبار');
      expect(RecitationMode.lookUp.textInitiallyHidden, isFalse);
      expect(RecitationMode.fromMemory.textInitiallyHidden, isTrue);
      expect(RecitationMode.exam.textInitiallyHidden, isTrue);
    });
  });

  group('ProgressStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pro-recitation-test-');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('record + reload: resume passage, mode, tier, dates', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      await store.recordSession(_sampleResult());
      final reloaded = ProgressStore(dir: dir);
      await reloaded.load();
      expect(reloaded.lastPassage?.surah, 1);
      expect(reloaded.lastPassage?.fromAyah, 1);
      expect(reloaded.lastPassage?.toAyah, 2);
      expect(reloaded.lastMode, RecitationMode.lookUp);
      expect(reloaded.lastTier, 'lite');
      expect(reloaded.sessions.length, 1);
      expect(reloaded.sessions.first.result.matchedWords, 2);
      expect(reloaded.reviewDateOf(1, 1), isNotNull);
      expect(reloaded.reviewDateOf(1, 99), isNull);
    });

    test('error ayah counts accumulate across sessions', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      await store.recordSession(_sampleResult());
      await store.recordSession(_sampleResult());
      expect(store.topErrorAyahs(), [
        (1, 2, 2),
      ]);
    });

    test('corrupt progress file starts empty instead of throwing', () async {
      await dir.create(recursive: true);
      await File('${dir.path}/progress.json')
          .writeAsString('{not json');
      final store = ProgressStore(dir: dir);
      await store.load();
      expect(store.lastPassage, isNull);
      expect(store.sessions, isEmpty);
    });

    test('empty store has no resume passage', () async {
      final store = ProgressStore(dir: dir);
      await store.load();
      expect(store.lastPassage, isNull);
      expect(store.topErrorAyahs(), isEmpty);
    });
  });
}
