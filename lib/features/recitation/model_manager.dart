// Downloads + verifies the Tilawa model assets, and tracks install status.
//
// Source of truth for hashes/sizes: docs/model-card.md in yazinsai/tilawa
// (re-verified 2026-11-25 against the live registry + the downloaded files):
//   lite: spliced-clean-lite@1-int8, 24,650,054 bytes,
//         sha256 4974de78d3c35d2542e7a24d99b747e1160d6e31e366fb68492b74a789890f1b
//   full: spliced-clean@1-int8, 67,759,744 bytes,
//         sha256 714e98addee73b1b8781ad7d99b6d3c745acd9116638baf4e12891f53a15af1b
//   ref:  ref-v2.json (4,749,281 bytes at check time; sha256 is NOT pinned by
//         the model card — it is verified by byte count + JSON schema check
//         in tools/check_ref_schema.py, and by the SDK's bundled registry).
//
// Downloads happen ONCE, on explicit user request, from https://tilawa.dev/v1/
// (model + reference) and from the jsDelivr CDN mirror of onnxruntime-web
// (the 2 WASM runtime files — see kOrtWasmFiles below).
// After that the app works fully offline (airplane mode). Nothing is ever
// downloaded silently in the background.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'speech_engine.dart';

class ModelAsset {
  const ModelAsset({
    required this.tier,
    required this.modelId,
    required this.version,
    required this.bytes,
    required this.sha256,
  });

  final String tier; // "lite" | "full"
  final String modelId;
  final String version;
  final int bytes;
  final String sha256;

  String get fileName => 'model-$tier.onnx';
  String get url =>
      'https://tilawa.dev/v1/models/$modelId/$version/model.onnx';
}

const kLiteModel = ModelAsset(
  tier: 'lite',
  modelId: 'spliced-clean-lite',
  version: '1-int8',
  bytes: 24650054,
  sha256:
      '4974de78d3c35d2542e7a24d99b747e1160d6e31e366fb68492b74a789890f1b',
);

const kFullModel = ModelAsset(
  tier: 'full',
  modelId: 'spliced-clean',
  version: '1-int8',
  bytes: 67759744,
  sha256:
      '714e98addee73b1b8781ad7d99b6d3c745acd9116638baf4e12891f53a15af1b',
);

const kReferenceUrl = 'https://tilawa.dev/v1/reference/ref-v2.json';
const kReferenceFile = 'ref-v2.json';

/// WASM files of onnxruntime-web, self-hosted. The version MUST match the
/// version the web bundle was built against (see web/package.json).
/// tools/download_assets.py downloads the same version from the jsDelivr CDN
/// mirror of the onnxruntime-web npm package — never from tilawa.dev at
/// runtime (the app must not depend on tilawa.dev after first install).
///
/// VERIFIED 2026-11-25 against the live jsDelivr listing: onnxruntime-web
/// 1.30.0 (and every version back to 1.19.0) ships ONLY simd-threaded
/// builds — there is NO ort-wasm-simd.wasm / ort-wasm.wasm any more, so the
/// old 4-file list 404'd on the phone (poc-9). The threaded build needs
/// SharedArrayBuffer, which needs cross-origin isolation — LocalServer
/// therefore sends COOP: same-origin + COEP: require-corp on every
/// response (see lib/local_server.dart). If the WebView still reports
/// crossOriginIsolated == false, the engine cannot load and the PoC must
/// record that as a NO-GO data point (do NOT silently fall back).
/// The .mjs is the Emscripten loader glue the runtime fetches from
/// wasmPaths alongside the .wasm; both files are required.
/// Same 2 files as tools/download_assets.py ORT_WASM_FILES — keep both
/// lists in sync.
const kOrtWebVersion = '1.30.0';
const kOrtWasmFiles = [
  'ort-wasm-simd-threaded.mjs',
  'ort-wasm-simd-threaded.wasm',
];
const kOrtBaseUrl =
    'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist';

class ModelManager {
  ModelManager._(this._dir);
  final Directory _dir;

