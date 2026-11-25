// Pure session logic for the Pro recitation flow — no widgets, no I/O.
//
// Everything here is unit-tested in test/session_logic_test.dart and runs
// in plain `flutter test` with no device, no WebView and no engine.
//
// Honesty rules enforced by this file (never relax them in the UI):
// - A word is "matched" (green) ONLY when the engine actually observed it
//   in a position event with state == locked and confidence >= 0.6
//   (kMinConfidence — the engine's own default). Anything else is
//   "not reviewed", never "correct".
// - Only a CONFIRMED checker event counts as an error. `suspected` is
//   transient, `uncertain` means "needs re-check" (yellow, never an error),
//   `resolved` means the user self-corrected (a note, never an error).
// - Hesitation / short silence produces no event at all from the engine,
//   so it can never become an error here.
// - The engine detects MEMORIZATION mistakes only (wrong/omitted/added
//   words, skipped passage). It does NOT detect tajweed or makharij —
//   nothing in this file may label a result as tajweed.

import 'package:permission_handler/permission_handler.dart';

import 'models.dart';
import 'speech_engine.dart';

/// The engine's own default confidence floor (see @tilawa/core README).
/// A word observed below this is shown as uncertain, never as matched.
const double kMinConfidence = 0.6;

/// The three recitation modes the setup screen offers.
enum RecitationMode {
  /// Text visible while reciting.
  lookUp,

  /// Text hidden while reciting; shown again on demand.
  fromMemory,

  /// Like fromMemory, but the passage is chosen freely and the text stays
  /// hidden until the test ends or the user asks to show it.
  exam,
}

extension RecitationModeInfo on RecitationMode {
  String get label => switch (this) {
        RecitationMode.lookUp => 'التسميع بالنظر',
        RecitationMode.fromMemory => 'التسميع غيباً',
        RecitationMode.exam => 'الاختبار',
      };

  String get description => switch (this) {
        RecitationMode.lookUp =>
          'تظهر الآيات أثناء القراءة، وتُظلَّل الكلمات التي تتلوها.',
        RecitationMode.fromMemory =>
          'تختفي الآيات أثناء القراءة؛ سمّع من حفظك ثم أظهرها للمراجعة.',
        RecitationMode.exam =>
          'اختر السورة ونطاق الآيات؛ تبقى الآيات مخفية حتى نهاية الاختبار '
          'أو حتى تطلب إظهارها.',
      };

  /// Whether the ayah text starts hidden when the session opens.
  bool get textInitiallyHidden => this != RecitationMode.lookUp;
}

/// Microphone permission outcome, mapped from the platform status.
///
/// `denied` means the user refused once: the app may ask again.
/// `permanentlyDenied` means the system will never show the dialog again:
/// the user must enable it from the phone's Settings — the UI must show a
/// button that opens the app settings (openAppSettings), not re-request.
enum MicPermissionState {
  granted,
  denied,
  permanentlyDenied,
  restricted,
  unknown,
}

extension MicPermissionStateInfo on MicPermissionState {
  /// Short message the UI shows for this state.
  String get message => switch (this) {
        MicPermissionState.granted => 'الميكروفون مسموح — جاهز للتسميع.',
        MicPermissionState.denied =>
          'إذن الميكروفون مرفوض — يمكنك طلبه مجدداً من هنا.',
        MicPermissionState.permanentlyDenied =>
          'إذن الميكروفون مرفوض نهائياً — فعّله من إعدادات الهاتف: '
          'الإعدادات ← التطبيقات ← تلاوة برو ← الأذونات ← الميكروفون.',
        MicPermissionState.restricted =>
          'الميكروفون مقيّد على هذا الجهاز (سياسة نظام) — لا يمكن بدء التسميع.',
        MicPermissionState.unknown =>
          'حالة إذن الميكروفون غير معروفة — جرّب طلب الإذن.',
      };

  /// True when the session may start (permission already granted).
  bool get canStart => this == MicPermissionState.granted;

  /// True when the UI should offer a "request again" button.
  bool get canRequestAgain => this == MicPermissionState.denied;

