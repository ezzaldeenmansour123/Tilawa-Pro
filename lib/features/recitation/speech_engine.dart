// Engine-neutral speech interface for the Tilawa recitation follower.
//
// Contract (from @tilawa/core 1.0.0-rc.1 README + model card):
// - Events arrive in order: `capabilities` first, then `position` / `checker`.
// - `timeMs` is the SESSION AUDIO CLOCK (ms of 16 kHz audio since the first
//   sample), NOT wall time. Latency metrics must pair it with the wall clock
//   recorded when the session started (see EventLog).
// - Default policy: minConfidence 0.6; a mistake is confirmed after the next
//   word starts or after 2.5 s (whichever the session policy says).
// - The engine flags MEMORIZATION mistakes only: no tajweed, no pronunciation,
//   Hafs only, adults only, no fast hadr, no children's voices.
// - Audio never leaves the device.

import 'models.dart';

/// What the loaded engine reports about itself (the `capabilities` event).
class EngineCapabilities {
  const EngineCapabilities({
    required this.modelVersion,
    required this.modelRelease,
    required this.referenceVersion,
    required this.sdkVersion,
    required this.modelSha256,
    required this.tier,
    required this.backend,
    required this.supported,
    required this.unsupported,
  });

  final String modelVersion; // e.g. "spliced-clean-lite@1-int8"
  final String modelRelease;
  final String referenceVersion; // e.g. "ref-v2"
  final String sdkVersion;
  final String modelSha256;
  final String tier; // "lite" | "full"
  final String backend; // e.g. "wasm" | "webgpu" | "cpu"
  final List<ErrorClass> supported;
  final List<String> unsupported;

  factory EngineCapabilities.fromJson(Map<String, dynamic> j) {
    final supportedRaw = (j['supported'] as List?) ?? const [];
    return EngineCapabilities(
      modelVersion: (j['modelVersion'] ?? '') as String,
      modelRelease: (j['modelRelease'] ?? '') as String,
      referenceVersion: (j['referenceVersion'] ?? '') as String,
      sdkVersion: (j['sdkVersion'] ?? '') as String,
      modelSha256: (j['modelSha256'] ?? '') as String,
      tier: (j['tier'] ?? '') as String,
      backend: (j['backend'] ?? '') as String,
      supported: supportedRaw
          .map((e) => errorClassFromString(e as String))
          .whereType<ErrorClass>()
          .toList(),
      unsupported:
          ((j['unsupported'] as List?) ?? const []).cast<String>(),
    );
  }
}

/// Where the reciter is (`position` event).
class PositionEvent {
  const PositionEvent({
    required this.timeMs,
    required this.observed,
    required this.confidence,
    required this.state,
    this.expected,
  });

  /// Session audio clock (ms).
  final int timeMs;

  /// Best-first candidate words actually observed.
  final List<RefWord> observed;

  /// Confidence of the best candidate (0..1).
  final double confidence;

  final TrackState state;

  /// In memorization sessions: the passage word the reciter should be on.
  final RefWord? expected;
}

/// A possible mistake (`checker` event). The `id` is stable across states.
class CheckerEvent {
  const CheckerEvent({
    required this.id,
    required this.timeMs,
    required this.state,
    required this.errorClass,
    required this.location,
    this.expectedPhonemes,
    this.observedPhonemes,
  });

  final String id;
  final int timeMs;
  final CheckerState state;
  final ErrorClass errorClass;
  final RefWord location;
  final String? expectedPhonemes;
  final String? observedPhonemes;

  /// True only for a CONFIRMED mistake with confidence policy applied.
  /// `uncertain` and `resolved` (self-correction) are never counted as errors.
  bool get countsAsError => state == CheckerState.confirmed;
}

/// A declared passage for a memorization session.
class Passage {
  const Passage({
    required this.surah,
    required this.fromAyah,
    required this.toAyah,
  });
  final int surah;
  final int fromAyah;
  final int toAyah;
}

/// How a session was started.
enum SessionMode { free, memorization }

/// Model loading status shown on the model card (never start before `ready`).
enum ModelStatus { notInstalled, downloading, ready, failed }

class ModelInfo {
  const ModelInfo({
    required this.status,
    required this.tier,
    this.version,
    this.bytes,
    this.sha256Short,
    this.downloadFraction,
    this.error,
    this.ortBytes,
    this.referenceOk,
    this.wasmOk,
    this.bundleOk,
  });

  final ModelStatus status;
  final String tier; // "lite" | "full"
  final String? version;
  final int? bytes;
  final String? sha256Short; // first 12 hex chars
  final double? downloadFraction; // 0..1 while downloading
  final String? error;
  final int? ortBytes; // total bytes of downloaded onnxruntime-web WASM files

  /// نتيجة فحص المرجع في status(): true = موجود + SHA مطابقة + 6236 آية.
  /// null = لم يُفحص (لا يحدث في status() الحالي — يُفحص دائماً).
  final bool? referenceOk;

  /// نتيجة فحص WASM في status(): true = الحجم + SHA مطابقان للملفين.
  final bool? wasmOk;

  /// نتيجة فحص حزمة المحرك (bundle.js) في status(): true = موجودة في
  /// هذا البناء، false = غائبة (نسخة تطوير محلية بلا بناء ويب)،
  /// null = لم يُفحص بعد عند الإقلاع (يُتجاهل — لا يمنع «جاهز»).
  final bool? bundleOk;
}

class SpeechEngineException implements Exception {
  SpeechEngineException(this.message, {this.reason});
  final String message;
  final String? reason; // e.g. MicrophoneError reason: denied|unavailable|insecure-context
  @override
  String toString() => 'SpeechEngineException: $message'
      '${reason == null ? '' : ' ($reason)'}';
}

/// The single interface every engine adapter must implement.
///
/// Lifecycle: [load] (once) -> [startSession] -> events -> [endSession] ->
/// [dispose]. [load] must verify the model SHA-256 before reporting ready.
abstract class SpeechEngine {
  /// Loads the model + reference from local storage. Throws
  /// [SpeechEngineException] on integrity failure or load failure.
  /// [onProgress] receives 0..1 while downloading (first install only).
  Future<EngineCapabilities> load({
    required String tier,
    void Function(double fraction)? onProgress,
  });

  /// Starts a session. [passage] is required for memorization mode.
  /// Returns a broadcast stream of [PositionEvent]/[CheckerEvent].
  /// The stream's first event is always the capabilities object, delivered
  /// as [EngineCapabilities] through [capabilitiesStream].
  Stream<Object> startSession({
    required SessionMode mode,
    Passage? passage,
  });

  /// The capabilities event of the current session (null before start).
  EngineCapabilities? get capabilities;

  /// Stops listening and ends the session (idempotent). Drains audio and
  /// decides every open mistake, per the engine contract.
  Future<void> endSession();

  /// Releases the model and all resources.
  Future<void> dispose();

  /// Words of a passage from the loaded reference (ref-v2.json), as display
  /// text. Returns null if the reference is not loaded. The text comes from
  /// the engine's own reference — never from memory, never invented.
  /// Each inner list is one ayah's words, in order.
  List<List<String>>? passageWords(Passage passage);
}
