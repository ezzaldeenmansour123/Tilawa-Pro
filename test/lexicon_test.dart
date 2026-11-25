// اختبارات باني البحث المعجمي (FTS3 — Lexicon).
//
// تثبّت سلوك lib/search/lexicon_search.dart — وهو نقل حرفي لمنطق
// بايثون المُختبَر في ~/workspace/tilawa/phase1/fts3/fts3_test.py
// (التشغيل 5: 41 استعلاماً، missing=0 على قاعدة الـ6,236 آية كاملة).
// هذه الاختبارات وحدات خالصة (لا قاعدة بيانات)؛ التحقق الكامل
// بالأعداد على قاعدة التطبيق يقع على tools/verify_lexicon.py.
//
// التشغيل: `flutter test test/lexicon_test.dart`
import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/search/lexicon_search.dart';

/// معجم مصغّر يحمل الحالات الحرجة فقط (ليس القاعدة الكاملة).
LexiconQueryBuilder smallBuilder() => LexiconQueryBuilder(
      lexiconQuran: {
        'كانت': 'كانت',
        'بسم': 'اسم',
        'لموسي': 'موسي',
        'موسي': 'موسي',
        'صابرين': 'صابرين',
        'الصلاه': 'صلاه',
        'صلاه': 'صلاه',
        'وبالمؤمنين': 'مؤمنين',
        'مؤمنين': 'مؤمنين',
        'المؤمنين': 'مؤمنين',
      },
      lexiconTafsir: {
        'كمال': 'كمال',
        'ومالكهم': 'مالكهم',
        'مالكهم': 'مالكهم',
      },
    );

