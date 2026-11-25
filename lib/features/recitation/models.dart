// Shared value types for the Pro speech engine.
//
// These types are engine-neutral: the WebView adapter (webview_engine.dart)
// translates @tilawa/core/web events into them, and any future adapter
// (Dart/ONNX re-implementation, sherpa-onnx + Tarteel Whisper) must produce
// the same shapes. The main Tilawa app will depend on SpeechEngine only.

/// One word in the Quran reference, 1-based indices, matching the engine's
/// `{surah, ayah, word}` references and `ref-v2.json` (`ayahs[].w`).
class RefWord {
  const RefWord({required this.surah, required this.ayah, required this.word});
  final int surah;
  final int ayah;
  final int word;

  factory RefWord.fromJson(Map<String, dynamic> j) => RefWord(
        surah: (j['surah'] as num).toInt(),
        ayah: (j['ayah'] as num).toInt(),
        word: (j['word'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {'surah': surah, 'ayah': ayah, 'word': word};

  @override
  String toString() => '$surah:$ayah:$word';

  @override
  bool operator ==(Object other) =>
      other is RefWord &&
      other.surah == surah &&
      other.ayah == ayah &&
      other.word == word;

  @override
  int get hashCode => Object.hash(surah, ayah, word);
}

/// Tracking state from `position.state`.
enum TrackState { acquiring, locked, ambiguous, lost }

TrackState trackStateFromString(String s) => switch (s) {
      'acquiring' => TrackState.acquiring,
      'locked' => TrackState.locked,
      'ambiguous' => TrackState.ambiguous,
      'lost' => TrackState.lost,
      _ => TrackState.acquiring,
    };

/// Error classes the 1.x engine supports (memorization only).
enum ErrorClass { wrongWord, omittedWord, addedWord, skippedPassage }

ErrorClass? errorClassFromString(String s) => switch (s) {
      'wrong_word' => ErrorClass.wrongWord,
      'omitted_word' => ErrorClass.omittedWord,
      'added_word' => ErrorClass.addedWord,
      'skipped_passage' => ErrorClass.skippedPassage,
      _ => null,
    };

String errorClassLabel(ErrorClass c) => switch (c) {
      ErrorClass.wrongWord => 'كلمة خاطئة',
      ErrorClass.omittedWord => 'كلمة محذوفة',
      ErrorClass.addedWord => 'كلمة زائدة',
      ErrorClass.skippedPassage => 'مقطع متخطَّى',
    };

/// Lifecycle of one suspected mistake.
enum CheckerState { suspected, confirmed, resolved, uncertain }

CheckerState checkerStateFromString(String s) => switch (s) {
      'suspected' => CheckerState.suspected,
      'confirmed' => CheckerState.confirmed,
      'resolved' => CheckerState.resolved,
      'uncertain' => CheckerState.uncertain,
      _ => CheckerState.suspected,
    };
