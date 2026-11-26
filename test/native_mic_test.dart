// Tests for the native mic capture path (2026-11-26).
//
// What is covered here (pure Dart, no platform channels):
// - PcmFramer: fixed 100 ms framing of variable-size stream chunks.
// - The base64 transport contract (Dart base64Encode -> JS atob).
// - NativeMicRecorder's state machine with a fake backend stream.
// - The named errors (permission / recorderStart / recorderStream).
//
// What is NOT covered here (needs CI + the phone):
// - The real `record` backend (AudioRecord on Android): whether
//   startStream delivers 16 kHz mono PCM16 on the S22 Ultra.
// - The JS pushPcm decode (covered by the bundle smoke test's
//   method check + the phone protocol, not by a unit test).
// - The WebViewEngine pump (needs a WebViewController; exercised in
//   CI's flutter test only through the framer/recorder units here).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:tilawa_pro/features/recitation/native_mic.dart';

class FakeBackend implements MicRecorderBackend {
  FakeBackend({this.permission = true});

  bool permission;
  RecordConfig? lastConfig;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  bool disposed = false;
  Object? startError;

  // A fresh single-subscription controller per startStream (a real
  // recorder also hands out a new stream per start).
  StreamController<Uint8List>? _current;

  void emit(Uint8List bytes) => _current?.add(bytes);
  void emitError(Object e) => _current?.addError(e);
  Future<void> closeStream() async => await _current?.close();

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    if (startError != null) throw startError!;
    lastConfig = config;
    _current = StreamController<Uint8List>();
    return _current!.stream;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Uint8List _pattern(int length, [int start = 0]) => Uint8List.fromList(
      List<int>.generate(length, (i) => (start + i) % 256),
    );

void main() {
  group('frame math', () {
    test('100 ms of 16 kHz mono PCM16 is 3200 bytes', () {
      expect(NativeMicRecorder.kSampleRate, 16000);
      expect(NativeMicRecorder.kChannels, 1);
      expect(NativeMicRecorder.kFrameBytes, 3200);
      expect(NativeMicRecorder.kFrameBytes,
          NativeMicRecorder.kSampleRate ~/ 10 * 2);
    });

    test('capture config matches the web path constraints exactly', () {
      final c = NativeMicRecorder.kConfig;
      expect(c.encoder, AudioEncoder.pcm16bits);
      expect(c.sampleRate, 16000);
      expect(c.numChannels, 1);
      expect(c.autoGain, isFalse);
      expect(c.echoCancel, isFalse);
      expect(c.noiseSuppress, isFalse);
    });
  });

  group('PcmFramer', () {
    test('emits nothing for less than one frame', () {
      final framer = PcmFramer();
      expect(framer.add(_pattern(3199)), isEmpty);
      expect(framer.bufferedBytes, 3199);
    });

    test('emits exactly one frame at 3200 bytes', () {
      final framer = PcmFramer();
      final frames = framer.add(_pattern(3200));
      expect(frames, hasLength(1));
      expect(frames.first.length, 3200);
      expect(framer.bufferedBytes, 0);
    });

    test('splits 6400 bytes into two frames, preserving bytes', () {
      final framer = PcmFramer();
      final input = _pattern(6400);
      final frames = framer.add(input);
      expect(frames, hasLength(2));
      expect(frames[0], _pattern(3200));
      expect(frames[1], _pattern(3200, 3200 % 256));
    });

    test('accumulates a partial tail across adds', () {
      final framer = PcmFramer();
      expect(framer.add(_pattern(5000)), hasLength(1));
      expect(framer.bufferedBytes, 1800);
      expect(framer.add(_pattern(1400)), hasLength(1));
      expect(framer.bufferedBytes, 0);
    });

    test('flush returns the tail, null when empty', () {
      final framer = PcmFramer();
      expect(framer.flush(), isNull);
      framer.add(_pattern(100));
      final tail = framer.flush();
      expect(tail, hasLength(100));
      expect(framer.flush(), isNull);
    });

    test('empty chunks are ignored', () {
      final framer = PcmFramer();
      expect(framer.add(Uint8List(0)), isEmpty);
      expect(framer.bufferedBytes, 0);
    });
  });

  group('base64 transport contract', () {
    test('round-trips PCM16 bytes through standard base64', () {
      final bytes = _pattern(3200);
      final encoded = base64Encode(bytes);
      // Standard base64 alphabet only (what JS atob decodes).
      expect(encoded, matches(RegExp(r'^[A-Za-z0-9+/=]+$')));
      expect(base64Decode(encoded), bytes);
      // 3200 bytes -> 4268 chars (33% overhead, as documented).
      expect(encoded.length, 4268);
    });
  });

  group('NativeMicRecorder state machine (fake backend)', () {
    late FakeBackend backend;
    late NativeMicRecorder mic;
    late List<(Uint8List, int)> frames;
    late List<Object> errors;

    setUp(() {
      backend = FakeBackend();
      mic = NativeMicRecorder(backend: backend);
      frames = [];
      errors = [];
    });

    tearDown(() async {
      await mic.dispose();
    });

    Future<void> startMic() => mic.start(
          onFrame: (frame, seq) => frames.add((frame, seq)),
          onError: errors.add,
        );

    test('start checks permission and fails named when denied', () async {
      backend.permission = false;
      await expectLater(
        startMic(),
        throwsA(isA<NativeMicException>().having(
          (e) => e.reason,
          'reason',
          MicFailureReason.permission,
        )),
      );
      expect(mic.state, NativeMicState.idle);
    });

    test('startStream failure is a named recorderStart error', () async {
      backend.startError = StateError('no device');
      await expectLater(
        startMic(),
        throwsA(isA<NativeMicException>().having(
          (e) => e.reason,
          'reason',
          MicFailureReason.recorderStart,
        )),
      );
    });

    test('frames arrive in order with per-start sequences', () async {
      await startMic();
      expect(backend.lastConfig?.sampleRate, 16000);
      backend.emit(_pattern(5000));
      backend.emit(_pattern(3000));
      await pumpEventQueue();
      // 8000 bytes -> two 3200-byte frames; 1600 bytes buffered.
      expect(frames.map((f) => f.$2), [0, 1]);
      expect(frames.map((f) => f.$1.length), [3200, 3200]);
      expect(mic.state, NativeMicState.recording);
    });

    test('stop flushes the tail as a final partial frame', () async {
      await startMic();
      backend.emit(_pattern(100));
      await pumpEventQueue();
      expect(frames, isEmpty);
      await mic.stop();
      expect(frames, hasLength(1));
      expect(frames.first.$1.length, 100);
      expect(frames.first.$2, 0);
      expect(mic.state, NativeMicState.stopped);
      expect(backend.stopCalls, 1);
    });

    test('pause/resume toggle the backpressure state', () async {
      await startMic();
      await mic.pause();
      expect(mic.state, NativeMicState.paused);
      expect(backend.pauseCalls, 1);
      await mic.resume();
      expect(mic.state, NativeMicState.recording);
      expect(backend.resumeCalls, 1);
    });

    test('pause/resume are no-ops in the wrong state', () async {
      await mic.pause();
      await mic.resume();
      expect(backend.pauseCalls, 0);
      expect(backend.resumeCalls, 0);
    });

    test('start twice throws StateError', () async {
      await startMic();
      await expectLater(startMic(), throwsStateError);
    });

    test('stop when idle is a no-op', () async {
      await mic.stop();
      expect(backend.stopCalls, 0);
      expect(mic.state, NativeMicState.idle);
    });

    test('stream error mid-session reports recorderStream', () async {
      await startMic();
      backend.emitError(StateError('audio record died'));
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(
        (errors.first as NativeMicException).reason,
        MicFailureReason.recorderStream,
      );
    });

    test('stream closing on its own mid-session reports recorderStream',
        () async {
      await startMic();
      await backend.closeStream();
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect(
        (errors.first as NativeMicException).reason,
        MicFailureReason.recorderStream,
      );
    });

    test('restart after stop starts a fresh sequence', () async {
      await startMic();
      backend.emit(_pattern(3200));
      await pumpEventQueue();
      await mic.stop();
      expect(frames.map((f) => f.$2), [0]);
      frames.clear();
      await startMic();
      backend.emit(_pattern(3200));
      await pumpEventQueue();
      expect(frames.map((f) => f.$2), [0]);
    });
  });
}
