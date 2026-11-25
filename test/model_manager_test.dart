// Tests for ModelManager verification (Phase 2, 2.5) — no device, no
// network. The pinned hashes come from the real files downloaded
// 2026-11-25 from the same URLs the app uses (see model_manager.dart);
// the full «ready» path needs the real 24 MB model file, so it is NOT
// covered here — only the failure branches reachable with local files,
// plus the pinned-constant guards. A device/CI run with a real download
// is still needed for the ready path (see the report).
//
// Covered: verifyFile, pinned-constant shape, ortWasmReady (size),
// ortWasmVerified (size + SHA), referenceOk failure branches,
// status() bundle gate and model failure branches.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/features/recitation/model_manager.dart';
import 'package:tilawa_pro/features/recitation/speech_engine.dart';

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('pro-model-manager-test-');

void main() {
  late Directory dir;
  late ModelManager manager;

  setUp(() async {
    dir = await _tempDir();
    manager = ModelManager.forTest(dir);
    ModelManager.bundleAvailable = null;
  });

  tearDown(() async {
    ModelManager.bundleAvailable = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('pinned constants', () {
    test('reference hash is a 64-hex SHA-256 with the measured size', () {
      expect(kReferenceBytes, 4749281);
      expect(kReferenceSha256.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(kReferenceSha256), isTrue);
    });

    test('WASM assets carry the measured sizes and 64-hex hashes', () {
      // JSEP pair (2026-11-26): the 1.30.0 loader requests ONLY these
      // two files; the old non-JSEP pair is retired (see
      // model_manager.dart). Pins verified against jsDelivr itself.
      expect(kOrtWasmFiles, [
        'ort-wasm-simd-threaded.jsep.mjs',
        'ort-wasm-simd-threaded.jsep.wasm',
      ]);
      expect(kOrtWasmAssets.map((a) => a.name).toList(), kOrtWasmFiles);
      expect(kOrtWasmAssets[0].bytes, 46851);
      expect(kOrtWasmAssets[0].sha256,
          '709853412fd1ffc34247af1e73569227b5b79629c5ca3f59cc39cf7e500e4947');
      expect(kOrtWasmAssets[1].bytes, 28312028);
      expect(kOrtWasmAssets[1].sha256,
          '3ad23231b5bd6d9dda55a7f84606315e0bf35b6750c28ee993c987c54cacab0f');
      expect(kOrtWasmTotalBytes, 28358879);
      for (final a in kOrtWasmAssets) {
        expect(a.sha256.length, 64);
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a.sha256), isTrue);
      }
    });
  });

  group('verifyFile', () {
    test('matches the SHA-256 of the content', () async {
      final f = File('${dir.path}/x.bin');
      await f.writeAsString('hello tilawa');
      final digest = sha256.convert(utf8.encode('hello tilawa')).toString();
      expect(await ModelManager.verifyFile(f, digest), isTrue);
      expect(await ModelManager.verifyFile(f, '0' * 64), isFalse);
    });
  });

  group('ortWasmReady / ortWasmVerified', () {
    Future<void> writeWasm({bool correctSize = true, bool correctHash = false}) async {
      final ort = Directory('${dir.path}/ort/$kOrtWebVersion');
      await ort.create(recursive: true);
      for (final asset in kOrtWasmAssets) {
        final bytes = correctSize
            ? List<int>.filled(asset.bytes, 7)
            : List<int>.filled(asset.bytes + 1, 7);
        await File('${ort.path}/${asset.name}').writeAsBytes(bytes);
      }
      // correctHash cannot be fabricated: the pinned hashes belong to
      // the real jsDelivr files. The mismatch branch is what is tested.
      expect(correctHash, isFalse);
    }

    test('missing files are not ready', () async {
      expect(await manager.ortWasmReady(), isFalse);
      expect(await manager.ortWasmVerified(), isFalse);
    });

    test('wrong size is not ready', () async {
      await writeWasm(correctSize: false);
      expect(await manager.ortWasmReady(), isFalse);
      expect(await manager.ortWasmVerified(), isFalse);
    });

    test('right size is ready but wrong bytes fail SHA verification',
        () async {
      await writeWasm(correctSize: true);
      expect(await manager.ortWasmReady(), isTrue);
      // Same size, wrong content: size passes, SHA must fail.
      expect(await manager.ortWasmVerified(), isFalse);
    });
  });

  group('referenceOk', () {
    test('missing reference is not ok', () async {
      expect(await manager.referenceOk(), isFalse);
    });

    test('wrong size is not ok', () async {
      await manager.referenceFile.writeAsString('{"ayahs":[]}');
      expect(await manager.referenceOk(), isFalse);
    });

    test('right size but wrong SHA is not ok', () async {
      final bytes = List<int>.filled(kReferenceBytes, 32);
      await manager.referenceFile.writeAsBytes(bytes);
      expect(await manager.referenceOk(), isFalse);
    });
  });

  group('status()', () {
    test('no model file -> notInstalled', () async {
      final info = await manager.status('lite');
      expect(info.status, ModelStatus.notInstalled);
    });

    test('model with wrong size -> failed naming the model', () async {
      await manager.modelFile('lite').writeAsString('too small');
      final info = await manager.status('lite');
      expect(info.status, ModelStatus.failed);
      expect(info.error, contains('حجم النموذج'));
    });

    test('model with right size but wrong SHA -> failed', () async {
      final bytes = List<int>.filled(kLiteModel.bytes, 9);
      await manager.modelFile('lite').writeAsBytes(bytes);
      final info = await manager.status('lite');
      expect(info.status, ModelStatus.failed);
      expect(info.error, contains('SHA-256'));
    });

    test('bundleAvailable == false fails before any file check', () async {
      ModelManager.bundleAvailable = false;
      final info = await manager.status('lite');
      expect(info.status, ModelStatus.failed);
      expect(info.error, contains('bundle.js'));
      expect(info.bundleOk, isFalse);
    });

    test('bundleAvailable == null skips the bundle check', () async {
      ModelManager.bundleAvailable = null;
      final info = await manager.status('lite');
      expect(info.status, ModelStatus.notInstalled);
      expect(info.bundleOk, isNull);
    });
  });
}
