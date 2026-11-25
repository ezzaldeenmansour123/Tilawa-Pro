# Phase 0 — Tilawa FTS5 Arabic search: test results (Task B)

- Date: 2026-11-25. Environment: Python 3, SQLite 3.45.1, FTS5.
- Scope: local only, working copy `~/workspace/tilawa/`. **No push, no APK
  build, no modification of the original repo.** `lib/db.dart` and
  `tools/build_db.py` were NOT modified — the fix was implemented and tested
  as Python ports in the test script; the proposed real patch is in §6 below.
- Test script: [`fts_test.py`](sandbox:/workspace/tilawa/phase0/fts_test.py)
  (run: `python3 fts_test.py`, exit 0 = fixed suite passes).
  Full raw output:
  [`fts_test_output.txt`](sandbox:/workspace/tilawa/phase0/fts_test_output.txt).
- Fixture: 9 real Quranic fragments (refs given) in an experimental FTS5
  table built with the exact schema/tokenizer from `build_db.py`
  (`fts5(norm, tafsir, tokenize='unicode61 remove_diacritics 0')`), with
  `norm()` / `_strip_prefix()` copied verbatim and `_searchExpr()` ported
  literally from `lib/db.dart`. Tafsir texts in the fixture are SYNTHETIC
  (written for the test, labelled as such in the script) — NOT real tafsir.

## Verdict: YES — the fix works on this fixture

| Suite | Result |
|---|---|
| BASELINE (old index + old `_searchExpr` + old LIKE tafsir) | **11/26 passed, 15 failed** (the bugs, as documented in the audit) |
| FIXED (new index + new query variants + FTS tafsir column) | **26/26 passed, 0 failed** — exit code 0 |
| Ablation: old index + NEW query (required 7 only) | 4/7 — prefix queries fixed, but FP tokens survive |
| Ablation: new index + OLD query (required 7 only) | 3/7 — FPs gone, but prefix queries still fail |

Both halves of the fix are necessary: neither alone passes the required 7.
The index-side change alone does not fix the queries, and the query-side
change alone does not remove the false-positive tokens.

## 1. Quran search — required queries (before / after)

IDs are `surah:ayah`. "Expected" is the desired result in both columns.

| Query | Expected | BASELINE (got) | FIXED (got) |
|---|---|---|---|
| بالصلاة | {2:3, 2:43, 2:153, 4:103} | {} — FAIL | {2:3, 2:43, 2:153, 4:103} — PASS |
| والمؤمنين | {4:103} | {} — FAIL | {4:103} — PASS |
| فالغيب | {2:3, 6:59} | {} — FAIL | {2:3, 6:59} — PASS |
| للصابرين | {2:155} | {} — FAIL | {2:155} — PASS |
| انت | {} (must NOT find كانت) | {4:103} — FAIL (false positive) | {} — PASS |
| سم | {} (must NOT find بسم) | {1:1} — FAIL (false positive) | {} — PASS |
| تابا | {} (must NOT find كتابا) | {4:103} — FAIL (false positive) | {} — PASS |

Required: baseline 0/7, fixed 7/7.

## 2. Quran search — extra probes (before / after)

| Query | Expected | BASELINE | FIXED |
|---|---|---|---|
| الصلاة | {2:3, 2:43, 2:153, 4:103} | same — PASS | same — PASS |
| صلاة (bare) | {2:3, 2:43, 2:153, 4:103} | same — PASS | same — PASS |
| مؤمنون (bare) | {9:71} | {9:71} — PASS | {9:71} — PASS |
| بالغيب | {2:3, 6:59} | {2:3} only — FAIL (see note) | {2:3, 6:59} — PASS |
| بصلاة | {} (expected empty) | {} — PASS | {} — PASS (known trade-off, §5) |
| بصابرين | {2:155} | {} — FAIL | {2:155} — PASS |
| كانت | {4:103} | {4:103} — PASS | {4:103} — PASS |
| الذين يؤمنون | {2:3} | {2:3} — PASS | {2:3} — PASS |
| بالصلاة والزكاة | {2:43} | {} — FAIL | {2:43} — PASS |
| مؤمنين (bare) | {4:103} | {4:103} — PASS | {4:103} — PASS |
| للمتقين | {2:2} | {2:2} — PASS | {2:2} — PASS |

Note on بالغيب (baseline): the audit says it "succeeded only because the
text contains بالغيب literally" — confirmed and sharpened: baseline finds
only 2:3 (literal بالغيب) and misses 6:59 (bare الغيب). The fix finds both.

## 3. Tafsir search — FTS column vs old LIKE (before / after)

