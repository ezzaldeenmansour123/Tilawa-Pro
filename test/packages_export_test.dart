// اختبارات صفحتي الحزم والتصدير — تلاوة برو
//
// تغطي المنطق الذي تعتمد عليه الصفحتان الجديدتان:
//   - lib/features/packages/packages_page.dart
//   - lib/features/data/export_page.dart
// دون واجهة (منطق نقي + مدير تنزيل عبر خادم HTTPS محلي).
//
// التنزيل الحي هنا ضد خادم محلي فقط (شهادة موقعة ذاتياً تُولَّد
// في setUpAll عبر openssl) — لا اختبار حي ضد everyayah/cdn إطلاقاً.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tilawa_pro/data/user_export.dart';
import 'package:tilawa_pro/features/packages/download_manager.dart';
import 'package:tilawa_pro/features/packages/package_catalog.dart';
import 'package:tilawa_pro/features/packages/package_models.dart';
import 'package:tilawa_pro/features/packages/reciters.dart';

String _shaHex(List<int> bytes) => sha256.convert(bytes).toString();

/// 64 حرفاً سداسية عشرية (بصمة وهمية صالحة الشكل للتحقق البنيوي).
String _fakeHash(String seed) => _shaHex(utf8.encode(seed));

PackageFile _file(String path, String url, {String? fallbackUrl}) =>
    PackageFile(
      path: path,
      sizeBytes: 10,
      sha256: _fakeHash(path),
      sourceUrl: url,
      fallbackUrl: fallbackUrl,
    );

PackageManifest _manifest({
  String id = 'test-pkg',
  List<PackageFile>? files,
  PackageKind kind = PackageKind.reciter,
}) =>
    PackageManifest(
      id: id,
      kind: kind,
      version: '1',
      titleAr: 'حزمة اختبار',
      sourceNote: 'اختبار',
      files: files ??
          [_file('001001.mp3', 'https://example.com/a.mp3')],
    );