  /// True when the UI must offer an "open app settings" button.
  bool get needsAppSettings => this == MicPermissionState.permanentlyDenied;
}

/// Maps a platform [PermissionStatus] to the app's permission state.
/// Pure function — unit-tested, so a platform change cannot silently
/// turn a permanent denial into a re-request loop.
MicPermissionState micPermissionState(PermissionStatus status) => switch (status) {
      PermissionStatus.granted => MicPermissionState.granted,
      PermissionStatus.denied => MicPermissionState.denied,
      PermissionStatus.permanentlyDenied => MicPermissionState.permanentlyDenied,
      PermissionStatus.restricted => MicPermissionState.restricted,
      PermissionStatus.limited => MicPermissionState.denied,
      PermissionStatus.provisional => MicPermissionState.denied,
    };

/// How one word of the passage is marked on screen.
enum WordMark {
  /// No position event ever observed this word: never shown as correct.
  notReviewed,

  /// Engine observed it (locked, confidence >= 0.6).
  matched,

  /// A CONFIRMED checker event at this word.
  error,

  /// An `uncertain` checker event at this word: re-check, never an error.
  needsReview,
}

extension WordMarkInfo on WordMark {
  String get label => switch (this) {
        WordMark.notReviewed => 'لم تُراجَع بعد',
        WordMark.matched => 'مطابقة',
        WordMark.error => 'خطأ مؤكد',
        WordMark.needsReview => 'تحتاج إعادة تحقق',
      };
}

/// Accumulates engine events for one session and derives per-word marks.
///
/// A word matched in ANY segment counts once (segments are the pause/
/// resume slices of one session — see session_screen.dart). Confirmed
/// errors are de-duplicated by the engine's stable checker `id`.
class WordTracker {
  /// Words the engine observed (locked, confidence >= [kMinConfidence]).
  final Set<RefWord> matched = {};

  /// Last observed confidence per word (any state), for the results screen
  /// ("confidence when available"). Null means the engine never observed
  /// the word at all.
  final Map<RefWord, double> confidenceByWord = {};

  /// Confirmed mistakes, keyed by the engine's stable checker id.
  final Map<String, CheckerEvent> confirmedById = {};

  /// Words with an `uncertain` checker event (never errors).
  final Set<RefWord> needsReview = {};

  /// Human-readable notes (self-corrections), shown, never counted.
  final List<String> notes = [];

  /// The word the engine is currently tracking (best candidate), if any.
  RefWord? current;

  /// Confidence of [current] (0 when nothing is tracked).
  double currentConfidence = 0;

  /// Tracking state of [current].
  TrackState currentState = TrackState.acquiring;

  /// Feed one position event into the tracker.
  void observe(PositionEvent event) {
    final best = event.observed.isNotEmpty ? event.observed.first : null;
    current = best;
    currentConfidence = event.confidence;
    currentState = event.state;
    if (best == null) return;
    confidenceByWord[best] = event.confidence;
    if (event.state == TrackState.locked &&
        event.confidence >= kMinConfidence) {
      matched.add(best);
    }
  }

  /// Feed one checker event into the tracker.
  void applyChecker(CheckerEvent event) {
    switch (event.state) {
      case CheckerState.confirmed:
        confirmedById[event.id] = event;
      case CheckerState.uncertain:
        needsReview.add(event.location);
      case CheckerState.resolved:
        // Self-correction: if this mistake was confirmed before, it no
        // longer counts; record it as a note, never as an error.
        confirmedById.remove(event.id);
        needsReview.remove(event.location);
        notes.add('صحّحت نفسك عند ${event.location} — لا يُحسب خطأً');
      case CheckerState.suspected:
        // Transient: the engine has not decided yet. Ignore.
        break;
    }
  }

  /// Confirmed errors, de-duplicated, in passage order.
  List<CheckerEvent> get confirmedErrors {
    final list = confirmedById.values.toList()
      ..sort((a, b) {
        final byAyah = a.location.ayah.compareTo(b.location.ayah);
        return byAyah != 0
            ? byAyah
            : a.location.word.compareTo(b.location.word);
      });
    return list;
  }

