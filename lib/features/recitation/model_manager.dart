// Downloads + verifies the Tilawa model assets, and tracks install status.
//
// Source of truth for hashes/sizes: docs/model-card.md in yazinsai/tilawa
// (re-verified 2026-11-25 against the live registry + the downloaded files):
//   lite: spliced-clean-lite@1-int8, 24,650,054 bytes,
//         sha256 4974de78d3c35d2542e7a24d99b747e1160d6e31e366fb68492b74a789890f1b
//   full: spliced-clean@1-int8, 67,759,744 bytes,
//         sha256 714e98addee73b1b8781ad7d99b6d3c745acd9116638baf4e12891f53a15af1b
//   ref:  ref-v2.json, 4,749,281 bytes,
//         sha256 f236384ea91e81ad554ba2777bc4073c3ff41e34120343a8a474571c577b7727
//         — downloaded 2026-11-25 from the same URL the app downloads
//         from (https://tilawa.dev/v1/reference/ref-v2.json), 6236 ayahs,
//         version "ref-v2". Pinned here since Phase 2 (2.5): before that
//         the reference had NO pinned hash and was only checked by ayah
//         count, and only when first downloaded.
//   wasm: onnxruntime-web 1.30.0 from the jsDelivr CDN mirror, downloaded
//         2026-11-25 from the same URLs the app downloads from:
//         ort-wasm-simd-threaded.mjs, 24,381 bytes,
//           sha256 e13f7f94fc51b4ca72b12faeb1ee95f4ace6dfbc8939bc718aabdc0a27c4299b
//         ort-wasm-simd-threaded.wasm, 14,239,897 bytes,
//           sha256 3398c10d07d229bd91b364548e130e0e51a8e5704b88c7c083ebbeb78842dee2
//
// Downloads happen ONCE, on explicit user request, from https://tilawa.dev/v1/
// (model + reference) and from the jsDelivr CDN mirror of onnxruntime-web
// (the 2 WASM runtime files — see kOrtWasmFiles below).
// After that the app works fully offline (airplane mode). Nothing is ever
// downloaded silently in the background.
//
// Resumable downloads (Phase 2, 2.5): every file downloads through
// ResumableDownload (resumable_download.dart) — the same mechanism as
// lib/features/packages/download_manager.dart (.part file + HTTP Range +
// SHA-256 before the atomic rename). An interrupted download resumes from
// its .part file instead of starting over; cancelDownload() stops a
// running download and keeps the .part for later resume.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'resumable_download.dart';
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

/// Pinned reference identity (Phase 2, 2.5). The file is re-verified
/// against these on every status() call and re-downloaded on mismatch —
/// a stale or corrupt ref-v2.json can no longer sit undetected.
const kReferenceBytes = 4749281;
const kReferenceSha256 =
    'f236384ea91e81ad554ba2777bc4073c3ff41e34120343a8a474571c577b7727';

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

/// Pinned WASM identity (Phase 2, 2.5): exact bytes + SHA-256 of the files
/// downloaded 2026-11-25 from the jsDelivr URLs above. Verified by size
/// at download time and by ortWasmReady(), and by size + SHA in status().
class OrtWasmAsset {
  const OrtWasmAsset({
    required this.name,
    required this.bytes,
    required this.sha256,
  });
  final String name;
  final int bytes;
  final String sha256;
}

const kOrtWasmAssets = [
  OrtWasmAsset(
    name: 'ort-wasm-simd-threaded.mjs',
    bytes: 24381,
    sha256:
        'e13f7f94fc51b4ca72b12faeb1ee95f4ace6dfbc8939bc718aabdc0a27c4299b',
  ),
  OrtWasmAsset(
    name: 'ort-wasm-simd-threaded.wasm',
    bytes: 14239897,
    sha256:
        '3398c10d07d229bd91b364548e130e0e51a8e5704b88c7c083ebbeb78842dee2',
  ),
];

int get kOrtWasmTotalBytes =>
    kOrtWasmAssets.fold(0, (sum, a) => sum + a.bytes);

class ModelManager {
  ModelManager._(this._dir);
  final Directory _dir;

