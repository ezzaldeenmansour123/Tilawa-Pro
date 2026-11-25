// Early environment probe for the recitation engine (Tilawa Pro).
//
// Runs in the WebView page BEFORE loadWebModel is called, and posts its
// result to Dart as {type:'env-probe', probe:{...}} so a failed load can
// name its cause instead of failing with a bare error string (the
// pro-build-28 failure mode: Dart received only "No onnxruntime-web
// provider could run the model (...)" and nothing about the environment
// that produced it).
//
// What it measures (2026-11-26, JSEP/WASM follow-up repair):
//   - crossOriginIsolated (boolean) — settles the isolation question
//     before any inference; previously reported only AFTER a successful
//     load (bridge.js modelLoadMs), i.e. never on failure.
//   - SharedArrayBuffer: typeof + a LIVE probe (construct one and post
//     it through a MessageChannel, mirroring onnxruntime-web's own
//     isMultiThreadSupported in wasm-factory.ts:13-38). A typeof check
//     alone cannot distinguish "SAB defined" from "SAB transferable".
//   - WebGPU: "gpu" in navigator + navigator.gpu.requestAdapter()
//     (guarded, with timeout — must never hang the load). Presence of
//     navigator.gpu alone proves nothing about the adapter.
//   - providers: the provider list loadWebModel will actually try — the
//     @tilawa/core default ["webgpu","wasm"] (see bridge.js: the default
//     is kept deliberately; a post-initWasm WebGPU failure cannot poison
//     the wasm attempt, so WebGPU stays optional and wasm is the
//     guaranteed fallback).
//   - threadsApplied: crossOriginIsolated ? threads : 1 — the value
//     @tilawa/core will actually apply (dist/runtime/web.js:37).
//   - jsep: HTTP status of BOTH JSEP files the 1.30.0 loader requests
//     (ort-wasm-simd-threaded.jsep.mjs/.wasm under wasmPaths), fetched
//     from inside the page (HEAD). This is the in-WebView second opinion
//     on the Dart pre-flight: Dart's HttpClient cannot see a COEP-blocked
//     fetch, the page can.
//
// Design rules:
//   - Each individual check is defensive (its own try/catch, result
//     recorded as a status string) — one broken check must never kill
//     the others or the load.
//   - The probe NEVER blocks the load path when it succeeds: the bridge
//     awaits it with a bounded timeout, and its findings are diagnostic
//     only — the Dart pre-flight (exact sizes over HTTP) is the gate
//     that blocks a load, not the probe.
//   - Only a genuinely unexpected throw from the probe itself (not a
//     failed check) is posted by the bridge as {type:'error'} — a
//     failed check is data, an exploding probe means the page is in an
//     unknown state and Dart must hear about it by name.
//   - No network outside the localhost server: every URL probed is
//     wasmPaths + a JSEP filename (127.0.0.1). Nothing is fetched from
//     a CDN at runtime.
//
// Testable without a WebView: this module imports nothing and only
// touches globalThis/fetch/navigator/MessageChannel, so
// web/test-env-probe.mjs exercises it in Node with shims.

export const JSEP_FILES = [
  'ort-wasm-simd-threaded.jsep.mjs',
  'ort-wasm-simd-threaded.jsep.wasm',
];

/// Provider list loadWebModel will try (the @tilawa/core default —
// the bridge passes no `providers`, so this is what runs).
export const PROVIDERS = ['webgpu', 'wasm'];

