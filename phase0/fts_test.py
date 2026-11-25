#!/usr/bin/env python3
"""Phase 0 — Tilawa FTS5 Arabic search: baseline vs fixed (experimental DB).

Task B: rebuild the normalisation/index logic LITERALLY from
tools/build_db.py + lib/db.dart in a small experimental FTS5 table,
implement the fix proposed in AUDIT_2026-11-25.md §3, and test it.

Fix under test (audit §3):
  (a) apply the same prefix-stripping on the QUERY side in Dart:
      for each term generate {original, stripped وال/فال/بال/لل/كال,
      stripped ال, stripped و/ف/ب/ل/ك};
  (b) restrict single-letter stripping: strip و/ف/ب/ل/ك ONLY if the
      remainder starts with «ال» or its length is >= 5 — blocks
      انت <- كانت, سم <- بسم, تابا <- كتابا, keeps والصلاة <- الصلاة;
  (c) move tafsir search onto the FTS column itself (ayahs_fts.tafsir)
      instead of LIKE on the raw tafsir table.

Scope / honesty notes:
  * Sample ayahs are REAL Quranic fragments (with surah:ayah refs) but
    this is a TEST FIXTURE, not the real 6236-ayah database. Tafsir
    texts here are SYNTHETIC fixtures written for the test (labelled
    as such below) — they are NOT real tafsir quotations.
  * lib/db.dart and tools/build_db.py are NOT modified by this script.
    The fixed functions below are Python ports of the proposed Dart /
    Python changes; the Dart equivalent is written up in
    FTS_TEST_RESULTS.md for the implementing step.
  * One deliberate preservation, VERIFIED redundant on this fixture:
    the old _searchExpr also added the «ال»+term variant for bare terms
    (صلاة -> الصلاة). The fixed generator keeps it for bare terms
    only (no stripping applied). A follow-up ablation re-ran the whole
    26-test suite with that variant removed: 0 failures in both the
    Quran and the tafsir suites — because index-side stripping already
    stores the bare stem for every prefixed form (وال strips و+ال, so
    «والمؤمنون» is indexed as «مؤمنون»). So the preservation is
    harmless but NOT needed for recall on this fixture; the implementer
    may keep it (pre-existing behaviour) or drop it. One theoretical
    case where it matters: short «ال»-words whose ال-strip is blocked
    by the length guard (e.g. «الله», remainder «له» < 3): a bare query
    «له» would then also match «الله» — pre-existing old behaviour,
    arguably noise, not tested as required either way.
  * One deliberate safety guard, documented in the results file: a
    single-letter strip whose remainder is exactly «ال» (query term
    «وال»/«فال»/… alone) is NOT emitted, because «"ال"*» as a prefix
    query would match every «ال»-token in the index.

Run:  python3 fts_test.py        (exit 0 = all required tests pass)
"""
import re
import sqlite3
import sys

# --------------------------------------------------------------------------
# 1. VERBATIM from tools/build_db.py (do not "improve" — this is the baseline)
# --------------------------------------------------------------------------
TASHKEEL = re.compile(r'[\u064B-\u065F\u06D6-\u06ED\u0640]')
ALEF = re.compile(r'[إأآٱ]')
NONWORD = re.compile(r'[^\u0621-\u064A\u0660-\u0669a-zA-Z0-9\s]')
SPACES = re.compile(r'\s+')


def norm(s):
    s = s.replace('\u0648\u0670', 'ا').replace('\u0649\u0670', 'ى').replace('\u0670', 'ا')
    s = TASHKEEL.sub('', s)
    s = ALEF.sub('ا', s).replace('ى', 'ي').replace('ة', 'ه')
    s = NONWORD.sub(' ', s)
    return SPACES.sub(' ', s).strip()


def _strip_prefix_old(w):
    """VERBATIM from tools/build_db.py (unrestricted single-letter strip)."""
    for p in ('وال', 'فال', 'بال', 'لل', 'كال'):
        if w.startswith(p) and len(w) - len(p) >= 2:
            return w[len(p):]
    if w.startswith('ال') and len(w) - 2 >= 3:
        return w[2:]
    for p in ('و', 'ف', 'ب', 'ل', 'ك'):
        if w.startswith(p) and len(w) - 1 >= 2:
            return w[1:]
    return None


def search_norm_old(s):
    words = norm(s).split(' ')
    out = []
    for w in words:
        if not w:
            continue
        out.append(w)
        stripped = _strip_prefix_old(w)
        if stripped and stripped != w:
            out.append(stripped)
    return ' '.join(out)


