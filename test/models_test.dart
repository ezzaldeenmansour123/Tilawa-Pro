// اختبارات النماذج المنقولة إلى lib/data/models.dart (Phase 1، الخطوة 1 من التقسيم).
//
// الغرض: تثبيت سلوك/قيم الكود المنقول حرفياً من lib/db.dart (الأسطر 46-100، التزام 07204f14)
// قبل أي دمج. هذه الاختبارات لا تثبت صحة المحتوى القرآني ولا صحة معرّفات خارجية؛
// بل تثبت أن النقل لم يغيّر أي قيمة — أي اختلاف لاحق في هذه القيم هو خطأ نقل.
// التشغيل (في بيئة فيها Flutter SDK): `flutter test test/models_test.dart`
// ملاحظة: لا Flutter/Dart SDK في بيئة كتابة هذه الاختبارات — لم تُشغَّل بعد.

import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/data/models.dart';
import 'package:tilawa_pro/db.dart' as db;

void main() {
  group('Surah', () {
    test('const constructor keeps positional field order', () {
      const s = Surah(1, 'الفاتحة', 'الفاتحة', 'Al-Fatiha', 'مكية', 7, 1);
      expect(s.id, 1);
      expect(s.nameAr, 'الفاتحة');
      expect(s.nameShort, 'الفاتحة');
      expect(s.nameEn, 'Al-Fatiha');
      expect(s.revelation, 'مكية');
      expect(s.ayahCount, 7);
      expect(s.juzStart, 1);
    });
  });

  group('Ayah', () {
    test('const constructor keeps positional field order', () {
      const a = Ayah(1, 1, 1, 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ', 1, 1, 1, 1, false, 'الفاتحة');
      expect(a.id, 1);
      expect(a.surah, 1);
      expect(a.ayah, 1);
      expect(a.text, contains('بِسْمِ'));
      expect(a.juz, 1);
      expect(a.hizb, 1);
      expect(a.quarter, 1);
      expect(a.page, 1);
      expect(a.sajda, isFalse);
      expect(a.surahName, 'الفاتحة');
    });

    test('sajda flag can be true', () {
      const a = Ayah(2, 7, 206, 'text', 9, 18, 72, 176, true, 'الأعراف');
      expect(a.sajda, isTrue);
    });
  });

  group('Ijaz', () {
    test('const constructor keeps positional field order', () {
      const i = Ijaz(1, 'عنوان', '2:255', 2, 255, 'نص الإعجاز', 'المصدر');
      expect(i.id, 1);
      expect(i.title, 'عنوان');
      expect(i.ayahRef, '2:255');
      expect(i.surah, 2);
      expect(i.ayah, 255);
      expect(i.text, 'نص الإعجاز');
      expect(i.source, 'المصدر');
    });
  });

  group('Reciter', () {
    test('fallbackEdition is optional and defaults to null', () {
      const r = Reciter('x', 'قارئ', 'Folder_64kbps');
      expect(r.fallbackEdition, isNull);
      const r2 = Reciter('y', 'قارئ', 'Folder_64kbps', 'ar.edition');
      expect(r2.fallbackEdition, 'ar.edition');
    });
  });

  group('reciters (the 7 known readers)', () {
    test('exactly 7, in the original order, with original folders', () {
      expect(reciters.length, 7);
      expect(reciters.map((r) => r.id).toList(),
          ['afasy', 'husary', 'basit', 'minshawi', 'sudais', 'muaiqly', 'shuraym']);
      expect(reciters.map((r) => r.folder).toList(), [
        'Alafasy_64kbps',
        'Husary_64kbps',
        'Abdul_Basit_Murattal_64kbps',
        'Minshawy_Murattal_128kbps',
        'Abdurrahmaan_As-Sudais_64kbps',
        'Maher_AlMuaiqly_64kbps',
        'Saood_ash-Shuraym_64kbps',
      ]);
    });

    test('fallback editions as moved (not "fixed")', () {
      expect(reciters.map((r) => r.fallbackEdition).toList(), [
        'ar.alafasy',
        'ar.husary',
        'ar.abdulbasitmurattal',
        'ar.minshawi',
        // NOTE (Phase 0): the live API spells the Sudais edition
        // 'ar.abdurrahmaansudais'; the value below is the moved value,
        // asserted as-is. Do not "fix" it here — that is a separate decision.
        'ar.abdulrahmanalsudais',
        'ar.maheralmuaiqly',
        'ar.saoodashshuraym',
      ]);
    });

    test('Arabic names are non-empty', () {
      for (final r in reciters) {
        expect(r.nameAr.trim(), isNotEmpty);
      }
    });
  });

  group('offlineTafsirs', () {
    test('exactly the 3 bundled tafsirs, in order', () {
      expect(offlineTafsirs.length, 3);
      expect(offlineTafsirs.map((t) => t.$1).toList(),
          ['muyassar', 'jalalayn', 'saadi']);
      expect(offlineTafsirs.map((t) => t.$2).toList(),
          ['التفسير الميسر', 'تفسير الجلالين', 'تفسير السعدي']);
    });
  });

  group('onlineTafsirs', () {
    test('exactly the 3 Quran.com v4 ids, in order', () {
      expect(onlineTafsirs.length, 3);
      expect(onlineTafsirs.map((t) => t.$1).toList(), [14, 15, 90]);
      expect(onlineTafsirs.map((t) => t.$2).toList(),
          ['تفسير ابن كثير', 'تفسير الطبري', 'تفسير القرطبي']);
    });

    test('Qurtubi id 90 is present as moved — value is UNVERIFIED (Phase 0)',
        () {
      // This test pins the moved value so any accidental change fails loudly.
      // It does NOT claim id 90 is the correct Qurtubi id.
      expect(onlineTafsirs.any((t) => t.$1 == 90 && t.$2 == 'تفسير القرطبي'),
          isTrue);
    });
  });

  group('db.dart re-export (the split keeps models reachable via db.dart)', () {
    test('Surah / reciters / tafsir lists are reachable through db.dart', () {
      // db.dart does `import 'data/models.dart';` + `export 'data/models.dart';`
      // so main.dart keeps working unchanged through its `import 'db.dart';`.
      expect(db.reciters.length, 7);
      expect(db.offlineTafsirs.length, 3);
      expect(db.onlineTafsirs.length, 3);
      const s = db.Surah(114, 'الناس', 'الناس', 'An-Nas', 'مكية', 6, 30);
      expect(s.ayahCount, 6);
      expect(identical(db.reciters, reciters), isTrue);
    });
  });
}
