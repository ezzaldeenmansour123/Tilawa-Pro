// WebView bridge: runs @tilawa/core/web inside the Pro app's WebView.
//
// Exposed to Dart as window.TilawaPro:
//   init({assetBase, tier, modelUrl, referenceUrl, wasmPaths}) -> loads the
//     model + reference from the localhost server, reports capabilities.
//   startSession({mode, surah, fromAyah, toAyah})
//   stopSession()
//   dispose()
//
// Every engine event is forwarded to Dart through the `TilawaBridge`
// JavaScriptChannel as JSON:
//   {type:"ready", capabilities:{...}}
//   {type:"position", event:{...}}   (position events, with timeMs audio clock)
//   {type:"checker", event:{...}}    (checker events, suspected/confirmed/...)
//   {type:"modelLoadMs", ms, backend}
//   {type:"error", message, reason}  (incl. MicrophoneError reasons:
//                                      denied | unavailable | insecure-context)
//
// Notes, from the upstream README (verified 2026-11-25):
// - `listen()` needs a secure context; the Dart localhost server provides it.
// - Default confirm policy is "next-word" (a mistake is confirmed once the
//   next word starts); the app keeps the upstream default (2.5 s delay is
//   the other option) so results are comparable with the upstream numbers.
// - minConfidence default is 0.6; the PoC keeps it and displays anything
//   below it as "uncertain" instead of a verdict.
// - The reference is loaded from the self-hosted ref-v2.json; the model from
//   the self-hosted .onnx file. Nothing is fetched from tilawa.dev at runtime.

import { createTilawa, loadWebModel } from '@tilawa/core/web';

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
let mic = null;

window.TilawaPro = {
  async init(opts) {
    const t0 = performance.now();
    try {
      // Load the reference + model from the localhost server (self-hosted).
      // loadWebModel({model, reference, wasmPaths}) is the documented
      // offline path; createTilawa with a loaded model does not hit the
      // network at all.
      const reference = await (await fetch(opts.referenceUrl)).json();
      // poc-10: onnxruntime-web >= 1.19 ships ONLY threaded WASM builds
      // (ort-wasm-simd-threaded.wasm); the single-threaded files do not
      // exist, which 404ed poc-9. The localhost server now sends COOP+COEP
      // (see lib/local_server.dart), so the page IS cross-origin isolated
      // and SharedArrayBuffer works — request threads > 1 so the loader
      // uses the threaded build that actually exists.
      const threads = Math.max(2, Math.min(4, navigator.hardwareConcurrency || 4));
      const model = await loadWebModel({
        model: opts.modelUrl,
        reference,
        wasmPaths: opts.wasmPaths,
        threads,
      });
      tilawa = await createTilawa({ model, reference });
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
          modelVersion: opts.tier === 'lite'
            ? 'spliced-clean-lite@1-int8'
            : 'spliced-clean@1-int8',
          modelRelease: '1',
          referenceVersion: reference.version || 'ref-v2',
          sdkVersion: '1.0.0-rc.1',
          modelSha256: 'verified-by-dart-before-load',
          tier: opts.tier,
          backend: 'unknown-yet',
          supported: ['wrong_word', 'omitted_word', 'added_word', 'skipped_passage'],
          unsupported: ['tajweed', 'pronunciation', 'hadr', 'children'],
        },
      });
    } catch (err) {
      post({
        type: 'error',
        message: 'فشل تحميل النموذج: ' + (err && err.message ? err.message : String(err)),
        reason: err && err.reason ? err.reason : undefined,
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
    // Microphone -> session. Rejects with MicrophoneError on denial.
    tilawa
      .listen(session)
      .then((m) => {
        mic = m;
      })
      .catch((err) => {
        post({
          type: 'error',
          message: 'تعذّر فتح الميكروفون: ' + (err && err.message ? err.message : String(err)),
          reason: err && err.reason ? err.reason : 'unavailable',
        });
      });
  },

  async stopSession() {
    try {
      if (mic) {
        await mic.stop();
        mic = null;
      }
    } catch (_) {
      /* stopping the mic is best-effort */
    }
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
