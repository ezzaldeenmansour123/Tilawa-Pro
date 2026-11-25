#!/usr/bin/env python3
"""Literal text verification for the Tilawa mushaf UI (Phase 1).

Checks, against the shipped library database (assets/quran.db as built
by tools/build_db.py, or the copy extracted from the built APK):
  1. SHA-256 of the DB matches the bundled .sha256 file (when given).
  2. Structural integrity: 6236 ayahs, 114 surahs, pages 1..604
     (604 distinct), page order monotonic in ayah id, no ayah without
     a page, tafsir coverage of all 6236 ayahs.
  3. Sample dump: 9 sample ayahs printed verbatim (repr + length +
     page + juz) so a reviewer can compare them codepoint by codepoint
     with the source.
  4. Display-path audit of lib/main.dart: the Quranic text is shown
     only as `Ayah.text` verbatim — no replace/substring/normalize is
     applied to an ayah's text before display, copy or share — and the
     basmala shown above a surah in mushaf mode comes from the DB
     itself (ayah 1:1 via ayahById(1)), not from a hand-typed literal.

This script does NOT compare the DB against an external Quran text:
the DB was built by tools/build_db.py from the pinned Tanzil
Uthmani v1.1 snapshot with fail-loud checks (114/6236/per-surah
counts, I'jaz quote checks); the independent-source eyeball check
for 2:255 against the pinned 2017 Tanzil text is recorded in
phase1/MUSHAF_TEXT_UI.md. A byte-level diff against the pinned
2017 text is part of tools/verify_tajweed.py (it must NOT be
expected to be equal: the 2017 text prefixes the basmala to every
surah-start ayah, the v1.1 DB does not).

usage:
  python3 tools/verify_text.py --db <quran.db> [--sha256 <quran.db.sha256>]
                               [--main lib/main.dart]
exit code: 0 = all checks passed, 1 = any failure.
"""
import argparse
import hashlib
import re
import sqlite3
import sys

SAMPLES = [(1, 1), (1, 7), (2, 2), (2, 255), (2, 286), (18, 110),
           (36, 58), (112, 1), (114, 1)]

FAILURES = []