# --------------------------------------------------------------------------
# 2. FIXED index-side stripping (audit §3 rule b) — same shape as above,
#    only the single-letter branch gains the restriction.
# --------------------------------------------------------------------------
def _strip_prefix_new(w):
    for p in ('وال', 'فال', 'بال', 'لل', 'كال'):
        if w.startswith(p) and len(w) - len(p) >= 2:
            return w[len(p):]
    if w.startswith('ال') and len(w) - 2 >= 3:
        return w[2:]
    for p in ('و', 'ف', 'ب', 'ل', 'ك'):
        if w.startswith(p):
            rest = w[1:]
            # Restricted: remainder must start with «ال» (and be at least
            # 3 chars, so the degenerate remainder «ال» itself is never
            # emitted) OR be at least 5 chars long.
            if len(rest) >= 2 and ((rest.startswith('ال') and len(rest) >= 3)
                                   or len(rest) >= 5):
                return rest
    return None


def search_norm_new(s):
    words = norm(s).split(' ')
    out = []
    for w in words:
        if not w:
            continue
        out.append(w)
        stripped = _strip_prefix_new(w)
        if stripped and stripped != w:
            out.append(stripped)
    return ' '.join(out)


# --------------------------------------------------------------------------
# 3. Query side. OLD: literal port of lib/db.dart _searchExpr.
#    NEW: audit §3 rule (a) — all four variants per term.
# --------------------------------------------------------------------------
def search_expr_old(normed):
    """Literal port of lib/db.dart _searchExpr (baseline)."""
    groups = []
    for t in normed.split(' '):
        if not t:
            continue
        variants = {t}
        if t.startswith('ال') and len(t) > 4:
            variants.add(t[2:])
        else:
            variants.add('ال' + t)
        groups.append('(' + ' OR '.join('"%s"*' % v for v in sorted(variants)) + ')')
    return ' AND '.join(groups)


COMPOUND = ('وال', 'فال', 'بال', 'لل', 'كال')
SINGLE = ('و', 'ف', 'ب', 'ل', 'ك')


def _strip_compound(t):
    for p in COMPOUND:
        if t.startswith(p) and len(t) - len(p) >= 2:
            return t[len(p):]
    return None


def _strip_al(t):
    if t.startswith('ال') and len(t) - 2 >= 3:
        return t[2:]
    return None


def _strip_single(t):
    for p in SINGLE:
        if t.startswith(p):
            rest = t[1:]
            if len(rest) >= 2 and ((rest.startswith('ال') and len(rest) >= 3)
                                   or len(rest) >= 5):
                return rest
    return None


def term_variants_new(t):
    """Fixed per-term variants (audit §3a) + preserved bare-term «ال»+t."""
    variants = {t}
    stripped_any = False
    for f in (_strip_compound, _strip_al, _strip_single):
        v = f(t)
        if v and v != t:
            variants.add(v)
            stripped_any = True
    # Preserve old _searchExpr behaviour for BARE terms only (see the
    # docstring: verified redundant on this fixture — the suite passes
    # 26/26 with it removed — but kept as pre-existing behaviour).
    if not stripped_any and not t.startswith('ال'):
        variants.add('ال' + t)
    return variants


def search_expr_new(normed):
    groups = []
    for t in normed.split(' '):
        if not t:
            continue
        variants = term_variants_new(t)
        groups.append('(' + ' OR '.join('"%s"*' % v for v in sorted(variants)) + ')')
    return ' AND '.join(groups)


def tafsir_expr_new(normed):
    """Fixed tafsir search (audit §3c): same variants, scoped to the
    tafsir column of ayahs_fts instead of LIKE on the raw tafsir table.
    FTS5 column-filter syntax, verified against SQLite 3.45.1 in the
    probe step: ({tafsir} : "v1"* OR {tafsir} : "v2"*) per term, ANDed."""
    groups = []
    for t in normed.split(' '):
        if not t:
            continue
        variants = term_variants_new(t)
        inner = ' OR '.join('{tafsir} : "%s"*' % v for v in sorted(variants))
        groups.append('(' + inner + ')')
    return ' AND '.join(groups)


