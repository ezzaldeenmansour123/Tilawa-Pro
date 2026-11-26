// WebView bridge: runs @tilawa/core/web inside the Pro app's WebView.
//
// Exposed to Dart as window.TilawaPro:
//   init({assetBase, tier, modelUrl, referenceUrl, wasmPaths}) -> loads the
//     model + reference from the localhost server, reports capabilities.
//   startSession({mode, surah, fromAyah, toAyah})
//   pushPcm(base64, sampleRate, seq) -> feeds one PCM16 frame to the
//     engine session via session.pushAudio; posts pcm-ack / pcm-error.
//   stopSession()
//   dispose()
//
// AUDIO (2026-11-26 — native capture, Misbar-style): the microphone is
// captured NATIVELY in Flutter (package `record`, 16 kHz mono PCM16)
// and pushed here frame by frame. The WebView NEVER calls
// getUserMedia / tilawa.listen() anymore: on the user's S22 Ultra the
// WebView audio source genuinely will not start (NotReadableError
// "Could not start audio source" persisted through the WebView
// permission grant in pro-35 and the exact-name + retry in pro-36),
// while the same phone's native recorder path is the standard Android
// route. The engine is source-agnostic by design — @tilawa/core's web
// startMicrophone itself only feeds session.pushAudio(gated, 16000)
// (dist/web.js:152), and its react-native entry says: "The app pushes
// PCM from its own recorder with session.pushAudio(samples, sampleRate)".
// VAD: the web path's default is vad:false (dist/defaults.js:16), so
// no VAD gating is lost by pushing raw PCM here.
//
// Every engine event is forwarded to Dart through the `TilawaBridge`
// JavaScriptChannel as JSON:
//   {type:"ready", capabilities:{...}}
//   {type:"probe", result:"passed"} (the loader's warmup probe ran and
//     returned structurally valid output — explicit evidence, never
//     inferred from ready alone)
//   {type:"stage", stage:"load-onnx"|"create-session"} (load progress
//     inside init, so Dart can name the stage a hang or failure stopped
//     at instead of timing out on a generic "loading model")
//   {type:"position", event:{...}}   (position events, with timeMs audio clock)
//   {type:"checker", event:{...}}    (checker events, suspected/confirmed/...)
//   {type:"pcm-ack", seq}            (one pushed PCM frame was consumed by
//                                      the engine; Dart's backpressure ack)
//   {type:"pcm-error", seq, message, name} (a pushed frame was rejected —
//                                      the engine session is then dead, see
//                                      session.js pushAudio: a failed push
//                                      ends the session; Dart stops the
//                                      native recorder and surfaces this)
//   {type:"env-probe", probe:{...}} (NEW 2026-11-26: early environment
//     probe, posted BEFORE loadWebModel — crossOriginIsolated,
//     SharedArrayBuffer live check, navigator.gpu + requestAdapter,
//     provider list, threads applied, HTTP status of both JSEP files.
//     Posted even when the load later fails, so Dart can name the cause.
//     See web/src/env_probe.js.)
//   {type:"modelLoadMs", ms, backend}
//   {type:"error", message, reason}  (engine/load failures. The
//                                      microphone no longer fails here:
//                                      capture is native in Dart, so a
//                                      mic failure arrives as a Dart-side
//                                      NativeMicException on the event
//                                      stream, not as a bridge error.)
//     Since 2026-11-26 the load-error post ALSO carries the environment
//     (crossOriginIsolated, sharedArrayBuffer, gpuInNavigator,
//     providers, threadsApplied) so a failure string is never the only
//     evidence again.
//
// PROVIDER DECISION (2026-11-26, verified from onnxruntime-web 1.30.0
// source — see ~/workspace/tilawa/JSEP_WASM_PRO_IMPLEMENTATION_2026-11-26.md):
// the bridge passes NO `providers`, so @tilawa/core uses its default
// ["webgpu","wasm"]. That default is KEPT deliberately. A webgpu failure
// AFTER a successful initWasm cannot poison the wasm attempt: backend
// init runs initWasm FIRST and the EP init SECOND (backend-wasm.ts:69-76);
// the sticky `aborted` flag is set only by the initWasm catch
// (proxy-wrapper.ts:150-158); a failed initEp never sets it; and the
// per-backend abort cache (backend-impl.ts:74-101) is per name, so the
// webgpu entry's abort does not touch the wasm entry. The observed
// pro-build-28 poisoning happened because initWasm ITSELF failed (the
// missing .jsep.mjs) — once the JSEP files are served, initWasm succeeds
// and a later webgpu adapter/JSEP failure falls through to wasm cleanly.
// WebGPU is therefore optional-only by construction: tried when
// available, never a condition for tasmee'.
//
// SINGLE-THREAD VERDICT (2026-11-26): onnxruntime-web 1.30.0 ships ONLY
// threaded builds (dist/ has no single-threaded file) and @tilawa/core
// requires onnxruntime-web >= 1.19.0, so there is no separate
// single-threaded build to download and no downgrade path. The
// single-thread path is the SAME JSEP files with numThreads = 1 —
// which @tilawa/core already forces when the page is not isolated
// (dist/runtime/web.js:37) and onnxruntime-web falls back to on its own
// with a warning (wasm-factory.ts:131-149). A missing SharedArrayBuffer
// therefore cannot fail a load; only the missing JSEP files could.
//
// Notes, from the upstream README (verified 2026-11-25):
// - The WebView never calls `listen()`: audio arrives via pushPcm from
//   the native recorder. The localhost server still provides the secure
//   context the page (WASM) needs.
// - Default confirm policy is "next-word" (a mistake is confirmed once the
//   next word starts); the app keeps the upstream default (2.5 s delay is
//   the other option) so results are comparable with the upstream numbers.
// - minConfidence default is 0.6; the PoC keeps it and displays anything
//   below it as "uncertain" instead of a verdict.
// - The reference is loaded from the self-hosted ref-v2.json; the model from
//   the self-hosted .onnx file. Nothing is fetched from tilawa.dev at runtime.

