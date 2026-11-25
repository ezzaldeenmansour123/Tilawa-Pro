// اقتراح Dart للقاعدة المعجمية (FTS3 — Lexicon) — تلاوة
//
// تحذير: هذا الملف اقتراح غير مختبَر (لا على جهاز ولا في Dart).
// وهو نقل حرفي لمنطق بايثون المُختبَر في:
//   ~/workspace/tilawa/phase1/fts3/fts3_test.py
//   ~/workspace/tilawa/phase1/fts3/build_lexicon.py
//   ~/workspace/tilawa/phase0/fts_test.py  (norm + termVariantsNew)
// النتائج المُختبَرة في بايثون (التشغيل 5 النهائي، 41 استعلاماً، missing=0):
//   بالصلاة قرآن 63، فالغيب 48، للصابرين 15، والمؤمنين 142، بصابرين 15،
//   موسى 452/452، قال 3079/3079، يوم 1234/1235 (−1 تفسير: 2:239 ويومئ)،
//   ما 5229/5230 (−1 تفسير: 7:97 ومامن).
// قبل الدمج: اختبار flutter test على قاعدة الـ6,236 آية كاملة +
// قياس الزمن على الجهاز (بايثون: نطاق التفسير 11–1180ms، يتجاوز ~10ms).
//
// الجداول المطلوبة في قاعدة التطبيق (من quran_lexicon.db):
//   lexicon(surface TEXT PRIMARY KEY, base TEXT, source TEXT)          -- قرآن (QAC)
//   lexicon_tafsir(surface TEXT PRIMARY KEY, base TEXT, source TEXT)   -- تفسير (fallback)
//   lexicon_extra(ayah_id INTEGER, token TEXT)                         -- حالياً 0 صفوف (دفاعي)
//   lexicon_meta(key TEXT PRIMARY KEY, value TEXT)
// إسناد إلزامي عند الشحن: Quranic Arabic Corpus v0.4 (GPL) —
// corpus.quran.com — والتحقق القانوني قبل التوزيع (المعجم اشتقاق لا نسخة حرفية).
// لا تعديل لنص أي آية أبداً؛ التطبيع في أعمدة/جداول منفصلة فقط.

import 'package:sqflite/sqflite.dart';

/// بحث معجمي: يطابق قاعدة الحدّ لا الرمز المجرّد عشوائياً.
///
/// المطابقة بالبادئة مقصودة (انت→انتقام، سم→سميع)؛ الذي أُزيل هو
/// النسخ المجرّدة الزائفة فقط (كانت←انت، بسم←سم، كتابا←تابا).
class LexiconSearch {
  LexiconSearch._();

  static const _compound = ['وال', 'فال', 'بال', 'لل', 'كال'];
  static const _single = ['و', 'ف', 'ب', 'ل', 'ك'];

  // ---- الحالة المحمّلة مرة واحدة عند فتح القاعدة ----
  late final Map<String, String> _lexQ; // سطح قرآني -> قاعدة
  late final Map<String, String> _lexT; // سطح تفسيري -> قاعدة
  late final Set<String> _bases; // كل القواعد (قرآن + تفسير)
  late final Map<String, List<String>> _byBaseQ; // قاعدة -> أسطح قرآنية
  late final Map<String, List<String>> _byBaseT; // قاعدة -> أسطح تفسيرية
  late final Map<int, List<String>> _extra; // ayah_id -> رموز ممتصة (دفاعي)

  // الرموز الأصلية لكل آية، مُعاد بناؤها من عمود FTS نفسه
  // (انظر reconstructOriginals). تُبنى مرة واحدة عند الفتح.
  late final Map<int, _AyahOriginals> _originals;

