// Smoke test: actually EVALUATE the built web bundle in Node.
//
// Usage (from web/):  node smoke-bundle.mjs [path/to/bundle.js]
// Default bundle: ../assets/web/bundle.js (built by `npm run build`).
//
// What this proves:
//   - bundle.js loads AND evaluates without throwing at the top level
//     (the poc-14 failure mode: a bundle that arrives HTTP 200 but throws
//     during evaluation dies BEFORE `window.TilawaPro` is defined, and
//     `test -s` / `node --check` can never catch that);
//   - after evaluation, `window.TilawaPro` is an object exposing the four
//     bridge methods Dart calls: init, startSession, pushPcm, stopSession,
//     dispose.
//
// What this does NOT prove (stated honestly):
//   - no model is loaded, no WASM is instantiated, no audio flows, no
//     microphone is opened, and nothing runs inside a real WebView —
//     `init()` is never called here. Model/WASM/mic behaviour is covered
//     by the on-device phone protocol, not by this file.
//
// The shims below are the minimal browser surface the bundle's top-level
// code touches during evaluation (proven by running this file locally
// against the real 1,040,578-byte bundle). Node 24 exposes `navigator` /
// `document` / `location` as getter-only on globalThis, hence
// Object.defineProperty instead of plain assignment.

import { statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const GLOBAL_NAME = 'TilawaPro';
const EXPECTED_METHODS = ['init', 'startSession', 'pushPcm', 'stopSession', 'dispose'];

const bundlePath = process.argv[2]
  ? process.argv[2]
  : fileURLToPath(new URL('../assets/web/bundle.js', import.meta.url));

let stat;
try {
  stat = statSync(bundlePath);
} catch {
  console.error(`SMOKE FAIL: bundle not found: ${bundlePath}`);
  process.exit(1);
}
if (stat.size === 0) {
  console.error(`SMOKE FAIL: bundle is empty: ${bundlePath}`);
  process.exit(1);
}

// Minimal browser shims (evaluation-time only).
globalThis.window = globalThis;
globalThis.self = globalThis;
Object.defineProperty(globalThis, 'navigator', {
  value: { hardwareConcurrency: 4, userAgent: 'node-smoke', gpu: undefined },
  configurable: true,
});
Object.defineProperty(globalThis, 'document', {
  value: {
    createElement: () => ({ getContext: () => null, style: {}, addEventListener() {} }),
    currentScript: null,
  },
  configurable: true,
});
Object.defineProperty(globalThis, 'location', {
  value: { href: 'http://localhost/', origin: 'http://localhost' },
  configurable: true,
});

// EVALUATE the bundle — any top-level throw fails the run here.
try {
  await import(bundlePath);
} catch (err) {
  console.error(`SMOKE FAIL: bundle threw during evaluation: ${bundlePath}`);
  console.error(`  ${err && err.message ? err.message : String(err)}`);
  console.error('  A bundle that throws before defining the bridge fails here — this is the poc-14 failure mode.');
  process.exit(1);
}

const bridge = globalThis[GLOBAL_NAME];
if (typeof bridge !== 'object' || bridge === null) {
  console.error(
    `SMOKE FAIL: window.${GLOBAL_NAME} is not an object after evaluating ${bundlePath} ` +
      `(got ${typeof bridge}) — the bundle threw or aborted before defining the bridge.`,
  );
  process.exit(1);
}
const missing = EXPECTED_METHODS.filter((m) => typeof bridge[m] !== 'function');
if (missing.length > 0) {
  console.error(
    `SMOKE FAIL: window.${GLOBAL_NAME} is missing methods: ${missing.join(', ')} ` +
      `(present: ${EXPECTED_METHODS.filter((m) => typeof bridge[m] === 'function').join(', ') || 'none'}).`,
  );
  process.exit(1);
}
console.log(
  `BUNDLE SMOKE OK: ${bundlePath} (${stat.size} bytes) evaluated cleanly; ` +
    `window.${GLOBAL_NAME} exposes ${EXPECTED_METHODS.join(', ')}.`,
);
console.log('NOTE: this proves evaluation + bridge shape only — no model/WASM/mic/WebView was exercised.');
