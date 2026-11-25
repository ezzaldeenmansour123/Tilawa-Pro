#!/usr/bin/env python3
"""Tajweed alignment gate for Tilawa (Phase 1).

Question: may the cpfair/quran-tajweed annotations
(`output/tajweed.hafs.uthmani-pause-sajdah.json`, CC BY 4.0) be applied
to the app's Quran text (Tanzil Uthmani v1.1, as stored in quran.db)?

The annotations' start/end offsets are Unicode-codepoint offsets into
the pinned Tanzil Uthmani text of ca. Apr 6, 2017 (cpfair's
`quran-uthmani.txt`). The README itself warns that Tanzil's encoding
"has changed slightly since the annotations were generated" and that
a different text file requires rebuilding the data "from scratch (at
your own risk)". Two drift mechanisms are already documented:
  * the 2017 file prefixes the basmala to ayah 1 of every surah
    (except 1 and 9); the v1.1 DB stores ayah 1 without it
    (DB 2:1 is just 'الٓمٓ') — so every surah-start ayah's offsets
    would be shifted by the basmala length if applied naively;
  * the pause-mark/tanwin layer differs between the 2017 encoding
    and newer ones (cpfair issue #2; AnaMuslim's pipeline notes
    offsets "would drift mid-ayah"), so offsets can also drift
    inside an ayah.

This script is the gate: it FAILS LOUDLY unless every annotation can
be projected onto the DB text exactly. Until it passes with the real
dataset, no tajweed data is bundled and no letter is coloured.

Phases:
  A. DB-only structural pre-checks (always run).
  B. --text2017 <quran-uthmani.txt>: per-ayah codepoint-exact
     comparison of the 2017 text vs the DB after stripping the
     basmala prefix (the 2017 file's own 1:1 text + ' ') from
     surah-start ayahs. ANY differing ayah -> exit 1.
  C. --tajweed <json>: every annotation must reference a known rule
     (the 18 in lib/tajweed.dart), lie inside its 2017 ayah text,
     and — once Phase B is fully equal — project onto the DB text
     (basmala-prefix shift only; any annotation overlapping the
     stripped prefix is rejected). Any failure -> exit 1.

Exit codes: 0 = full verification passed (B and C both ran clean);
              1 = alignment failure (data present but unusable);
              2 = required inputs missing (nothing verified yet).

usage:
  python3 tools/verify_tajweed.py --db <quran.db>
      [--text2017 <quran-uthmani.txt>] [--tajweed <tajweed.json>]
"""
import argparse
import json
import sqlite3
import sys

KNOWN_RULES = {
    'ghunnah', 'hamzat_wasl', 'idghaam_ghunnah', 'idghaam_mutajanisayn',
    'idghaam_mutaqaribayn', 'idghaam_no_ghunnah', 'idghaam_shafawi',
    'ikhfa', 'ikhfa_shafawi', 'iqlab', 'lam_shamsiyyah', 'madd_2',
    'madd_246', 'madd_6', 'madd_munfasil', 'madd_muttasil', 'qalqalah',
    'silent',
}


def load_2017(path):
    """Parse Tanzil 'surah|ayah|text' lines -> {(s,a): text}."""
    out = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n').rstrip(' ')
            if not line:
                continue
            parts = line.split('|', 2)
            if len(parts) != 3:
                continue
            try:
                s, a = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            out[(s, a)] = parts[2]
    return out


