// Regression tests for LocalServer's URL -> file mapping.
//
// Written 2026-11-25 after the poc-12 phone failure: the engine never
// became ready (120 s timeout, no error) because the /ort/ branch built
// File('<dir>ort/...') — the '/' missing — so every WASM request 404'd
// while the disk-side check (ModelManager.ortWasmReady) passed. These
// tests fetch the files over HTTP exactly as the WebView does, so a
// broken mapping fails here instead of hanging a phone.
//
// NOTE: the asset routes (/ and /bundle.js) are NOT tested here — they go
// through rootBundle, and assets/web/* is not declared in pubspec.yaml
// yet (the coordinator adds it at wiring time). The file routes below
// cover the bug.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/features/recitation/local_server.dart';

Future<(int, String, HttpHeaders)> _get(LocalServer s, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('${s.baseUrl}${path.startsWith('/') ? path.substring(1) : path}'),
    );
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body, res.headers);
  } finally {
    client.close();
  }
}

/// Test-only mirror of the pre-flight check in
/// `WebViewEngine._checkServed`
/// (lib/features/recitation/webview_engine.dart): fetch [url] over HTTP
/// and demand 200 + a non-empty body — or, when [expectedBytes] is given,
/// 200 + exactly that many bytes. A failure names the URL, the expected
/// size and the actual status/size, exactly like the production check.
/// Kept in the test because _checkServed is private to an engine that
/// needs a live WebViewController and cannot be called from a unit test;
/// the contract is what matters, and it is exercised here against the
/// real LocalServer, so a broken mapping fails here exactly as it would
/// fail the pre-flight on a phone.
class CheckFailed implements Exception {
  CheckFailed(this.message);
  final String message;
  @override
  String toString() => 'CheckFailed: $message';
}

Future<void> checkServed(String url, String label,
    {int? expectedBytes}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw CheckFailed(
          '$label غير متاح من الخادم المحلي — الرابط: $url — '
          'الحالة الفعلية: HTTP ${res.statusCode}'
          '${expectedBytes == null ? '' : ' (المتوقع: 200 وحجم $expectedBytes بايت)'}');
    }
    var bytes = 0;
    await for (final chunk in res) {
      bytes += chunk.length;
    }
    if (expectedBytes != null && bytes != expectedBytes) {
      throw CheckFailed(
          '$label وصل بحجم خاطئ من الخادم المحلي — الرابط: $url — '
          'المتوقع: $expectedBytes بايت، الفعلي: $bytes بايت');
    }
    if (bytes == 0) {
      throw CheckFailed('$label وصل فارغاً من الخادم المحلي — الرابط: $url');
    }
  } finally {
    client.close();
  }
}