  static Future<LexiconSearch> open(Database db) async {
    final s = LexiconSearch._();
    s._lexQ = {
      for (final r in await db.query('lexicon'))
        (r['surface'] as String): (r['base'] as String),
    };
    s._lexT = {
      for (final r in await db.query('lexicon_tafsir'))
        (r['surface'] as String): (r['base'] as String),
    };
    s._bases = {...s._lexQ.values, ...s._lexT.values};
    s._byBaseQ = {};
    for (final e in s._lexQ.entries) {
      (s._byBaseQ[e.value] ??= []).add(e.key);
    }
    s._byBaseT = {};
    for (final e in s._lexT.entries) {
      (s._byBaseT[e.value] ??= []).add(e.key);
    }
    s._extra = {};
    for (final r in await db.query('lexicon_extra')) {
      (s._extra[r['ayah_id'] as int] ??= []).add(r['token'] as String);
    }
    // الرموز الأصلية من عمودي FTS (norm للتفسير؟ لا: norm للقرآن، tafsir للتفسير).
    s._originals = {};
    final rows = await db.rawQuery(
      'SELECT ayahs_fts.rowid AS gid, ayahs_fts.norm AS ncol, '
      'ayahs_fts.tafsir AS tcol FROM ayahs_fts ORDER BY ayahs_fts.rowid',
    );
    for (final r in rows) {
      final gid = r['gid'] as int;
      final q = reconstructOriginals(r['ncol'] as String? ?? '');
      q.addAll(s._extra[gid] ?? const []);
      s._originals[gid] = _AyahOriginals(
        quran: q,
        tafsir: reconstructOriginals(r['tcol'] as String? ?? ''),
      );
    }
    return s;
  }