  /// The mark of one word for display.
  WordMark markOf(RefWord word) {
    if (confirmedById.values.any((e) => e.location == word)) {
      return WordMark.error;
    }
    if (matched.contains(word)) return WordMark.matched;
    if (needsReview.contains(word)) return WordMark.needsReview;
    return WordMark.notReviewed;
  }
}

/// The result of one finished session. JSON-serialisable for local storage.
class SessionResult {
  SessionResult({
    required this.surah,
    required this.fromAyah,
    required this.toAyah,
    required this.mode,
    required this.tier,
    required this.reviewedAyahs,
    required this.totalWords,
    required this.matchedWords,
    required this.errorCount,
    required this.needsReviewCount,
    required this.matchPercent,
    required this.errorAyahs,
    required this.errors,
    required this.notes,
    required this.segments,
    required this.startedAt,
    required this.endedAt,
    this.confidenceByWord = const {},
  });

  final int surah;
  final int fromAyah;
  final int toAyah;
  final RecitationMode mode;
  final String tier;

  /// Ayahs the engine actually observed (≥1 matched word or confirmed
  /// error). Any other ayah of the passage is "not reviewed", never correct.
  final List<int> reviewedAyahs;

  /// Words of the reviewed ayahs only (the denominator of match %).
  final int totalWords;

  /// Words matched (locked, confidence >= 0.6), de-duplicated across segments.
  final int matchedWords;

  final int errorCount;
  final int needsReviewCount;

  /// matchedWords / totalWords * 100, or null when no ayah was reviewed
  /// (never a fake 0%: "no data" is shown instead).
  final double? matchPercent;

  /// Ayahs with at least one confirmed error, ascending.
  final List<int> errorAyahs;

  /// Confirmed errors in passage order (for the results screen).
  final List<CheckerEvent> errors;

  final List<String> notes;

  /// Last observed confidence per word, keyed "surah:ayah:word".
  /// Only words the engine actually observed have an entry — the results
  /// screen shows "confidence when available" from this map, never a
  /// guessed number.
  final Map<String, double> confidenceByWord;

  /// Number of recording segments (1 when the session was never paused).
  final int segments;

  final DateTime startedAt;
  final DateTime endedAt;

  /// The contiguous range that contains every error ayah, or null when
  /// there are no errors. «إعادة تسميع الأخطاء» starts a session on it.
  Passage? get reReciteRange => errorAyahs.isEmpty
      ? null
      : Passage(
          surah: surah,
          fromAyah: errorAyahs.first,
          toAyah: errorAyahs.last,
        );

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => {
        'surah': surah,
        'fromAyah': fromAyah,
        'toAyah': toAyah,
        'mode': mode.name,
        'tier': tier,
        'reviewedAyahs': reviewedAyahs,
        'totalWords': totalWords,
        'matchedWords': matchedWords,
        'errorCount': errorCount,
        'needsReviewCount': needsReviewCount,
        'matchPercent': matchPercent,
        'errorAyahs': errorAyahs,
        'errors': errors
            .map((e) => {
                  'id': e.id,
                  'errorClass': e.errorClass.name,
                  'surah': e.location.surah,
                  'ayah': e.location.ayah,
                  'word': e.location.word,
                })
            .toList(),
        'notes': notes,
        'confidenceByWord': confidenceByWord,
        'segments': segments,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
      };

