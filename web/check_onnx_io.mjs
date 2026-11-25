// ONNX I/O verification for the Tilawa recitation models.
//
// Usage (from web/):
//   node check_onnx_io.mjs --model <path/to/model.onnx> --manifest <path/to/manifest.json> [--tier lite|full]
//
// What this checks (DEV ENVIRONMENT ONLY):
//   1. A REAL onnxruntime-node InferenceSession can be created from the
//      .onnx file, with the SAME session options @tilawa/core's Node loader
//      uses (loadNodeModel -> ortBackend: executionProviders ["cpu"],
//      intraOpNumThreads 1, graphOptimizationLevel "all").
//   2. The session's input/output names, dtypes and shapes match EXACTLY
//      what @tilawa/core expects to feed and read (see EXPECTED I/O below).
//   3. One inference run succeeds with feeds built EXACTLY like the web
//      loader's warmup probe (loadWebModel -> warmup in @tilawa/core
//      dist/runtime/web.js): x filled with the manifest padValue, every
//      manifest state zero-filled — and the outputs the listener needs
//      (log_probs + new_<state> per state) come back with the right
//      type/shape.
//   4. A SECOND, chained inference run: the same silence-shaped x, but
//      states fed from run 1's new_<state> outputs — exactly how the
//      listener chains steps at runtime — with the outputs verified
//      again, plus log_probs probability validity (finite, <= 0,
//      exp() sums to ~1 per frame) and proof the chained states moved
//      from zero (real stateful computation, not a shape-correct stub).
//
// EXPECTED I/O — measured from @tilawa/core 1.0.0-rc.1
// (web/node_modules/@tilawa/core/dist/runtime/{web,listener,node}.js):
//   - Feature extraction happens in JS BEFORE the model: Fbank
//     (dist/runtime/fbank.js) turns 16 kHz PCM into 80-dim log-mel frames
//     (25 ms Povey window, 10 ms shift, high_freq -400, snip_edges,
//     per-frame DC removal, pre-emphasis 0.97). The model NEVER sees audio.
//   - Per inference step the listener (dist/runtime/listener.js) feeds:
//       x: float32 [1, window, fbank.mels]  (window=45, mels=80 -> [1,45,80])
//       + one feed per manifest `states` entry: its name, dtype and shape,
//         zero-filled on the first step, then updated from the previous
//         step's outputs.
//     and reads:
//       log_probs: float32, last dim == vocab (tokens.length + 1 = 43),
//         data length divisible by vocab (one row per output frame)
//       new_<state>: same dtype and dims as the corresponding state input.
//   - The web warmup probe feeds x filled with fbank.padValue (-23.0259)
//     and all states zero-filled, then runs once; a failure there surfaces
//     before any session starts. This script reproduces that probe exactly.
//   - The Node loader (loadNodeModel) does NOT warm up; the poc.yml
//     node-smoke test covers the Node path with a real silence session.
//
// Exit code: 0 = session created AND I/O matches AND probe run + output
// verification passed. 1 = session-creation failure or ANY I/O mismatch
// or probe/output failure. 2 = usage / missing files.
//
// NOTE (read before drawing conclusions): a PASS here answers ONLY
// "does the session create and does the I/O match" in this dev
// environment. It NEVER proves tasmee' works on the phone — the phone
// path (WebView + onnxruntime-web/WASM + microphone + Dart bridge) is
// verified by the separate on-device phone protocol, not by this file.
// More precisely: this script validates the MODEL (I/O + real chained
// inference) via onnxruntime-node on the CPU. It does NOT validate the
// WebView backend: it never loads onnxruntime-web, never touches a
// wasmPaths URL, never fetches a JSEP file, never runs in a WebView,
// and never checks crossOriginIsolated / SharedArrayBuffer /
// navigator.gpu. A PASS here is compatible with the phone failing on
// any of those — which is exactly what happened on pro-build-28 (the
// model was fine; the JSEP runtime files were missing).
// NO NETWORK: this script reads only the local --model / --manifest
// files given on its command line. It makes no HTTP request to any
// host — no CDN, no tilawa.dev — at any point. The same holds at
// runtime: the bridge loads model, reference and WASM only from the
// localhost server (127.0.0.1).

