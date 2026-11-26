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
//   - (RESOLVED 2026-11-26, pro-build-34 phone test) The WebView does NOT
//     grant microphone access from the app-level RECORD_AUDIO permission
//     alone: the page's getUserMedia triggers a WebChromeClient
//     PermissionRequest that is denied with no handler, so the bridge
//     reported "Permission denied" while setup showed the mic as allowed.
//     The fix registers AndroidWebViewController
//     .setOnPlatformPermissionRequest (webview_flutter_android 4.14.1),
//     granting ONLY the microphone. The old note claiming "webview_flutter
//     has no onPermissionRequest API" was wrong.
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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'event_log.dart';
import 'local_server.dart';
import 'model_manager.dart';
import 'models.dart';
import 'speech_engine.dart';

/// App version + build, mirrored from pubspec.yaml (`version: 1.1.0+1`).
/// There is no package_info_plus dependency (deliberately: no new
/// dependency for this fix-up), so this literal must be kept in sync
/// with pubspec.yaml and the '1.1.0+1' literals in main.dart by hand.
/// A runtime-read version would need package_info_plus.
const kAppVersion = '1.1.0+1';

/// Whether a WebView permission request may be granted: exactly the
/// microphone and nothing else. The page only ever asks for audio
/// capture (getUserMedia audio-only); granting anything else (camera
/// etc.) would be wrong. Pure function, unit-tested in
/// test/webview_mic_permission_test.dart.
bool shouldGrantMicPermission(Set<WebViewPermissionResourceType> types) =>
    types.length == 1 &&
    types.contains(WebViewPermissionResourceType.microphone);

class WebViewEngine implements SpeechEngine {
  WebViewEngine({required this.modelManager});

  final ModelManager modelManager;

  WebViewController? _controller;
  LocalServer? _server;
  final _events = StreamController<Object>.broadcast();
  EngineCapabilities? _capabilities;
  EventLog? _log;
  String? _tier;
  // Last load stage (Arabic label) — promoted to a field (not a load()
  // local) so the bridge's 'stage' messages during init() can advance
  // it too; otherwise a hang inside the JS load would only ever name
  // the last Dart stage in the timeout error. [_loadStages] keeps the
  // full trail for the session event log (beginLog records it).
  String _stage = '';
  final _loadStages = <String>[];
  void Function(String stageLabel)? _onStage;

  /// True once the bridge reported the loader's warmup probe passed for
  /// the current load (explicit 'probe' message — never inferred from
  /// 'ready'). Reset at the start of every load(); a stale bundle that
  /// never posts 'probe' leaves this false, and beginLog records that
  /// absence instead of assuming a probe ran.
  bool _probePassed = false;

  /// The last 'modelLoadMs' payload from the bridge (load time, backend,
  /// crossOriginIsolated, threads) — the proof the ONNX Inference
  /// Session was created. Kept in a field because the event log is not
  /// open yet during load(), so appending it there directly would drop
  /// it; beginLog carries it into the session log instead.
  Map<String, dynamic>? _lastModelLoad;

  /// The last 'env-probe' payload from the bridge (2026-11-26): the
  /// environment measured in the page BEFORE loadWebModel —
  /// crossOriginIsolated, SharedArrayBuffer live check, navigator.gpu +
  /// requestAdapter result, provider list, threads applied, HTTP status
  /// of both JSEP files. Posted before the load, so it is available even
  /// when the load FAILS (unlike modelLoadMs, which is success-only):
  /// the 'error' handler below appends a one-line summary of it to the
  /// failure, and beginLog carries the full probe into the session log.
  /// Null when the bridge never posted a probe (e.g. a stale bundle).
  Map<String, dynamic>? _lastEnvProbe;