"Old LIKE" is the literal port of `_searchTafsirSync` (LIKE on raw tafsir
text). "FTS" is the new column-scoped query on `ayahs_fts.tafsir`.

| Query | Expected | Old LIKE | New FTS tafsir |
|---|---|---|---|
| بالصلاة | {2:3, 2:153, 4:103} | {} — FAIL | {2:3, 2:153, 4:103} — PASS |
| الصابرين | {2:155} | {2:155} — PASS | {2:155} — PASS |
| انت | {} | {4:103} — FAIL (LIKE substring: كانت contains انت) | {} — PASS |
| زكاة | {2:43} | {2:43} — PASS | {2:43} — PASS |
| سم | {} | {1:1} — FAIL (LIKE substring: بسم contains سم) | {} — PASS |
| الغيب | {2:3, 6:59} | {2:3, 6:59} — PASS | {2:3, 6:59} — PASS |
| زكاه (ه-spelling) | {2:43} | {} — FAIL (ة/ه mismatch in raw text) | {2:43} — PASS |
| الصلاه (ه-spelling) | {2:3, 2:153, 4:103} | {} — FAIL (ة/ه mismatch) | {2:3, 2:153, 4:103} — PASS |

Scoping verified: FTS query بالصلاة returns 2:3/2:153/4:103 but NOT 2:43,
whose Quran text contains الصلاة but whose (fixture) tafsir does not —
the column filter really does restrict to the tafsir column. The working
MATCH form (verified on SQLite 3.45.1) is one group per term:
`({tafsir} : "v1"* OR {tafsir} : "v2"* ...)`, groups joined by AND.

## 4. What the restricted strip removes from the index

Junk tokens present in the OLD index, gone in the NEW index (per ayah):

| Ayah | Removed junk tokens |
|---|---|
| 1:1 | سم (from بسم) |
| 2:43 | اتوا (from واتوا) |
| 2:155 | بشر (from وبشر), له (from لله) |
| 4:103 | انت (from كانت), تابا (from كتابا) |
| 6:59 | عنده (from وعنده) |
| 2:2 | يه (from فيه) |
| 9:71 | عض, عضهم (from بعض, بعضهم) |

Legitimate strips are all preserved, e.g. والصلاة → الصلاة (via the
single-letter branch: و + الصلاة), بالصبر → صبر, للمتقين → متقين,
ويقيمون → يقيمون (remainder ≥ 5). Note: stripping وال removes و+ال, so
«والمؤمنون» is indexed as the bare stem «مؤمنون» — the compound branch
does not leave an «ال»-form behind; the single-letter branch is what
produces the «ال»-form variant on the query side.

## 5. Known limitation / trade-off (honest — not hidden)

**بصلاة still returns 0 after the fix, by design of audit rule (b).**
A single letter + 4-letter bare noun (ب + صلاة) is not stripped: the
remainder (صلاة, 4 chars) neither starts with «ال» nor reaches length 5.
The same applies to وصلاة / فصلاة / لصلاة / كصلاة and any other
single-letter prefix on a short bare noun. This is the price of rule (b);
the audit's rule as specified accepts it, and the test records it as an
expected-empty result rather than a failure. Single-letter prefixes on
longer remainders still work (بصابرين → {2:155} — PASS), and all
compound prefixes (وال/فال/بال/لل/كال) work regardless of length.
No other required or probed query fails.

## 6. Proposed patch for the implementing step (NOT applied)

### 6a. `tools/build_db.py` — replace `_strip_prefix` (index side)

```python
def _strip_prefix(w):
    for p in ('وال', 'فال', 'بال', 'لل', 'كال'):
        if w.startswith(p) and len(w) - len(p) >= 2:
            return w[len(p):]
    if w.startswith('ال') and len(w) - 2 >= 3:
        return w[2:]
    for p in ('و', 'ف', 'ب', 'ل', 'ك'):
        if w.startswith(p):
            rest = w[1:]
            # Restricted (Phase 0 fix): remainder must start with «ال»
            # (and be at least 3 chars, so the bare remainder «ال» itself
            # is never emitted) OR be at least 5 chars long.
            if len(rest) >= 2 and ((rest.startswith('ال') and len(rest) >= 3)
                                   or len(rest) >= 5):
                return rest
    return None
```

Rebuilding `assets/quran.db` in CI is required for this half to take
effect; installed users get it through the existing `needsUpdate()` /
SHA-256 replacement path.

### 6b. `lib/db.dart` — replace `_searchExpr` (query side)