import { createHash } from 'node:crypto';
import { createReadStream, readFileSync, statSync } from 'node:fs';
import * as ort from 'onnxruntime-node';

const DISCLAIMER =
  'DEV ENVIRONMENT ONLY: this answers "does the session create and does ' +
  'the I/O match" — it NEVER proves tasmee\' works on the phone.';

function usage() {
  console.error(
    'Usage: node check_onnx_io.mjs --model <model.onnx> --manifest <manifest.json> [--tier lite|full] [--threads 1]',
  );
}

function parseArgs(argv) {
  const out = { threads: 1 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--model' || a === '--manifest' || a === '--tier' || a === '--threads') {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) {
        console.error(`Missing value for ${a}`);
        usage();
        process.exit(2);
      }
      out[a.slice(2)] = a === '--threads' ? Number(v) : v;
    } else if (a === '--help' || a === '-h') {
      usage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${a}`);
      usage();
      process.exit(2);
    }
  }
  if (!out.model || !out.manifest) {
    console.error('Missing required --model and/or --manifest.');
    usage();
    process.exit(2);
  }
  if (!Number.isInteger(out.threads) || out.threads < 1) {
    console.error('--threads must be a positive integer.');
    process.exit(2);
  }
  return out;
}

function sha256File(path) {
  return new Promise((resolve, reject) => {
    const h = createHash('sha256');
    createReadStream(path)
      .on('data', (c) => h.update(c))
      .on('error', reject)
      .on('end', () => resolve(h.digest('hex')));
  });
}

// onnxruntime-node public metadata entries are {name, type, dimensions};
// the binding-level shape is {name, type: number, shape, symbolicDimensions}.
// Normalise both to {name, type: string, dims: (number|string)[]}.
const NUMERIC_TYPES = {
  0: 'undefined', 1: 'float32', 2: 'uint8', 3: 'int8', 4: 'uint16', 5: 'int16',
  6: 'int32', 7: 'int64', 8: 'string', 9: 'bool', 10: 'float16', 11: 'float64',
  12: 'uint32', 13: 'uint64', 14: 'complex64', 15: 'complex128', 16: 'bfloat16',
  17: 'float8e4m3fn', 18: 'float8e4m3fnuz', 19: 'float8e5m2', 20: 'float8e5m2fnuz',
  21: 'uint4', 22: 'int4',
};

function normaliseMetadata(meta) {
  const out = new Map();
  const entries = Array.isArray(meta)
    ? meta
    : Object.values(meta ?? {});
  for (const e of entries) {
    if (!e || typeof e.name !== 'string') continue;
    const type = typeof e.type === 'string'
      ? e.type
      : (NUMERIC_TYPES[e.type] ?? `type#${e.type}`);
    const dims = Array.isArray(e.dimensions)
      ? e.dimensions
      : Array.isArray(e.shape)
        ? e.shape.map((d, i) => {
          const sym = Array.isArray(e.symbolicDimensions) ? e.symbolicDimensions[i] : '';
          return d === 0 && sym ? sym : d;
        })
        : [];
    out.set(e.name, { name: e.name, type, dims });
  }
  return out;
}

function dimsEqual(measured, expected) {
  // Returns {ok, dynamic: string[]} — a symbolic (string) measured dim
  // accepts the expected value at run time; a concrete measured dim must
  // equal the expected value. Rank must match exactly.
  if (measured.length !== expected.length) return { ok: false, dynamic: [] };
  const dynamic = [];
  for (let i = 0; i < expected.length; i++) {
    const m = measured[i];
    if (typeof m === 'string') {
      dynamic.push(`dim[${i}]='${m}' (expected ${expected[i]})`);
    } else if (m !== expected[i]) {
      return { ok: false, dynamic };
    }
  }
  return { ok: true, dynamic };
}