  /// One-line summary of [_lastEnvProbe] for failure messages, or null
  /// when no probe was received. Lets a failed load name its cause
  /// (e.g. JSEP 404, no GPU adapter) instead of showing only the
  /// engine's error string.
  String? get _envProbeSummary {
    final p = _lastEnvProbe;
    if (p == null) return null;
    final jsep = p['jsep'];
    final jsepSummary = jsep is Map
        ? jsep.entries.map((e) => '${e.key}=${e.value}').join(', ')
        : '?';
    return 'بيئة المحرك: crossOriginIsolated=${p['crossOriginIsolated']}, '
        'SharedArrayBuffer=${p['sharedArrayBuffer']}, '
        'GPU=${p['gpuInNavigator']} (adapter=${p['gpuAdapter']}), '
        'providers=${(p['providers'] as List?)?.join('+')}, '
        'threads=${p['threadsApplied']}, JSEP: $jsepSummary';
  }

  /// True once any session log has been written in this process.
  /// Static on purpose: engine instances are re-created per screen
  /// (main.dart holds one, packages_page.dart builds another), so only
  /// a static survives them — and it resets when the OS kills/restarts
  /// the process, which is exactly what makes the first beginLog of a
  /// process the "first session since this app launch" (cold start).
  static bool _sessionLoggedThisProcess = false;

  /// Advances [_stage], records it in [_loadStages] (no consecutive
  /// duplicates) and mirrors it to the UI via [_onStage].
  void setStage(String label) {
    _stage = label;
    if (_loadStages.isEmpty || _loadStages.last != label) {
      _loadStages.add(label);
    }
    _onStage?.call(label);
  }
  // "surah:ayah" -> display words, from the engine's own ref-v2.json.
  Map<String, List<String>>? _referenceWords;
  bool _listening = false;

  /// Permanent diagnostics (Phase 2, 2.3): the last JS console error and
  /// the last failed subresource seen by the WebView, so a bridge failure
  /// can name its cause instead of timing out. Null when nothing failed.
  String? lastConsoleError;
  String? lastResourceError;

