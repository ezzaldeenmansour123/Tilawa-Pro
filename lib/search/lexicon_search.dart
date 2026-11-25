// بحث معجمي (FTS3 — Lexicon) — تلاوة برو.
//
// Pure-Dart query builder: normalization + base resolution + FTS5
// MATCH-expression generation. NO database dependency, so it is
// unit-testable (see test/lexicon_test.dart). The DB-backed search
// that uses it lives in lib/db.dart (_searchLexiconSync).
//
// Ported verbatim from the verified Python implementation:
//   ~/workspace/tilawa/phase1/fts3/fts3_test.py
//   ~/workspace/tilawa/phase1/fts3/build_lexicon.py
//   ~/workspace/tilawa/phase0/fts_test.py  (norm + termVariantsNew)
// Verified on the full 6,236-ayah DB (run 5, 41 queries, missing=0):
//   بالصلاة قرآن 63، فالغيب 48، للصابرين 15، والمؤمنين 142،
//   بصابرين 15، موسى 452/452، قال 3079/3079، يوم 1234/1235
//   (−1 تفسير: 2:239 ويومئ)، ما 5229/5230 (−1 تفسير: 7:97 ومامن).
// Full rationale: ~/workspace/tilawa/phase1/fts3/LEXICON_RESULTS.md
//
// Design in one line: instead of blindly stripping a prefix (which
// cannot tell كانت←انت apart from لموسى), every surface token maps
// to its morphological BASE (from Quranic Arabic Corpus v0.4), and
// matching is done on bases, not on blindly stripped tokens.
//
// Tables required in the library DB (see tools/attach_lexicon.py):
//   lexicon(surface TEXT PRIMARY KEY, base TEXT, votes INTEGER, source TEXT)
//   lexicon_tafsir(surface TEXT PRIMARY KEY, base TEXT, source TEXT)
//   lexicon_extra(ayah_id INTEGER, token TEXT)
//   lexicon_meta(key TEXT PRIMARY KEY, value TEXT)
//
// LICENCE: the lexicon tables are DERIVED from Quranic Arabic Corpus
// v0.4 (GPL, corpus.quran.com). Attribution is REQUIRED (README.md
// + the in-app About/Settings screen). Legal confirmation for
// shipping the derived tables is STILL PENDING — recorded in
// lexicon_meta ('license_note') and in the lexicon report.
// Never modify any ayah text; normalization lives in separate
// columns/tables only.

/// Search scope: Quran text (the `norm` FTS column) or tafsir text
/// (the `tafsir` FTS column).
enum LexiconScope { quran, tafsir }