function typedArray(dtype, n) {
  switch (dtype) {
    case 'float32': return new Float32Array(n);
    case 'float64': return new Float64Array(n);
    case 'int64': return new BigInt64Array(n);
    case 'int32': return new Int32Array(n);
    case 'uint8': return new Uint8Array(n);
    case 'int8': return new Int8Array(n);
    case 'uint32': return new Uint32Array(n);
    case 'int16': return new Int16Array(n);
    case 'uint16': return new Uint16Array(n);
    case 'bool': return new Uint8Array(n);
    default: throw new Error(`unsupported manifest dtype for probe feeds: ${dtype}`);
  }
}

const args = parseArgs(process.argv.slice(2));
const failures = [];
const warnings = [];
const fail = (msg) => { failures.push(msg); console.error(`  FAIL: ${msg}`); };
const warn = (msg) => { warnings.push(msg); console.error(`  WARN: ${msg}`); };

console.log(`ONNX I/O CHECK — model: ${args.model}`);
console.log(`  manifest: ${args.manifest}${args.tier ? ` (tier ${args.tier})` : ''}`);
console.log(`  ${DISCLAIMER}`);

// ---- Load manifest: the source of truth for expected I/O. ----
let manifest;
try {
  manifest = JSON.parse(readFileSync(args.manifest, 'utf8'));
} catch (err) {
  console.error(`FAIL: cannot read manifest ${args.manifest}: ${err.message}`);
  process.exit(2);
}
const modelStat = (() => {
  try {
    return statSync(args.model);
  } catch (err) {
    console.error(`FAIL: cannot stat model ${args.model}: ${err.message}`);
    process.exit(2);
  }
})();
const modelSha = await sha256File(args.model);
const window_ = manifest.window;
const mels = manifest.fbank?.mels;
const padValue = manifest.fbank?.padValue;
const vocab = Array.isArray(manifest.tokens) || typeof manifest.tokens === 'string'
  ? manifest.tokens.length + 1
  : null;
const states = Array.isArray(manifest.states) ? manifest.states : [];
console.log(
  `  manifest id=${manifest.id} arch=${manifest.arch} ` +
  `window=${window_} mels=${mels} padValue=${padValue} vocab=${vocab} states=${states.length}`,
);
console.log(`  model file: ${modelStat.size} bytes, sha256 ${modelSha}`);
if (manifest.bytes !== undefined && manifest.bytes !== modelStat.size) {
  fail(`model size ${modelStat.size} != manifest bytes ${manifest.bytes}`);
}
if (manifest.sha256 && manifest.sha256 !== modelSha) {
  fail(`model sha256 ${modelSha} != manifest sha256 ${manifest.sha256}`);
}
if (!Number.isInteger(window_) || !Number.isInteger(mels) || typeof padValue !== 'number'
  || !Number.isInteger(vocab) || states.length === 0) {
  console.error('FAIL: manifest is missing window / fbank.mels / fbank.padValue / tokens / states.');
  process.exit(2);
}

// ---- Expected I/O (what @tilawa/core feeds and reads). ----
const expectedInputs = new Map([
  ['x', { name: 'x', type: 'float32', dims: [1, window_, mels] }],
  ...states.map((s) => [s.name, { name: s.name, type: s.dtype, dims: s.shape }]),
]);
const expectedOutputs = new Map([
  ['log_probs', { name: 'log_probs', type: 'float32', dims: null }], // dims checked on run output
  ...states.map((s) => [`new_${s.name}`, { name: `new_${s.name}`, type: s.dtype, dims: s.shape }]),
]);
console.log(`  expected inputs: ${expectedInputs.size} (x + ${states.length} states)`);
console.log(`  expected outputs: ${expectedOutputs.size} (log_probs + ${states.length} new_* states)`);

// ---- 1. Create a REAL InferenceSession (same options as loadNodeModel). ----
let session;
const t0 = Date.now();
try {
  session = await ort.InferenceSession.create(args.model, {
    executionProviders: ['cpu'],
    intraOpNumThreads: args.threads,
    graphOptimizationLevel: 'all',
  });
  console.log(`  session creation: OK (${Date.now() - t0} ms, onnxruntime-node ${ort.env?.version ?? 'unknown'})`);
} catch (err) {
  console.error(`  session creation: FAIL — ${err && err.message ? err.message : String(err)}`);
  console.error(`  ${DISCLAIMER}`);
  process.exit(1);
}