  // ---- norm(): حرفي من phase0/fts_test.py ----
  static String norm(String s) {
    s = s
        .replaceAll('\u0648\u0670', 'ا')
        .replaceAll('\u0649\u0670', 'ى')
        .replaceAll('\u0670', 'ا');
    s = s.replaceAll(RegExp(r'[\u064B-\u065F\u06D6-\u06ED\u0640]'), '');
    s = s
        .replaceAll(RegExp(r'[إأآٱ]'), 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll('ة', 'ه');
    s = s.replaceAll(RegExp(r'[^\u0621-\u064A\u0660-\u0669a-zA-Z0-9\s]'), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ---- _stripPrefixOld(): حرفي من tools/build_db.py ----
  // يعيد أول تجريد مطابق (مركّب ثم ال ثم حرف واحد) أو null.
  static String? stripPrefixOld(String w) {
    for (final p in _compound) {
      if (w.startsWith(p) && w.length - p.length >= 2) return w.substring(p.length);
    }
    if (w.startsWith('ال') && w.length - 2 >= 3) return w.substring(2);
    for (final p in _single) {
      if (w.startsWith(p) && w.length - 1 >= 2) return w.substring(1);
    }
    return null;
  }

  /// إعادة بناء الرموز الأصلية من عمود FTS: كل أصلي متبوع بنسخته
  /// المجرّدة؛ تُسقط النسخة إلا في حالة السلسلة (chain rescue):
  /// الرمز الذي يساوي تجريد سابقه يُبقى إن كان التالي يساوي تجريده هو،
  /// لأنه خُزّن أصلياً (مثال: تفسير 7:21 «لكما كما ما قلت»؛
  /// و28:45 «ولكنا لكنا كنا نا»).
  static List<String> reconstructOriginals(String column) {
    final toks = column.split(' ').where((t) => t.isNotEmpty).toList();
    final orig = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (i > 0 && stripPrefixOld(toks[i - 1]) == t) {
        if (i + 1 < toks.length && stripPrefixOld(t) == toks[i + 1]) {
          orig.add(t); // إنقاذ السلسلة: أصلي لا نسخة
          continue;
        }
        continue;
      }
      orig.add(t);
    }
    return orig;
  }

  // ---- termVariantsNew(): حرفي من phase0/fts_test.py ----
  static String? _stripCompound(String t) {
    for (final p in _compound) {
      if (t.startsWith(p) && t.length - p.length >= 2) return t.substring(p.length);
    }
    return null;
  }

  static String? _stripAl(String t) {
    if (t.startsWith('ال') && t.length - 2 >= 3) return t.substring(2);
    return null;
  }

  static String? _stripSingleNew(String t) {
    for (final p in _single) {
      if (t.startsWith(p)) {
        final rest = t.substring(1);
        if (rest.length >= 2 &&
            ((rest.startsWith('ال') && rest.length >= 3) || rest.length >= 5)) {
          return rest;
        }
      }
    }
    return null;
  }

  static Set<String> termVariantsNew(String t) {
    final variants = <String>{t};
    var strippedAny = false;
    for (final f in [_stripCompound, _stripAl, _stripSingleNew]) {
      final v = f(t);
      if (v != null && v != t) {
        variants.add(v);
        strippedAny = true;
      }
    }
    if (!strippedAny && !t.startsWith('ال')) variants.add('ال' + t);
    return variants;
  }

  // ---- fallbackBase(): حرفي من fts3_test.py ----
  // مركّب/ال غير مشروط؛ حرف واحد فقط إن كان الباقي قاعدة معروفة
  // والسطح نفسه ليس قاعدة معروفة (هذا ما يمنع كانت←انت ويسمح لموسى).
  String _fallbackBase(String w) {
    for (final p in _compound) {
      if (w.startsWith(p) && w.length - p.length >= 2) return w.substring(p.length);
    }
    if (w.startsWith('ال') && w.length - 2 >= 3) return w.substring(2);
    for (final p in _single) {
      if (w.startsWith(p) && w.length - 1 >= 2) {
        final r = w.substring(1);
        if (_bases.contains(r) && !_bases.contains(w)) return r;
      }
    }
    return w;
  }

  /// قاعدة حدّ الاستعلام: المعجم أولاً (التفسير ثم القرآن في نطاق
  /// التفسير، والقرآن أولاً في نطاق القرآن)، وإلا fallback.
  String queryBase(String term, _Scope scope) {
    final t = norm(term);
    if (scope == _Scope.tafsir && _lexT.containsKey(t)) return _lexT[t]!;
    if (_lexQ.containsKey(t)) return _lexQ[t]!;
    if (_lexT.containsKey(t)) return _lexT[t]!;
    return _fallbackBase(t);
  }

  String _baseOfQ(String w) => _lexQ[w] ?? _fallbackBase(w);
  String _baseOfT(String w) => _lexT[w] ?? _fallbackBase(w);

  // ---- المسند: آية تطابق حداً إن بدأ أحد رموزها (أو قاعدته) بقاعدة الحدّ ----
  bool _termMatches(List<String> originals, String bq, String Function(String) baseOf) {
    for (final w in originals) {
      if (w.startsWith(bq) || baseOf(w).startsWith(bq)) return true;
    }
    return false;
  }

  bool _ayahMatches(int gid, List<String> bqs, _Scope scope) {
    final o = _originals[gid];
    if (o == null) return false;
    if (scope == _Scope.quran) {
      return bqs.every((bq) => _termMatches(o.quran, bq, _baseOfQ));
    }
    return bqs.every((bq) => _termMatches(o.tafsir, bq, _baseOfT));
  }

  // ---- المرشحون من FTS: variants(الحدّ) ∪ variants(قاعدته) +
  // توسيع معجمي للأسطح التي تفوتها variants العادية (متعددة البوادئ
  // مثل وبالمؤمنين، والمسبوقة بألف مثل أفلا) ----
  Future<Set<int>> _candidates(
      Database db, List<String> terms, _Scope scope) async {
    final col = scope == _Scope.quran ? 'norm' : 'tafsir';
    final byBase = scope == _Scope.quran ? _byBaseQ : _byBaseT;
    final groups = <String>[];
    for (final term in terms) {
      final t = norm(term);
      final bq = queryBase(term, scope);
      final allv = {...termVariantsNew(t), ...termVariantsNew(bq)};
      final needed = <String>{};
      for (final entry in byBase.entries) {
        if (!entry.key.startsWith(bq)) continue;
        for (final s in entry.value) {
          if (allv.any((v) => s.startsWith(v))) continue;
          final st = stripPrefixOld(s);
          if (st != null && allv.any((v) => st.startsWith(v))) continue;
          needed.add(s);
        }
      }
      final vs = <String>{...allv};
      for (final s in needed) {
        vs.addAll(termVariantsNew(s));
      }
      groups.add('(' +
          vs.map((v) => '{$col} : "$v"*').join(' OR ') +
          ')');
    }
    final expr = groups.join(' AND ');
    final rows = await db.rawQuery(
      'SELECT rowid FROM ayahs_fts WHERE ayahs_fts MATCH ?',
      [expr],
    );
    return {for (final r in rows) r['rowid'] as int};
  }

  /// البحث الجديد: يعيد معرّفات الآيات (rowid = ayahs.id) المطابقة.
  /// [scope]: 'quran' لنطاق القرآن، 'tafsir' لنطاق التفسير.
  Future<Set<int>> search(Database db, String query, _Scope scope) async {
    final terms = norm(query).split(' ').where((t) => t.isNotEmpty).toList();
    if (terms.isEmpty) return {};
    final bqs = [for (final t in terms) queryBase(t, scope)];
    final cands = await _candidates(db, terms, scope);
    return {for (final gid in cands) if (_ayahMatches(gid, bqs, scope)) gid};
  }
}

enum _Scope { quran, tafsir }

class _AyahOriginals {
  _AyahOriginals({required this.quran, required this.tafsir});
  final List<String> quran;
  final List<String> tafsir;
}