  static Future<ModelManager> create() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/tilawa-models');
    await dir.create(recursive: true);
    return ModelManager._(dir);
  }

  /// Tests only: build a manager over an explicit directory.
  factory ModelManager.forTest(Directory dir) => ModelManager._(dir);

  /// Whether the engine bundle (assets/web/bundle.js) exists in THIS
  /// build. Set once at app startup by main.dart (rootBundle.load):
  ///   true  = bundle present and non-empty (CI-built APK),
  ///   false = bundle absent (local dev build — the web bundle is built
  ///           by CI only, so the engine genuinely cannot load there),
  ///   null  = not checked yet (status() then skips the bundle check
  ///           instead of blocking on an unknown).
  static bool? bundleAvailable;

  ResumableDownload? _activeDownload;

  /// True while a download() call is in progress.
  bool get isDownloading => _activeDownload != null;

  /// Cancels a running download() (keeps the .part file for resume).
  /// Safe when nothing is downloading.
  void cancelDownload() => _activeDownload?.cancel();

  File modelFile(String tier) {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    return File('${_dir.path}/${asset.fileName}');
  }

  File get referenceFile => File('${_dir.path}/$kReferenceFile');

  Directory get ortDir => Directory('${_dir.path}/ort/$kOrtWebVersion');

  /// True only when the onnxruntime-web files the 1.30.0 loader needs are
  /// present with their exact pinned sizes in <modelDir>/ort/<version>/
  /// (where LocalServer serves them from). Checked before load() so a
  /// missing runtime fails loudly with an actionable message instead of a
  /// cryptic bridge error. Size-only by design (fast, called on every
  /// status refresh); the full size + SHA check is [ortWasmVerified],
  /// used by [status].
  Future<bool> ortWasmReady() async {
    for (final asset in kOrtWasmAssets) {
      final f = File('${ortDir.path}/${asset.name}');
      if (!await f.exists() || await f.length() != asset.bytes) {
        return false;
      }
    }
    return true;
  }

  /// Full WASM verification: pinned size + pinned SHA-256 for both files.
  /// Used by [status]; slower than [ortWasmReady] (hashes ~14 MB).
  Future<bool> ortWasmVerified() async {
    for (final asset in kOrtWasmAssets) {
      final f = File('${ortDir.path}/${asset.name}');
      if (!await f.exists() || await f.length() != asset.bytes) {
        return false;
      }
      if (!await verifyFile(f, asset.sha256)) return false;
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

  /// True only when the reference exists with its pinned size + SHA-256
  /// and parses as JSON with exactly 6236 ayahs. Any failure (missing,
  /// wrong size/hash, unparsable, wrong ayah count) returns false — the
  /// caller re-downloads instead of trusting a stale file.
  Future<bool> referenceOk() async {
    try {
      final f = referenceFile;
      if (!await f.exists() || await f.length() != kReferenceBytes) {
        return false;
      }
      if (!await verifyFile(f, kReferenceSha256)) return false;
      final decoded =
          jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final ayahs = decoded['ayahs'] as List;
      return ayahs.length == 6236;
    } catch (_) {
      return false;
    }
  }

  /// Full readiness: the model file + the reference + the WASM runtime +
  /// (when checked at startup) the engine bundle must ALL be verified
  /// before «جاهز» is shown. Before Phase 2 this checked the model file
  /// alone, so «مثبَّت — جاهز» could hide a corrupt reference, broken
  /// WASM, or a build without bundle.js.
  Future<ModelInfo> status(String tier) async {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    final bundleOk = bundleAvailable;
    if (bundleOk == false) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'حزمة المحرك (bundle.js) غير موجودة في هذا البناء — '
            'التسميع غير متاح حتى يُبنى التطبيق مع حزمة الويب (CI).',
        bundleOk: false,
      );
    }
    final file = modelFile(tier);
    if (!await file.exists()) {
      return ModelInfo(
        status: ModelStatus.notInstalled,
        tier: tier,
        bundleOk: bundleOk,
      );
    }
    final bytes = await file.length();
    if (bytes != asset.bytes) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'حجم النموذج لا يطابق السجل ($bytes ≠ ${asset.bytes})',
        bundleOk: bundleOk,
      );
    }
    if (!await verifyFile(file, asset.sha256)) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'بصمة SHA-256 لا تطابق — الملف تالف أو مزوَّر',
        bundleOk: bundleOk,
      );
    }
    if (!await referenceOk()) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'المرجع (ref-v2.json) غائب أو تالف — أعد تنزيله من صفحة '
            '«النموذج» (يُعاد تنزيله تلقائياً عند الضغط على تنزيل).',
        bundleOk: bundleOk,
      );
    }
    if (!await ortWasmVerified()) {
      return ModelInfo(
        status: ModelStatus.failed,
        tier: tier,
        error: 'ملفات تشغيل المحرك (WASM) غائبة أو تالفة — أعد تنزيلها '
            'من صفحة «النموذج».',
        bundleOk: bundleOk,
      );
    }
    return ModelInfo(
      status: ModelStatus.ready,
      tier: tier,
      version: '${asset.modelId}@${asset.version}',
      bytes: bytes,
      sha256Short: asset.sha256.substring(0, 12),
      ortBytes: await ortBytes(),
      referenceOk: true,
      wasmOk: true,
      bundleOk: bundleOk,
    );
  }

  /// Downloads tier + reference + onnxruntime-web WASM files, verifying
  /// SHA-256 of every file before installing it. Throws
  /// [SpeechEngineException] on any mismatch or network failure.
  /// Resumable: an interrupted download continues from its .part file on
  /// the next call; cancelDownload() stops it and keeps the .part.
  /// The reference is re-verified (pinned SHA + 6236 ayahs) on every
  /// call and re-downloaded on any mismatch — a corrupt file already on
  /// disk is never trusted. [onProgress] reports overall 0..1 across
  /// all three phases.
  Future<void> download({
    required String tier,
    void Function(double fraction)? onProgress,
  }) async {
    final asset = tier == 'lite' ? kLiteModel : kFullModel;
    final total =
        asset.bytes + kReferenceBytes + kOrtWasmTotalBytes;
    var completed = 0;
    void Function(int, int?) progressFor(int base) =>
        (received, _) {
          onProgress?.call(
              ((base + received) / total).clamp(0.0, 1.0));
        };

    final downloader = ResumableDownload();
    _activeDownload = downloader;
    try {
      // 1. Model.
      await downloader.downloadChecked(
        url: Uri.parse(asset.url),
        dest: modelFile(tier),
        expectedBytes: asset.bytes,
        expectedSha256: asset.sha256,
        onProgress: progressFor(completed),
      );
      completed += asset.bytes;
      onProgress?.call(completed / total);
      // 2. Reference — re-verified every run, re-downloaded on mismatch.
      if (!await referenceOk()) {
        await downloader.downloadChecked(
          url: Uri.parse(kReferenceUrl),
          dest: referenceFile,
          expectedBytes: kReferenceBytes,
          expectedSha256: kReferenceSha256,
          onProgress: progressFor(completed),
        );
        if (!await referenceOk()) {
          await referenceFile.delete().catchError((_) => referenceFile);
          throw SpeechEngineException(
              'المرجع بعد التنزيل لا يحتوي 6236 آية أو بصمته لا تطابق');
        }
      }
      completed += kReferenceBytes;
      onProgress?.call(completed / total);
      // 3. WASM runtime files.
      await _downloadOrtWasm(
        downloader: downloader,
        base: completed,
        total: total,
        onProgress: onProgress,
      );
      completed += kOrtWasmTotalBytes;
      onProgress?.call(1.0);
    } finally {
      if (identical(_activeDownload, downloader)) _activeDownload = null;
    }
  }

  /// Downloads any missing or corrupt onnxruntime-web WASM file into
  /// <modelDir>/ort/<version>/ — the directory LocalServer serves as /ort/
  /// and the bridge passes as wasmPaths. Without these files the engine
  /// cannot load at all (see the note on kOrtWasmFiles above).
  /// Files already present with pinned size + SHA are skipped.
  Future<void> _downloadOrtWasm({
    required ResumableDownload downloader,
    required int base,
    required int total,
    required void Function(double fraction)? onProgress,
  }) async {
    await ortDir.create(recursive: true);
    var done = 0;
    for (final asset in kOrtWasmAssets) {
      final dest = File('${ortDir.path}/${asset.name}');
      await downloader.downloadChecked(
        url: Uri.parse('$kOrtBaseUrl/${asset.name}'),
        dest: dest,
        expectedBytes: asset.bytes,
        expectedSha256: asset.sha256,
        onProgress: (received, _) {
          onProgress?.call(
              ((base + done + received) / total).clamp(0.0, 1.0));
        },
      );
      done += asset.bytes;
      onProgress?.call(((base + done) / total).clamp(0.0, 1.0));
    }
  }

  static Future<bool> verifyFile(File file, String expectedSha256) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedSha256;
  }
}
