// WebView adapter: hosts @tilawa/core/web and translates its events.
//
// Flow:
//   1. ModelManager has downloaded + SHA-verified the model + ref-v2.json.
//   2. LocalServer serves assets/web/* + the model files on 127.0.0.1.
//   3. WebView loads the page; the JS bridge (web/src/bridge.js) calls
//      createTilawa with self-hosted assetBase + wasmPaths, then reports
//      every engine event back through the `TilawaBridge` JavaScriptChannel.
//   4. This class parses those events into SpeechEngine types and appends
//      them to the session EventLog.
//
// Known unknowns (to be measured on the S22 Ultra, NOT assumed):
//   - Whether the WebView grants microphone access after the app-level
//     RECORD_AUDIO permission (webview_flutter has no onPermissionRequest
//     API; if the WebView denies the mic, this adapter fails loudly with
//     reason "unavailable" and the PoC records NO-GO for the WebView path).
//   - Whether WebGPU is available inside the WebView (the `backend` field
//     of the capabilities event tells us: "webgpu" | "wasm" | "cpu").
//   - WASM is multi-threaded in Android WebView now that LocalServer
//     sends COOP + COEP (cross-origin isolation enables SharedArrayBuffer;
//     fixed 2026-11-25 after the poc-9 phone test showed the 1.30.0
//     loader 404ing on the single-threaded files that no longer exist).
//     Whether this S22 Ultra's WebView actually reports
//     crossOriginIsolated == true is still to be measured on-device.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webview_flutter/webview_flutter.dart';

import 'event_log.dart';
import 'local_server.dart';
import 'model_manager.dart';
import 'models.dart';
import 'speech_engine.dart';

class WebViewEngine implements SpeechEngine {
  WebViewEngine({required this.modelManager});

  final ModelManager modelManager;

  WebViewController? _controller;
  LocalServer? _server;
  final _events = StreamController<Object>.broadcast();
  EngineCapabilities? _capabilities;
  EventLog? _log;
  String? _tier;
  // "surah:ayah" -> display words, from the engine's own ref-v2.json.
  Map<String, List<String>>? _referenceWords;
  bool _listening = false;

  @override
  EngineCapabilities? get capabilities => _capabilities;

  /// True once a model has loaded successfully in this engine instance.
  bool get isLoaded => _capabilities != null && _controller != null;

  /// The tier of the currently loaded model, or null before load().
  String? get loadedTier => _tier;

  /// Number of ayahs in [surah] (Hafs), derived from the loaded reference
  /// itself (ref-v2.json), or null before load(). The setup screen uses
  /// surah_names.dart for picking a passage *before* load; this is the
  /// cross-check from the engine's own reference afterwards.
  int? ayahCount(int surah) => _ayahCounts?[surah];

  Map<int, int>? _ayahCounts;

  /// Model-load timeout. 60 s, not the PoC's 120 s: the model + WASM come
  /// from the localhost server, so a healthy load takes seconds; waiting
  /// 120 s in silence was the poc-12 phone experience. The timeout error
  /// names the last completed stage, so a repeat failure is diagnosable.
  static const kModelLoadTimeout = Duration(seconds: 60);

