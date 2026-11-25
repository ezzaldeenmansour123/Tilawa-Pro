// Unit tests for web/src/env_probe.js — runnable in Node, no WebView.
//
// Usage (from web/):  node test-env-probe.mjs
// Exit 0 = all pass, 1 = any failure.
//
// The probe only touches globalThis / navigator / fetch /
// MessageChannel / SharedArrayBuffer, so each case installs shims,
// imports the module fresh (query-string cache-bust), runs runEnvProbe,
// and restores the globals. Node 24 provides MessageChannel and
// SharedArrayBuffer natively.

import { strict as assert } from 'node:assert';

let failures = 0;
function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => console.log(`  PASS: ${name}`))
    .catch((e) => {
      failures += 1;
      console.error(`  FAIL: ${name} — ${e && e.message ? e.message : String(e)}`);
    });
}

const saved = {
  navigator: globalThis.navigator,
  fetch: globalThis.fetch,
  crossOriginIsolated: globalThis.crossOriginIsolated,
  SharedArrayBuffer: globalThis.SharedArrayBuffer,
};

function restore() {
  if (saved.navigator === undefined) {
    delete globalThis.navigator;
  } else {
    Object.defineProperty(globalThis, 'navigator', {
      value: saved.navigator, configurable: true,
    });
  }
  globalThis.fetch = saved.fetch;
  if (saved.crossOriginIsolated === undefined) {
    delete globalThis.crossOriginIsolated;
  } else {
    globalThis.crossOriginIsolated = saved.crossOriginIsolated;
  }
  if (saved.SharedArrayBuffer === undefined) {
    delete globalThis.SharedArrayBuffer;
  } else {
    globalThis.SharedArrayBuffer = saved.SharedArrayBuffer;
  }
}

function setNavigator(value) {
  Object.defineProperty(globalThis, 'navigator', {
    value, configurable: true,
  });
}

async function loadProbe() {
  // Fresh import per case so no module state leaks between cases.
  return import(`./src/env_probe.js?case=${Math.random()}`);
}

const WASM_PATHS = 'http://127.0.0.1:44905/ort/1.30.0/';
const FAST = { adapterMs: 200, sabMs: 200, fetchMs: 200 };

console.log('ENV PROBE TESTS — web/src/env_probe.js');

await check('all-good env: isolated + SAB live + GPU adapter + JSEP 200', async () => {
  globalThis.crossOriginIsolated = true;
  setNavigator({
    hardwareConcurrency: 4,
    gpu: { requestAdapter: async () => ({ limits: {}, features: {} }) },
  });
  globalThis.fetch = async () => ({ status: 200 });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 4, timeouts: FAST });
  assert.equal(p.crossOriginIsolated, true);
  assert.equal(p.sharedArrayBuffer, 'supported');
  assert.equal(p.gpuInNavigator, true);
  assert.equal(p.gpuAdapter, 'adapter');
  assert.deepEqual(p.providers, ['webgpu', 'wasm']);
  assert.equal(p.threadsRequested, 4);
  assert.equal(p.threadsApplied, 4);
  assert.equal(p.jsep['ort-wasm-simd-threaded.jsep.mjs'], 200);
  assert.equal(p.jsep['ort-wasm-simd-threaded.jsep.wasm'], 200);
  restore();
});

await check('not isolated: threads forced to 1, SAB still reported honestly', async () => {
  globalThis.crossOriginIsolated = false;
  setNavigator({ hardwareConcurrency: 4 });
  globalThis.fetch = async () => ({ status: 200 });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 4, timeouts: FAST });
  assert.equal(p.crossOriginIsolated, false);
  assert.equal(p.threadsApplied, 1);
  assert.equal(p.gpuInNavigator, false);
  assert.equal(p.gpuAdapter, 'n/a');
  restore();
});

await check('SharedArrayBuffer absent: typeof undefined, no throw', async () => {
  globalThis.crossOriginIsolated = false;
  delete globalThis.SharedArrayBuffer;
  setNavigator({ hardwareConcurrency: 4 });
  globalThis.fetch = async () => ({ status: 200 });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 2, timeouts: FAST });
  assert.equal(p.sharedArrayBuffer, 'undefined');
  assert.equal(p.threadsApplied, 1);
  restore();
});

await check('GPU present but adapter null is reported, not hidden', async () => {
  globalThis.crossOriginIsolated = true;
  setNavigator({
    hardwareConcurrency: 4,
    gpu: { requestAdapter: async () => null },
  });
  globalThis.fetch = async () => ({ status: 200 });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 2, timeouts: FAST });
  assert.equal(p.gpuInNavigator, true);
  assert.equal(p.gpuAdapter, 'null');
  restore();
});

await check('requestAdapter that never resolves reports timeout, probe returns', async () => {
  globalThis.crossOriginIsolated = true;
  setNavigator({
    hardwareConcurrency: 4,
    gpu: { requestAdapter: () => new Promise(() => {}) },
  });
  globalThis.fetch = async () => ({ status: 200 });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({
    wasmPaths: WASM_PATHS, threads: 2,
    timeouts: { adapterMs: 50, sabMs: 200, fetchMs: 200 },
  });
  assert.equal(p.gpuAdapter, 'timeout');
  restore();
});

await check('JSEP 404 is reported per file (mjs 404, wasm 200)', async () => {
  globalThis.crossOriginIsolated = true;
  setNavigator({ hardwareConcurrency: 4 });
  globalThis.fetch = async (url) => ({
    status: String(url).endsWith('.jsep.mjs') ? 404 : 200,
  });
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 2, timeouts: FAST });
  assert.equal(p.jsep['ort-wasm-simd-threaded.jsep.mjs'], 404);
  assert.equal(p.jsep['ort-wasm-simd-threaded.jsep.wasm'], 200);
  restore();
});

await check('fetch throwing is reported as error, probe still returns', async () => {
  globalThis.crossOriginIsolated = true;
  setNavigator({ hardwareConcurrency: 4 });
  globalThis.fetch = async () => { throw new Error('network down'); };
  const { runEnvProbe } = await loadProbe();
  const p = await runEnvProbe({ wasmPaths: WASM_PATHS, threads: 2, timeouts: FAST });
  assert.match(p.jsep['ort-wasm-simd-threaded.jsep.mjs'], /^error:/);
  assert.match(p.jsep['ort-wasm-simd-threaded.jsep.wasm'], /^error:/);
  restore();
});

await check('missing wasmPaths throws (bridge posts this as the error)', async () => {
  const { runEnvProbe } = await loadProbe();
  await assert.rejects(runEnvProbe({ threads: 2 }), /wasmPaths is required/);
  restore();
});

restore();
console.log(`env-probe tests: ${failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`}`);
process.exit(failures === 0 ? 0 : 1);