// ---- 2. Measure session metadata and compare with expectations. ----
const inMeta = normaliseMetadata(session.inputMetadata);
const outMeta = normaliseMetadata(session.outputMetadata);
console.log(`  measured inputs (${inMeta.size}):`);
for (const [name, m] of inMeta) {
  console.log(`    ${name}: type=${m.type} dims=[${m.dims.join(', ')}]`);
}
console.log(`  measured outputs (${outMeta.size}):`);
for (const [name, m] of outMeta) {
  console.log(`    ${name}: type=${m.type} dims=[${m.dims.join(', ')}]`);
}

console.log('  comparing metadata vs @tilawa/core expectations:');
for (const [name, exp] of expectedInputs) {
  const got = inMeta.get(name);
  if (!got) { fail(`missing expected input '${name}'`); continue; }
  if (got.type !== exp.type) {
    fail(`input '${name}' type=${got.type}, expected ${exp.type}`);
    continue;
  }
  const cmp = dimsEqual(got.dims, exp.dims);
  if (!cmp.ok) {
    fail(`input '${name}' dims=[${got.dims.join(', ')}], expected [${exp.dims.join(', ')}]`);
  } else if (cmp.dynamic.length) {
    warn(`input '${name}' has dynamic dims (${cmp.dynamic.join('; ')}) — accepted, run will use expected shape`);
  } else {
    console.log(`    input '${name}': OK (type=${got.type} dims=[${got.dims.join(', ')}])`);
  }
}
for (const [name, exp] of expectedOutputs) {
  if (exp.dims === null) continue; // log_probs dims are verified on the run output, below
  const got = outMeta.get(name);
  if (!got) { fail(`missing expected output '${name}'`); continue; }
  if (got.type !== exp.type) {
    fail(`output '${name}' type=${got.type}, expected ${exp.type}`);
    continue;
  }
  const cmp = dimsEqual(got.dims, exp.dims);
  if (!cmp.ok) {
    fail(`output '${name}' dims=[${got.dims.join(', ')}], expected [${exp.dims.join(', ')}]`);
  } else if (cmp.dynamic.length) {
    warn(`output '${name}' has dynamic dims (${cmp.dynamic.join('; ')}) — accepted, run output will be checked`);
  } else {
    console.log(`    output '${name}': OK (type=${got.type} dims=[${got.dims.join(', ')}])`);
  }
}
for (const name of inMeta.keys()) {
  if (!expectedInputs.has(name)) fail(`unexpected extra input '${name}' (engine never feeds it)`);
}
for (const name of outMeta.keys()) {
  if (!expectedOutputs.has(name)) fail(`unexpected extra output '${name}' (engine never reads it)`);
}
// log_probs metadata: must exist, float32; dims (if concrete) must end in vocab.
{
  const got = outMeta.get('log_probs');
  if (!got) {
    fail("missing expected output 'log_probs'");
  } else if (got.type !== 'float32') {
    fail(`output 'log_probs' type=${got.type}, expected float32`);
  } else if (got.dims.length > 0) {
    const last = got.dims[got.dims.length - 1];
    if (typeof last === 'number' && last !== vocab) {
      fail(`output 'log_probs' last dim=${last}, expected vocab ${vocab}`);
    } else {
      console.log(`    output 'log_probs': OK (type=float32 dims=[${got.dims.join(', ')}])`);
    }
  } else {
    console.log("    output 'log_probs': OK (type=float32, dims not declared in metadata)");
  }
}

// ---- 3. Probe run: feeds built exactly like the web warmup. ----
console.log('  probe run (warmup feeds: x=padValue, states=zeros):');
const feeds = {};
{
  const xData = new Float32Array(window_ * mels).fill(padValue);
  feeds.x = new ort.Tensor('float32', xData, [1, window_, mels]);
  for (const s of states) {
    const n = s.shape.reduce((a, b) => a * b, 1);
    feeds[s.name] = new ort.Tensor(s.dtype, typedArray(s.dtype, n), s.shape);
  }
}
let out;
const t1 = Date.now();
try {
  out = await session.run(feeds);
  console.log(`  probe run: OK (${Date.now() - t1} ms)`);
} catch (err) {
  fail(`probe run threw: ${err && err.message ? err.message : String(err)}`);
  out = null;
}