void main() {
  group('PackageManifest: تحليل/تحقق', () {
    test('round-trip JSON يحفظ الحقول ويحسب الحجم الكلي', () {
      final m = _manifest(files: [
        _file('a.mp3', 'https://example.com/a.mp3'),
        _file('b.mp3', 'https://example.com/b.mp3'),
      ]);
      final back = PackageManifest.fromJsonString(m.toJsonString());
      expect(back.id, m.id);
      expect(back.kind, PackageKind.reciter);
      expect(back.files.length, 2);
      expect(back.totalBytes, 20);
      expect(back.fileCount, 2);
      expect(() => back.validate(), returnsNormally);
    });

    test('يرفض مساراً فيه ..', () {
      final m = _manifest(files: [
        _file('../escape.mp3', 'https://example.com/a.mp3'),
      ]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض مساراً مطلقاً', () {
      final m = _manifest(files: [
        _file('/etc/passwd', 'https://example.com/a.mp3'),
      ]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض رابطاً غير https', () {
      final m = _manifest(files: [
        _file('a.mp3', 'http://example.com/a.mp3'),
      ]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض رابطاً احتياطياً غير https', () {
      final m = _manifest(files: [
        _file('a.mp3', 'https://example.com/a.mp3',
            fallbackUrl: 'http://example.com/a.mp3'),
      ]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض بصمة أقصر من 64 حرفاً', () {
      const bad = PackageFile(
        path: 'a.mp3',
        sizeBytes: 10,
        sha256: 'abcd',
        sourceUrl: 'https://example.com/a.mp3',
      );
      final m = _manifest(files: [bad]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض ملفاً مكرراً', () {
      final m = _manifest(files: [
        _file('a.mp3', 'https://example.com/a.mp3'),
        _file('a.mp3', 'https://example.com/b.mp3'),
      ]);
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض هوية ناقصة', () {
      final m = _manifest(id: '', files: []);
      expect(() => m.validate(), throwsFormatException);
    });

    test('fromJson يرفض kind غير معروف', () {
      final json = _manifest().toJson()..['kind'] = 'no-such-kind';
      expect(() => PackageManifest.fromJson(json), throwsArgumentError);
    });

    test('ayahCount غير صالح يُرفض', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'ت',
        sourceNote: '',
        files: [],
        ayahCount: 0,
      );
      expect(() => m.validate(), throwsFormatException);
    });
  });

  group('PackageRecord: تقدم وتوفر دون إنترنت', () {
    test('progress من البايتات ويُقص عند 1', () {
      final m = _manifest(files: [
        _file('a.mp3', 'https://example.com/a.mp3'),
      ]);
      final r = PackageRecord(
          manifest: m, status: PackageStatus.downloading, downloadedBytes: 5);
      expect(r.progress, 0.5);
      r.downloadedBytes = 999;
      expect(r.progress, 1.0);
    });

    test('مثبّت + متحقق = متوفر دون إنترنت؛ وبدون verifiedAt = لا', () {
      final m = _manifest(files: []);
      final ok = PackageRecord(
        manifest: m,
        status: PackageStatus.installed,
        verifiedAt: DateTime.now(),
      );
      expect(ok.availableOffline, isTrue);
      final noVerify =
          PackageRecord(manifest: m, status: PackageStatus.installed);
      expect(noVerify.availableOffline, isFalse);
    });

    test('round-trip JSON للسجل', () {
      final m = _manifest();
      final r = PackageRecord(
        manifest: m,
        status: PackageStatus.paused,
        downloadedBytes: 7,
        lastError: 'خطأ',
        installedAt: DateTime.utc(2026, 11, 25),
      );
      final back = PackageRecord.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.manifest.id, 'test-pkg');
      expect(back.status, PackageStatus.paused);
      expect(back.downloadedBytes, 7);
      expect(back.lastError, 'خطأ');
    });
  });

  group('الكتالوج: اتساق مع الصفحات', () {
    test('10 بنود بمعرّفات فريدة، ولا شيء منها داخل APK', () {
      expect(packageCatalog.length, 10);
      final ids = packageCatalog.map((p) => p.id).toSet();
      expect(ids.length, 10);
      expect(packageCatalog.every((p) => p.inApk == false), isTrue);
    });

    test('ورش: مقيسة 1.6MB', () {
      final w = packageCatalog
          .singleWhere((p) => p.id == 'warsh-package');
      expect(w.sizeBytes, 1600000);
      expect(w.sizeSource, SizeSource.measured);
      expect(w.displaySize, contains('1.5 MB'));
    });

    test('نموذج التسميع الخفيف: مقيس 24,650,054 + 4,700,000', () {
      final lite = packageCatalog.singleWhere((p) => p.id == 'ai-model-lite');
      expect(lite.sizeBytes, 24650054 + 4700000);
      expect(lite.sizeSource, SizeSource.measured);
    });

    test('القارئ العام: تقديري بلا رقم دقيق — لا رقم مخترع', () {
      final r =
          packageCatalog.singleWhere((p) => p.id == 'reciter-full');
      expect(r.kind, PackageKind.reciter);
      expect(r.sizeBytes, isNull);
      expect(r.estimatedRangeAr, isNotNull);
    });

    test('صور المصحف: مقيسة ≈120MB', () {
      final m = packageCatalog
          .singleWhere((p) => p.id == 'mushaf-images-2600');
      expect(m.sizeBytes, 120 * 1024 * 1024);
      expect(m.sizeSource, SizeSource.measured);
    });

    test('formatBytes حدوده', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('القرّاء الـ17: اتساق مع الكتالوج والتصدير', () {
    test('17 قارئاً بمعرّفات فريدة', () {
      expect(reciters17.length, 17);
      expect(reciters17.map((r) => r.id).toSet().length, 17);
    });

    test('السبعة الحاليون في التطبيق هم أول سبعة بنفس المعرّفات', () {
      expect(
          reciters17.take(7).map((r) => r.id).toList(),
          ['afasy', 'husary', 'basit', 'minshawi', 'sudais', 'muaiqly',
            'shuraym']);
    });

    test(
        'كل القرّاء الـ17 في kKnownReciterIds — التوسيع الموثق 2026-11-25: '
        'العشرة الجدد موثقو الاكتمال في سجل التطبيق نفسه، فلا يُعزلون عند الاستيراد',
        () {
      expect(kKnownReciterIds, reciters17.map((r) => r.id).toSet());
      for (final id in reciters17.skip(7).map((r) => r.id)) {
        expect(kKnownReciterIds.contains(id), isTrue,
            reason: 'القارئ الجديد $id في kKnownReciterIds بعد التوسيع');
      }
    });

    test('الحصري والمنشاوي: EveryAyah أولاً (ثغرة 6235 في islamic.network)',
        () {
      final husary = reciters17.singleWhere((r) => r.id == 'husary');
      final minshawi = reciters17.singleWhere((r) => r.id == 'minshawi');
      expect(husary.primarySource, contains('EveryAyah'));
      expect(minshawi.primarySource, contains('EveryAyah'));
      expect(husary.everyayahFolder, 'Husary_128kbps');
      expect(minshawi.everyayahFolder, 'Minshawy_Murattal_128kbps');
    });

    test('قوالب الروابط آيةً بآية', () {
      expect(everyayahAyahUrl('Husary_128kbps', 2, 255),
          'https://everyayah.com/data/Husary_128kbps/002255.mp3');
      expect(islamicNetworkAyahUrl('ar.husary', 128, 255),
          'https://cdn.islamic.network/quran/audio/128/ar.husary/255.mp3');
    });

    test('ترقيم الآيات العام: الحدود والمجموع 6236', () {
      expect(ayahsPerSurah.fold<int>(0, (a, b) => a + b), 6236);
      expect(ayahsPerSurah.length, 114);
      final first = globalAyahToSurahAyah(1);
      expect((first.surah, first.ayah), (1, 1));
      final last = globalAyahToSurahAyah(6236);
      expect((last.surah, last.ayah), (114, 6));
      expect(() => globalAyahToSurahAyah(0), throwsArgumentError);
      expect(() => globalAyahToSurahAyah(6237), throwsArgumentError);
    });
  });

  group('تصدير المستخدم: round-trip وتحقق', () {
    const original = UserExportData(
      favorites: [1, 2, 255],
      history: [6236, 255, 1],
      tags: {2: 'وسم', 255: 'آية الكرسي'},
      notes: {1: 'ملاحظة'},
      khatmahQuarter: 241,
      favReciters: ['afasy', 'husary'],
      warshReady: true,
    );

    test('round-trip كامل يحفظ كل حقل والبصمة', () {
      final text = original.toExportString(appVersion: '1.0.0');
      final v = validateExportText(text);
      expect(v.isValid, isTrue);
      expect(v.data, original);
      expect(v.warnings, isEmpty);
      expect(v.quarantined, isEmpty);
      expect(v.counts['favorites'], 3);
      expect(v.counts['history'], 3);
      expect(v.counts['tags'], 2);
    });

    test('التلاعب بالحمولة بعد التوقيع يُرفض بالبصمة', () {
      final map = jsonDecode(original.toExportString()) as Map<String, dynamic>;
      (map['data'] as Map<String, dynamic>)['favorites'] = [1, 2, 3];
      final v = validateExportText(jsonEncode(map));
      expect(v.isValid, isFalse);
      expect(v.rejectionReason, contains('SHA-256'));
    });

    test('صيغة غير معروفة وإصدار أحدث يُرفضان', () {
      final badFormat = jsonDecode(original.toExportString())
          as Map<String, dynamic>;
      badFormat['format'] = 'other-format';
      expect(validateExportText(jsonEncode(badFormat)).isValid, isFalse);
      final newer = jsonDecode(original.toExportString())
          as Map<String, dynamic>;
      newer['format_version'] = 2;
      final v = validateExportText(jsonEncode(newer));
      expect(v.isValid, isFalse);
      expect(v.rejectionReason, contains('أحدث'));
    });

    test('JSON معطوب يُرفض', () {
      expect(validateExportText('{not json').isValid, isFalse);
      expect(validateExportText('[]').isValid, isFalse);
    });

    test('معرّفات آيات خارج النطاق وتكرار تُعزل ولا توقف الاستيراد', () {
      final map = jsonDecode(original.toExportString()) as Map<String, dynamic>;
      final data = map['data'] as Map<String, dynamic>;
      data['favorites'] = [1, 0, 6237, 2, 2];
      // إعادة توقيع الحمولة المعدلة لتجتاز فحص البصمة.
      map['sha256'] = UserExportData(
        favorites: [1, 0, 6237, 2, 2],
        history: original.history,
        tags: original.tags,
        notes: original.notes,
        khatmahQuarter: original.khatmahQuarter,
        favReciters: original.favReciters,
        warshReady: original.warshReady,
      ).sha256;
      final v = validateExportText(jsonEncode(map));
      expect(v.isValid, isTrue);
      expect(v.data!.favorites, [1, 2]);
      expect(v.quarantined.length, 3); // 0، 6237، تكرار 2
    });

    test('قارئ غير معروف في fav_reciters يُعزل', () {
      const incoming = UserExportData(
        favorites: [1],
        favReciters: ['afasy', 'made-up-reciter'],
      );
      final v = validateExportText(incoming.toExportString());
      expect(v.isValid, isTrue);
      expect(v.data!.favReciters, ['afasy']);
      expect(v.quarantined.any((q) => q.field == 'fav_reciters'), isTrue);
    });

    test('الدمج: اتحاد مفضلة، سجل وارد أولاً بسقف 100، ختمة الأكبر', () {
      const current = UserExportData(
        favorites: [1, 2],
        history: [10, 20],
        tags: {1: 'قديم'},
        khatmahQuarter: 5,
      );
      const incoming = UserExportData(
        favorites: [2, 3],
        history: [30, 10],
        tags: {1: 'جديد', 2: 'x'},
        khatmahQuarter: 3,
        warshReady: true,
      );
      final merged = current.mergeWith(incoming);
      expect(merged.favorites, [1, 2, 3]);
      expect(merged.history, [30, 10, 20]);
      expect(merged.tags, {1: 'جديد', 2: 'x'});
      expect(merged.khatmahQuarter, 5); // التقدم لا يتراجع
      expect(merged.warshReady, isTrue);
      // سقف السجل 100.
      final long = UserExportData(
          history: List.generate(150, (i) => i + 1));
      expect(
          const UserExportData().mergeWith(long).history.length, 100);
    });

    test('sha256Hex يطابق المتجه المعروف', () {
      expect(sha256Hex('abc'),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
  });

  group('DownloadManager: تحقق وحذف بلا شبكة', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tilawa-pkg-test-');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('init يعيد بناء السجل من القرص + verify + إفساد + delete',
        () async {
      final content = utf8.encode('fake-mp3-bytes');
      final manifest = PackageManifest(
        id: 'local-pkg',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'محلية',
        sourceNote: '',
        files: [
          PackageFile(
            path: '001001.mp3',
            sizeBytes: content.length,
            sha256: _shaHex(content),
            sourceUrl: 'https://example.com/001001.mp3',
          ),
        ],
      );
      final pkgDir = Directory('${tmp.path}/local-pkg');
      await pkgDir.create(recursive: true);
      await File('${pkgDir.path}/manifest.json')
          .writeAsString(manifest.toJsonString());
      await File('${pkgDir.path}/001001.mp3').writeAsBytes(content);

      final manager = DownloadManager(packagesDir: tmp);
      await manager.init();
      expect(manager.record('local-pkg'), isNotNull);
      expect(manager.record('local-pkg')!.status, PackageStatus.incomplete);
      expect(await manager.verify('local-pkg'), isTrue);
      expect(manager.isAvailableOffline('local-pkg'), isTrue);

      // إفساد ملف واحد → التحقق يفشل.
      await File('${pkgDir.path}/001001.mp3')
          .writeAsBytes(utf8.encode('corrupted!'));
      expect(await manager.verify('local-pkg'), isFalse);
      expect(manager.isAvailableOffline('local-pkg'), isFalse);

      await manager.delete('local-pkg');
      expect(await pkgDir.exists(), isFalse);
      expect(manager.record('local-pkg'), isNull);
      manager.dispose();
    });

    test('سجل registry تالف يُحفظ جانباً ويُعاد بناؤه', () async {
      await File('${tmp.path}/registry.json').writeAsString('{broken');
      final manager = DownloadManager(packagesDir: tmp);
      await manager.init();
      expect(manager.records, isEmpty);
      final renamed = await tmp
          .list()
          .where((e) => e.path.contains('registry.json.corrupt-'))
          .toList();
      expect(renamed.length, 1);
      manager.dispose();
    });
  });

  group('DownloadManager: تنزيل حي عبر HTTPS محلي', () {
    late Directory tmp;
    late HttpServer server;
    late String base;
    late Map<String, List<int>> files;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('tilawa-pkg-https-');
      final keyPath = '${tmp.path}/key.pem';
      final certPath = '${tmp.path}/cert.pem';
      final gen = await Process.run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048',
        '-keyout', keyPath, '-out', certPath,
        '-days', '2', '-nodes',
        '-subj', '/CN=127.0.0.1',
        '-addext', 'subjectAltName=IP:127.0.0.1',
      ]);
      expect(gen.exitCode, 0, reason: gen.stderr.toString());
      files = {
        'f1.bin': List<int>.generate(256 * 1024, (i) => i % 251),
        'f2.bin': List<int>.generate(256 * 1024, (i) => (i * 7) % 253),
        'f3.bin': List<int>.generate(256 * 1024, (i) => (i * 13) % 247),
        'fb.bin': List<int>.generate(4096, (i) => i % 97),
      };
      final ctx = SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
      server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4, 0, ctx);
      base = 'https://127.0.0.1:${server.port}';
      server.listen((HttpRequest req) async {
        final name =
            req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last;
        final bytes = files[name];
        final res = req.response;
        if (req.uri.path.startsWith('/missing/') || bytes == null) {
          res.statusCode = HttpStatus.notFound;
          await res.close();
          return;
        }
        var start = 0;
        final range = req.headers.value('range');
        if (range != null) {
          final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
          if (m != null) start = int.parse(m.group(1)!);
        }
        if (start >= bytes.length) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await res.close();
          return;
        }
        if (start > 0) {
          res.statusCode = HttpStatus.partialContent;
          res.headers.set('Content-Range',
              'bytes $start-${bytes.length - 1}/${bytes.length}');
        }
        res.headers.contentLength = bytes.length - start;
        res.headers.contentType = ContentType.binary;
        const chunk = 8192;
        try {
          for (var off = start; off < bytes.length; off += chunk) {
            final end = (off + chunk).clamp(0, bytes.length);
            res.add(bytes.sublist(off, end));
            await res.flush();
            await Future.delayed(const Duration(milliseconds: 20));
          }
          await res.close();
        } catch (_) {
          try {
            await res.close();
          } catch (_) {}
        }
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    DownloadManager newManager(Directory dir) {
      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      return DownloadManager(packagesDir: dir, httpClient: client);
    }

    PackageManifest threeFilesManifest() => PackageManifest(
          id: 'https-pkg',
          kind: PackageKind.reciter,
          version: '1',
          titleAr: 'حزمة HTTPS محلية',
          sourceNote: 'اختبار',
          files: [
            for (final n in ['f1.bin', 'f2.bin', 'f3.bin'])
              PackageFile(
                path: n,
                sizeBytes: files[n]!.length,
                sha256: _shaHex(files[n]!),
                sourceUrl: '$base/$n',
              ),
          ],
        );

    test('تنزيل كامل + تحقق SHA-256 + متوفر دون إنترنت', () async {
      final dir = await Directory.systemTemp.createTemp('tilawa-pkg-dl-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final manager = newManager(dir);
      await manager.init();
      final manifest = threeFilesManifest();
      await manager.download(manifest);
      final r = manager.record('https-pkg')!;
      expect(r.status, PackageStatus.installed);
      expect(await manager.verify('https-pkg'), isTrue);
      expect(manager.isAvailableOffline('https-pkg'), isTrue);
      expect(await manager.usedBytes(), greaterThan(0));
      manager.dispose();
    });

    test('إيقاف أثناء التنزيل يُبقي .part ثم الاستئناف يكمل', () async {
      final dir = await Directory.systemTemp.createTemp('tilawa-pkg-pr-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final manager = newManager(dir);
      await manager.init();
      final manifest = threeFilesManifest();
      var sawProgress = false;
      final firstProgress = Completer<void>();
      final dl = manager.download(manifest, onProgress: (_) {
        if (!sawProgress) {
          sawProgress = true;
          firstProgress.complete();
        }
      });
      await firstProgress.future.timeout(const Duration(seconds: 10));
      await manager.pause('https-pkg');
      await dl; // يجب أن ينتهي بلا استثناء (إيقاف لا فشل).
      final paused = manager.record('https-pkg')!;
      expect(paused.status, PackageStatus.paused);
      expect(sawProgress, isTrue);
      // ملف .part محفوظ والتقدم محفوظ — لا يُفقد ما نُزّل.
      // (ملف جزئي واحد على الأقل بامتداد .part داخل مجلد الحزمة.)
      final pkgFiles = await Directory('${dir.path}/https-pkg')
          .list()
          .map((e) => e.path)
          .toList();
      expect(pkgFiles.any((p) => p.endsWith('.part')), isTrue,
          reason: 'لا ملف .part بعد الإيقاف — فُقد التقدم: $pkgFiles');
      expect(paused.downloadedBytes, greaterThan(0));

      await manager.resume('https-pkg');
      expect(manager.record('https-pkg')!.status, PackageStatus.installed);
      expect(await manager.verify('https-pkg'), isTrue);
      expect(manager.isAvailableOffline('https-pkg'), isTrue);
      manager.dispose();
    });

    test('فشل المصدر الأساسي 404 يُغطى بالرابط الاحتياطي', () async {
      final dir = await Directory.systemTemp.createTemp('tilawa-pkg-fb-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final manager = newManager(dir);
      await manager.init();
      final manifest = PackageManifest(
        id: 'fb-pkg',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'احتياطي',
        sourceNote: 'اختبار',
        files: [
          PackageFile(
            path: 'fb.bin',
            sizeBytes: files['fb.bin']!.length,
            sha256: _shaHex(files['fb.bin']!),
            sourceUrl: '$base/missing/fb.bin',
            fallbackUrl: '$base/fb.bin',
          ),
        ],
      );
      await manager.download(manifest);
      expect(manager.record('fb-pkg')!.status, PackageStatus.installed);
      expect(await manager.verify('fb-pkg'), isTrue);
      manager.dispose();
    });

    test('إعادة التنزيل بعد فشل التحقق: ملف تالف يُعاد تنزيله', () async {
      final dir = await Directory.systemTemp.createTemp('tilawa-pkg-rt-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final manager = newManager(dir);
      await manager.init();
      final manifest = PackageManifest(
        id: 'rt-pkg',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'إعادة',
        sourceNote: 'اختبار',
        files: [
          PackageFile(
            path: 'fb.bin',
            sizeBytes: files['fb.bin']!.length,
            sha256: _shaHex(files['fb.bin']!),
            sourceUrl: '$base/fb.bin',
          ),
        ],
      );
      await manager.download(manifest);
      expect(manager.isAvailableOffline('rt-pkg'), isTrue);
      // إفساد الملف المثبّت ثم استئناف: يجب أن يُعاد تنزيله ويُتحقق.
      await File('${dir.path}/rt-pkg/fb.bin')
          .writeAsBytes(List<int>.filled(4096, 0));
      expect(await manager.verify('rt-pkg'), isFalse);
      await manager.resume('rt-pkg');
      expect(await manager.verify('rt-pkg'), isTrue);
      expect(manager.isAvailableOffline('rt-pkg'), isTrue);
      manager.dispose();
    });
  });
}