  /// True once the page's own `page-loaded` bridge message arrived.
  bool get pageLoadedFromBridge => _pageLoadedFromBridge;
  bool _pageLoadedFromBridge = false;

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
    _onStage = onStage;
    _loadStages.clear();
    _probePassed = false;
    _lastModelLoad = null;
    _lastEnvProbe = null;
    // Last completed stage (Arabic label), shown in the timeout error so
    // a hang is never silent again: the UI mirrors it live via onStage.
    // Stage map for this load path (check files → check model → verify
    // integrity happen atomically inside status(); load WASM → load
    // ONNX are the pre-flight checks below; init ORT → create session
    // → probe happen inside the JS init and are reported back by the
    // bridge's 'stage' messages, which advance this same stage).
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
    final controllerCreated = _controller == null;
    _controller ??= WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setOnConsoleMessage(_onConsoleMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // The page re-fires this on every load; complete only the
            // completer of the current load() call.
            if (_pageLoaded != null && !_pageLoaded!.isCompleted) {
              _pageLoaded!.complete();
            }
          },
          // Permanent diagnostics (Phase 2, 2.3): a failing subresource
          // (bundle.js / WASM / model) used to be invisible to Dart —
          // onPageFinished fires anyway and init() then hung.
          onWebResourceError: (error) {
            final detail =
                'resource error: ${error.url ?? '?'} — ${error.description} '
                '(code ${error.errorCode})';
            lastResourceError = detail;
            debugPrint('[WebViewEngine] $detail');
          },
        ),
      )
      ..addJavaScriptChannel(
        'TilawaBridge',
        onMessageReceived: _onBridgeMessage,
      );
    // MICROPHONE (2026-11-26): register the WebView permission handler
    // ONCE, when the controller is created (before loadRequest). The
    // app-level RECORD_AUDIO permission (permission_handler, requested
    // by the UI before load()) is NOT enough: the page's getUserMedia
    // triggers a WebChromeClient PermissionRequest inside the WebView,
    // and with no handler the WebView denies it — the pro-build-34
    // phone test proved exactly that ("Permission denied" while setup
    // showed the mic as allowed). Grant ONLY the microphone.
    if (controllerCreated &&
        _controller!.platform is AndroidWebViewController) {
      await (_controller!.platform as AndroidWebViewController)
          .setOnPlatformPermissionRequest((request) async {
        if (shouldGrantMicPermission(request.types)) {
          await request.grant();
        } else {
          await request.deny();
        }
      });
    }
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
    // JSEP contract (2026-11-26): the 1.30.0 loader requests ONLY the
    // JSEP pair, so the pre-flight demands HTTP 200 + the EXACT pinned
    // size of EACH JSEP file (not 200 + non-empty as before — a
    // truncated .wasm passed the old check and 404'd the load on
    // pro-build-28 while every gate was green).
    for (final asset in kOrtWasmAssets) {
      await _checkServed(
        '${_server!.baseUrl}ort/$kOrtWebVersion/${asset.name}',
        'ملف التشغيل ${asset.name}',
        expectedBytes: asset.bytes,
      );
    }
    // PRE-FLIGHT: model + reference (2026-11-26 404 fix). The disk-side
    // checks above prove the files exist on disk, but they cannot see a
    // broken server mapping — and the model 404 was exactly that. Fetch
    // each file over HTTP and demand 200 + the exact expected size for
    // the tier being loaded. Two model URLs are checked on purpose:
    // the flat URL Dart hands the bridge (generic /models/ mapping)
    // AND the registry path the engine actually fetches
    // (models/<id>/<version>/model.onnx) — loadWebModel ignores the
    // model URL and requests the registry path, so checking only the
    // first URL would have passed while the real fetch 404'd.
    setStage('جارٍ التحقق من النموذج والمرجع عبر الخادم المحلي…');
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    await _checkServed(
      '${_server!.baseUrl}models/model-$tier.onnx',
      'ملف النموذج (model-$tier.onnx)',
      expectedBytes: asset.bytes,
    );
    await _checkServed(
      '${_server!.baseUrl}models/${asset.modelId}/${asset.version}/model.onnx',
      'ملف النموذج (مسار السجل models/${asset.modelId}/${asset.version}/model.onnx)',
      expectedBytes: asset.bytes,
    );
    await _checkServed(
      '${_server!.baseUrl}models/ref-v2.json',
      'المرجع (ref-v2.json)',
      expectedBytes: kReferenceBytes,
    );
    setStage('جارٍ التحقق من جسر المحرك…');
    // Bridge check WITH RETRIES (Phase 2, 2.3): a single immediate
    // `typeof` can race a still-evaluating bundle.js (classic scripts
    // block parsing, but a slow WebView must not turn into a false
    // "bridge missing" verdict). Five attempts, 500 ms apart, demanding
    // both the object AND its init function. A persistent absence is a
    // hard, named failure — never a silent hang, never a timeout.
    var bridgeFound = false;
    for (var attempt = 0; attempt < 5 && !bridgeFound; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final bridge = await _controller!.runJavaScriptReturningResult(
        "typeof window.TilawaPro !== 'undefined' && "
        "typeof window.TilawaPro.init === 'function' ? 'yes' : 'no'",
      );
      bridgeFound = bridge.toString().contains('yes');
    }
    if (!bridgeFound) {
      final cause = lastResourceError ?? lastConsoleError;
      throw SpeechEngineException(
          'جسر المحرك غير موجود في الصفحة — حزمة المحرك (bundle.js) لم '
          'تُحمَّل أو رمت خطأً أثناء التقييم. أعد بناء الحزمة أو أعد '
          'تشغيل التطبيق.'
          '${cause == null ? '' : ' آخر خطأ مسجَّل: $cause'}');
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
          'توقف عند مرحلة: $_stage. إن تكرر ذلك، تحقق من صفحة «النموذج» '
          '(النموذج مثبَّت + ملفات التشغيل موجودة)، ثم أعد المحاولة.'),
    );
  }

  /// Fetches one file the engine needs from the localhost server and
  /// demands HTTP 200 + a non-empty body — or, when [expectedBytes] is
  /// given, 200 + exactly that many bytes. The disk-side checks cannot
  /// do this: a file can exist on disk yet be unservable (wrong server
  /// path), which is exactly what hung poc-12 and 404'd the model on
  /// 2026-11-26. A failed check names the URL, the expected size and
  /// the actual status/size. Throws [SpeechEngineException] with an
  /// actionable message instead of letting init hang.
  Future<void> _checkServed(String url, String label,
      {int? expectedBytes}) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw SpeechEngineException(
            '$label غير متاح من الخادم المحلي — الرابط: $url — '
            'الحالة الفعلية: HTTP ${res.statusCode}'
            '${expectedBytes == null ? '' : ' (المتوقع: 200 وحجم $expectedBytes بايت)'} — '
            'أعد تشغيل التطبيق، وإن تكرر أعد تنزيل النموذج.');
      }
      var bytes = 0;
      await for (final chunk in res) {
        bytes += chunk.length;
      }
      if (expectedBytes != null && bytes != expectedBytes) {
        throw SpeechEngineException(
            '$label وصل بحجم خاطئ من الخادم المحلي — الرابط: $url — '
            'المتوقع: $expectedBytes بايت، الفعلي: $bytes بايت — '
            'الملف غير مكتمل أو من فئة خاطئة؛ أعد تنزيل النموذج.');
      }
      if (bytes == 0) {
        throw SpeechEngineException(
            '$label وصل فارغاً من الخادم المحلي — الرابط: $url — '
            'أعد المحاولة.');
      }
    } on SpeechEngineException {
      rethrow;
    } on TimeoutException {
      throw SpeechEngineException(
          'انتهت مهلة الوصول إلى $label من الخادم المحلي — الرابط: $url — '
          'الخادم لا يرد.');
    } finally {
      client.close();
    }
  }

  /// Permanent diagnostics (Phase 2, 2.3): JS console output used to be
  /// invisible to Dart — a bundle that threw during evaluation left no
  /// trace anywhere. Errors are kept for the bridge-failure message.
  void _onConsoleMessage(JavaScriptConsoleMessage message) {
    debugPrint(
        '[WebViewEngine] console.${message.level.name}: ${message.message}');
    if (message.level == JavaScriptLogLevel.error) {
      lastConsoleError = message.message;
    }
  }

  Completer<EngineCapabilities>? _loadCompleter;
  Completer<void>? _pageLoaded;

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final data = jsonDecode(message.message) as Map<String, dynamic>;
    final type = data['type'] as String?;
    switch (type) {
      case 'page-loaded':
        // The page's own signal (previously ignored): proves tilawa.html
        // executed its inline script. It says nothing about bundle.js —
        // the bundle check in load() is what proves the bridge.
        _pageLoadedFromBridge = true;
      case 'bundle-error':
      case 'page-error':
        // Reported by tilawa.html itself (script onerror / window.onerror
        // / missing-bridge check): the bundle failed to load or threw
        // while evaluating. Fail the pending load loudly with the layer
        // named, instead of waiting for the 60 s model timeout.
        final err = SpeechEngineException(
          (data['message'] ?? 'خطأ في حزمة المحرك') as String,
          reason: data['reason'] as String?,
        );
        debugPrint('[WebViewEngine] $type: ${err.message}');
        if (_loadCompleter != null) {
          _loadCompleter!.completeError(err);
          _loadCompleter = null;
        } else {
          _events.addError(err);
        }
      case 'stage':
        // Load progress inside the JS init (bridge.js posts 'load-onnx'
        // before loadWebModel and 'create-session' after it resolves).
        // Only meaningful while a load is pending; a stray stage after
        // load is ignored. Advances the same stage the timeout error
        // names, so a hang inside init() is diagnosable.
        if (_loadCompleter != null) {
          final s = (data['stage'] as String?) ?? '';
          setStage(s == 'load-onnx'
              ? 'جارٍ تحميل ملف النموذج (ONNX) وتهيئة المحرك…'
              : s == 'create-session'
                  ? 'جارٍ إنشاء جلسة المحرك…'
                  : 'جارٍ تحميل النموذج داخل المحرك…');
        }
      case 'probe':
        // Explicit warmup-probe result from the bridge (posted right
        // after loadWebModel resolves): the ONNX session was created and
        // its probe run returned structurally valid output. Only
        // meaningful while a load is pending.
        if (_loadCompleter != null && data['result'] == 'passed') {
          _probePassed = true;
          debugPrint('[WebViewEngine] probe passed — ONNX session '
              'created and warmup run returned valid output');
          setStage('تم إنشاء جلسة المحرك ونجح اختبارها…');
        }
      case 'ready':
        final caps = EngineCapabilities.fromJson(
          (data['capabilities'] as Map).cast<String, dynamic>(),
        );
        // Tier truthfulness (§6): the bridge reports the model it
        // ACTUALLY loaded (from the loader's own manifest). If it
        // disagrees with the tier the user picked — e.g. a stale
        // bundle.js without the tier fix loaded full for a lite pick —
        // never show a wrong "ready" card: fail loudly instead.
        // Two caps shapes arrive here: the bridge's provisional one
        // (modelVersion "spliced-clean@1-int8", tier present) and the
        // engine's real one from the first session (modelVersion is the
        // bare manifest id "spliced-clean", tier ABSENT) — accept both,
        // and accept a missing tier, but never a wrong model id.
        if (_tier != null) {
          final expectedId =
              (_tier == 'lite' ? kLiteModel : kFullModel).modelId;
          final modelOk = caps.modelVersion == expectedId ||
              caps.modelVersion.startsWith('$expectedId@');
          final tierOk = caps.tier.isEmpty || caps.tier == _tier;
          if (!modelOk || !tierOk) {
            final err = SpeechEngineException(
                'المحرك حمّل نموذجاً من فئة مختلفة عن المطلوبة: طُلبت '
                'فئة «$_tier» ($expectedId@1-int8) لكن المحرك أبلغ عن '
                '«${caps.modelVersion}»'
                '${caps.tier.isEmpty ? '' : ' (فئة «${caps.tier}»)'} — '
                'أعد بناء حزمة المحرك (bundle.js) أو أعد تنزيل النموذج.');
            if (_loadCompleter != null) {
              _loadCompleter!.completeError(err);
              _loadCompleter = null;
            } else {
              _events.addError(err);
            }
            break;
          }
        }
        _capabilities = caps;
        // Explicit "session created" evidence (a): the ONNX session
        // exists, its warmup probe reported, and the engine is ready —
        // one log line in logcat, so a load that only "looks ready" in
        // the UI still has a checkable trace. The visible state is the
        // recitation screen's «محمَّل (tier)» row.
        debugPrint('[WebViewEngine] engine ready: modelVersion='
            '${caps.modelVersion} tier=${caps.tier} '
            'backend=${caps.backend} probePassed=$_probePassed');
        _loadCompleter?.complete(caps);
        _loadCompleter = null;
        await _log?.append('capabilities',
            data['capabilities'] as Map<String, dynamic>,
            audioMs: null);
      case 'env-probe':
        // Early environment probe from the bridge (posted BEFORE
        // loadWebModel): the page's crossOriginIsolated, live
        // SharedArrayBuffer check, navigator.gpu + requestAdapter
        // result, provider list, threads applied, and the HTTP status
        // of both JSEP files as the page itself sees them. Stored even
        // when the load later fails — this is the diagnostic that names
        // the cause (the pro-build-28 failure arrived with no such
        // context at all). Also appended to the session log when one
        // opens, so a detached log file still carries it.
        final probe = (data['probe'] as Map?)?.cast<String, dynamic>();
        if (probe != null) {
          _lastEnvProbe = probe;
          debugPrint('[WebViewEngine] env-probe: $probe');
          await _log?.append('meta', {'envProbe': probe}, audioMs: null);
        }
      case 'error':
        final rawMessage = (data['message'] ?? 'خطأ من المحرك') as String;
        // Name the cause when the probe arrived: a bare engine string
        // ("No onnxruntime-web provider could run the model ...") is
        // ambiguous by construction, so append the one-line probe
        // summary (isolation, SAB, GPU adapter, JSEP statuses). The
        // bridge also attaches the same fields to the error post
        // itself; this covers probes posted before an error whose own
        // payload predates them.
        final summary = _envProbeSummary;
        final err = SpeechEngineException(
          summary == null ? rawMessage : '$rawMessage\n$summary',
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
        // Proof the ONNX Inference Session was created (a): load time,
        // backend, cross-origin isolation, thread count. The event log
        // is NOT open during load(), so this used to be silently dropped
        // by the `_log?.append` below — keep it in [_lastModelLoad] so
        // beginLog carries it into the session log, and log it now.
        _lastModelLoad = {
          'modelLoadMs': data['ms'],
          'backend': data['backend'],
          // poc-10 diagnostics: proves on the phone whether the page was
          // really cross-origin isolated and how many WASM threads ran.
          'crossOriginIsolated': data['crossOriginIsolated'],
          'threads': data['threads'],
        };
        debugPrint('[WebViewEngine] ONNX session created: '
            'modelLoadMs=${data['ms']} backend=${data['backend']} '
            'crossOriginIsolated=${data['crossOriginIsolated']} '
            'threads=${data['threads']}');
        await _log?.append('meta', _lastModelLoad!, audioMs: null);
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
    // First session log of this process == first session since the app
    // launch (see _sessionLoggedThisProcess). Recorded before creating
    // the log so a crash mid-create still leaves the flag consistent
    // for the next attempt in the same process.
    final coldStart = !_sessionLoggedThisProcess;
    _sessionLoggedThisProcess = true;
    _log = await EventLog.create(sessionId: sessionId, sessionMeta: {
      ...meta,
      'sessionStartedWallMs': DateTime.now().millisecondsSinceEpoch,
      // Build/device identity (Q6): ties a detached log file to the
      // app build and the OS it ran on. backend/modelVersion are
      // already recorded below; they are not repeated here.
      'appVersion': kAppVersion,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'coldStart': coldStart,
      'tier': _tier,
      'backend': _capabilities?.backend,
      'modelVersion': _capabilities?.modelVersion,
      'modelSha256': _capabilities?.modelSha256,
      // The stage trail of the load that produced this session, so a
      // later failure can be traced to the stage it stopped at.
      'loadStages': List<String>.of(_loadStages),
      // Load evidence (a): the warmup probe's explicit result and the
      // ONNX-session creation payload. probePassed == false means the
      // probe never reported (e.g. a stale bundle) — recorded as-is,
      // never assumed true.
      'probePassed': _probePassed,
      'modelLoad': _lastModelLoad,
      // Early environment probe (2026-11-26): the page's isolation,
      // SAB, GPU adapter and JSEP statuses measured BEFORE loadWebModel
      // — the context a failed load used to arrive without. Null when
      // the bridge never posted one (stale bundle).
      'envProbe': _lastEnvProbe,
      // Offline evidence (b): the engine's only network surface is the
      // localhost server (model, reference and WASM all served from
      // 127.0.0.1; the microphone goes straight into the engine) — no
      // external fetch happens after load. This records the transport,
      // not an OS airplane-mode reading: the app has no connectivity
      // plugin, so it cannot observe the OS radio state.
      'network': 'localhost-only',
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
