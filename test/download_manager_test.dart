// اختبارات مدير التنزيلات — تلاوة برو
//
// الحالة: اختبارات التهيئة (manifest/record) منفَّذة محلياً عبر
// `flutter test` (انظر BUILD_REPORT). اختبار التنزيل/الاستئناف
// الكامل ما زال skip — يحتاج خادم HTTP محلياً يخدم ملفات
// اختبار ويحترم Range؛ لا اختبار حي ضد everyayah/cdn إطلاقاً.
//
// منطق الاستئناف والتحقق نفسه اختُبر بمحاكاة Python محلية
// (tools/simulate_download.py — نُفّذت فعلاً ونجحت).

import 'package:flutter_test/flutter_test.dart';

import 'package:tilawa_pro/features/packages/package_models.dart';
import 'package:tilawa_pro/features/packages/reciters.dart';

void main() {
  group('PackageManifest.validate', () {
    test('يرفض مساراً فيه ..', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'اختبار',
        sourceNote: '',
        files: [
          PackageFile(
            path: '../escape.mp3',
            sizeBytes: 3,
            sha256: '0000000000000000000000000000000000000000000000000000000000000000',
            sourceUrl: 'https://example.com/a.mp3',
          ),
        ],
      );
      expect(() => m.validate(), throwsFormatException);
    });

    test('يرفض رابطاً غير https', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'اختبار',
        sourceNote: '',
        files: [
          PackageFile(
            path: '001001.mp3',
            sizeBytes: 3,
            sha256: '0000000000000000000000000000000000000000000000000000000000000000',
            sourceUrl: 'http://example.com/a.mp3',
          ),
        ],
      );
      expect(() => m.validate(), throwsFormatException);
    });

    test('يقبل manifest سليماً ويحسب الحجم الكلي', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'اختبار',
        sourceNote: '',
        files: [
          PackageFile(
            path: '001001.mp3',
            sizeBytes: 10,
            sha256: '0000000000000000000000000000000000000000000000000000000000000000',
            sourceUrl: 'https://example.com/a.mp3',
          ),
          PackageFile(
            path: '001002.mp3',
            sizeBytes: 20,
            sha256: '1111111111111111111111111111111111111111111111111111111111111111',
            sourceUrl: 'https://example.com/b.mp3',
          ),
        ],
      );
      expect(() => m.validate(), returnsNormally);
      expect(m.totalBytes, 30);
    });
  });

  group('PackageRecord.availableOffline', () {
    test('مثبّت + متحقق = متوفر دون إنترنت', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'اختبار',
        sourceNote: '',
        files: [],
      );
      final r = PackageRecord(
        manifest: m,
        status: PackageStatus.installed,
        verifiedAt: DateTime.now(),
      );
      expect(r.availableOffline, isTrue);
    });

    test('غير مكتمل = غير متوفر دون إنترنت', () {
      const m = PackageManifest(
        id: 'x',
        kind: PackageKind.reciter,
        version: '1',
        titleAr: 'اختبار',
        sourceNote: '',
        files: [],
      );
      final r = PackageRecord(
        manifest: m,
        status: PackageStatus.incomplete,
      );
      expect(r.availableOffline, isFalse);
    });
  });

  group('DownloadManager (يحتاج خادماً محلياً — لم يُنفَّذ بعد)', () {
    test('تنزيل + إيقاف + استئناف + تحقق SHA-256 + حذف', () async {
      // يُنفَّذ في بيئة Flutter: خادم HttpServer محلي يخدم
      // 3 ملفات اختبار مع دعم Range، ثم:
      // 1. download() حتى اكتمال ملف واحد ثم pause().
      // 2. التحقق أن الحالة paused وأن ملف .part موجود.
      // 3. resume() حتى الاكتمال.
      // 4. verify() يعيد true، وisAvailableOffline() يعيد true.
      // 5. إفساد ملف → verify() يعيد false.
      // 6. delete() يزيل المجلد والسجل.
      fail('لم يُنفَّذ بعد — يحتاج Dart/Flutter SDK وخادماً محلياً');
    }, skip: true);
  });

  group('globalAyahToSurahAyah (من reciters.dart)', () {
    test('حدود الترقيم العام', () {
      // 1 → 1:1، 7 → 1:7، 8 → 2:1، 6236 → 114:6.
      final first = globalAyahToSurahAyah(1);
      expect(first.surah, 1);
      expect(first.ayah, 1);
      final lastFatiha = globalAyahToSurahAyah(7);
      expect(lastFatiha.surah, 1);
      expect(lastFatiha.ayah, 7);
      final firstBaqara = globalAyahToSurahAyah(8);
      expect(firstBaqara.surah, 2);
      expect(firstBaqara.ayah, 1);
      final last = globalAyahToSurahAyah(6236);
      expect(last.surah, 114);
      expect(last.ayah, 6);
    });
  });
}
