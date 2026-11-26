// Native microphone capture for tasmee' (2026-11-26).
//
// WHY THIS FILE EXISTS: the WebView audio source will not start on the
// user's S22 Ultra — getUserMedia throws NotReadableError ("Could not
// start audio source") inside the WebView even after the WebView
// permission grant (pro-35) and the exact-name + retry (pro-36). The
// audio is therefore captured NATIVELY with package `record` (Android
// AudioRecord, 16 kHz mono PCM16) and pushed into the engine session
// with session.pushAudio — the engine is source-agnostic by design
// (@tilawa/core's web startMicrophone itself only feeds
// session.pushAudio(gated, 16000); its react-native entry says: "The
// app pushes PCM from its own recorder with session.pushAudio(samples,
// sampleRate)"). The WebView never calls getUserMedia anymore.
//
// What this file owns: the recorder, the fixed 100 ms framing, and the
// named errors. The transport (base64 + runJavaScript + ack window)
// lives in WebViewEngine, which is the only caller.

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

/// Why a native-mic failure happened — surfaced verbatim to the UI, so
/// a failure is never a bare "something went wrong".
enum MicFailureReason {
  /// RECORD_AUDIO is not granted (checked before starting; the setup
  /// screen requests it via permission_handler first, so this is the
  /// revoked-in-settings safety net).
  permission,

  /// startStream() itself threw (no device, recorder busy, …).
  recorderStart,

  /// The recorder's stream errored or closed unexpectedly mid-session.
  recorderStream,
}

class NativeMicException implements Exception {
  NativeMicException(this.reason, this.message);

  final MicFailureReason reason;
  final String message;

  @override
  String toString() => 'NativeMicException($reason): $message';
}

/// The recorder's states. `paused` is the backpressure state only
/// (engine paused the capture because it is behind); a user pause ends
/// the segment and stops the recorder instead (see WebViewEngine).
enum NativeMicState { idle, recording, paused, stopped }

/// The platform recorder behind [NativeMicRecorder], kept behind an
/// interface so the state machine is unit-testable with a fake stream
/// (no platform channels in tests).
abstract class MicRecorderBackend {
  Future<bool> hasPermission();

  Future<Stream<Uint8List>> startStream(RecordConfig config);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> dispose();
}

/// The real backend: package `record`'s [AudioRecorder].
class RecordBackend implements MicRecorderBackend {
  RecordBackend([AudioRecorder? recorder])
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() =>
      _recorder.hasPermission(request: false);

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) =>
      _recorder.startStream(config);

  @override
  Future<void> pause() => _recorder.pause();

  @override
  Future<void> resume() => _recorder.resume();

  @override
  Future<void> stop() => _recorder.stop();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Re-chunks the recorder's variable-size stream emissions into fixed
/// frames. Pure (no platform code) — fully unit-tested.
class PcmFramer {
  PcmFramer({this.frameBytes = NativeMicRecorder.kFrameBytes});

  /// One frame: 100 ms of 16 kHz mono PCM16 = 1600 samples × 2 bytes.
  final int frameBytes;

  final _buffer = BytesBuilder();

  /// Feeds raw bytes; returns every complete frame now available
  /// (possibly none). A partial tail stays buffered.
  List<Uint8List> add(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    _buffer.add(chunk);
    final out = <Uint8List>[];
    while (_buffer.length >= frameBytes) {
      final bytes = _buffer.takeBytes();
      out.add(Uint8List.sublistView(bytes, 0, frameBytes));
      if (bytes.length > frameBytes) {
        _buffer.add(Uint8List.sublistView(bytes, frameBytes));
      }
    }
    return out;
  }

  /// The buffered tail (< one frame), or null when empty. Called at
  /// stop() so the last spoken words are still pushed to the engine
  /// instead of being dropped with the recorder.
  Uint8List? flush() => _buffer.length == 0 ? null : _buffer.takeBytes();

  /// Buffered bytes not yet emitted as a frame.
  int get bufferedBytes => _buffer.length;
}

/// Native mic capture: 16 kHz, mono, PCM16, framed at 100 ms.
///
/// Contract:
/// - The caller (WebViewEngine) owns the permission: the setup screen
///   requests RECORD_AUDIO via permission_handler before the engine
///   loads. [start] still re-checks it and fails with
///   [MicFailureReason.permission] instead of starting deaf.
/// - [start] throws [NativeMicException] on failure (the engine
///   surfaces it on the event stream); stream errors mid-session go
///   to [onError].
/// - Frames arrive via [onFrame] in order, each exactly [kFrameBytes]
///   except the final flushed tail from [stop].
/// - [pause]/[resume] are the engine's backpressure valve (capture
///   pauses while the engine catches up); a user pause stops the
///   recorder via [stop] instead.
/// - [stop] is best-effort and never throws (it runs during teardown);
///   a failure there is recorded in [lastError] for diagnostics.
class NativeMicRecorder {
  NativeMicRecorder({MicRecorderBackend? backend})
      : _backend = backend ?? RecordBackend();

  /// Capture rate the engine is fed at. 16 kHz is the model rate: the
  /// web path resampled to exactly this before pushAudio, so capturing
  /// at 16 kHz keeps the pushed stream identical — no resampler runs
  /// anywhere (pushAudio would resample anyway if the rate ever
  /// differed, but it never should).
  static const kSampleRate = 16000;