void main() {
  late Directory dir;
  late LocalServer server;
  final logs = <String>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pro-local-server-test-');
    await Directory('${dir.path}/ort/1.30.0').create(recursive: true);
    await File('${dir.path}/ort/1.30.0/ort-wasm-simd-threaded.wasm')
        .writeAsString('fake-wasm-bytes');
    await File('${dir.path}/ort/1.30.0/ort-wasm-simd-threaded.mjs')
        .writeAsString('fake-mjs-glue');
    // JSEP pair (2026-11-26): the files the 1.30.0 loader actually
    // requests. The non-JSEP files above stay as generic /ort/ fixtures;
    // the JSEP files below are what the pre-flight contract gates on.
    await File('${dir.path}/ort/1.30.0/ort-wasm-simd-threaded.jsep.mjs')
        .writeAsString('fake-jsep-mjs-glue');
    await File('${dir.path}/ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm')
        .writeAsString('fake-jsep-wasm-bytes');
    await File('${dir.path}/model-lite.onnx').writeAsString('fake-model');
    await File('${dir.path}/model-full.onnx').writeAsString('fake-model-full');
    await File('${dir.path}/ref-v2.json').writeAsString('{"ayahs":[]}');
    server = await LocalServer.start(dir);
    logs.clear();
    LocalServer.onLog = logs.add;
  });

  tearDown(() async {
    LocalServer.onLog = null;
    await server.stop();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('serves the WASM runtime from /ort/<version>/ (the poc-12 bug)', () async {
    final (status, body, headers) = await _get(
      server,
      '/ort/1.30.0/ort-wasm-simd-threaded.wasm',
    );
    expect(status, 200);
    expect(body, 'fake-wasm-bytes');
    expect(headers.value('cross-origin-opener-policy'), 'same-origin');
    final (mjsStatus, mjsBody, _) = await _get(
      server,
      '/ort/1.30.0/ort-wasm-simd-threaded.mjs',
    );
    expect(mjsStatus, 200);
    expect(mjsBody, 'fake-mjs-glue');
  });

  test('serves model + reference from /models/', () async {
    final (modelStatus, modelBody, _) =
        await _get(server, '/models/model-lite.onnx');
    expect(modelStatus, 200);
    expect(modelBody, 'fake-model');
    final (refStatus, refBody, _) = await _get(server, '/models/ref-v2.json');
    expect(refStatus, 200);
    expect(refBody, '{"ayahs":[]}');
  });

  // --- 2026-11-26 JSEP fix: the loader requests ONLY the JSEP pair ---
  // (pro-build-28 404'd on ort-wasm-simd-threaded.jsep.mjs while the
  // non-JSEP pair was served and verified). The /ort/ branch is generic,
  // so no server change was needed — these tests pin the serving
  // behaviour the fix depends on: both JSEP files 200 with the right
  // bytes and MIME types, and a missing JSEP file a clean 404.

  test('serves the JSEP pair from /ort/<version>/ (the pro-build-28 404)',
      () async {
    final (mjsStatus, mjsBody, mjsHeaders) = await _get(
      server,
      '/ort/1.30.0/ort-wasm-simd-threaded.jsep.mjs',
    );
    expect(mjsStatus, 200);
    expect(mjsBody, 'fake-jsep-mjs-glue');
    expect(mjsHeaders.value('content-type'), contains('text/javascript'));
    expect(mjsHeaders.value('cross-origin-opener-policy'), 'same-origin');
    final (wasmStatus, wasmBody, wasmHeaders) = await _get(
      server,
      '/ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm',
    );
    expect(wasmStatus, 200);
    expect(wasmBody, 'fake-jsep-wasm-bytes');
    expect(wasmHeaders.value('content-type'), contains('application/wasm'));
  });

  test('missing JSEP file is a clean 404 naming the path', () async {
    await File('${dir.path}/ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm')
        .delete();
    final (status, body, _) = await _get(
      server,
      '/ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm',
    );
    expect(status, 404);
    expect(body, contains('ort-wasm-simd-threaded.jsep.wasm'));
  });

  test('unknown paths 404 (missing WASM file is a clean 404)', () async {
    final (status, _, _) =
        await _get(server, '/ort/1.30.0/does-not-exist.wasm');
    expect(status, 404);
    final (otherStatus, _, _) = await _get(server, '/no-such-route');
    expect(otherStatus, 404);
  });

  test('logs every request with its final status (Phase 2, 2.3a)', () async {
    await _get(server, '/ort/1.30.0/ort-wasm-simd-threaded.wasm');
    await _get(server, '/ort/1.30.0/does-not-exist.wasm');
    await _get(server, '/no-such-route');
    expect(
      logs,
      contains('GET /ort/1.30.0/ort-wasm-simd-threaded.wasm -> 200'),
    );
    expect(
      logs,
      contains('GET /ort/1.30.0/does-not-exist.wasm -> 404'),
    );
    expect(logs, contains('GET /no-such-route -> 404'));
  });

  // --- 2026-11-26 404 fix: registry-path mapping + pre-flight contract ---

  test('registry path serves the flat full model (the 2026-11-26 404)',
      () async {
    final (status, body, _) = await _get(
      server,
      '/models/spliced-clean/1-int8/model.onnx',
    );
    expect(status, 200);
    expect(body, 'fake-model-full');
  });

  test('registry path serves the flat lite model', () async {
    final (status, body, _) = await _get(
      server,
      '/models/spliced-clean-lite/1-int8/model.onnx',
    );
    expect(status, 200);
    expect(body, 'fake-model');
  });

  test('flat model URLs serve the right tier file', () async {
    final (fullStatus, fullBody, _) =
        await _get(server, '/models/model-full.onnx');
    expect(fullStatus, 200);
    expect(fullBody, 'fake-model-full');
    final (liteStatus, liteBody, _) =
        await _get(server, '/models/model-lite.onnx');
    expect(liteStatus, 200);
    expect(liteBody, 'fake-model');
    // The two tiers must never be confused: the registry full path and
    // the flat full path serve the same bytes, distinct from lite.
    expect(fullBody, isNot(liteBody));
  });

  test('unknown /models/ paths 404 (never serve a wrong file)', () async {
    final (unknownRegistry, _, _) = await _get(
      server,
      '/models/some-other-model/1-int8/model.onnx',
    );
    expect(unknownRegistry, 404);
    final (unknownFlat, _, _) =
        await _get(server, '/models/model-unknown.onnx');
    expect(unknownFlat, 404);
    final (unknownVersion, _, _) = await _get(
      server,
      '/models/spliced-clean/2-int8/model.onnx',
    );
    expect(unknownVersion, 404);
  });

  group('pre-flight contract (mirrors WebViewEngine._checkServed)', () {
    test('passes on a correct server with the exact expected size',
        () async {
      await checkServed(
        '${server.baseUrl}models/spliced-clean/1-int8/model.onnx',
        'full model (registry path)',
        expectedBytes: 'fake-model-full'.length,
      );
      await checkServed(
        '${server.baseUrl}models/model-lite.onnx',
        'lite model (flat path)',
        expectedBytes: 'fake-model'.length,
      );
      await checkServed(
        '${server.baseUrl}models/ref-v2.json',
        'reference',
        expectedBytes: '{"ayahs":[]}'.length,
      );
    });

    test('JSEP pre-flight contract: 200 + exact pinned size per file',
        () async {
      // Mirrors WebViewEngine's pre-flight loop over kOrtWasmAssets
      // (2026-11-26): each JSEP file must arrive with HTTP 200 AND its
      // exact pinned byte count — 200 + non-empty used to pass a
      // truncated .wasm while the load 404'd on the phone.
      await checkServed(
        '${server.baseUrl}ort/1.30.0/ort-wasm-simd-threaded.jsep.mjs',
        'JSEP loader glue',
        expectedBytes: 'fake-jsep-mjs-glue'.length,
      );
      await checkServed(
        '${server.baseUrl}ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm',
        'JSEP runtime',
        expectedBytes: 'fake-jsep-wasm-bytes'.length,
      );
    });

    test('JSEP pre-flight fails naming URL + expected/actual on wrong size',
        () async {
      const url = 'ort/1.30.0/ort-wasm-simd-threaded.jsep.wasm';
      try {
        await checkServed(
          '${server.baseUrl}$url',
          'JSEP runtime',
          expectedBytes: 999,
        );
        fail('expected checkServed to throw on a JSEP size mismatch');
      } on CheckFailed catch (e) {
        expect(e.message, contains(url));
        expect(e.message, contains('999'));
        expect(e.message, contains('${'fake-jsep-wasm-bytes'.length}'));
      }
    });

    test('JSEP pre-flight fails naming URL + HTTP status on a 404',
        () async {
      const url = 'ort/1.30.0/ort-wasm-simd-threaded.jsep.mjs';
      await File('${dir.path}/$url').delete();
      try {
        await checkServed(
          '${server.baseUrl}$url',
          'JSEP loader glue',
          expectedBytes: 10,
        );
        fail('expected checkServed to throw on a missing JSEP file');
      } on CheckFailed catch (e) {
        expect(e.message, contains(url));
        expect(e.message, contains('404'));
      }
    });

    test('fails naming URL + expected/actual on a wrong size', () async {
      const url = 'models/spliced-clean/1-int8/model.onnx';
      try {
        await checkServed(
          '${server.baseUrl}$url',
          'full model (registry path)',
          expectedBytes: 999,
        );
        fail('expected checkServed to throw on a size mismatch');
      } on CheckFailed catch (e) {
        expect(e.message, contains(url));
        expect(e.message, contains('999'));
        expect(e.message, contains('${'fake-model-full'.length}'));
      }
    });

    test('fails naming URL + HTTP status on a 404', () async {
      const url = 'models/does-not-exist.onnx';
      try {
        await checkServed(
          '${server.baseUrl}$url',
          'missing model',
          expectedBytes: 10,
        );
        fail('expected checkServed to throw on a 404');
      } on CheckFailed catch (e) {
        expect(e.message, contains(url));
        expect(e.message, contains('404'));
      }
    });

    test('fails on an empty body even without an expected size', () async {
      await File('${dir.path}/empty.onnx').writeAsString('');
      try {
        await checkServed('${server.baseUrl}models/empty.onnx', 'empty file');
        fail('expected checkServed to throw on an empty body');
      } on CheckFailed catch (e) {
        expect(e.message, contains('models/empty.onnx'));
      }
    });
  });
}