  static Future<ModelManager> create() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/tilawa-models');
    await dir.create(recursive: true);
    return ModelManager._(dir);
  }

  File modelFile(String tier) {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    return File('${_dir.path}/${asset.fileName}');
  }

  File get referenceFile => File('${_dir.path}/$kReferenceFile');

  Directory get ortDir => Directory('${_dir.path}/ort/$kOrtWebVersion');

  /// True only when the onnxruntime-web files the 1.30.0 loader needs are
  /// present and non-empty in <modelDir>/ort/<version>/ (where LocalServer
  /// serves them from). Checked before load() so a missing runtime fails
  /// loudly with an actionable message instead of a cryptic bridge error.
  Future<bool> ortWasmReady() async {
    for (final name in kOrtWasmFiles) {
      final f = File('${ortDir.path}/$name');
      if (!await f.exists() || await f.length() == 0) return false;
    }
    return true;
  }

  /// Total bytes of the downloaded WASM files (0 when not installed).
  Future<int> ortBytes() async {
    var total = 0;
    for (final name in kOrtWasmFiles) {
      final f = File('${ortDir.path}/$name');
      if (await f.exists()) total += await f.length();
    }
    return total;
  }

  Future<ModelInfo> status(String tier) async {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    final file = modelFile(tier);
    if (!await file.exists()) {
      return ModelInfo(status: ModelStatus.notInstalled, tier: tier);
    }
    final bytes = await file.length();
    if (bytes != asset.bytes) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'حجم النموذج لا يطابق السجل ($bytes ≠ ${asset.bytes})',
      );
    }
    final ok = await verifyFile(file, asset.sha256);
    if (!ok) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'بصمة SHA-256 لا تطابق — الملف تالف أو مزوَّر',
      );
    }
    return ModelInfo(
      status: ModelStatus.ready,
      tier: tier,
      version: '${asset.modelId}@${asset.version}',
      bytes: bytes,
      sha256Short: asset.sha256.substring(0, 12),
      ortBytes: await ortBytes(),
    );
  }

  /// Downloads tier + reference (if missing) + onnxruntime-web WASM files,
  /// verifying SHA-256 of the model. Throws [SpeechEngineException] on any
  /// mismatch or network failure. The reference has no pinned SHA in the
  /// model card: it is verified by byte count (> 4 MB) + JSON schema check
  /// (see check_ref_schema.py). The WASM files have no pinned hash either:
  /// they are verified present + non-empty (a corrupt WASM fails loudly at
  /// loadWebModel and is reported as a load error, not silent wrong data).
  Future<void> download({
    required String tier,
    void Function(double fraction)? onProgress,
  }) async {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    await _downloadChecked(
      url: asset.url,
      dest: modelFile(tier),
      expectedBytes: asset.bytes,
      expectedSha256: asset.sha256,
      onProgress: onProgress,
    );
    if (!await referenceFile.exists()) {
      await _downloadReference();
    }
    await _downloadOrtWasm();
  }

  /// Downloads any missing onnxruntime-web WASM file into
  /// <modelDir>/ort/<version>/ — the directory LocalServer serves as /ort/
  /// and the bridge passes as wasmPaths. Without these files the engine
  /// cannot load at all (see the note on kOrtWasmFiles above).
  Future<void> _downloadOrtWasm() async {
    await ortDir.create(recursive: true);
    for (final name in kOrtWasmFiles) {
      final dest = File('${ortDir.path}/$name');
      if (await dest.exists() && await dest.length() > 0) continue;
      final tmp = File('${dest.path}.tmp');
      final req = await HttpClient()
          .getUrl(Uri.parse('$kOrtBaseUrl/$name'));
      final res = await req.close();
      if (res.statusCode != 200) {
        await tmp.delete().catchError((_) => tmp);
        throw SpeechEngineException(
            'فشل تنزيل ملف التشغيل $name: HTTP ${res.statusCode}');
      }
      final sink = tmp.openWrite();
      await sink.addStream(res);
      await sink.close();
      if (await tmp.length() == 0) {
        await tmp.delete();
        throw SpeechEngineException(
            'ملف التشغيل $name نُزِّل فارغاً — أعد المحاولة');
      }
      await tmp.rename(dest.path);
    }
  }

  Future<void> _downloadReference() async {
    final tmp = File('${referenceFile.path}.tmp');
    final res = await http.get(Uri.parse(kReferenceUrl));
    if (res.statusCode != 200) {
      throw SpeechEngineException(
          'فشل تنزيل المرجع: HTTP ${res.statusCode}');
    }
    await tmp.writeAsBytes(res.bodyBytes);
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
    final ayahs = decoded['ayahs'] as List;
    if (ayahs.length != 6236) {
      await tmp.delete();
      throw SpeechEngineException(
          'المرجع لا يحتوي 6236 آية (وجد ${ayahs.length})');
    }
    await tmp.rename(referenceFile.path);
  }

  Future<void> _downloadChecked({
    required String url,
    required File dest,
    required int expectedBytes,
    required String expectedSha256,
    void Function(double fraction)? onProgress,
  }) async {
    final tmp = File('${dest.path}.tmp');
    final req = await HttpClient().getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw SpeechEngineException('فشل التنزيل: HTTP ${res.statusCode}');
    }
    final sink = tmp.openWrite();
    var received = 0;
    await for (final chunk in res) {
      received += chunk.length;
      sink.add(chunk);
      onProgress?.call(received / expectedBytes);
    }
    await sink.close();
    if (received != expectedBytes) {
      await tmp.delete();
      throw SpeechEngineException(
          'حجم التنزيل لا يطابق ($received ≠ $expectedBytes)');
    }
    if (!await verifyFile(tmp, expectedSha256)) {
      await tmp.delete();
      throw SpeechEngineException('بصمة SHA-256 لا تطابق بعد التنزيل');
    }
    await tmp.rename(dest.path);
  }

  static Future<bool> verifyFile(File file, String expectedSha256) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedSha256;
  }
}