def search_tafsir_like_old(con, q):
    """Literal port of lib/db.dart _searchTafsirSync (baseline): LIKE on
    the RAW tafsir text, words stripped of tashkeel only, variants
    {raw, normalized}."""
    words = [re.sub(r'[\u064B-\u065F\u06D6-\u06ED\u0640]', '', w.strip())
             for w in q.split(' ')]
    words = [w for w in words if len(w) > 1]
    if not words:
        return []
    clauses, args = [], []
    for w in words:
        variants = {w, norm(w)}
        if len(variants) == 1:
            clauses.append('t.text LIKE ?')
            args.append('%' + next(iter(variants)) + '%')
        else:
            clauses.append('(t.text LIKE ? OR t.text LIKE ?)')
            args.extend('%' + v + '%' for v in sorted(variants))
    sql = ('SELECT a.id FROM tafsir t JOIN ayahs a '
           'ON a.surah=t.surah AND a.ayah=t.ayah WHERE ' + ' AND '.join(clauses))
    return [r[0] for r in con.execute(sql, args)]


# --------------------------------------------------------------------------
# 4. Sample data — REAL Quranic fragments (refs given) as TEST FIXTURES.
#    Tafsir texts are SYNTHETIC fixtures for this test, NOT real tafsir.
# --------------------------------------------------------------------------
# (id, surah, ayah, simple-clean text, synthetic tafsir fixture)
SAMPLES = [
    (1, 1, 1, 'بسم الله الرحمن الرحيم',
     'ابتداء القراءة بسم الله الرحمن الرحيم'),
    (2, 2, 3, 'الذين يؤمنون بالغيب ويقيمون الصلاة',
     'يؤمنون بالغيب ويقيمون الصلاة عماد الدين'),
    (3, 2, 43, 'وأقيموا الصلاة وآتوا الزكاة',
     'الزكاة حق المال يؤخذ من الأغنياء'),
    (4, 2, 153, 'يا أيها الذين آمنوا استعينوا بالصبر والصلاة',
     'استعينوا بالصبر والصلاة على الشدائد'),
    (5, 2, 155, 'وبشر الصابرين الذين إذا أصابتهم مصيبة قالوا إنا لله وإنا إليه راجعون',
     'بشر الصابرين بالثواب الجزيل'),
    (6, 4, 103, 'إن الصلاة كانت على المؤمنين كتابا موقوتا',
     'كانت الصلاة مفروضة على المؤمنين في أوقات محددة'),
    (7, 6, 59, 'وعنده مفاتح الغيب لا يعلمها إلا هو',
     'الغيب ما غاب عن الخلق ولا يعلمه إلا الله'),
    (8, 2, 2, 'ذلك الكتاب لا ريب فيه هدى للمتقين',
     'هدى للمتقين الذين يعملون بالكتاب'),
    (9, 9, 71, 'والمؤمنون والمؤمنات بعضهم أولياء بعض',
     'المؤمنون والمؤمنات يتناصرون'),
]
NAMES = {s[0]: '%d:%d' % (s[1], s[2]) for s in SAMPLES}


def build_db(search_norm_fn):
    """Same schema shape as tools/build_db.py (ayahs_fts with norm+tafsir
    columns, unicode61, remove_diacritics 0)."""
    con = sqlite3.connect(':memory:')
    cur = con.cursor()
    cur.executescript('''
    CREATE TABLE surahs(id INTEGER PRIMARY KEY, name_short TEXT);
    CREATE TABLE ayahs(id INTEGER PRIMARY KEY, surah INTEGER, ayah INTEGER,
                       text TEXT, juz INTEGER, hizb INTEGER, quarter INTEGER,
                       page INTEGER, sajda INTEGER);
    CREATE TABLE tafsir(surah INTEGER, ayah INTEGER, source TEXT, text TEXT,
                        PRIMARY KEY(surah, ayah, source));
    CREATE VIRTUAL TABLE ayahs_fts USING fts5(norm, tafsir,
        tokenize='unicode61 remove_diacritics 0');
    ''')
    cur.execute("INSERT INTO surahs VALUES(1,'الفاتحة')")
    for sid in (2, 4, 6, 9):
        cur.execute('INSERT INTO surahs VALUES(?,?)', (sid, 'سورة %d' % sid))
    for gid, surah, ayah, text, tf in SAMPLES:
        cur.execute('INSERT INTO ayahs VALUES(?,?,?,?,?,?,?,?,?)',
                    (gid, surah, ayah, text, 1, 1, 1, 1, 0))
        cur.execute('INSERT INTO tafsir VALUES(?,?,?,?)',
                    (surah, ayah, 'fixture', tf))
        cur.execute('INSERT INTO ayahs_fts(rowid, norm, tafsir) VALUES(?,?,?)',
                    (gid, search_norm_fn(text), search_norm_fn(tf)))
    cur.execute("INSERT INTO ayahs_fts(ayahs_fts) VALUES('optimize')")
    con.commit()
    return con


