// مدير التنزيلات — تلاوة
//
// Pure Dart قدر الإمكان: المنطق كله هنا بلا Flutter؛ الواجهة
// (الشاشة) تقرأ الحالات فقط. يعتمد على dart:io وdart:convert
// وpackage:crypto (موجودة في pubspec.yaml).
//
// ما يفعله: قائمة الحزم، عرض الحجم قبل التنزيل، تنزيل بملفات ‎.part
// مع إيقاف/استئناف عبر HTTP Range، حذف حزمة، تحقق SHA-256 لكل ملف
// ولكامل الحزمة، وحالة «متوفر دون إنترنت» لكل حزمة، واحتساب المساحة.
//
// ما لا يفعله: لا تنزيل تلقائي إطلاقاً (كل تنزيل بضغطة مستخدم
// صريحة)؛ لا تنزيل في الخلفية دون إذن؛ لا حذف لمحتوى مثبَّت عند
// تحديث التطبيق؛ لا ملفات صوتية/صور داخل APK.
//
// الحالة: كود مكتوب في 2026-11-25 ولم يُختبر بعد — لا على جهاز
// ولا بـ `dart test` (لا Dart/Flutter SDK في هذه البيئة).
// منطق الاستئناف والتحقق نفسه اختُبر بمحاكاة Python محلية
// (tools/simulate_download.py) — لا كود Dart نفسه. انظر DESIGN.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package_models.dart';

/// مصدر معلومات المساحة الحرة. لا توجد في Dart واجهة قياسية
/// للمساحة الحرة — التطبيق يمرّر تنفيذاً بقناة منصة (MethodChannel)
/// أو إضافة disk_space؛ والتنفيذ الافتراضي هنا يعيد «غير معروف»
/// بدل اختراع رقم. يُربط في Phase 2.
abstract class StorageInfoProvider {
  /// بايتات حرة في وحدة تخزين الحزم، أو null إن تعذّرت المعرفة.
  Future<int?> freeBytes();
}

class UnknownStorageInfoProvider implements StorageInfoProvider {
  @override
  Future<int?> freeBytes() async => null;
}

/// تقدّم التنزيل — يُمرَّر لواجهة المستخدم.
class DownloadProgress {
  final String packageId;
  final int downloadedBytes;
  final int totalBytes;
  final String currentFile;

  const DownloadProgress({
    required this.packageId,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.currentFile,
  });

  double get fraction =>
      totalBytes == 0 ? 0 : (downloadedBytes / totalBytes).clamp(0.0, 1.0);
}

/// نتيجة تحقق ملف واحد.
class FileVerification {
  final String path;
  final bool exists;
  final bool hashMatches;
  final int? actualSize;

  const FileVerification({
    required this.path,
    required this.exists,
    required this.hashMatches,
    this.actualSize,
  });

  bool get ok => exists && hashMatches;
}

/// مدير الحزم. مثيل واحد لكل مجلد حزم في التطبيق.
class DownloadManager {
  /// مجلد الحزم: .../app_documents/packages/
  /// كل حزمة مجلد فرعي باسمه: packages/<packageId>/ + manifest.json
  /// + ملفاتها. السجل: packages/registry.json (كتابة ذرية).
  final Directory packagesDir;

  final HttpClient _http;
  final StorageInfoProvider storageInfo;

  /// السجل المحلي — يُحمَّل من registry.json عند الإنشاء.
  final Map<String, PackageRecord> _records = {};

  /// مهام التنزيل الجارية (للإيقاف): packageId -> اشتراك التنزيل.
  final Map<String, StreamSubscription<List<int>>> _active = {};

  /// مكمِلات اكتمال التنزيل الجاري: packageId -> completer يُكمله
  /// pause() صراحةً، لأن StreamSubscription.asFuture() لا يكتمل عند
  /// إلغاء الاشتراك إطلاقاً (سلوك Dart الموثّق) فيعلق download() للأبد
  /// بعد أي pause() — اكتُشف باختبار test/packages_export_test.dart.
  final Map<String, Completer<void>> _downloadDone = {};

  /// طلبات الإيقاف: packageId -> true إن طلب المستخدم الإيقاف.
  final Set<String> _pauseRequested = {};