  @override
  Future<EngineCapabilities> load({
    required String tier,
    void Function(double fraction)? onProgress,
    void Function(String stageLabel)? onStage,
  }) async {
    _tier = tier;
    // Last completed stage (Arabic label), shown in the timeout error so
    // a hang is never silent again: the UI mirrors it live via onStage.
    var stage = 'جارٍ فحص النموذج…';
    void setStage(String label) {
      stage = label;
      onStage?.call(label);
    }

    setStage('جارٍ فحص النموذج…');
    final info = await modelManager.status(tier);
    if (info.status != ModelStatus.ready) {
      throw SpeechEngineException(
          'النموذج غير جاهز: ${info.error ?? 'غير مثبَّت'}');
    }
    // The WASM runtime must be present too (downloaded with the model —
    // see ModelManager.download). Without it loadWebModel fails with a
    // cryptic bridge error; fail here instead, with an actionable message.
    if (!await modelManager.ortWasmReady()) {
      throw SpeechEngineException(
          'ملفات تشغيل المحرك (WASM) غير موجودة — نزّلها من صفحة «النموذج» '
          '(زر التنزيل ينزّل النموذج والمرجع وملفات WASM معاً).');
    }
    // Load the reference words for the passage display (from the engine's
    // own ref-v2.json — never invented text).
    setStage('جارٍ قراءة المرجع…');
    final refText = await modelManager.referenceFile.readAsString();
    final ref = jsonDecode(refText) as Map<String, dynamic>;
    final ayahs = ref['ayahs'] as List;
    if (ayahs.length != 6236) {
      throw SpeechEngineException(
          'المرجع لا يحتوي 6236 آية (وجد ${ayahs.length})');
    }
    _referenceWords = {
      for (final a in ayahs)
        '${(a as Map)['s']}:${a['a']}':
            ((a['w'] as List).cast<String>()),
    };
    // Ayah counts per surah, derived from the same reference.
    final counts = <int, int>{};
    for (final key in _referenceWords!.keys) {
      final surah = int.parse(key.split(':').first);
      counts[surah] = (counts[surah] ?? 0) + 1;
    }
    _ayahCounts = counts;

    _server ??= await LocalServer.start(
      Directory(modelManager.referenceFile.parent.path),
    );
    setStage('جارٍ تحميل صفحة المحرك…');
    _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // The page re-fires this on every load; complete only the
            // completer of the current load() call.
            if (_pageLoaded != null && !_pageLoaded!.isCompleted) {
              _pageLoaded!.complete();
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        'TilawaBridge',
        onMessageReceived: _onBridgeMessage,
      );
    // NOTE: microphone permission is requested by the UI (permission_handler)
    // BEFORE load() is called. If the WebView still refuses getUserMedia,
    // the bridge reports {type:"error", reason:"denied"|"unavailable"|
    // "insecure-context"} and load() throws — recorded as a NO-GO data point.
    _pageLoaded = Completer<void>();
    await _controller!.loadRequest(Uri.parse('${_server!.baseUrl}tilawa.html'));
    await _pageLoaded!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () =>
          throw SpeechEngineException('انتهت مهلة تحميل صفحة المحرك'),
    );
    // PRE-FLIGHT (added 2026-11-25 after the poc-12 phone failure).
    // The 30 s page timeout above proves tilawa.html arrived, but it says
    // NOTHING about the subresources init() needs: onPageFinished fires
    // even when bundle.js or the WASM files 404, and the disk-side checks
    // (status/ortWasmReady) cannot see a broken server mapping — the
    // /ort/ path bug (LocalServer served "<dir>ort/..." instead of
    // "<dir>/ort/...") passed every gate and then hung init silently.
    // So, before calling init, fetch each served file over HTTP and
    // demand 200 + non-empty, and verify the bridge object exists.
    setStage('جارٍ التحقق من حزمة المحرك (bundle.js)…');
    await _checkServed(
      '${_server!.baseUrl}bundle.js',
      'حزمة المحرك (bundle.js)',
    );
    setStage('جارٍ التحقق من ملفات التشغيل عبر الخادم المحلي…');
    for (final name in kOrtWasmFiles) {
      await _checkServed(
        '${_server!.baseUrl}ort/$kOrtWebVersion/$name',
        'ملف التشغيل $name',
      );
    }
    setStage('جارٍ التحقق من جسر المحرك…');
    final bridge = await _controller!.runJavaScriptReturningResult(
      "window.TilawaPro ? 'yes' : 'no'",
    );
    if (!bridge.toString().contains('yes')) {
      throw SpeechEngineException(
          'جسر المحرك غير موجود في الصفحة — حزمة المحرك (bundle.js) لم '
          'تُحمَّل. أعد بناء الحزمة أو أعد تشغيل التطبيق.');
    }
    setStage('جارٍ تحميل النموذج داخل المحرك…');
    final completer = Completer<EngineCapabilities>();
    _loadCompleter = completer;
    await _controller!.runJavaScript(
      'window.TilawaPro.init(${jsonEncode({
        'assetBase': _server!.baseUrl,
        'tier': tier,
        'modelUrl': '${_server!.baseUrl}models/model-$tier.onnx',
        'referenceUrl': '${_server!.baseUrl}models/ref-v2.json',
        'wasmPaths': '${_server!.baseUrl}ort/$kOrtWebVersion/',
      })});',
    );
    return completer.future.timeout(
      kModelLoadTimeout,
      onTimeout: () => throw SpeechEngineException(
          'انتهت مهلة تحميل النموذج (${kModelLoadTimeout.inSeconds} ثانية) — '
          'توقف عند مرحلة: $stage. إن تكرر ذلك، تحقق من صفحة «النموذج» '
          '(النموذج مثبَّت + ملفات التشغيل موجودة)، ثم أعد المحاولة.'),
    );
  }

  /// Fetches one file the engine needs from the localhost server and
  /// demands HTTP 200 + a non-empty body. The disk-side checks cannot do
  /// this: a file can exist on disk yet be unservable (wrong server path),
  /// which is exactly what hung poc-12. Throws [SpeechEngineException]
  /// with an actionable message instead of letting init hang.
  Future<void> _checkServed(String url, String label) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw SpeechEngineException(
            '$label غير متاح من الخادم المحلي (HTTP ${res.statusCode}) — '
            'أعد تشغيل التطبيق، وإن تكرر أعد تنزيل النموذج.');
      }
      var bytes = 0;
      await for (final chunk in res) {
        bytes += chunk.length;
      }
      if (bytes == 0) {
        throw SpeechEngineException(
            '$label وصل فارغاً من الخادم المحلي — أعد المحاولة.');
      }
    } on SpeechEngineException {
      rethrow;
    } on TimeoutException {
      throw SpeechEngineException(
          'انتهت مهلة الوصول إلى $label من الخادم المحلي — الخادم لا يرد.');
    } finally {
      client.close();
    }
  }

  Completer<EngineCapabilities>? _loadCompleter;
  Completer<void>? _pageLoaded;

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final data = jsonDecode(message.message) as Map<String, dynamic>;
    final type = data['type'] as String?;
    switch (type) {
      case 'ready':
        final caps = EngineCapabilities.fromJson(
          (data['capabilities'] as Map).cast<String, dynamic>(),
        );
        _capabilities = caps;
        _loadCompleter?.complete(caps);
        _loadCompleter = null;
        await _log?.append('capabilities',
            data['capabilities'] as Map<String, dynamic>,
            audioMs: null);
      case 'error':
        final err = SpeechEngineException(
          (data['message'] ?? 'خطأ من المحرك') as String,
          reason: data['reason'] as String?,
        );
        if (_loadCompleter != null) {
          _loadCompleter!.completeError(err);
          _loadCompleter = null;
        } else {
          _events.addError(err);
        }
      case 'position':
        final payload = (data['event'] as Map).cast<String, dynamic>();
        final ev = _parsePosition(payload);
        await _log?.append('position', payload, audioMs: ev.timeMs);
        _events.add(ev);
      case 'checker':
        final payload = (data['event'] as Map).cast<String, dynamic>();
        final ev = _parseChecker(payload);
        await _log?.append('checker', payload, audioMs: ev.timeMs);
        _events.add(ev);
      case 'modelLoadMs':
        await _log?.append('meta', {
          'modelLoadMs': data['ms'],
          'backend': data['backend'],
          // poc-10 diagnostics: proves on the phone whether the page was
          // really cross-origin isolated and how many WASM threads ran.
          'crossOriginIsolated': data['crossOriginIsolated'],
          'threads': data['threads'],
        }, audioMs: null);
    }
  }

  PositionEvent _parsePosition(Map<String, dynamic> p) {
    final observed = ((p['observed'] as List?) ?? const [])
        .map((o) => RefWord.fromJson((o['word'] as Map).cast<String, dynamic>()))
        .toList();
    final expected = p['expected'] == null
        ? null
        : RefWord.fromJson((p['expected'] as Map).cast<String, dynamic>());
    return PositionEvent(
      timeMs: (p['timeMs'] as num).toInt(),
      observed: observed,
      confidence: ((observed.isNotEmpty
                  ? (p['observed'][0]['confidence'] as num?)?.toDouble()
                  : null) ??
              0.0),
      state: trackStateFromString((p['state'] ?? 'acquiring') as String),
      expected: expected,
    );
  }

  CheckerEvent _parseChecker(Map<String, dynamic> c) {
    final loc = (c['location'] as Map).cast<String, dynamic>();
    return CheckerEvent(
      id: (c['id'] ?? '') as String,
      timeMs: (c['timeMs'] as num).toInt(),
      state: checkerStateFromString((c['state'] ?? 'suspected') as String),
      errorClass: errorClassFromString((c['errorClass'] ?? '') as String) ??
          ErrorClass.wrongWord,
      location: RefWord.fromJson(loc),
      expectedPhonemes: c['expected'] as String?,
      observedPhonemes: c['observed'] as String?,
    );
  }

  @override
  Stream<Object> startSession({
    required SessionMode mode,
    Passage? passage,
  }) {
    if (_controller == null || _capabilities == null) {
      throw SpeechEngineException('حمّل النموذج أولاً (load قبل startSession)');
    }
    // Never run two recording sessions at once: the bridge holds a single
    // `session`/`mic`, so a second start would silently hijack the first.
    if (_listening) {
      throw SpeechEngineException(
          'جلسة تسجيل أخرى تعمل بالفعل — أنهِها أو أوقفها أولاً');
    }
    if (mode == SessionMode.memorization && passage == null) {
      throw ArgumentError('memorization requires a passage');
    }
    _listening = true;
    _controller!.runJavaScript(
      'window.TilawaPro.startSession(${jsonEncode({
        'mode': mode.name,
        'surah': passage?.surah,
        'fromAyah': passage?.fromAyah,
        'toAyah': passage?.toAyah,
      })});',
    );
    return _events.stream;
  }

  /// Called by the UI when a session starts, so the log carries the
  /// wall-clock anchor needed for latency math (see LogMetrics).
  Future<void> beginLog({
    required String sessionId,
    required Map<String, dynamic> meta,
  }) async {
    _log = await EventLog.create(sessionId: sessionId, sessionMeta: {
      ...meta,
      'sessionStartedWallMs': DateTime.now().millisecondsSinceEpoch,
      'tier': _tier,
      'backend': _capabilities?.backend,
      'modelVersion': _capabilities?.modelVersion,
      'modelSha256': _capabilities?.modelSha256,
    });
  }

  @override
  Future<void> endSession() async {
    if (_listening) {
      _listening = false;
      await _controller?.runJavaScript('window.TilawaPro.stopSession();');
    }
    // Always close the log, even when called after a pause (where
    // endSegment already stopped the mic but deliberately kept the log
    // open). Otherwise a paused-then-abandoned session would leave its
    // log file without a 'session-ended' line.
    await _log?.append('meta', {'event': 'session-ended'}, audioMs: null);
    _log = null;
  }

  /// Ends ONE recording segment (pause) WITHOUT closing the session log.
  ///
  /// Pause/resume truthfulness: the engine has no "pause" — a session is
  /// a take. Pausing therefore stops the mic and ends the engine session
  /// (bridge stopSession), and resuming starts a NEW engine session on
  /// the same passage (startSession). The log stays open across segments,
  /// each segment boundary is recorded as a meta line, and the UI's
  /// WordTracker de-duplicates matched words across segments, so a word
  /// re-observed after resume is never counted twice. What the engine
  /// cannot do — and this code never pretends otherwise — is resume
  /// mid-ayah tracking: a resumed segment re-tracks from the passage
  /// start and re-locks when the user recites.
  Future<void> endSegment({required int segment}) async {
    if (!_listening) return;
    _listening = false;
    await _controller?.runJavaScript('window.TilawaPro.stopSession();');
    await _log?.append(
      'meta',
      {'event': 'segment-ended', 'segment': segment},
      audioMs: null,
    );
  }

  /// Appends a `meta` line to the open session log, if any. Used by the
  /// session screen for segment boundaries and pause/resume markers.
  Future<void> appendLogMeta(Map<String, dynamic> meta) async {
    await _log?.append('meta', meta, audioMs: null);
  }

  @override
  List<List<String>>? passageWords(Passage passage) {
    final ref = _referenceWords;
    if (ref == null) return null;
    // _referenceWords maps "surah:ayah" -> display words; look the passage
    // up directly by (surah, ayah).
    final out = <List<String>>[];
    for (var a = passage.fromAyah; a <= passage.toAyah; a++) {
      final words = ref['${passage.surah}:$a'];
      if (words == null) return null;
      out.add(words);
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    await endSession();
    await _controller?.runJavaScript(
        'window.TilawaPro && window.TilawaPro.dispose();');
    await _server?.stop();
    await _events.close();
  }
}