/// Must stay identical to normalizeAr() in lib/db.dart and norm() in
/// tools/build_db.py. Uthmani spelling: the dagger alef (U+0670) is a
/// letter, not a mark: "وٰ" is pronounced as a long "a" (الصلوة =
/// الصلاة), a bare dagger alef is an alef (عِظَٰمًا = عظامًا), but
/// after ى it is only a length mark (أَوۡحَىٰ = أوحى).
String lexiconNormalize(String s) {
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

/// The OLD (unrestricted) prefix strip, verbatim from
/// tools/build_db.py _strip_prefix(). Used ONLY to reconstruct the
/// original tokens stored in the FTS column (see
/// [LexiconQueryBuilder.reconstructOriginals]) — never to decide a
/// match, which is what made the old search produce false positives.
String? lexiconStripPrefixOld(String w) {
  for (final p in LexiconQueryBuilder.compoundPrefixes) {
    if (w.startsWith(p) && w.length - p.length >= 2) {
      return w.substring(p.length);
    }
  }
  if (w.startsWith('ال') && w.length - 2 >= 3) return w.substring(2);
  for (final p in LexiconQueryBuilder.singlePrefixes) {
    if (w.startsWith(p) && w.length - 1 >= 2) {
      return w.substring(1);
    }
  }
  return null;
}

/// Lexicon-driven search: resolves query terms to morphological bases
/// and builds the FTS5 candidate expression. The lexicon maps are
/// passed in (surface -> base); the builder never touches a database.
///
/// Matching is by PREFIX on purpose (انت→انتقام، سم→سميع/سماوات);
/// what the lexicon removes is only the FALSE stripped copies
/// (كانت←انت، بسم←سم، كتابا←تابا).
class LexiconQueryBuilder {
  LexiconQueryBuilder({
    required Map<String, String> lexiconQuran,
    required Map<String, String> lexiconTafsir,
  })  : _lexQ = Map.unmodifiable(lexiconQuran),
        _lexT = Map.unmodifiable(lexiconTafsir),
        _bases = {...lexiconQuran.values, ...lexiconTafsir.values} {
    for (final e in _lexQ.entries) {
      (_byBaseQ[e.value] ??= []).add(e.key);
    }
    for (final e in _lexT.entries) {
      (_byBaseT[e.value] ??= []).add(e.key);
    }
  }

  static const compoundPrefixes = ['وال', 'فال', 'بال', 'لل', 'كال'];
  static const singlePrefixes = ['و', 'ف', 'ب', 'ل', 'ك'];

  final Map<String, String> _lexQ; // Quran surface -> base (QAC)
  final Map<String, String> _lexT; // tafsir surface -> base (fallback)
  final Set<String> _bases; // every known base (Quran + tafsir)
  final Map<String, List<String>> _byBaseQ = {};
  final Map<String, List<String>> _byBaseT = {};

  /// Rebuild the ORIGINAL tokens of one FTS column: every original is
  /// stored followed by its stripped copy; the copy is dropped —
  /// except in a chain (chain rescue): a token that is the strip of
  /// its predecessor is kept if the NEXT token is its own strip,
  /// because that proves it was itself stored as an original (a copy
  /// is never followed by its own strip). Example: tafsir 7:21
  /// «لكما كما ما قلت» and 28:45 «ولكنا لكنا كنا نا».
  static List<String> reconstructOriginals(String column) {
    final toks = column.split(' ').where((t) => t.isNotEmpty).toList();
    final orig = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      if (i > 0 && lexiconStripPrefixOld(toks[i - 1]) == t) {
        if (i + 1 < toks.length &&
            lexiconStripPrefixOld(t) == toks[i + 1]) {
          orig.add(t); // chain rescue: a real original, not a copy
          continue;
        }
        continue;
      }
      orig.add(t);
    }
    return orig;
  }

  static String? _stripCompound(String t) {
    for (final p in compoundPrefixes) {
      if (t.startsWith(p) && t.length - p.length >= 2) {
        return t.substring(p.length);
      }
    }
    return null;
  }

  static String? _stripAl(String t) {
    if (t.startsWith('ال') && t.length - 2 >= 3) return t.substring(2);
    return null;
  }

  static String? _stripSingleNew(String t) {
    for (final p in singlePrefixes) {
      if (t.startsWith(p)) {
        final rest = t.substring(1);
        if (rest.length >= 2 &&
            ((rest.startsWith('ال') && rest.length >= 3) ||
                rest.length >= 5)) {
          return rest;
        }
      }
    }
    return null;
  }

  /// FTS term variants, verbatim from phase0/fts_test.py
  /// term_variants_new(): the term itself plus one strip level
  /// (compound, ال, single-letter with a length guard); if nothing
  /// stripped and the term does not start with ال, also ال+term.
  static Set<String> termVariants(String t) {
    final variants = <String>{t};
    var strippedAny = false;
    for (final f in [_stripCompound, _stripAl, _stripSingleNew]) {
      final v = f(t);
      if (v != null && v != t) {
        variants.add(v);
        strippedAny = true;
      }
    }
    if (!strippedAny && !t.startsWith('ال')) variants.add('ال$t');
    return variants;
  }

  /// Fallback base (verbatim from fts3_test.py): compound/ال strips
  /// are unconditional (safe); a single-letter strip applies ONLY if
  /// the remainder is a known base AND the surface is not itself a
  /// known base. This is what keeps كانت/بسم/كتابا/وعد/فارض whole
  /// while stripping لموسى/ويوم/وقالوا/بصابرين.
  String fallbackBase(String w) {
    for (final p in compoundPrefixes) {
      if (w.startsWith(p) && w.length - p.length >= 2) {
        return w.substring(p.length);
      }
    }
    if (w.startsWith('ال') && w.length - 2 >= 3) return w.substring(2);
    for (final p in singlePrefixes) {
      if (w.startsWith(p) && w.length - 1 >= 2) {
        final r = w.substring(1);
        if (_bases.contains(r) && !_bases.contains(w)) return r;
      }
    }
    return w;
  }

  /// Base of a query term: the lexicon first (tafsir lexicon first in
  /// tafsir scope, Quran lexicon first in Quran scope), else the
  /// fallback. A known base maps to itself.
  String queryBase(String term, LexiconScope scope) {
    final t = lexiconNormalize(term);
    if (scope == LexiconScope.tafsir && _lexT.containsKey(t)) {
      return _lexT[t]!;
    }
    if (_lexQ.containsKey(t)) return _lexQ[t]!;
    if (_lexT.containsKey(t)) return _lexT[t]!;
    return fallbackBase(t);
  }

  /// Bases of all terms of a (normalized) query, in order.
  List<String> queryBases(List<String> terms, LexiconScope scope) =>
      [for (final t in terms) queryBase(t, scope)];

  String _baseOfQ(String w) => _lexQ[w] ?? fallbackBase(w);
  String _baseOfT(String w) => _lexT[w] ?? fallbackBase(w);

  /// Predicate: one term matches one ayah's original tokens iff some
  /// original token w satisfies w.startsWith(bq) OR
  /// base(w).startsWith(bq), where bq is the term's base.
  bool termMatches(List<String> originals, String bq, LexiconScope scope) {
    final baseOf = scope == LexiconScope.quran ? _baseOfQ : _baseOfT;
    for (final w in originals) {
      if (w.startsWith(bq) || baseOf(w).startsWith(bq)) return true;
    }
    return false;
  }

  /// An ayah matches iff EVERY query base matches its originals.
  bool ayahMatches(
      List<String> originals, List<String> bases, LexiconScope scope) {
    return bases.every((bq) => termMatches(originals, bq, scope));
  }

  /// FTS5 MATCH expression for the candidate set:
  /// variants(term) ∪ variants(base), ANDed across terms, plus the
  /// lexicon-driven expansion: surfaces whose base starts with the
  /// query base but which the plain variants miss — multi-prefix
  /// tokens (وبالمؤمنين، وللمؤمنين، فبما…) whose one-level copy
  /// starts with no variant, and أ-prefixed tokens (أفلا، أأنتم…)
  /// which have no stripped copy at all. Surfaces the plain variants
  /// already cover are skipped, so the expression stays small.
  /// Terms are ANDed explicitly (FTS5 rejects implicit AND between
  /// two parenthesised groups); variants of one term are ORed.
  String buildMatchExpression(List<String> terms, LexiconScope scope) {
    final col = scope == LexiconScope.quran ? 'norm' : 'tafsir';
    final byBase = scope == LexiconScope.quran ? _byBaseQ : _byBaseT;
    final groups = <String>[];
    for (final term in terms) {
      final t = lexiconNormalize(term);
      final bq = queryBase(term, scope);
      final allv = {...termVariants(t), ...termVariants(bq)};
      final needed = <String>{};
      for (final entry in byBase.entries) {
        if (!entry.key.startsWith(bq)) continue;
        for (final s in entry.value) {
          if (allv.any((v) => s.startsWith(v))) continue;
          final st = lexiconStripPrefixOld(s);
          if (st != null && allv.any((v) => st.startsWith(v))) continue;
          needed.add(s);
        }
      }
      final vs = <String>{...allv};
      for (final s in needed) {
        vs.addAll(termVariants(s));
      }
      final sortedVs = vs.toList()..sort();
      groups.add('(${sortedVs.map((v) => '{$col} : "$v"*').join(' OR ')})');
    }
    return groups.join(' AND ');
  }
}
