// Pure progress computations for the tasmee' UI redesign (2026-11-26).
//
// No widgets, no I/O: every function takes plain data and returns plain
// data, so it is unit-testable in plain `flutter test`.
//
// All numbers come from real stores (ProgressStore sessions, HifzStore
// reviews/items, quiz completions). Nothing here invents a value: when a
// source is empty the result is empty/zero and the UI shows an honest
// empty state instead.

import '../memorization/hifz_store.dart';
import 'progress_store.dart';
import 'speech_engine.dart';

String tasmeeDayKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// ───────── Quiz questions ─────────────────────────────────────────────

/// Where the quiz questions came from (shown honestly on the quiz screen).
enum QuizQuestionSource { errorAyahs, lastPassage, presets }

/// One quiz question: complete this ayah by voice.
typedef QuizQuestion = ({int surah, int ayah});

/// Orders quiz candidates: repeated-error ayahs first, then the ayahs of
/// the last reviewed passage, then the ready-made passages (Al-Fatiha)
/// when the user has no history yet. Ayahs with fewer than 2 words are
/// skipped (a completion question needs at least one shown word and one
/// hidden word). Returns at most [count] questions, de-duplicated, plus
/// the set of sources the returned questions actually came from.
({List<QuizQuestion> questions, Set<QuizQuestionSource> sources})
    buildQuizQuestions({
  required List<(int surah, int ayah, int count)> errorAyahs,
  Passage? lastPassage,
  required int Function(int surah, int ayah) wordCountOf,
  int count = 5,
}) {
  final out = <QuizQuestion>[];
  final seen = <String>{};
  final sources = <QuizQuestionSource>{};

  bool add(int surah, int ayah, QuizQuestionSource source) {
    if (out.length >= count) return false;
    final key = '$surah:$ayah';
    if (seen.contains(key)) return true;
    if (wordCountOf(surah, ayah) < 2) return true;
    seen.add(key);
    out.add((surah: surah, ayah: ayah));
    sources.add(source);
    return out.length < count;
  }

  for (final e in errorAyahs) {
    if (!add(e.$1, e.$2, QuizQuestionSource.errorAyahs)) break;
  }
  if (out.length < count && lastPassage != null) {
    for (var a = lastPassage.fromAyah; a <= lastPassage.toAyah; a++) {
      if (!add(lastPassage.surah, a, QuizQuestionSource.lastPassage)) break;
    }
  }
  if (out.length < count) {
    // Ready-made fallback: Al-Fatiha (1:1–7). These are the app's
    // standard preset passages, not invented content.
    for (var a = 1; a <= 7; a++) {
      if (!add(1, a, QuizQuestionSource.presets)) break;
    }
  }
  return (questions: out, sources: sources);
}

/// Human-readable source line for the quiz screen.
String quizSourceLabel(Set<QuizQuestionSource> sources) {
  if (sources.length == 1) {
    return switch (sources.first) {
      QuizQuestionSource.errorAyahs => 'أسئلة من آيات تتكرر فيها أخطاؤك.',
      QuizQuestionSource.lastPassage => 'أسئلة من آخر مقطع راجعته.',
      QuizQuestionSource.presets => 'أسئلة من المقاطع الجاهزة (الفاتحة).',
    };
  }
  if (sources.contains(QuizQuestionSource.errorAyahs) &&
      sources.contains(QuizQuestionSource.lastPassage)) {
    return 'أسئلة من آيات أخطائك وآخر مقطع راجعته.';
  }
  return 'أسئلة من مراجعاتك والمقاطع الجاهزة.';
}

// ───────── Daily / weekly review counts ───────────────────────────────

/// Ayahs reviewed per day for the last [days] days (oldest first),
/// counting each ayah once per day. Sources: tasmee' sessions
/// (reviewedAyahs) + hifz reviews (one review = one ayah). [ayahIdOf]
/// maps a (surah, ayah) to its global ayah id for de-duplication; when
/// null, "surah:ayah" strings are used instead.
List<int> dailyReviewedAyahs({
  required List<StoredSession> sessions,
  required List<HifzReview> reviews,
  required DateTime now,
  int days = 7,
  int? Function(int surah, int ayah)? ayahIdOf,
}) {
  final today = _dayOnly(now);
  final perDay = List.generate(days, (_) => <Object>{});
  for (final s in sessions) {
    final d = _dayOnly(s.result.endedAt);
    final idx = days - 1 - today.difference(d).inDays;
    if (idx < 0 || idx >= days) continue;
    for (final a in s.result.reviewedAyahs) {
      perDay[idx].add(ayahIdOf?.call(s.result.surah, a) ?? '${s.result.surah}:$a');
    }
  }
  for (final r in reviews) {
    final d = _dayOnly(r.at);
    final idx = days - 1 - today.difference(d).inDays;
    if (idx < 0 || idx >= days) continue;
    perDay[idx].add(r.ayahId);
  }
  return perDay.map((s) => s.length).toList();
}

/// Distinct ayahs reviewed today (tasmee' sessions + hifz reviews).
int todayReviewedAyahs({
  required List<StoredSession> sessions,
  required List<HifzReview> reviews,
  required DateTime now,
  int? Function(int surah, int ayah)? ayahIdOf,
}) =>
    dailyReviewedAyahs(
      sessions: sessions,
      reviews: reviews,
      now: now,
      days: 1,
      ayahIdOf: ayahIdOf,
    ).first;

/// Days in a row (counting back from today) with at least one tasmee'
/// session, one hifz review, or one completed quiz.
int combinedStreakDays({
  required List<StoredSession> sessions,
  required List<HifzReview> reviews,
  required List<String> quizDates,
  required DateTime now,
}) {
  final active = <String>{
    for (final s in sessions) tasmeeDayKey(s.result.endedAt),
    for (final r in reviews) tasmeeDayKey(r.at),
    ...quizDates,
  };
  var streak = 0;
  var d = _dayOnly(now);
  while (active.contains(tasmeeDayKey(d))) {
    streak++;
    d = d.subtract(const Duration(days: 1));
  }
  return streak;
}

/// Short Arabic weekday label (السبت أول الأسبوع).
String arabicWeekdayShort(DateTime d) {
  const labels = ['سبت', 'أحد', 'اثنين', 'ثلاثاء', 'أربعاء', 'خميس', 'جمعة'];
  return labels[(d.weekday + 1) % 7];
}

// ───────── Juz progress ───────────────────────────────────────────────

/// Juz numbers (1..30) in which every ayah is memorized, plus the most
/// advanced incomplete juz (most memorized ayahs) with its counts.
/// [totalByJuz]: ayah count per juz (from the Quran DB).
/// [memorizedByJuz]: memorized ayah count per juz (HifzStore items with
/// reps > 0, grouped by the ayah's juz).
({List<int> completed, int? currentJuz, int currentMemorized, int currentTotal})
    juzProgress({
  required Map<int, int> totalByJuz,
  required Map<int, int> memorizedByJuz,
}) {
  final completed = <int>[];
  int? currentJuz;
  var best = 0;
  for (var juz = 1; juz <= 30; juz++) {
    final total = totalByJuz[juz] ?? 0;
    if (total == 0) continue;
    final memorized = memorizedByJuz[juz] ?? 0;
    if (memorized >= total) {
      completed.add(juz);
    } else if (memorized > best) {
      best = memorized;
      currentJuz = juz;
    }
  }
  final currentTotal = currentJuz == null ? 0 : (totalByJuz[currentJuz] ?? 0);
  return (
    completed: completed,
    currentJuz: currentJuz,
    currentMemorized: best,
    currentTotal: currentTotal,
  );
}