  factory SessionResult.fromJson(Map<String, dynamic> j) {
    RecitationMode modeFrom(String? s) => switch (s) {
          'fromMemory' => RecitationMode.fromMemory,
          'exam' => RecitationMode.exam,
          _ => RecitationMode.lookUp,
        };
    ErrorClass classFrom(String? s) => switch (s) {
          'omittedWord' => ErrorClass.omittedWord,
          'addedWord' => ErrorClass.addedWord,
          'skippedPassage' => ErrorClass.skippedPassage,
          _ => ErrorClass.wrongWord,
        };
    return SessionResult(
      surah: (j['surah'] as num).toInt(),
      fromAyah: (j['fromAyah'] as num).toInt(),
      toAyah: (j['toAyah'] as num).toInt(),
      mode: modeFrom(j['mode'] as String?),
      tier: (j['tier'] as String?) ?? 'lite',
      reviewedAyahs:
          ((j['reviewedAyahs'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
      totalWords: (j['totalWords'] as num?)?.toInt() ?? 0,
      matchedWords: (j['matchedWords'] as num?)?.toInt() ?? 0,
      errorCount: (j['errorCount'] as num?)?.toInt() ?? 0,
      needsReviewCount: (j['needsReviewCount'] as num?)?.toInt() ?? 0,
      matchPercent: (j['matchPercent'] as num?)?.toDouble(),
      errorAyahs:
          ((j['errorAyahs'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
      errors: ((j['errors'] as List?) ?? const []).map((e) {
        final m = e as Map<String, dynamic>;
        return CheckerEvent(
          id: (m['id'] as String?) ?? '',
          timeMs: 0,
          state: CheckerState.confirmed,
          errorClass: classFrom(m['errorClass'] as String?),
          location: RefWord(
            surah: (m['surah'] as num).toInt(),
            ayah: (m['ayah'] as num).toInt(),
            word: (m['word'] as num).toInt(),
          ),
        );
      }).toList(),
      notes: ((j['notes'] as List?) ?? const []).cast<String>(),
      confidenceByWord: ((j['confidenceByWord'] as Map<String, dynamic>?) ?? const {})
          .map((k, v) => MapEntry(k, (v as num).toDouble())),
      segments: (j['segments'] as num?)?.toInt() ?? 1,
      startedAt: DateTime.parse(j['startedAt'] as String),
      endedAt: DateTime.parse(j['endedAt'] as String),
    );
  }
}

/// Builds a [SessionResult] from a finished session's tracker.
///
/// [words] is the passage text from engine.passageWords() (one list of
/// words per ayah, fromAyah..toAyah in order). An ayah counts as reviewed
/// only when the tracker observed at least one of its words (matched) or
/// confirmed an error in it.
SessionResult computeSessionResult({
  required Passage passage,
  required List<List<String>> words,
  required WordTracker tracker,
  required RecitationMode mode,
  required String tier,
  required int segments,
  required DateTime startedAt,
  required DateTime endedAt,
}) {
  final reviewedAyahs = <int>[];
  var totalWords = 0;
  for (var i = 0; i < words.length; i++) {
    final ayah = passage.fromAyah + i;
    final ayahWords = words[i];
    var reviewed = false;
    for (var w = 0; w < ayahWords.length; w++) {
      final ref = RefWord(surah: passage.surah, ayah: ayah, word: w + 1);
      if (tracker.matched.contains(ref) ||
          tracker.confirmedErrors.any((e) => e.location == ref)) {
        reviewed = true;
        break;
      }
    }
    if (reviewed) {
      reviewedAyahs.add(ayah);
      totalWords += ayahWords.length;
    }
  }
  final errors = tracker.confirmedErrors;
  final errorAyahs = errors.map((e) => e.location.ayah).toSet().toList()
    ..sort();
  final matchPercent = totalWords == 0
      ? null
      : (tracker.matched.length / totalWords) * 100;
  return SessionResult(
    surah: passage.surah,
    fromAyah: passage.fromAyah,
    toAyah: passage.toAyah,
    mode: mode,
    tier: tier,
    reviewedAyahs: reviewedAyahs,
    totalWords: totalWords,
    matchedWords: tracker.matched.length,
    errorCount: errors.length,
    needsReviewCount: tracker.needsReview.length,
    matchPercent: matchPercent,
    errorAyahs: errorAyahs,
    errors: errors,
    notes: List<String>.from(tracker.notes),
    confidenceByWord: tracker.confidenceByWord
        .map((k, v) => MapEntry(k.toString(), v)),
    segments: segments,
    startedAt: startedAt,
    endedAt: endedAt,
  );
}
