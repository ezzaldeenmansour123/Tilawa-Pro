// Localhost server that gives the WebView a SECURE CONTEXT.
//
// Why: `tilawa.listen()` needs a secure context (https or localhost).
// Files loaded from Flutter assets (`loadFlutterAsset`) are NOT a secure
// context, so `getUserMedia` would reject with MicrophoneError
// ("insecure-context"). Serving the same files from http://127.0.0.1:<port>/
// IS a secure context (localhost is a potentially trustworthy origin).
//
// The server binds 127.0.0.1 only (never 0.0.0.0), serves only the PoC web
// directory + the downloaded model files, and stops with the engine.
// No audio ever goes through this server — the microphone goes straight
// from the WebView's getUserMedia into the engine.

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

class LocalServer {
  LocalServer._(this._server, this._modelDir);
  final HttpServer _server;
  final Directory _modelDir;

  /// Permanent diagnostics (Phase 2, 2.3): every request is logged as
  /// `METHOD path -> status`. Before this, a 404/500 from the server was
  /// invisible — the WebView just hung and Dart saw a timeout.
  /// Tests may set [onLog] to capture lines; otherwise [debugPrint].
  static void Function(String message)? onLog;

  static void _log(String message) {
    final sink = onLog;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint('[LocalServer] $message');
    }
  }

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port/';

  static Future<LocalServer> start(Directory modelDir) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = LocalServer._(server, modelDir);
    server.listen(s._handle);
    return s;
  }

  Future<void> stop() => _server.close(force: true);

  static const _mime = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.onnx': 'application/octet-stream',
    '.css': 'text/css; charset=utf-8',
  };

  /// Cross-origin isolation headers (COOP + COEP + CORP), applied to
  /// EVERY response the server sends.
  ///
  /// Why this matters — fixed 2026-11-25 after the poc-9 phone test:
  /// onnxruntime-web >= 1.19 ships ONLY multi-threaded WASM builds
  /// (ort-wasm-simd-threaded.wasm); the single-threaded files
  /// (ort-wasm-simd.wasm, ort-wasm.wasm) do NOT exist in the package,
  /// so the loader 404s on them whenever numThreads == 1. And
  /// @tilawa/core/web sets numThreads = 1 whenever the page is NOT
  /// cross-origin isolated. Android WebView DOES support SharedArrayBuffer
  /// — it is gated on cross-origin isolation (Chromium >= 92), exactly
  /// like desktop Chrome — so serving COOP: same-origin + COEP:
  /// require-corp makes `crossOriginIsolated === true`, lets the loader
  /// use the threaded build, and unblocks the engine. The earlier claim
  /// in this file ("isolation is impossible in WebView") was wrong.
  /// CORP: same-origin on every response is what lets COEP require-corp
  /// admit our own same-origin subresources (bundle, model, wasm).
  static void _isolationHeaders(HttpResponse res) {
    res.headers.add('Cross-Origin-Opener-Policy', 'same-origin');
    res.headers.add('Cross-Origin-Embedder-Policy', 'require-corp');
    res.headers.add('Cross-Origin-Resource-Policy', 'same-origin');
  }

  Future<void> _handle(HttpRequest req) async {
    // 2.2 (Phase 2): the /ort/ branch below is VERIFIED fixed — it serves
    // File('${_modelDir.path}$path') where path starts with '/', exactly
    // like the /models/ branch serves '/${path.substring(8)}'. The old
    // code built File('${_modelDir.path}${path.substring(1)}') (missing
    // '/'), so every WASM request 404'd (poc-12). Regression-tested in
    // test/local_server_test.dart ('serves the WASM runtime from /ort/').
    final path = req.uri.path;
    final method = req.method;
    try {
      if (path == '/' || path == '/tilawa.html') {
        await _serveAsset(req, 'assets/web/tilawa.html');
      } else if (path == '/bundle.js') {
        await _serveAsset(req, 'assets/web/bundle.js');
      } else if (path.startsWith('/models/')) {
        await _serveFile(req, File('${_modelDir.path}/${path.substring(8)}'));
      } else if (path.startsWith('/ort/')) {
        // onnxruntime-web WASM files, downloaded by tools/download_assets.py
        // into <modelDir>/ort/<version>/.
        await _serveFile(req, File('${_modelDir.path}$path'));
      } else {
        _isolationHeaders(req.response);
        req.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await req.response.close();
      }
    } catch (e) {
      _isolationHeaders(req.response);
      req.response
        ..statusCode = HttpStatus.internalServerError
        ..write('server error: $e');
      await req.response.close();
    } finally {
      // Log every request with its final status (2.3a) — including the
      // 404/500 paths above, which used to fail silently.
      _log('$method $path -> ${req.response.statusCode}');
    }
  }

  Future<void> _serveAsset(HttpRequest req, String asset) async {
    final data = await rootBundle.load(asset);
    final ext = asset.substring(asset.lastIndexOf('.'));
    req.response.headers.contentType =
        ContentType.parse(_mime[ext] ?? 'application/octet-stream');
    req.response.headers.add('Cache-Control', 'no-store');
    req.response.headers.contentLength = data.lengthInBytes;
    _isolationHeaders(req.response);
    req.response.add(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    await req.response.close();
  }

  Future<void> _serveFile(HttpRequest req, File file) async {
    if (!await file.exists()) {
      // Isolation headers here too: under COEP require-corp a header-less
      // 404 subresource is blocked by the browser instead of arriving as
      // a clean 404, which would mask the real error from the loader.
      _isolationHeaders(req.response);
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('model file not found');
      await req.response.close();
      return;
    }
    final ext = file.path.substring(file.path.lastIndexOf('.'));
    req.response.headers.contentType =
        ContentType.parse(_mime[ext] ?? 'application/octet-stream');
    req.response.headers.add('Cache-Control', 'no-store');
    _isolationHeaders(req.response);
    req.response.headers.contentLength = await file.length();
    await req.response.addStream(file.openRead());
    await req.response.close();
  }
}