// ---- 4. Verify run outputs the way the listener consumes them. ----
if (out) {
  const lp = out.log_probs;
  if (!lp) {
    fail("probe run returned no 'log_probs' output");
  } else {
    const len = lp.data ? lp.data.length : 0;
    const lastDim = lp.dims && lp.dims.length ? lp.dims[lp.dims.length - 1] : null;
    console.log(`    log_probs: type=${lp.type} dims=[${(lp.dims || []).join(', ')}] data.length=${len}`);
    if (lp.type !== 'float32') fail(`log_probs run type=${lp.type}, expected float32`);
    if (lastDim !== null && lastDim !== vocab) {
      fail(`log_probs run last dim=${lastDim}, expected vocab ${vocab}`);
    }
    if (len === 0 || len % vocab !== 0) {
      fail(`log_probs data.length=${len} is not a positive multiple of vocab ${vocab}`);
    } else {
      console.log(`    log_probs: OK (${len / vocab} output frames x vocab ${vocab})`);
    }
  }
  for (const s of states) {
    const o = out[`new_${s.name}`];
    if (!o) { fail(`probe run returned no 'new_${s.name}' output`); continue; }
    if (o.type !== s.dtype) {
      fail(`'new_${s.name}' run type=${o.type}, expected ${s.dtype}`);
      continue;
    }
    const sameDims = Array.isArray(o.dims) && o.dims.length === s.shape.length
      && o.dims.every((d, i) => d === s.shape[i]);
    if (!sameDims) {
      fail(`'new_${s.name}' run dims=[${(o.dims || []).join(', ')}], expected [${s.shape.join(', ')}]`);
    }
  }
  console.log('    new_* state outputs: checked (only failures listed above)');
}

// ---- 5. Chained second inference (NEW 2026-11-26): the real listener
// feeds each step's new_<state> outputs back as the NEXT step's state
// inputs — a single warmup run cannot prove that chaining works. Run a
// second inference on the SAME silence-shaped input (x = padValue, as
// the web warmup uses) but with states taken from run 1's outputs, and
// verify the outputs are structurally valid again. Also verify the
// log_probs are genuine log-probabilities (finite, <= 0, exp() sums to
// ~1 per output frame) and that the chained state outputs actually
// MOVED from their zero inputs — a stub returning zeros would pass a
// shape check but fail here, so this proves real computation happened.
// (Step 3/4 above already ran a real inference — this step extends it
// to the multi-step chaining the listener depends on.)
console.log('  chained run (step 2: states = run-1 outputs, x = padValue):');
let out2 = null;
if (out) {
  const feeds2 = {};
  {
    const xData = new Float32Array(window_ * mels).fill(padValue);
    feeds2.x = new ort.Tensor('float32', xData, [1, window_, mels]);
    for (const s of states) {
      const prev = out[`new_${s.name}`];
      if (!prev) {
        fail(`cannot chain: run 1 returned no 'new_${s.name}'`);
        continue;
      }
      feeds2[s.name] = new ort.Tensor(s.dtype, prev.data, prev.dims);
    }
  }
  const t2 = Date.now();
  try {
    out2 = await session.run(feeds2);
    console.log(`  chained run: OK (${Date.now() - t2} ms)`);
  } catch (err) {
    fail(`chained run threw: ${err && err.message ? err.message : String(err)}`);
  }
  if (out2) {
    const lp2 = out2.log_probs;
    if (!lp2) {
      fail("chained run returned no 'log_probs' output");
    } else {
      const len2 = lp2.data ? lp2.data.length : 0;
      const lastDim2 = lp2.dims && lp2.dims.length ? lp2.dims[lp2.dims.length - 1] : null;
      console.log(`    log_probs: type=${lp2.type} dims=[${(lp2.dims || []).join(', ')}] data.length=${len2}`);
      if (lp2.type !== 'float32') fail(`chained log_probs type=${lp2.type}, expected float32`);
      if (lastDim2 !== null && lastDim2 !== vocab) {
        fail(`chained log_probs last dim=${lastDim2}, expected vocab ${vocab}`);
      }
      if (len2 === 0 || len2 % vocab !== 0) {
        fail(`chained log_probs data.length=${len2} is not a positive multiple of vocab ${vocab}`);
      } else {
        console.log(`    log_probs: OK (${len2 / vocab} output frames x vocab ${vocab})`);
      }
    }
    for (const s of states) {
      const o2 = out2[`new_${s.name}`];
      if (!o2) { fail(`chained run returned no 'new_${s.name}' output`); continue; }
      if (o2.type !== s.dtype) {
        fail(`chained 'new_${s.name}' type=${o2.type}, expected ${s.dtype}`);
        continue;
      }
      const sameDims = Array.isArray(o2.dims) && o2.dims.length === s.shape.length
        && o2.dims.every((d, i) => d === s.shape[i]);
      if (!sameDims) {
        fail(`chained 'new_${s.name}' dims=[${(o2.dims || []).join(', ')}], expected [${s.shape.join(', ')}]`);
      }
    }
    console.log('    chained new_* state outputs: checked (only failures listed above)');
  }
}