import { createTilawa, loadWebModel } from '@tilawa/core/web';
import { runEnvProbe } from './env_probe.js';

function post(msg) {
  // webview_flutter JavaScriptChannel named "TilawaBridge".
  if (window.TilawaBridge) {
    window.TilawaBridge.postMessage(JSON.stringify(msg));
  } else {
    // Fallback for debugging the page in a desktop browser.
    console.log('[TilawaPro]', JSON.stringify(msg));
  }
}

let tilawa = null;
let session = null;

window.TilawaPro = {
  async init(opts) {
    const t0 = performance.now();
    // Declared outside try: the catch below attaches the probe to the
    // error post, and a `let` inside try would be out of scope there.
    let envProbe = null;
    try {
      // Load the reference + model from the localhost server (self-hosted).
      // loadWebModel({model, reference, wasmPaths}) is the documented
      // offline path; createTilawa with a loaded model does not hit the
      // network at all.
      const reference = await (await fetch(opts.referenceUrl)).json();
      // Threads: onnxruntime-web >= 1.19 ships ONLY threaded WASM builds
      // (ort-wasm-simd-threaded.jsep.*); the single-threaded files do not
      // exist. Request 2–4 threads, but @tilawa/core forces numThreads = 1
      // whenever the page is NOT cross-origin isolated
      // (dist/runtime/web.js:37) — and the SAME JSEP files run
      // single-threaded in that case (onnxruntime-web falls back to 1
      // with a warning instead of failing, wasm-factory.ts:131-149). So
      // a missing SharedArrayBuffer can never fail this load; whether
      // this page is actually isolated is UNMEASURED until the env probe
      // below reports it — the old claim here ("the page IS isolated")
      // was an assumption, and it is removed. The localhost server still
      // sends COOP+COEP (see lib/local_server.dart) so isolation — and
      // threads > 1 — is possible, not guaranteed.
      const threads = Math.max(2, Math.min(4, navigator.hardwareConcurrency || 4));
      // EARLY ENV PROBE (2026-11-26): measure the environment BEFORE
      // loadWebModel and post it to Dart, so a failed load names its
      // cause. The probe never blocks the load when it succeeds — its
      // findings are diagnostic only (the Dart pre-flight is the gate).
      // Only a genuinely unexpected throw from the probe itself is
      // posted as an error: a failed CHECK is data, an exploding probe
      // means the page is in an unknown state.
      try {
        envProbe = await runEnvProbe({
          wasmPaths: opts.wasmPaths,
          threads,
        });
        post({ type: 'env-probe', probe: envProbe });
      } catch (probeErr) {
        post({
          type: 'error',
          message: 'فشل فحص بيئة المحرك قبل التحميل: ' +
            (probeErr && probeErr.message ? probeErr.message : String(probeErr)),
          reason: 'env-probe-failed',
        });
        return;
      }
      // 2026-11-26 404 + tier fix: loadWebModel derives the tier ONLY
      // from its `tier` option (default "full") and IGNORES the `model`
      // URL entirely — the loader fetches `<registry base>/model.onnx`
      // from its bundled registry instead. The bridge used to pass only
      // `model: opts.modelUrl`, so a lite pick silently loaded the FULL
      // model (and 404'd on models/spliced-clean/1-int8/model.onnx
      // because the server had no such file). Pass the tier explicitly.
      post({ type: 'stage', stage: 'load-onnx' });
      const model = await loadWebModel({
        tier: opts.tier,
        model: opts.modelUrl,
        reference,
        wasmPaths: opts.wasmPaths,
        threads,
      });
      // loadWebModel resolves only after its internal warmup probe (a
      // real session run on zeroed, silence-shaped inputs, checking the
      // run returns structurally valid output) succeeds — report that
      // result EXPLICITLY: a silent probe is not evidence, and Dart must
      // not declare ready on a load whose probe never reported.
      post({ type: 'probe', result: 'passed' });
      post({ type: 'stage', stage: 'create-session' });
      tilawa = await createTilawa({ model, reference });
      // Reaching here means the model loaded AND probed successfully —
      // ready is never declared on a failed or unprobed load.
      // Report the model that was ACTUALLY loaded (from the loader's own
      // manifest), not the tier Dart asked for: if the bundle is stale
      // or the tier mismatched, Dart must see the truth and fail loudly
      // instead of showing a wrong "ready" card.
      const loadedId = (model && model.manifest && model.manifest.id) || null;
      const loadedTier = loadedId === 'spliced-clean-lite' ? 'lite'
        : loadedId === 'spliced-clean' ? 'full' : opts.tier;
      const ms = Math.round(performance.now() - t0);
      // The capabilities event arrives on the first session, but the PoC
      // also needs the backend + load time now: subscribe to a throwaway
      // probe session is NOT possible (a session is a take), so the backend
      // is reported from the first real session's capabilities event, and
      // the load time is reported here.
      post({ type: 'modelLoadMs', ms, backend: 'unknown-yet', crossOriginIsolated: globalThis.crossOriginIsolated, threads });
      // Report readiness: the capabilities payload comes with the first
      // session; here we report the model identity from the registry data
      // the bridge already knows (tier + urls), so Dart can show the card.
      post({
        type: 'ready',
        capabilities: {
          modelVersion: (loadedId || (opts.tier === 'lite'
            ? 'spliced-clean-lite'
            : 'spliced-clean')) + '@1-int8',
          modelRelease: '1',
          referenceVersion: reference.version || 'ref-v2',
          sdkVersion: '1.0.0-rc.1',
          modelSha256: 'verified-by-dart-before-load',
          tier: loadedTier,
          backend: 'unknown-yet',
          supported: ['wrong_word', 'omitted_word', 'added_word', 'skipped_passage'],
          unsupported: ['tajweed', 'pronunciation', 'hadr', 'children'],
        },
      });
    } catch (err) {
      // A bare error string is ambiguous by construction (the
      // pro-build-28 message labelled a provider-agnostic initWasm
      // failure as a "webgpu" failure) — attach the environment so Dart
      // can name the cause: isolation, SAB, GPU presence, the providers
      // actually attempted, and the threads actually applied. The
      // env-probe (posted before loadWebModel) carries the same values
      // with per-file JSEP statuses; these fields cover the case where
      // the probe never posted.
      post({
        type: 'error',
        message: 'فشل تحميل النموذج: ' + (err && err.message ? err.message : String(err)),
        reason: err && err.reason ? err.reason : undefined,
        crossOriginIsolated: globalThis.crossOriginIsolated,
        sharedArrayBuffer: typeof SharedArrayBuffer,
        gpuInNavigator: typeof navigator !== 'undefined' && 'gpu' in navigator,
        providers: ['webgpu', 'wasm'],
        threadsApplied: globalThis.crossOriginIsolated
          ? Math.max(2, Math.min(4, navigator.hardwareConcurrency || 4))
          : 1,
        envProbe,
      });
    }
  },

  startSession(opts) {
    if (!tilawa) {
      post({ type: 'error', message: 'المحرك غير محمّل بعد' });
      return;
    }
    const policy = { confirm: { after: 'next-word' } }; // upstream default
    if (opts.mode === 'memorization') {
      session = tilawa.startMemorization(
        { surah: opts.surah, fromAyah: opts.fromAyah, toAyah: opts.toAyah },
        policy,
      );
    } else {
      session = tilawa.startFreeRecitation(policy);
    }
    session.subscribe((e) => {
      if (e.type === 'capabilities') {
        // The real capabilities event: forward it so Dart replaces the
        // provisional card (notably the true `backend`: wasm/webgpu/cpu).
        post({ type: 'ready', capabilities: e });
      } else if (e.type === 'position' || e.type === 'checker') {
        post({ type: e.type, event: e });
      }
    });
    // No microphone here: audio arrives via pushPcm() from Dart's
    // native recorder (2026-11-26). The session is a take — position
    // and checker events flow through the subscribe() above exactly
    // as they did when the web listener fed it.
  },

  // One PCM16 frame from the native recorder (base64 of the raw
  // little-endian bytes, sampleRate as captured — 16000). Decodes to
  // Float32Array and calls session.pushAudio. pushAudio accepts any
  // sample rate and resamples internally (dist/session.js tapIn +
  // dist/runtime/listener.js:106-112), so the rate is passed through
  // honestly, never assumed. Resolves after the ack is posted; Dart
  // awaits this (via runJavaScript) AND counts the pcm-ack, so
  // backpressure works whether or not the WebView awaits the promise.
  // A rejected push ends the engine session (dist/session.js: pushAudio
  // sets failed=true, state=ended) — Dart treats pcm-error as fatal:
  // it stops the recorder and surfaces the error on the event stream.
  async pushPcm(base64, sampleRate, seq) {
    if (!session) {
      post({
        type: 'pcm-error',
        seq,
        message: 'لا توجد جلسة نشطة لدفع الصوت إليها',
        name: 'NoSession',
      });
      return;
    }
    try {
      const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
      const pcm16 = new Int16Array(
        bytes.buffer,
        bytes.byteOffset,
        bytes.byteLength >> 1,
      );
      const pcm = new Float32Array(pcm16.length);
      for (let i = 0; i < pcm16.length; i++) pcm[i] = pcm16[i] / 32768;
      await session.pushAudio(pcm, sampleRate);
      post({ type: 'pcm-ack', seq });
    } catch (err) {
      post({
        type: 'pcm-error',
        seq,
        message: err && err.message ? err.message : String(err),
        name: (err && err.cause && err.cause.name) || (err && err.name) || '',
      });
    }
  },

  async stopSession() {
    try {
      if (session) {
        await session.end();
        session = null;
      }
    } catch (_) {
      /* end() is idempotent; ignore */
    }
  },

  dispose() {
    if (tilawa) {
      tilawa.dispose();
      tilawa = null;
    }
  },
};