def first_diff(a, b):
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i, x, y
    return min(len(a), len(b)), None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', required=True)
    ap.add_argument('--text2017', default=None)
    ap.add_argument('--tajweed', default=None)
    args = ap.parse_args()

    con = sqlite3.connect(f'file:{args.db}?mode=ro', uri=True)
    cur = con.cursor()

    # ── Phase A: DB-only structural pre-checks ──
    print('== Phase A: DB structural pre-checks ==')
    n = cur.execute('SELECT COUNT(*) FROM ayahs').fetchone()[0]
    print(f'ayahs in DB: {n}')
    t11 = cur.execute('SELECT text FROM ayahs WHERE surah=1 AND ayah=1').fetchone()[0]
    t21 = cur.execute('SELECT text FROM ayahs WHERE surah=2 AND ayah=1').fetchone()[0]
    print(f'DB 1:1 (basmala, len {len(t11)}): {t11!r}')
    print(f'DB 2:1 (len {len(t21)}): {t21!r}')
    assert n == 6236, 'DB does not hold 6236 ayahs'
    assert t21 == 'الٓمٓ', 'unexpected: DB 2:1 is not the bare muqattaat text'
    n_bas = cur.execute("SELECT COUNT(*) FROM ayahs WHERE text LIKE 'بِسْمِ%'").fetchone()[0]
    print(f'DB ayahs starting with the basmala: {n_bas} (only 1:1 expected)')
    assert n_bas == 1
    print('Phase A OK: the DB strips the basmala prefix from surah-start '
          'ayahs, so the 2017 coordinate text MUST be stripped the same '
          'way before any offset is trusted.\n')

    if not args.text2017 or not args.tajweed:
        print('BLOCKED: alignment NOT verified — missing inputs.')
        if not args.text2017:
            print('  missing: --text2017 cpfair pinned quran-uthmani.txt (ca. 2017)')
        if not args.tajweed:
            print('  missing: --tajweed output/tajweed.hafs.uthmani-pause-sajdah.json')
        print('Do NOT bundle tajweed data or colour any letter until this '
              'script exits 0 with both inputs.')
        return 2

    # ── Phase B: per-ayah text equality (2017 stripped vs DB) ──
    print('== Phase B: 2017 text vs DB text, ayah by ayah ==')
    old = load_2017(args.text2017)
    print(f'2017 file ayahs parsed: {len(old)}')
    if len(old) != 6236:
        print('FAIL: 2017 file does not hold 6236 ayahs')
        return 1
    basmala = old[(1, 1)]
    assert basmala == t11, (
        'FAIL: 2017 file 1:1 differs from DB 1:1 — the files do not '
        'share even the basmala; check the input files.')
    prefix = basmala + ' '
    db_text = {(s, a): t for s, a, t in
               cur.execute('SELECT surah, ayah, text FROM ayahs')}
    differing = []
    for key in sorted(db_text):
        t_old = old.get(key)
        if t_old is None:
            differing.append((key, 'missing in 2017 file'))
            continue
        s, a = key
        if a == 1 and s not in (1, 9) and t_old.startswith(prefix):
            t_old = t_old[len(prefix):]
        if t_old != db_text[key]:
            i, x, y = first_diff(t_old, db_text[key])
            differing.append((key,
                              f'len {len(t_old)} vs {len(db_text[key])}, '
                              f'first diff at {i}: {x!r} vs {y!r}'))
    print(f'ayahs compared: 6236, differing: {len(differing)}')
    for key, why in differing[:10]:
        print(f'  DIFF {key[0]}:{key[1]} — {why}')
    if differing:
        print('FAIL: the 2017 coordinate text differs from the DB text on '
              f'{len(differing)} ayah(s). Offsets cannot be applied directly; '
              'a difflib letter-alignment projection is required first, and '
              'it must be reviewed ayah by ayah. No bundling.')
        return 1
    print('Phase B OK: 2017 text (basmala-stripped) == DB text on all '
          '6236 ayahs, codepoint-exact.\n')

    # ── Phase C: annotation bounds + projection ──
    print('== Phase C: annotation bounds and projection ==')
    data = json.load(open(args.tajweed, encoding='utf-8'))
    print(f'annotation entries (ayahs): {len(data)}')
    total = 0
    bad = []
    projected = 0
    for entry in data:
        s, a = entry['surah'], entry['ayah']
        key = (s, a)
        raw = old.get(key)
        if raw is None:
            bad.append((key, 'ayah missing from 2017 file'))
            continue
        # Offsets index the RAW 2017 ayah text (basmala prefix included).
        plen = len(prefix) if (a == 1 and s not in (1, 9)
                               and raw.startswith(prefix)) else 0
        for ann in entry.get('annotations', []):
            total += 1
            rule, st, en = ann['rule'], ann['start'], ann['end']
            if rule not in KNOWN_RULES:
                bad.append((key, f'unknown rule {rule!r}'))
                continue
            if not (0 <= st < en <= len(raw)):
                bad.append((key, f'{rule} {st}..{en} out of bounds (len {len(raw)})'))
                continue
            if st < plen:
                bad.append((key, f'{rule} {st}..{en} overlaps the stripped '
                          'basmala prefix — no DB characters there'))
                continue
            projected += 1
    print(f'annotations checked: {total}, projectable onto DB text: {projected}, '
          f'problems: {len(bad)}')
    for key, why in bad[:10]:
        print(f'  BAD {key[0]}:{key[1]} — {why}')
    if bad:
        print('FAIL: some annotations cannot be projected onto the DB text.')
        return 1
    print(f'Phase C OK: all {total} annotations project onto the DB text '
          '(basmala-prefix shift only).')
    print('\nVERIFY_TAJWEED: ALL CHECKS PASSED — data may be bundled with '
          'CC BY 4.0 attribution, and only with the projection above.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