// ---- 6. log_probs probability validity (both runs): genuine
// log-softmax output must be finite, <= 0 everywhere, and exp()
// must sum to ~1 per output frame. Shape checks alone cannot catch a
// model returning garbage numbers in the right shape.
for (const [label, result] of [['warmup', out], ['chained', out2]]) {
  if (!result || !result.log_probs) continue;
  const lp = result.log_probs;
  const data = lp.data;
  const frames = data.length / vocab;
  let finite = true;
  let maxVal = -Infinity;
  for (let i = 0; i < data.length; i++) {
    if (!Number.isFinite(data[i])) { finite = false; break; }
    if (data[i] > maxVal) maxVal = data[i];
  }
  if (!finite) {
    fail(`${label} log_probs contain non-finite values`);
    continue;
  }
  if (maxVal > 0) {
    fail(`${label} log_probs contain a positive value (${maxVal}) — not log-probabilities`);
    continue;
  }
  let worstSumErr = 0;
  for (let f = 0; f < frames; f++) {
    let sum = 0;
    for (let v = 0; v < vocab; v++) sum += Math.exp(data[f * vocab + v]);
    worstSumErr = Math.max(worstSumErr, Math.abs(sum - 1));
  }
  console.log(`    ${label} log_probs: finite, max=${maxVal.toFixed(4)} (<= 0), worst per-frame exp-sum error=${worstSumErr.toExponential(2)}`);
  if (worstSumErr > 1e-3) {
    fail(`${label} log_probs per-frame exp() sums deviate from 1 by ${worstSumErr.toExponential(2)} (> 1e-3) — not a log-softmax`);
  }
  // The chained states must have MOVED from their zero inputs: if every
  // new_<state> in the chained run is still all zeros, the model did no
  // stateful computation (or the chaining fed zeros by mistake).
  if (label === 'chained') {
    let anyNonZero = false;
    for (const s of states) {
      const o2 = result[`new_${s.name}`];
      if (!o2 || !o2.data) continue;
      for (let i = 0; i < o2.data.length; i++) {
        if (o2.data[i] !== 0 && o2.data[i] !== 0n) { anyNonZero = true; break; }
      }
      if (anyNonZero) break;
    }
    if (!anyNonZero) {
      fail('chained run: every new_<state> output is still all zeros — no stateful computation happened');
    } else {
      console.log('    chained states: moved from zero inputs (stateful computation confirmed)');
    }
  }
}

try { await session.release?.(); } catch { /* best-effort */ }

console.log(`  warnings: ${warnings.length}, failures: ${failures.length}`);
if (failures.length > 0) {
  console.error('ONNX I/O CHECK: FAIL');
  console.error(`  ${DISCLAIMER}`);
  process.exit(1);
}
console.log('ONNX I/O CHECK: PASS');
console.log(`  ${DISCLAIMER}`);
process.exit(0);
