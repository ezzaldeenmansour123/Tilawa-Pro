// The single readiness gate before any tasmee' session (2026-11-26).
//
// Extracted from RecitationScreen._start so the quiz screen and the
// setup screen run the SAME five checks in the SAME order:
//   1. model installed + SHA-verified,
//   2. WASM runtime files present,
//   3. microphone permission (request once when denied; permanently
//      denied -> the settings path, never a re-request loop),
//   4. engine loaded (skipped when already loaded with the same tier),
//   5. passage text loaded from the engine's own reference.
// Only then is the live session page pushed. Every failure returns its
// message instead of throwing, so the caller can show it in its own
// error card / SnackBar. [SessionStartStatus] carries the intermediate
// states back so the setup screen can keep its checklist rows in sync.

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import 'progress_store.dart';
import 'session_logic.dart';
import 'speech_engine.dart';
import 'webview_engine.dart';
import 'screens/session_screen.dart';

/// Intermediate gate states, mirrored back to the caller.
class SessionStartStatus {
  ModelInfo? modelInfo;
  bool wasmReady = false;
  MicPermissionState mic = MicPermissionState.unknown;
  int? loadMs;
  bool engineLoadAttempted = false;
  bool engineLoadFailed = false;
}

/// Runs the gate and, on success, pushes the live session page and awaits
/// its end. Returns the session result only when [returnResult] is true
/// (the quiz flow); otherwise null. [error] is non-null on any gate
/// failure — the exact message the setup screen used to show.
Future<({SessionResult? result, String? error, SessionStartStatus status})>
    startRecitationSession({
  required BuildContext context,
  required WebViewEngine engine,
  required ProgressStore progressStore,
  required Passage passage,
  required RecitationMode mode,
  required String tier,
  bool returnResult = false,
  void Function(String label)? onLoadingLabel,
}) async {
  final status = SessionStartStatus();

  try {
    // 1. Model installed + verified.
    final info = await engine.modelManager.status(tier);
    status.modelInfo = info;
    if (info.status != ModelStatus.ready) {
      return (
        result: null,
        error: 'النموذج غير جاهز: ${info.error ?? 'غير مثبَّت'} — '
            'نزّله أولاً من صفحة «النموذج».',
        status: status,
      );
    }
    // 2. WASM runtime files.
    final wasm = await engine.modelManager.ortWasmReady();
    status.wasmReady = wasm;
    if (!wasm) {
      return (
        result: null,
        error: 'ملفات تشغيل المحرك (WASM) غير موجودة — '
            'نزّلها من صفحة «النموذج» (زر التنزيل يشملها).',
        status: status,
      );
    }
    // 3. Microphone permission.
    var micState = micPermissionState(await Permission.microphone.status);
    if (!micState.canStart && micState.canRequestAgain) {
      micState = micPermissionState(await Permission.microphone.request());
    }
    status.mic = micState;
    if (!micState.canStart) {
      return (result: null, error: micState.message, status: status);
    }
    // 4. Engine load (skip when already loaded with this tier).
    int? loadMs;
    final engineReady = engine.isLoaded && engine.loadedTier == tier;
    if (!engineReady) {
      status.engineLoadAttempted = true;
      onLoadingLabel?.call('جارٍ تحميل النموذج…');
      try {
        final t0 = DateTime.now();
        await engine.load(
          tier: tier,
          onStage: (label) => onLoadingLabel?.call(label),
        );
        loadMs = DateTime.now().difference(t0).inMilliseconds;
        status.loadMs = loadMs;
      } on SpeechEngineException catch (e) {
        status.engineLoadFailed = true;
        return (result: null, error: e.toString(), status: status);
      }
    }
    // 5. Passage text from the engine's own reference.
    final words = engine.passageWords(passage);
    if (words == null) {
      return (
        result: null,
        error: 'تعذّر تحميل نص المقطع من المرجع.',
        status: status,
      );
    }
    if (!context.mounted) {
      return (
        result: null,
        error: 'أُلغيت الجلسة قبل بدئها.',
        status: status,
      );
    }
    // 6. Push the live session page and await its end.
    final result = await Navigator.push<SessionResult?>(
      context,
      MaterialPageRoute(
        builder: (_) => SessionScreen(
          engine: engine,
          passage: passage,
          mode: mode,
          tier: tier,
          words: words,
          progressStore: progressStore,
          loadMs: loadMs,
          returnResult: returnResult,
        ),
      ),
    );
    return (result: result, error: null, status: status);
  } on SpeechEngineException catch (e) {
    return (result: null, error: e.toString(), status: status);
  } catch (e) {
    return (result: null, error: 'خطأ غير متوقع: $e', status: status);
  }
}