function withTimeout(promise, ms, label) {
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve({ __timeout: true, label }), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/// Live SharedArrayBuffer probe, mirroring onnxruntime-web's own
// isMultiThreadSupported (wasm-factory.ts:13-38) EXACTLY: SAB must be
// defined and constructible, postable through a MessageChannel (no
// transfer list — a SAB is shared, not transferred), AND a
// shared-memory WebAssembly module must validate. Returns
// 'supported' | 'undefined' | 'not-constructible' |
// 'not-transferable' | 'no-shared-memory-wasm' | 'error:<message>'.
// Synchronous (like the upstream check) — never throws.
function probeSharedArrayBuffer() {
  try {
    if (typeof SharedArrayBuffer === 'undefined') return 'undefined';
    try {
      // eslint-disable-next-line no-new — construction is the test.
      new SharedArrayBuffer(1);
    } catch (e) {
      return 'not-constructible';
    }
    // Test for transferability of SABs (browsers; needed for Firefox).
    if (typeof MessageChannel !== 'undefined') {
      try {
        new MessageChannel().port1.postMessage(new SharedArrayBuffer(1));
      } catch (e) {
        return 'not-transferable';
      }
    }
    // Test for WebAssembly threads capability (the exact shared-memory
    // probe module bytes from wasm-factory.ts:31-35).
    const ok = WebAssembly.validate(
      new Uint8Array([
        0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 5, 4, 1, 3, 1, 1, 10, 11, 1, 9, 0, 65, 0, 254, 16,
        2, 0, 26, 11,
      ]),
    );
    return ok ? 'supported' : 'no-shared-memory-wasm';
  } catch (e) {
    return 'error:' + (e && e.message ? e.message : String(e));
  }
}

/// WebGPU probe: presence + adapter request, guarded with a timeout.
// Returns {gpuInNavigator, adapter} where adapter is 'adapter' |
// 'null' | 'n/a' (no navigator.gpu) | 'timeout' | 'error:<message>'.
// Never throws; requestAdapter() must not hang the load.
async function probeWebGpu(adapterTimeoutMs) {
  const out = { gpuInNavigator: false, adapter: 'n/a' };
  try {
    if (typeof navigator === 'undefined' || !('gpu' in navigator)) {
      return out;
    }
    out.gpuInNavigator = true;
    if (!navigator.gpu || typeof navigator.gpu.requestAdapter !== 'function') {
      out.adapter = 'error:no-requestAdapter';
      return out;
    }
    const result = await withTimeout(
      Promise.resolve().then(() => navigator.gpu.requestAdapter()),
      adapterTimeoutMs,
      'adapter',
    );
    if (result && result.__timeout) {
      out.adapter = 'timeout';
    } else if (result === null || result === undefined) {
      out.adapter = 'null';
    } else {
      out.adapter = 'adapter';
    }
    return out;
  } catch (e) {
    out.adapter = 'error:' + (e && e.message ? e.message : String(e));
    return out;
  }
}

/// HTTP status probe for one file (HEAD — no body is downloaded).
// Returns a number (HTTP status) or 'error:<message>' / 'timeout'.
// Never throws.
async function probeFileStatus(url, fetchTimeoutMs) {
  try {
    const res = await withTimeout(
      fetch(url, { method: 'HEAD' }),
      fetchTimeoutMs,
      'fetch',
    );
    if (res && res.__timeout) return 'timeout';
    return typeof res.status === 'number' ? res.status : 'error:no-status';
  } catch (e) {
    return 'error:' + (e && e.message ? e.message : String(e));
  }
}

/// Run the full probe. Options:
//   {wasmPaths, threads, timeouts?: {adapterMs?, fetchMs?}}
// (The SAB check is synchronous, like upstream's — it takes no timeout.)
// Returns a plain JSON-able object. Individual checks never throw;
// this function throws only on a genuinely unexpected failure (e.g.
// wasmPaths missing), which the bridge posts as an error.
export async function runEnvProbe(opts) {
  if (!opts || typeof opts.wasmPaths !== 'string' || !opts.wasmPaths) {
    throw new Error('env probe: wasmPaths is required');
  }
  const timeouts = opts.timeouts || {};
  const adapterMs = timeouts.adapterMs ?? 3000;
  const fetchMs = timeouts.fetchMs ?? 5000;

  const crossOriginIsolated =
    typeof globalThis !== 'undefined' && globalThis.crossOriginIsolated === true;
  const threads = typeof opts.threads === 'number' ? opts.threads : 1;
  const threadsApplied = crossOriginIsolated ? threads : 1;

  const sab = probeSharedArrayBuffer();
  const gpu = await probeWebGpu(adapterMs);
  const jsep = {};
  for (const name of JSEP_FILES) {
    jsep[name] = await probeFileStatus(opts.wasmPaths + name, fetchMs);
  }

  return {
    crossOriginIsolated,
    sharedArrayBuffer: typeof SharedArrayBuffer === 'undefined' ? 'undefined' : sab,
    gpuInNavigator: gpu.gpuInNavigator,
    gpuAdapter: gpu.adapter,
    providers: [...PROVIDERS],
    threadsRequested: threads,
    threadsApplied,
    jsep,
    wasmPaths: opts.wasmPaths,
  };
}