  DownloadManager({
    required this.packagesDir,
    HttpClient? httpClient,
    StorageInfoProvider? storageInfo,
  })  : _http = httpClient ?? HttpClient(),
        storageInfo = storageInfo ?? UnknownStorageInfoProvider();

  /// تهيئة: إنشاء المجلد + تحميل السجل. تُستدعى مرة عند إقلاع التطبيق.
  Future<void> init() async {
    await packagesDir.create(recursive: true);
    final regFile = File(_registryPath);
    if (await regFile.exists()) {
      try {
        final raw =
            jsonDecode(await regFile.readAsString()) as Map<String, dynamic>;
        for (final e in (raw['packages'] as List)) {
          final r =
              PackageRecord.fromJson(e as Map<String, dynamic>);
          _records[r.manifest.id] = r;
        }
      } on FormatException {
        // سجل تالف: لا يُحذف ولا يُرمَّم تخميناً — يُحفظ جانباً
        // ويُعاد بناء السجل من الـ manifests الموجودة على القرص.
        await regFile.rename(
            '${regFile.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
        await _rebuildRegistryFromDisk();
      }
    } else {
      await _rebuildRegistryFromDisk();
    }
  }

  String get _registryPath =>
      '${packagesDir.path}${Platform.pathSeparator}registry.json';

  /// إعادة بناء السجل من الـ manifests الموجودة فعلاً على القرص
  /// (بعد تلف السجل أو تحديث التطبيق — لا يحذف محتوى مثبّتاً).
  Future<void> _rebuildRegistryFromDisk() async {
    _records.clear();
    await for (final d in packagesDir.list()) {
      if (d is! Directory) continue;
      final mFile = File(
          '${d.path}${Platform.pathSeparator}manifest.json');
      if (!await mFile.exists()) continue;
      try {
        final m = PackageManifest.fromJsonString(
            await mFile.readAsString());
        _records[m.id] = PackageRecord(
          manifest: m,
          status: PackageStatus.incomplete,
          lastError: 'أُعيد بناء السجل من القرص — يُعاد التحقق',
        );
      } on FormatException {
        continue; // manifest تالف يُتجاهل ولا يُحذف.
      }
    }
    await _saveRegistry();
  }

  /// حفظ السجل ذرياً: ملف مؤقت + إعادة تسمية (نمط needsUpdate
  /// الموجود في db.dart).
  ///
  /// الحفظ متسلسل عبر طابور: حفظان متزامنان (مثلاً pause() أثناء
  /// حفظ download()) يكتبان الملف المؤقت نفسه فيفشل أحدهما عند
  /// إعادة التسمية بـ PathNotFoundException — اكتُشف باختبار
  /// test/packages_export_test.dart.
  Future<void> _saveQueue = Future.value();

  Future<void> _saveRegistry() {
    final run = _saveQueue.then<void>((_) => _saveRegistryNow());
    // لا يُسمَّم الطابور بخطأ سابق: الحفظ التالي يعمل دائماً.
    _saveQueue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _saveRegistryNow() async {
    final tmp = File('$_registryPath.tmp');
    final data = jsonEncode({
      'version': 1,
      'packages': _records.values.map((r) => r.toJson()).toList(),
    });
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(_registryPath);
  }

  // ---------- القراءة ----------

  List<PackageRecord> get records => _records.values.toList();

  PackageRecord? record(String packageId) => _records[packageId];

  /// حالة «متوفر دون إنترنت» لكل حزمة.
  bool isAvailableOffline(String packageId) =>
      _records[packageId]?.availableOffline ?? false;

  /// المساحة المستخدمة بالحزم (بايتات الملفات المكتملة + ‎.part).
  Future<int> usedBytes() async {
    var total = 0;
    await for (final e in packagesDir.list(recursive: true)) {
      if (e is File && !e.path.endsWith('registry.json')) {
        total += await e.length();
      }
    }
    return total;
  }

  /// مساحة حرة (null = غير معروفة — التنفيذ يأتي من المنصة).
  Future<int?> freeBytes() => storageInfo.freeBytes();

  // ---------- التنزيل ----------

  /// بدء/استئناف تنزيل حزمة. يعرض الحجم قبل التنزيل عبر
  /// manifest.totalBytes (على الواجهة عرضه قبل استدعاء هذه الدالة).
  /// لا تنزيل تلقائي: تُستدعى فقط بضغطة مستخدم.
  Future<void> download(
    PackageManifest manifest, {
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    manifest.validate();
    final id = manifest.id;
    if (_active.containsKey(id)) return; // تنزيل جارٍ أصلاً.

    final dir = Directory(
        '${packagesDir.path}${Platform.pathSeparator}$id');
    await dir.create(recursive: true);
    // حفظ الـ manifest داخل مجلد الحزمة أولاً (ليُعاد بناء السجل منه).
    await File('${dir.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(manifest.toJsonString(), flush: true);

    final record = _records.putIfAbsent(
      id,
      () => PackageRecord(manifest: manifest),
    );
    record.status = PackageStatus.downloading;
    record.lastError = null;
    await _saveRegistry();

    try {
      var downloaded = await _downloadedBytesOnDisk(dir, manifest);
      for (final file in manifest.files) {
        if (_pauseRequested.remove(id)) {
          record.status = PackageStatus.paused;
          record.downloadedBytes = downloaded;
          await _saveRegistry();
          return;
        }
        downloaded = await _downloadFile(
          packageId: id,
          dir: dir,
          file: file,
          alreadyDownloadedTotal: downloaded,
          onProgress: (p) => onProgress?.call(DownloadProgress(
            packageId: id,
            downloadedBytes: p,
            totalBytes: manifest.totalBytes,
            currentFile: file.path,
          )),
        );
      }
      // كل الملفات نُزّلت — تحقق نهائي قبل وسمها مثبّتة.
      // إيقاف طُلب أثناء الملف الأخير: لا يُتحقق من حزمة ناقصة.
      if (_pauseRequested.remove(id)) {
        record.status = PackageStatus.paused;
        record.downloadedBytes = downloaded;
        await _saveRegistry();
        return;
      }
      record.status = PackageStatus.verifying;
      await _saveRegistry();
      final ok = await verify(id);
      record.status =
          ok ? PackageStatus.installed : PackageStatus.incomplete;
      if (ok) {
        record.verifiedAt = DateTime.now();
        record.installedAt ??= DateTime.now();
      }
      record.downloadedBytes = manifest.totalBytes;
      await _saveRegistry();
    } on HttpException catch (e) {
      if (_pauseRequested.remove(id)) {
        record.status = PackageStatus.paused;
        record.lastError = null;
        record.downloadedBytes = await _downloadedBytesOnDisk(dir, manifest);
      } else {
        record.status = PackageStatus.failed;
        record.lastError = 'شبكة: ${e.message}';
      }
      await _saveRegistry();
      if (record.status == PackageStatus.paused) return;
      rethrow;
    } catch (e) {
      if (_pauseRequested.remove(id)) {
        // إلغاء الاشتراك أثناء ملف يصل هنا كخطأ — هو إيقاف لا فشل.
        record.status = PackageStatus.paused;
        record.lastError = null;
        record.downloadedBytes = await _downloadedBytesOnDisk(dir, manifest);
        await _saveRegistry();
        return;
      }
      record.status = PackageStatus.failed;
      record.lastError = e.toString();
      await _saveRegistry();
      rethrow;
    } finally {
      _active.remove(id);
    }
  }

  /// إيقاف تنزيل جارٍ: يُغلق الطلب ويُبقي ملفات ‎.part للاستئناف.
  /// لا يحذف ما نُزّل.
  Future<void> pause(String packageId) async {
    _pauseRequested.add(packageId);
    await _active[packageId]?.cancel();
    _active.remove(packageId);
    // إكمال completer التنزيل الجاري: بدونه يعلق await في _downloadFile
    // للأبد لأن asFuture() لا يكتمل عند الإلغاء.
    final done = _downloadDone.remove(packageId);
    if (done != null && !done.isCompleted) done.complete();
    final r = _records[packageId];
    if (r != null && r.status == PackageStatus.downloading) {
      r.status = PackageStatus.paused;
      await _saveRegistry();
    }
  }

  /// استئناف تنزيل متوقف من حيث توقف (HTTP Range).
  Future<void> resume(
    String packageId, {
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final r = _records[packageId];
    if (r == null) throw StateError('لا سجل للحزمة $packageId');
    if (r.status != PackageStatus.paused &&
        r.status != PackageStatus.failed &&
        r.status != PackageStatus.incomplete) {
      return;
    }
    await download(r.manifest, onProgress: onProgress);
  }

  /// حذف حزمة: مجلدها كاملاً + سجلها. تُستدعى فقط بطلب مستخدم.
  /// لا تُستدعى تلقائياً عند تحديث التطبيق أبداً.
  Future<void> delete(String packageId) async {
    await pause(packageId);
    final dir = Directory(
        '${packagesDir.path}${Platform.pathSeparator}$packageId');
    if (await dir.exists()) await dir.delete(recursive: true);
    _records.remove(packageId);
    await _saveRegistry();
  }

  // ---------- التحقق ----------

  /// تحقق SHA-256 لملف واحد على القرص.
  Future<FileVerification> verifyFile(
      Directory packageDir, PackageFile file) async {
    final target =
        File('${packageDir.path}${Platform.pathSeparator}${file.path}');
    if (!await target.exists()) {
      return FileVerification(
          path: file.path, exists: false, hashMatches: false);
    }
    final actualSize = await target.length();
    if (actualSize != file.sizeBytes) {
      return FileVerification(
        path: file.path,
        exists: true,
        hashMatches: false,
        actualSize: actualSize,
      );
    }
    final digest = await _sha256File(target);
    return FileVerification(
      path: file.path,
      exists: true,
      hashMatches: digest == file.sha256.toLowerCase(),
      actualSize: actualSize,
    );
  }

  /// تحقق كامل الحزمة: كل ملف موجود وحجمه وبصمته صحيحان.
  /// يعيد true فقط عند اكتمال كل الملفات. الملفات الغائبة/التالفة
  /// تُسجَّل في missingUpstream لتُعاد محاولتها (أو تُغطى بالاحتياطي).
  Future<bool> verify(String packageId) async {
    final r = _records[packageId];
    if (r == null) return false;
    final dir = Directory(
        '${packagesDir.path}${Platform.pathSeparator}$packageId');
    final missing = <String>[];
    for (final f in r.manifest.files) {
      final v = await verifyFile(dir, f);
      if (!v.ok) missing.add(f.path);
    }
    r.missingUpstream = missing;
    if (missing.isEmpty) {
      r.verifiedAt = DateTime.now();
      if (r.status != PackageStatus.downloading) {
        r.status = PackageStatus.installed;
      }
    } else {
      r.status = PackageStatus.incomplete;
    }
    await _saveRegistry();
    return missing.isEmpty;
  }

  /// تحقق اكتمال قارئ (6236 آية): يعيد قائمة الآيات الغائبة
  /// بصيغة سورة:آية. قارئ بآيات غائبة لا يُوسم مكتملاً أبداً.
  /// (يعتمد على manifest يضم ملفاً لكل آية — انظر reciters.dart.)
  Future<List<String>> verifyReciterCompleteness(String packageId) async {
    final r = _records[packageId];
    if (r == null) return ['لا سجل للحزمة $packageId'];
    final dir = Directory(
        '${packagesDir.path}${Platform.pathSeparator}$packageId');
    final missing = <String>[];
    for (final f in r.manifest.files) {
      final v = await verifyFile(dir, f);
      if (!v.ok) missing.add(f.path);
    }
    return missing;
  }

  // ---------- داخلي ----------

  Future<int> _downloadedBytesOnDisk(
      Directory dir, PackageManifest manifest) async {
    var total = 0;
    for (final f in manifest.files) {
      final target = File(
          '${dir.path}${Platform.pathSeparator}${f.path}');
      final part = File('${target.path}.part');
      if (await target.exists()) {
        total += await target.length();
      } else if (await part.exists()) {
        total += await part.length();
      }
    }
    return total;
  }

  /// تنزيل ملف واحد مع استئناف. يعيد مجموع البايتات المنزّلة للحزمة.
  Future<int> _downloadFile({
    required String packageId,
    required Directory dir,
    required PackageFile file,
    required int alreadyDownloadedTotal,
    required void Function(int totalDownloaded) onProgress,
  }) async {
    final target = File(
        '${dir.path}${Platform.pathSeparator}${file.path}');
    await target.parent.create(recursive: true);
    final part = File('${target.path}.part');

    // ملف مكتمل ومتحقق: يُتخطى.
    if (await target.exists()) {
      final v = await verifyFile(dir, file);
      if (v.ok) return alreadyDownloadedTotal + file.sizeBytes;
      await target.delete(); // تالف: يُعاد تنزيله.
    }

    var downloaded = await part.exists() ? await part.length() : 0;
    if (downloaded > file.sizeBytes) {
      await part.delete(); // ‎.part أطول من المتوقع = تالف.
      downloaded = 0;
    }

    final request = await _http.getUrl(Uri.parse(file.sourceUrl));
    if (downloaded > 0) {
      request.headers.set('Range', 'bytes=$downloaded-');
    }
    final response = await request.close();

    if (downloaded > 0 && response.statusCode == HttpStatus.ok) {
      // الخادم تجاهل Range: يُعاد الملف من الصفر (لا يُلحق فوق ‎.part).
      await part.delete();
      downloaded = 0;
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // 416: ‎.part مكتمل فعلاً — يُتحقق منه.
      downloaded = file.sizeBytes;
    } else if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      // فشل المصدر الأساسي: جرّب الاحتياطي (إن وُجد) لمرة واحدة.
      if (file.fallbackUrl != null) {
        return _downloadFileViaFallback(
          packageId: packageId,
          dir: dir,
          file: file,
          alreadyDownloadedTotal: alreadyDownloadedTotal,
          onProgress: onProgress,
        );
      }
      throw HttpException(
          'HTTP ${response.statusCode} لـ ${file.sourceUrl}');
    }

    final sink = part.openWrite(mode: FileMode.append);
    var total = alreadyDownloadedTotal + downloaded;
    // لا يُستخدم sub.asFuture() هنا: لا يكتمل عند إلغاء الاشتراك
    // فيعلق download() للأبد بعد pause() — يُستخدم completer
    // يُكمله pause() صراحةً (انظر _downloadDone).
    final done = Completer<void>();
    _downloadDone[packageId] = done;
    final sub = response.listen(
      (chunk) {
        sink.add(chunk);
        total += chunk.length;
        onProgress(total);
      },
      onError: (Object e) async {
        await sink.close();
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    // يُحفظ الاشتراك باسم الحزمة ليستطيع pause() إلغاءه.
    _active[packageId] = sub;
    try {
      await done.future;
    } finally {
      _downloadDone.remove(packageId);
    }
    if (_pauseRequested.contains(packageId)) {
      // إيقاف أثناء الملف: يُغلق .part ويُبقيه للاستئناف، ولا يعيد
      // تسميته هدفاً ناقصاً فيُحذف عند التحقق.
      await sink.close();
      _active.remove(packageId);
      return total;
    }
    await sink.flush();
    await sink.close();
    _active.remove(packageId);

    // تحقق فوري بعد اكتمال الملف: بصمة خاطئة = حذف وإعادة لاحقة.
    await part.rename(target.path);
    final v = await verifyFile(dir, file);
    if (!v.ok) {
      await target.delete();
      throw StateError(
          'فشل تحقق SHA-256 للملف ${file.path} — حُذف وسيُعاد تنزيله');
    }
    return total;
  }

  /// محاولة واحدة عبر الرابط الاحتياطي (مضيف/جودة أخرى لنفس الآية).
  Future<int> _downloadFileViaFallback({
    required String packageId,
    required Directory dir,
    required PackageFile file,
    required int alreadyDownloadedTotal,
    required void Function(int totalDownloaded) onProgress,
  }) async {
    final fallback = PackageFile(
      path: file.path,
      sizeBytes: file.sizeBytes,
      sha256: file.sha256,
      sourceUrl: file.fallbackUrl!,
    );
    // ملاحظة: حجم ملف الاحتياطي قد يختلف (جودة أخرى)؛ التحقق
    // بالبصمة هو الحكم لا الحجم — وإن اختلف الحجم تُرفض البصمة
    // المطابقة للحجم الأصلي. لهذا يُبنى manifest الاحتياطي ببصمته
    // الخاصة في Phase 2؛ هنا تُستخدم بصمة المصدر الأساسي فقط
    // عندما يكون الاحتياطي الملف نفسه من مضيف آخر.
    return _downloadFile(
      packageId: packageId,
      dir: dir,
      file: fallback,
      alreadyDownloadedTotal: alreadyDownloadedTotal,
      onProgress: onProgress,
    );
  }

  Future<String> _sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  void dispose() {
    _http.close();
  }
}