def search_quran(con, q, expr_fn):
    n = norm(q)
    if not n:
        return []
    expr = expr_fn(n)
    rs = con.execute(
        'SELECT a.id FROM ayahs_fts JOIN ayahs a ON a.id=ayahs_fts.rowid '
        'WHERE ayahs_fts MATCH ? ORDER BY rank LIMIT 50', (expr,))
    return [r[0] for r in rs]


def search_tafsir_fts(con, q):
    n = norm(q)
    if not n:
        return []
    expr = tafsir_expr_new(n)
    rs = con.execute(
        'SELECT a.id FROM ayahs_fts JOIN ayahs a ON a.id=ayahs_fts.rowid '
        'WHERE ayahs_fts MATCH ? ORDER BY rank LIMIT 30', (expr,))
    return [r[0] for r in rs]


def fmt(ids):
    return '{%s}' % ','.join(NAMES[i] for i in sorted(ids)) if ids else '{}'


# --------------------------------------------------------------------------
# 5. Test matrix
# --------------------------------------------------------------------------
# (query, expected_ids_or_None, note)
# expected=None means "expect empty"; otherwise the exact expected set.
QURAN_REQUIRED = [
    ('بالصلاة', {2, 3, 4, 6}, 'must succeed'),
    ('والمؤمنين', {6}, 'must succeed'),
    ('فالغيب', {2, 7}, 'must succeed'),
    ('للصابرين', {5}, 'must succeed'),
    ('انت', set(), 'must NOT find كانت (4:103)'),
    ('سم', set(), 'must NOT find بسم (1:1)'),
    ('تابا', set(), 'must NOT find كتابا (4:103)'),
]
QURAN_PROBES = [
    ('الصلاة', {2, 3, 4, 6}, 'bare ال-form (baseline already OK)'),
    ('صلاة', {2, 3, 4, 6}, 'bare term'),
    ('مؤمنون', {9}, 'bare term (text has والمؤمنون; passes with or without ال+t)'),
    ('بالغيب', {2, 7}, 'desired {2:3,6:59}; baseline finds only literal بالغيب (2:3)'),
    ('بصلاة', set(), 'KNOWN TRADE-OFF of rule (b): remainder صلاة is 4 chars, not ال- — still 0'),
    ('بصابرين', {5}, 'single-letter + long remainder (>=5) still strips'),
    ('كانت', {6}, 'the real word itself must still be found'),
    ('الذين يؤمنون', {2}, 'multi-term AND'),
    ('بالصلاة والزكاة', {3}, 'multi-term AND, prefix forms'),
    ('مؤمنين', {6}, 'bare term'),
    ('للمتقين', {8}, 'للمتقين (baseline OK: literal token exists)'),
]
TAFSIR_TESTS = [
    ('بالصلاة', {2, 4, 6}, 'FTS tafsir; NOT 2:43 (its tafsir has no صلاة) — scoping'),
    ('الصابرين', {5}, 'FTS tafsir'),
    ('انت', set(), 'FTS tafsir must NOT match كانت in 4:103 tafsir'),
    ('زكاة', {3}, 'FTS tafsir'),
    ('سم', set(), 'FTS tafsir must NOT match بسم in 1:1 tafsir'),
    ('الغيب', {2, 7}, 'FTS tafsir'),
    ('زكاه', {3}, 'ه-spelling query: FTS normalises both sides; LIKE cannot'),
    ('الصلاه', {2, 4, 6}, 'ه-spelling query: FTS normalises both sides; LIKE cannot'),
]


