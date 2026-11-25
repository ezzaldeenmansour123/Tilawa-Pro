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
    await File('${dir.path}/model-lite.onnx').writeAsString('fake-model');
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
}
