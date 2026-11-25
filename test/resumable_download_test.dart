// Tests for ResumableDownload (Phase 2, 2.5) — no device, no network:
// a local HttpServer stands in for tilawa.dev / jsDelivr, with real
// HTTP Range support, a Range-ignoring mode, and a slow mode for cancel.
//
// Covered: full download + SHA, resume from a .part file, restart when
// the server ignores Range, cancel keeps the .part and the next call
// resumes it, SHA mismatch deletes the part, 404 fails loudly, and an
// already-valid destination is not re-downloaded.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/features/recitation/resumable_download.dart';
import 'package:tilawa_pro/features/recitation/speech_engine.dart';

Uint8List _content(int size) {
  // Deterministic pseudo-random bytes (no all-zero trivial content).
  final out = Uint8List(size);
  var s = 12345;
  for (var i = 0; i < size; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s % 256;
  }
  return out;
}

String _sha(Uint8List bytes) => sha256.convert(bytes).toString();

/// Serves [content] at /file.bin. When [supportRange] is false the
/// server always answers 200 with the whole file (ignores Range).
/// When [chunkDelay] is set, the body is dripped in 8 KiB chunks so a
/// cancel can land mid-download.
Future<HttpServer> _serve(
  Uint8List content, {
  bool supportRange = true,
  Duration? chunkDelay,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (req.uri.path == '/missing.bin') {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('nope');
      await req.response.close();
      return;
    }
    if (req.uri.path != '/file.bin') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final range = req.headers.value('range');
    var start = 0;
    var status = HttpStatus.ok;
    if (supportRange && range != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (start >= content.length) {
          req.response.statusCode =
              HttpStatus.requestedRangeNotSatisfiable;
          await req.response.close();
          return;
        }
        status = HttpStatus.partialContent;
        req.response.headers.set(
            'Content-Range', 'bytes $start-${content.length - 1}/${content.length}');
      }
    }
    final body = content.sublist(start);
    req.response
      ..statusCode = status
      ..headers.contentLength = body.length;
    if (chunkDelay == null) {
      req.response.add(body);
      await req.response.close();
    } else {
      // Drip-feed so cancel() can interrupt the transfer.
      const chunk = 8192;
      for (var i = 0; i < body.length; i += chunk) {
        final end = (i + chunk).clamp(0, body.length);
        req.response.add(body.sublist(i, end));
        await req.response.flush();
        await Future.delayed(chunkDelay);
      }
      await req.response.close();
    }
  });
  return server;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pro-resume-test-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('full download verifies size + SHA and installs atomically',
      () async {
    final bytes = _content(100000);
    final server = await _serve(bytes);
    try {
      final dest = File('${dir.path}/file.bin');
      final dl = ResumableDownload();
      final out = await dl.downloadChecked(
        url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
        dest: dest,
        expectedBytes: bytes.length,
        expectedSha256: _sha(bytes),
      );
      expect(out.path, dest.path);
      expect(await dest.readAsBytes(), bytes);
      expect(await File('${dest.path}.part').exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('resumes from an existing .part file via Range', () async {
    final bytes = _content(100000);
    final server = await _serve(bytes);
    try {
      final dest = File('${dir.path}/file.bin');
      await File('${dest.path}.part')
          .writeAsBytes(bytes.sublist(0, 40000));
      final dl = ResumableDownload();
      await dl.downloadChecked(
        url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
        dest: dest,
        expectedBytes: bytes.length,
        expectedSha256: _sha(bytes),
      );
      expect(await dest.readAsBytes(), bytes);
    } finally {
      await server.close(force: true);
    }
  });

  test('restarts from scratch when the server ignores Range', () async {
    final bytes = _content(60000);
    final server = await _serve(bytes, supportRange: false);
    try {
      final dest = File('${dir.path}/file.bin');
      // A stale .part that must NOT be appended to (server sends 200).
      await File('${dest.path}.part')
          .writeAsBytes(_content(20000));
      final dl = ResumableDownload();
      await dl.downloadChecked(
        url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
        dest: dest,
        expectedBytes: bytes.length,
        expectedSha256: _sha(bytes),
      );
      expect(await dest.readAsBytes(), bytes);
    } finally {
      await server.close(force: true);
    }
  });

  test('cancel keeps the .part and the next call resumes it', () async {
    final bytes = _content(300000);
    final server = await _serve(bytes,
        chunkDelay: const Duration(milliseconds: 20));
    try {
      final dest = File('${dir.path}/file.bin');
      final dl = ResumableDownload();
      var cancelled = false;
      try {
        await dl.downloadChecked(
          url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
          dest: dest,
          expectedBytes: bytes.length,
          expectedSha256: _sha(bytes),
          onProgress: (received, _) {
            if (received > 20000 && !cancelled) {
              cancelled = true;
              dl.cancel();
            }
          },
        );
        fail('download should have been cancelled');
      } on SpeechEngineException catch (e) {
        expect(e.reason, 'cancelled');
      }
      expect(cancelled, isTrue);
      final part = File('${dest.path}.part');
      expect(await part.exists(), isTrue);
      final partLen = await part.length();
      expect(partLen, greaterThan(0));
      expect(partLen, lessThan(bytes.length));
      expect(await dest.exists(), isFalse);

      // Resume with a fast server: must complete from the .part.
      await server.close(force: true);
      final fast = await _serve(bytes);
      try {
        final dl2 = ResumableDownload();
        await dl2.downloadChecked(
          url: Uri.parse('http://127.0.0.1:${fast.port}/file.bin'),
          dest: dest,
          expectedBytes: bytes.length,
          expectedSha256: _sha(bytes),
        );
        expect(await dest.readAsBytes(), bytes);
      } finally {
        await fast.close(force: true);
      }
    } finally {
      await server.close(force: true).catchError((_) {});
    }
  });

  test('SHA mismatch deletes the part and throws', () async {
    final bytes = _content(50000);
    final server = await _serve(bytes);
    try {
      final dest = File('${dir.path}/file.bin');
      final dl = ResumableDownload();
      await expectLater(
        dl.downloadChecked(
          url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
          dest: dest,
          expectedBytes: bytes.length,
          expectedSha256: '0' * 64,
        ),
        throwsA(isA<SpeechEngineException>()),
      );
      expect(await dest.exists(), isFalse);
      expect(await File('${dest.path}.part').exists(), isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('HTTP 404 throws a SpeechEngineException', () async {
    final server = await _serve(_content(1000));
    try {
      final dl = ResumableDownload();
      await expectLater(
        dl.downloadChecked(
          url: Uri.parse('http://127.0.0.1:${server.port}/missing.bin'),
          dest: File('${dir.path}/file.bin'),
        ),
        throwsA(isA<SpeechEngineException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('already-valid destination is not re-downloaded', () async {
    final bytes = _content(40000);
    final server = await _serve(bytes);
    try {
      final dest = File('${dir.path}/file.bin');
      await dest.writeAsBytes(bytes);
      final before = await dest.stat();
      final dl = ResumableDownload();
      final out = await dl.downloadChecked(
        url: Uri.parse('http://127.0.0.1:${server.port}/file.bin'),
        dest: dest,
        expectedBytes: bytes.length,
        expectedSha256: _sha(bytes),
      );
      expect(out.path, dest.path);
      expect((await dest.stat()).modified, before.modified);
    } finally {
      await server.close(force: true);
    }
  });
}