void main() {
  group('lexiconNormalize — must stay identical to normalizeAr in lib/db.dart', () {
    test('dagger alef is a letter: الرحمٰن -> الرحمان', () {
      expect(lexiconNormalize('ٱلرَّحْمَٰنِ'), 'الرحمان');
    });
    test('وٰ -> ا: الصلوة -> الصلاه', () {
      expect(lexiconNormalize('ٱلصَّلَوٰةَ'), 'الصلاه');
    });
    test('diacritics stripped, ة -> ه, ى -> ي', () {
      expect(lexiconNormalize('بِسْمِ ٱللَّهِ'), 'بسم الله');
      expect(lexiconNormalize('مُوسَىٰ'), 'موسي');
      expect(lexiconNormalize('إِلَى'), 'الي');
    });
    test('empty stays empty', () {
      expect(lexiconNormalize(''), '');
    });
  });

  group('lexiconStripPrefixOld — the OLD strip (reconstruction only)', () {
    test('strips one compound step (verbatim _strip_prefix): والمؤمنين -> مؤمنين, بالصلاه -> صلاه', () {
      // وال تُجرَّد كخطوة مركبة واحدة (و+ال معاً) — وهذا التجريد الأعمى
      // نفسه هو ما يجعل البحث القديم يخطئ؛ الدالة هنا للتوثيق وإعادة
      // البناء فقط، لا لتقرير المطابقة.
      expect(lexiconStripPrefixOld('والمؤمنين'), 'مؤمنين');
      expect(lexiconStripPrefixOld('بالصلاه'), 'صلاه');
    });
    test('the old strip DOES produce the false positive كانت -> انت', () {
      // This is exactly why the old strip must never decide a match.
      expect(lexiconStripPrefixOld('كانت'), 'انت');
    });
    test('no prefix -> null', () {
      expect(lexiconStripPrefixOld('موسي'), isNull);
    });
  });

  group('reconstructOriginals — FTS column -> original tokens', () {
    test('drops the stripped copy: بالصلاه صلاه الصلاه', () {
      expect(
        LexiconQueryBuilder.reconstructOriginals('بالصلاه صلاه الصلاه'),
        ['بالصلاه', 'الصلاه'],
      );
    });
    test('chain rescue: لكما كما ما قلت keeps the real كما', () {
      expect(
        LexiconQueryBuilder.reconstructOriginals('لكما كما ما قلت'),
        ['لكما', 'كما', 'قلت'],
      );
    });
    test('chain rescue: ولكنا لكنا كنا نا keeps لكنا and كنا', () {
      expect(
        LexiconQueryBuilder.reconstructOriginals('ولكنا لكنا كنا نا'),
        ['ولكنا', 'لكنا', 'كنا'],
      );
    });
    test('empty column -> empty list', () {
      expect(LexiconQueryBuilder.reconstructOriginals(''), isEmpty);
    });
  });

  group('termVariants', () {
    test('بالصلاه -> itself + صلاه + الصلاه', () {
      expect(
        LexiconQueryBuilder.termVariants('بالصلاه'),
        {'بالصلاه', 'صلاه', 'الصلاه'},
      );
    });
    test('bare term gains ال+term: موسي -> موسي + الموسي', () {
      expect(
        LexiconQueryBuilder.termVariants('موسي'),
        {'موسي', 'الموسي'},
      );
    });
    test('الصلاه -> الصلاه + صلاه', () {
      expect(
        LexiconQueryBuilder.termVariants('الصلاه'),
        {'الصلاه', 'صلاه'},
      );
    });
  });

  group('queryBase — lexicon first, fallback otherwise', () {
    final b = smallBuilder();

    test('known surfaces map to their QAC base', () {
      expect(b.queryBase('كانت', LexiconScope.quran), 'كانت');
      expect(b.queryBase('بسم', LexiconScope.quran), 'اسم');
      expect(b.queryBase('لموسي', LexiconScope.quran), 'موسي');
    });
    test('a known base maps to itself', () {
      expect(b.queryBase('موسي', LexiconScope.quran), 'موسي');
      expect(b.queryBase('صلاه', LexiconScope.quran), 'صلاه');
    });
    test('prefixed query term strips via fallback (L2): بصابرين -> صابرين', () {
      expect(b.queryBase('بصابرين', LexiconScope.quran), 'صابرين');
      expect(b.queryBase('بصلاه', LexiconScope.quran), 'صلاه');
    });
    test('unknown term with no known remainder stays whole', () {
      expect(b.queryBase('انت', LexiconScope.quran), 'انت');
    });
    test('tafsir scope prefers the tafsir lexicon', () {
      expect(b.queryBase('كمال', LexiconScope.tafsir), 'كمال');
      expect(b.queryBase('ومالكهم', LexiconScope.tafsir), 'مالكهم');
    });
    test('queryBases keeps order', () {
      expect(
        b.queryBases(['بالصلاه', 'والزكاه'], LexiconScope.quran),
        ['صلاه', 'زكاه'],
      );
    });
  });

  group('fallbackBase — the guarded strip', () {
    final b = smallBuilder();

    test('كانت/وعد/فارض stay whole: their remainders are not known bases', () {
      expect(b.fallbackBase('كانت'), 'كانت');
      expect(b.fallbackBase('وعد'), 'وعد');
      expect(b.fallbackBase('فارض'), 'فارض');
    });
    test('ومالكهم -> مالكهم (remainder is a known tafsir base)', () {
      expect(b.fallbackBase('ومالكهم'), 'مالكهم');
    });
    test('compound/ال strips are unconditional', () {
      expect(b.fallbackBase('والزكاه'), 'زكاه');
      expect(b.fallbackBase('الصلاه'), 'صلاه');
    });
  });

  group('termMatches / ayahMatches — the predicate', () {
    final b = smallBuilder();

    test('كانت does NOT match انت (the L1 false positive is gone)', () {
      expect(b.termMatches(['كانت', 'في', 'بيت'], 'انت', LexiconScope.quran),
          isFalse);
      expect(
          b.ayahMatches(['كانت'], ['انت'], LexiconScope.quran), isFalse);
    });
    test('لموسي matches موسي via its base', () {
      expect(b.termMatches(['لموسي', 'قال'], 'موسي', LexiconScope.quran),
          isTrue);
    });
    test('prefix matching is intended: انت matches انتقام', () {
      expect(b.termMatches(['انتقام'], 'انت', LexiconScope.quran), isTrue);
    });
    test('an ayah matches iff EVERY base matches', () {
      expect(
        b.ayahMatches(
            ['بالصلاه', 'والزكاه'], ['صلاه', 'زكاه'], LexiconScope.quran),
        isTrue,
      );
      expect(
        b.ayahMatches(
            ['بالصلاه'], ['صلاه', 'زكاه'], LexiconScope.quran),
        isFalse,
      );
    });
  });

  group('buildMatchExpression — FTS5 candidate expression', () {
    final b = smallBuilder();

    test('بالصلاه expands to its variants + its base variants', () {
      final expr = b.buildMatchExpression(['بالصلاه'], LexiconScope.quran);
      expect(expr, contains('{norm} : "بالصلاه"*'));
      expect(expr, contains('{norm} : "صلاه"*'));
      expect(expr, contains('{norm} : "الصلاه"*'));
    });
    test('lexicon expansion reaches multi-prefix surfaces: مؤمنين finds وبالمؤمنين', () {
      final expr = b.buildMatchExpression(['مؤمنين'], LexiconScope.quran);
      expect(expr, contains('بالمؤمنين'));
      expect(expr, contains('{norm} : "مؤمنين"*'));
    });
    test('two terms are ANDed, tafsir scope uses the tafsir column', () {
      final expr =
          b.buildMatchExpression(['بالصلاه', 'والزكاه'], LexiconScope.quran);
      expect(expr, contains(' AND '));
      final exprT =
          b.buildMatchExpression(['كمال'], LexiconScope.tafsir);
      expect(exprT, contains('{tafsir} : "كمال"*'));
      expect(exprT, isNot(contains('{norm}')));
    });
    test('empty terms -> empty expression', () {
      expect(b.buildMatchExpression([], LexiconScope.quran), '');
    });
  });

  group('empty lexicon — degrades to identity, never crashes', () {
    final b = LexiconQueryBuilder(lexiconQuran: {}, lexiconTafsir: {});
    test('unknown terms stay whole without known bases', () {
      expect(b.queryBase('بصابرين', LexiconScope.quran), 'بصابرين');
      expect(b.queryBase('كانت', LexiconScope.quran), 'كانت');
    });
  });
}