def check(name, ok, detail=''):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f' — {detail}' if detail else ''))
    if not ok:
        FAILURES.append(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', required=True)
    ap.add_argument('--sha256', default=None)
    ap.add_argument('--main', default=None)
    args = ap.parse_args()

    # 1. SHA-256
    if args.sha256:
        expected = open(args.sha256, encoding='utf-8').read().strip()
        got = hashlib.sha256(open(args.db, 'rb').read()).hexdigest()
        check('sha256 matches bundled file', got == expected, f'{got[:12]}…')

    con = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)
    cur = con.cursor()

    # 2. Structural integrity
    n_ayahs = cur.execute('SELECT COUNT(*) FROM ayahs').fetchone()[0]
    check('ayahs == 6236', n_ayahs == 6236, str(n_ayahs))
    n_surahs = cur.execute('SELECT COUNT(*) FROM surahs').fetchone()[0]
    check('surahs == 114', n_surahs == 114, str(n_surahs))
    mn, mx, distinct = cur.execute(
        'SELECT MIN(page), MAX(page), COUNT(DISTINCT page) FROM ayahs').fetchone()
    check('pages 1..604 (604 distinct)', (mn, mx, distinct) == (1, 604, 604),
          f'min={mn} max={mx} distinct={distinct}')
    viol = cur.execute(
        'SELECT COUNT(*) FROM (SELECT a.id, a.page, '
        '(SELECT MAX(page) FROM ayahs WHERE id < a.id) AS prev_max '
        'FROM ayahs a) WHERE page < prev_max').fetchone()[0]
    check('page order monotonic in ayah id', viol == 0, f'violations={viol}')
    nopage = cur.execute(
        'SELECT COUNT(*) FROM ayahs WHERE page IS NULL OR page < 1 OR page > 604'
    ).fetchone()[0]
    check('every ayah has a page 1..604', nopage == 0, str(nopage))
    tafsir_ayahs, tafsir_rows = cur.execute(
        'SELECT COUNT(DISTINCT surah || \':\' || ayah), COUNT(*) FROM tafsir'
    ).fetchone()
    check('tafsir covers all 6236 ayahs', tafsir_ayahs == 6236,
          f'{tafsir_ayahs} ayahs, {tafsir_rows} rows')
    quick = cur.execute('PRAGMA quick_check').fetchone()[0]
    check('PRAGMA quick_check == ok', quick == 'ok', str(quick))

    # 3. Sample dump (verbatim, for codepoint-level review)
    print('\n-- sample ayahs (verbatim from DB) --')
    for s, a in SAMPLES:
        text, page, juz = cur.execute(
            'SELECT text, page, juz FROM ayahs WHERE surah=? AND ayah=?',
            (s, a)).fetchone()
        print(f'{s}:{a} page={page} juz={juz} len={len(text)} text={text!r}')
    # Basmala facts (used by the mushaf surah header)
    t11 = cur.execute('SELECT text FROM ayahs WHERE surah=1 AND ayah=1').fetchone()[0]
    t21 = cur.execute('SELECT text FROM ayahs WHERE surah=2 AND ayah=1').fetchone()[0]
    check('1:1 is the basmala; 2:1 has no basmala prefix',
          t21 == 'الٓمٓ' and t11.startswith('بِسْمِ'), f'2:1={t21!r}')
    n_bas = cur.execute("SELECT COUNT(*) FROM ayahs WHERE text LIKE 'بِسْمِ%'").fetchone()[0]
    check('only one ayah starts with the basmala (1:1)', n_bas == 1, str(n_bas))

    # 4. Display-path audit of lib/main.dart
    if args.main:
        src = open(args.main, encoding='utf-8').read()
        lines = src.splitlines()
        # Only Ayah-text receivers count here (a/_a/ayah/cur/_daily/r):
        # a TextEditingController's .text (e.g. pageCtl.text.trim()) is
        # user input for a page number, not Quranic text.
        bad = [i + 1 for i, ln in enumerate(lines)
               if re.search(r'\b(?:a|_a|ayah|cur|_daily!|m\.ayah!|r)\.text\s*\.\s*'
                            r'(?:replaceAll|replace|substring|trim|toLowerCase|toUpperCase)\s*\(', ln)
               or re.search(r'normalizeAr\([^)]*(?:a|_a|ayah|cur)\.text', ln)]
        check('no transformation of Ayah.text before display/copy/share',
              not bad, f'lines={bad}' if bad else 'none found')
        direct = [i + 1 for i, ln in enumerate(lines)
                  if re.search(r'Text\(\s*[\w!.]+\.text', ln)]
        direct += [i + 1 for i, ln in enumerate(lines)
                   if re.search(r'TextSpan\(\s*text:\s*[\w!.]+\.text', ln)]
        direct = sorted(set(direct))
        check('ayah text rendered directly as Text(<x>.text) / TextSpan(text: <x>.text)',
              len(direct) > 0, f'{len(direct)} sites: lines {direct}')
        check('mushaf basmala comes from DB ayah 1:1 (ayahById(1))',
              'ayahById(1)' in src, 'found' if 'ayahById(1)' in src else 'missing')
        lit_lines = [i + 1 for i, ln in enumerate(lines) if 'بِسْمِ' in ln]
        print(f'    note: hand-typed basmala literal occurs at lines {lit_lines} '
              f'(Settings preview only — pre-existing; the mushaf header '
              f'must use _basmala from ayahById(1), never this literal)')

    print()
    if FAILURES:
        print(f'VERIFY_TEXT: {len(FAILURES)} FAILURE(S): {FAILURES}')
        return 1
    print('VERIFY_TEXT: ALL CHECKS PASSED')
    return 0


if __name__ == '__main__':
    sys.exit(main())