def run_suite(label, con, quran_fn, tafsir_fn, tafsir_old_fn=None):
    print('=' * 78)
    print(label)
    print('=' * 78)
    fails = 0
    total = 0
    for section, cases, fn in (('QURAN — required', QURAN_REQUIRED, quran_fn),
                               ('QURAN — extra probes', QURAN_PROBES, quran_fn)):
        print('\n-- %s --' % section)
        for q, expected, note in cases:
            total += 1
            got = set(fn(q))
            ok = got == expected
            if not ok:
                fails += 1
            print('%-18s expected %-16s got %-16s %s  [%s]'
                  % (q, fmt(expected), fmt(got), 'PASS' if ok else 'FAIL', note))
    print('\n-- TAFSIR --')
    for q, expected, note in TAFSIR_TESTS:
        total += 1
        got = set(tafsir_fn(q))
        ok = got == expected
        if not ok:
            fails += 1
        line = ('%-18s expected %-16s got %-16s %s  [%s]'
                % (q, fmt(expected), fmt(got), 'PASS' if ok else 'FAIL', note))
        if tafsir_old_fn is not None:
            old = set(tafsir_old_fn(q))
            line += '   | old-LIKE: %s' % fmt(old)
        print(line)
    print('\n%s: %d/%d passed, %d failed' % (label, total - fails, total, fails))
    return fails


def main():
    print('SQLite %s | FTS5 experimental DB, 9 sample ayahs' % sqlite3.sqlite_version)
    print('Sample ayahs (real fragments, test fixtures):')
    for gid, s, a, text, _ in SAMPLES:
        print('  %d:%d  %s' % (s, a, text))
    print('Tafsir texts are SYNTHETIC fixtures, not real tafsir quotations.')
    print()

    # Show what the index actually contains, old vs new (auditability).
    for label, fn in (('OLD index (search_norm, unrestricted strip)', search_norm_old),
                      ('NEW index (search_norm, restricted strip)', search_norm_new)):
        print('-- %s --' % label)
        for gid, s, a, text, _ in SAMPLES:
            print('  %d:%d norm=[%s]' % (s, a, fn(text)))
        print()

    old_con = build_db(search_norm_old)
    new_con = build_db(search_norm_new)

    # Baseline failures are EXPECTED (they are the bugs being fixed) and
    # must NOT count toward the verdict: only the FIXED suite decides
    # whether the fix works. The baseline run is reported for comparison.
    baseline_fails = run_suite(
        'BASELINE (old index + old _searchExpr + old LIKE tafsir)',
        old_con,
        lambda q: search_quran(old_con, q, search_expr_old),
        lambda q: search_tafsir_like_old(old_con, q),
        tafsir_old_fn=None)

    # Fixed: new index + new query + new FTS tafsir — THIS decides pass/fail.
    fixed_fails = run_suite(
        'FIXED (new index + new query variants + FTS tafsir column)',
        new_con,
        lambda q: search_quran(new_con, q, search_expr_new),
        lambda q: search_tafsir_fts(new_con, q),
        tafsir_old_fn=lambda q: search_tafsir_like_old(new_con, q))

    # Ablation: prove BOTH halves are necessary (required queries only).
    print('=' * 78)
    print('ABLATION — required Quran queries only (proves both halves needed)')
    print('=' * 78)
    for label, con, fn in (
            ('old index + NEW query', old_con,
             lambda q: search_quran(old_con, q, search_expr_new)),
            ('new index + OLD query', new_con,
             lambda q: search_quran(new_con, q, search_expr_old))):
        print('\n-- %s --' % label)
        for q, expected, note in QURAN_REQUIRED:
            got = set(fn(q))
            print('%-18s expected %-16s got %-16s %s'
                  % (q, fmt(expected), fmt(got), 'PASS' if got == expected else 'FAIL'))
    # Ablation verdicts (computed, not asserted by eye)
    abl1 = all(set(search_quran(old_con, q, search_expr_new)) == e
               for q, e, _ in QURAN_REQUIRED)
    abl2 = all(set(search_quran(new_con, q, search_expr_old)) == e
               for q, e, _ in QURAN_REQUIRED)
    print('\nAblation verdict: old-index+new-query all-required-pass=%s (expect False:'
          ' FP tokens انت/سم/تابا survive in old index)' % abl1)
    print('Ablation verdict: new-index+old-query all-required-pass=%s (expect False:'
          ' prefix queries بالصلاة/والمؤمنين/فالغيب/للصابرين still fail)' % abl2)

    print()
    print('SUMMARY: baseline %d/26 failed (expected — these are the bugs); '
          'FIXED suite %d/26 failed.' % (baseline_fails, fixed_fails))
    print('FINAL: %s'
          % ('ALL FIXED-SUITE TESTS PASSED — fix works on this fixture'
             if fixed_fails == 0
             else ('%d FIXED-SUITE TEST(S) FAILED — fix does NOT fully work as specified'
                  % fixed_fails)))
    return 1 if fixed_fails else 0


if __name__ == '__main__':
    sys.exit(main())