  /// Mono: the engine tracks one voice.
  static const kChannels = 1;

  /// One frame: 100 ms of 16 kHz mono PCM16 = 1600 samples × 2 bytes.
  /// 10 frames/second; each frame is 3.2 KB (4.3 KB base64).
  static const kFrameBytes = 3200;

  /// The config handed to `record`. Processing is OFF (autoGain,
  /// echoCancel, noiseSuppress all false) to match the web path's
  /// getUserMedia constraints exactly (channelCount 1, all processing
  /// false) — the engine must hear the raw recitation, not a
  /// processed signal.
  static const kConfig = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: kSampleRate,
    numChannels: kChannels,
    autoGain: false,
    echoCancel: false,
    noiseSuppress: false,
  );

  final MicRecorderBackend _backend;
  final _framer = PcmFramer();

  NativeMicState _state = NativeMicState.idle;
  NativeMicState get state => _state;

  /// The last best-effort failure (from [stop]/[dispose]), if any.
  /// Kept for diagnostics; start/stream failures throw or call
  /// onError instead of landing here.
  Object? lastError;

  StreamSubscription<Uint8List>? _subscription;
  void Function(Uint8List frame, int sequence)? _onFrame;
  void Function(Object error)? _onError;
  int _sequence = 0;
  bool _stopping = false;

  /// Starts capture. Throws [NativeMicException] (permission or
  /// recorderStart) — the caller surfaces it. Frames are delivered to
  /// [onFrame] with a per-start sequence (0, 1, 2, …); stream errors
  /// go to [onError].
  Future<void> start({
    required void Function(Uint8List frame, int sequence) onFrame,
    required void Function(Object error) onError,
  }) async {
    if (_state == NativeMicState.recording ||
        _state == NativeMicState.paused) {
      throw StateError('NativeMicRecorder.start() while $_state');
    }
    if (!await _backend.hasPermission()) {
      throw NativeMicException(
        MicFailureReason.permission,
        'إذن الميكروفون غير ممنوح — فعّله من إعدادات الهاتف '
        '(الإعدادات ← التطبيقات ← تلاوة برو ← الأذونات ← الميكروفون).',
      );
    }
    _onFrame = onFrame;
    _onError = onError;
    _sequence = 0;
    _stopping = false;
    final Stream<Uint8List> stream;
    try {
      stream = await _backend.startStream(kConfig);
    } catch (e) {
      throw NativeMicException(
        MicFailureReason.recorderStart,
        'تعذّر بدء التسجيل الأصلي: $e',
      );
    }
    _state = NativeMicState.recording;
    _subscription = stream.listen(
      _onData,
      onError: (Object e) {
        if (_state == NativeMicState.recording ||
            _state == NativeMicState.paused) {
          _onError?.call(NativeMicException(
            MicFailureReason.recorderStream,
            'انقطع دفق الصوت من الميكروفون: $e',
          ));
        }
      },
      onDone: () {
        // The stream closing on its own mid-session (not from stop())
        // means the recorder died — the engine must hear about it
        // instead of waiting forever for audio that never comes.
        if (!_stopping &&
            (_state == NativeMicState.recording ||
                _state == NativeMicState.paused)) {
          _onError?.call(NativeMicException(
            MicFailureReason.recorderStream,
            'انتهى دفق الصوت من الميكروفون فجأة أثناء التسجيل.',
          ));
        }
      },
      cancelOnError: false,
    );
  }

  void _onData(Uint8List chunk) {
    if (_state != NativeMicState.recording &&
        _state != NativeMicState.paused) {
      return;
    }
    // Frames keep flowing into the framer while backpressure-paused:
    // the recorder is paused at the source then, so nothing arrives.
    // (A frame arriving here while paused would mean the pause did not
    // take — it is still pushed; dropping audio would corrupt the
    // recitation alignment, so never drop.)
    for (final frame in _framer.add(chunk)) {
      _onFrame?.call(frame, _sequence++);
    }
  }

  /// Backpressure pause: the engine is behind, so stop the capture at
  /// the source until it catches up. No-op unless recording.
  Future<void> pause() async {
    if (_state != NativeMicState.recording) return;
    try {
      await _backend.pause();
      _state = NativeMicState.paused;
    } catch (e) {
      lastError = e;
    }
  }

  /// Resume after a backpressure pause. No-op unless paused.
  Future<void> resume() async {
    if (_state != NativeMicState.paused) return;
    try {
      await _backend.resume();
      _state = NativeMicState.recording;
    } catch (e) {
      lastError = e;
    }
  }

  /// Stops capture. The buffered tail (< one frame) is emitted as a
  /// final partial frame first, so the last words are not lost.
  /// Best-effort: never throws.
  Future<void> stop() async {
    if (_state == NativeMicState.idle ||
        _state == NativeMicState.stopped) {
      return;
    }
    _stopping = true;
    try {
      await _subscription?.cancel();
    } catch (e) {
      lastError = e;
    }
    _subscription = null;
    try {
      await _backend.stop();
    } catch (e) {
      lastError = e;
    }
    final tail = _framer.flush();
    if (tail != null && tail.isNotEmpty) {
      _onFrame?.call(tail, _sequence++);
    }
    _state = NativeMicState.stopped;
    _stopping = false;
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _backend.dispose();
    } catch (e) {
      lastError = e;
    }
    _state = NativeMicState.idle;
  }
}