Generate, per term, {original, compound-stripped, ال-stripped,
single-letter-stripped (same restriction as §6a)}; keep the old «ال»+term
variant for bare terms only. (Verified redundant on this fixture — the
whole 26-test suite also passes with it removed, in both Quran and tafsir
search — because index-side stripping already stores the bare stem; keep
or drop is the implementer's choice. The one theoretical case where it
matters is short «ال»-words whose ال-strip is length-blocked, e.g. «الله»:
a bare query «له» would then also match «الله» — pre-existing old
behaviour, arguably noise.)

```dart
String? _stripCompound(String t) {
  for (final p in ['وال', 'فال', 'بال', 'لل', 'كال']) {
    if (t.startsWith(p) && t.length - p.length >= 2) return t.substring(p.length);
  }
  return null;
}

String? _stripAl(String t) {
  if (t.startsWith('ال') && t.length - 2 >= 3) return t.substring(2);
  return null;
}

String? _stripSingle(String t) {
  for (final p in ['و', 'ف', 'ب', 'ل', 'ك']) {
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

Set<String> _termVariants(String t) {
  final variants = <String>{t};
  var stripped = false;
  for (final f in [_stripCompound, _stripAl, _stripSingle]) {
    final v = f(t);
    if (v != null && v != t) { variants.add(v); stripped = true; }
  }
  if (!stripped && !t.startsWith('ال')) variants.add('ال$t');
  return variants;
}

String _searchExpr(String normed) {
  final groups = <String>[];
  for (final t in normed.split(' ')) {
    if (t.isEmpty) continue;
    groups.add('(${_termVariants(t).map((v) => '"$v"*').join(' OR ')})');
  }
  return groups.join(' AND ');
}
```

Safety guard (verified): `_stripSingle('وال')` returns null, so a lone
query term «وال» never emits the variant «ال» — a bare `"ال"*` prefix
query matches all 9 fixture rows, i.e. effectively the whole index.

### 6c. `lib/db.dart` — replace `_searchTafsirSync` (tafsir side)

Same variants, scoped to the tafsir column; drop the LIKE implementation:

```dart
List<TafsirHit> _searchTafsirSync(String p, String q) {
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    final n = normalizeAr(q);
    if (n.isEmpty) return [];
    final groups = <String>[];
    for (final t in n.split(' ')) {
      if (t.isEmpty) continue;
      groups.add('(${_termVariants(t).map((v) => '{tafsir} : "$v"*').join(' OR ')})');
    }
    final expr = groups.join(' AND ');
    final rs = db.select(
        'SELECT $_cols, t.source AS source, t.text AS ttext FROM tafsir t '
        'JOIN ayahs a ON a.surah=t.surah AND a.ayah=t.ayah $_join '
        'JOIN ayahs_fts ON ayahs_fts.rowid=a.id '
        'WHERE ayahs_fts MATCH ? ORDER BY rank LIMIT 30',
        [expr]);
    // ... build TafsirHit list from rs exactly as before ...
  } finally {
    db.dispose();
  }
}
```

Note: the unscoped Quran search (`_searchSync`, `WHERE ayahs_fts MATCH ?`)
searches BOTH the norm and the tafsir columns — that is pre-existing
behaviour in `db.dart` and was preserved as-is in this test (it is why a
bare query can also hit via a tafsir mention). `_askSync` and
`_relatedSync` still build variants with the old ال-only logic; audit §3
item 1 says they should reuse the same `_termVariants` — flagged for the
implementing step, not tested here.

## 7. What remains / what this does NOT prove

- **Out of scope for this task (per the brief):** root-based search,
  topic/subject search, English search — none of these exist in the DB
  (no `words`/`roots` tables) and none were tested.
- **Fixture size:** 9 sample ayahs, not the real 6236-ayah database. The
  logic is literal (verbatim `norm`/`_strip_prefix`, literal `_searchExpr`
  port), but full-DB validation must re-run these exact queries against a
  real `build_db.py` output before merging — especially to catch any
  real-world word where the ≥5 rule over- or under-strips.
- **Not tested here:** Flutter/Dart execution (the Dart in §6 is a
  hand-written equivalent of the tested Python, not compiled or run);
  `flutter test` regression tests; on-device behaviour; DB migration for
  already-installed users (new index requires a rebuilt DB).
- **Pre-existing behaviour preserved, not fixed:** unscoped MATCH
  searching the tafsir column too (§6c note); `"term"*` prefix matching
  (a query term matches any longer token starting with it — by design).

## Files

- [`phase0/fts_test.py`](sandbox:/workspace/tilawa/phase0/fts_test.py) — the
  test script (verbatim old logic + fixed logic + 26-test matrix + ablation).
- [`phase0/fts_test_output.txt`](sandbox:/workspace/tilawa/phase0/fts_test_output.txt) —
  full literal run output (SQLite 3.45.1, exit 0).
- This file — results, tables, proposed patch, limitations.
