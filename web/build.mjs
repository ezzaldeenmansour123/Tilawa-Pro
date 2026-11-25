// esbuild bundler for the Pro web bridge.
// Output: ../assets/web/bundle.js (loaded by assets/web/tilawa.html).
// The bundle contains @tilawa/core/web + the onnxruntime-web JS glue.
// The .wasm binaries and the ONNX model are NOT bundled: they are served
// by the Dart localhost server from the downloaded model directory
// (see lib/local_server.dart) and referenced via wasmPaths / modelUrl.

import * as esbuild from 'esbuild';

await esbuild.build({
  entryPoints: ['src/bridge.js'],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['chrome110'],
  outfile: '../assets/web/bundle.js',
  sourcemap: false,
  minify: true,
  logLevel: 'info',
});

console.log('bundle written: ../assets/web/bundle.js');
