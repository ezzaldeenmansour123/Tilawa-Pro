#!/usr/bin/env python3
"""Verify the lexicon search on the BUILT app DB (assets/quran.db).

Re-runs the 41 ground-truth queries from the verified Phase-1 run
(~/workspace/tilawa/phase1/fts3/fts3_results.json — run 5, missing=0)
against the shipped DB with the lexicon tables attached, using the
SAME algorithm (fts3_test.py: FTS candidates + post-filter on the
reconstructed originals). Checks, per query and scope (Quran/tafsir):

  * new count == ground-truth count (direct scan of all 6,236 ayahs
    with the same predicate — verifies candidate completeness);
  * missing == [] (no GT ayah lost by the FTS candidates);
  * new count == the count recorded in fts3_results.json;
  * the three false-positive sources stay absent
    (كانت 4:103 from انت, بسم 1:1 from سم, كتابا 4:103 from تابا);
  * the short-word totals vs the old index (موسي 452, يوم 1235,
    قال 3079, ما 5230 — the two documented -1 tafsir cases);
  * ayah-text SHA-256 == the one recorded in fts3_results.json
    (the attach must never touch the text);
  * lexicon row counts == 14,659 / 77,587 / 0.

Exit code 0 only if EVERY check passes; otherwise 1 with the
failing queries listed. Read-only on the DB (mode=ro).

Usage: python3 tools/verify_lexicon.py [--db assets/quran.db]
       [--gt ~/workspace/tilawa/phase1/fts3/fts3_results.json]
"""
import argparse
import hashlib
import json
import os
import sqlite3
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_db import norm, _strip_prefix as _strip_prefix_old  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_DB = os.path.join(ROOT, 'assets', 'quran.db')
DEFAULT_GT = '/home/hatch/workspace/tilawa/phase1/fts3/fts3_results.json'

COMPOUND = ('وال', 'فال', 'بال', 'لل', 'كال')
SINGLE = ('و', 'ف', 'ب', 'ل', 'ك')


def reconstruct_originals(column):
    toks = [t for t in (column or '').split(' ') if t]
    orig = []
    for i, t in enumerate(toks):
        if i > 0 and _strip_prefix_old(toks[i - 1]) == t:
            if i + 1 < len(toks) and _strip_prefix_old(t) == toks[i + 1]:
                orig.append(t)  # chain rescue
                continue
            continue
        orig.append(t)
    return orig


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
    variants = {t}
    stripped_any = False
    for f in (_strip_compound, _strip_al, _strip_single):
        v = f(t)
        if v and v != t:
            variants.add(v)
            stripped_any = True
    if not stripped_any and not t.startswith('ال'):
        variants.add('ال' + t)
    return variants


def main():
    ap = argparse.ArgumentParser(description='Verify lexicon search on the built DB.')
    ap.add_argument('--db', default=DEFAULT_DB)
    ap.add_argument('--gt', default=DEFAULT_GT)
    args = ap.parse_args()

    gt_data = json.load(open(args.gt, encoding='utf-8'))
    results = gt_data['results']
    print('ground truth: %s (%d queries)' % (args.gt, len(results)))

    con = sqlite3.connect('file:%s?mode=ro' % args.db, uri=True)
    assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    n_ayahs = con.execute('SELECT COUNT(*) FROM ayahs').fetchone()[0]
    assert n_ayahs == 6236, 'ayahs=%d' % n_ayahs

    counts = {t: con.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0]
              for t in ('lexicon', 'lexicon_tafsir', 'lexicon_extra')}
    print('lexicon counts: %s (expected 14659 / 77587 / 0)' % counts)
    lex_ok = counts == {'lexicon': 14659, 'lexicon_tafsir': 77587,
                        'lexicon_extra': 0}

    lex_q = dict(con.execute('SELECT surface, base FROM lexicon'))
    lex_t = dict(con.execute('SELECT surface, base FROM lexicon_tafsir'))
    bases = set(lex_q.values()) | set(lex_t.values())

    ayahs = {}
    text_hash = hashlib.sha256()
    for gid, s, a, ncol, tcol, text in con.execute(
            'SELECT ayahs_fts.rowid, ayahs.surah, ayahs.ayah, ayahs_fts.norm, '
            'ayahs_fts.tafsir, ayahs.text FROM ayahs_fts '
            'JOIN ayahs ON ayahs.id = ayahs_fts.rowid ORDER BY ayahs_fts.rowid'):
        ayahs[gid] = (s, a, reconstruct_originals(ncol),
                      reconstruct_originals(tcol))
        text_hash.update(text.encode('utf-8'))
    for gid, tok in con.execute('SELECT ayah_id, token FROM lexicon_extra'):
        ayahs[gid][2].append(tok)
    text_sha = text_hash.hexdigest()
    print('ayah text sha256: %s (expected %s) %s' % (
        text_sha, gt_data['text_sha256'],
        'OK' if text_sha == gt_data['text_sha256'] else 'MISMATCH'))
    text_ok = text_sha == gt_data['text_sha256']

    def fallback_base(w):
        for p in COMPOUND:
            if w.startswith(p) and len(w) - len(p) >= 2:
                return w[len(p):]
        if w.startswith('ال') and len(w) - 2 >= 3:
            return w[2:]
        for p in SINGLE:
            if w.startswith(p) and len(w) - 1 >= 2:
                r = w[1:]
                if r in bases and w not in bases:
                    return r
        return w

    def query_base(term, scope):
        t = norm(term)
        if scope == 'tafsir' and t in lex_t:
            return lex_t[t]
        if t in lex_q:
            return lex_q[t]
        if t in lex_t:
            return lex_t[t]
        return fallback_base(t)

    def base_of_q(w):
        return lex_q.get(w, fallback_base(w))

    def base_of_t(w):
        return lex_t.get(w, fallback_base(w))

    def term_matches(originals, bq, base_of):
        for w in originals:
            if w.startswith(bq) or base_of(w).startswith(bq):
                return True
        return False

    def ayah_matches(gid, terms_bq, scope):
        _, _, qtoks, ttoks = ayahs[gid]
        if scope == 'quran':
            return all(term_matches(qtoks, bq, base_of_q) for bq in terms_bq)
        return all(term_matches(ttoks, bq, base_of_t) for bq in terms_bq)

    by_base_q = defaultdict(list)
    for _s, _b in lex_q.items():
        by_base_q[_b].append(_s)
    by_base_t = defaultdict(list)
    for _s, _b in lex_t.items():
        by_base_t[_b].append(_s)

    def candidates(terms, scope):
        col = 'norm' if scope == 'quran' else 'tafsir'
        by_base = by_base_q if scope == 'quran' else by_base_t
        groups = []
        for term in terms:
            t = norm(term)
            bq = query_base(term, scope)
            allv = term_variants_new(t) | term_variants_new(bq)
            needed = set()
            for b, surfs in by_base.items():
                if not b.startswith(bq):
                    continue
                for s in surfs:
                    if any(s.startswith(v) for v in allv):
                        continue
                    st = _strip_prefix_old(s)
                    if st and any(st.startswith(v) for v in allv):
                        continue
                    needed.add(s)
            vs = set(allv)
            for s in needed:
                vs |= term_variants_new(s)
            groups.append('(' + ' OR '.join(
                '{%s} : "%s"*' % (col, v) for v in sorted(vs)) + ')')
        expr = ' AND '.join(groups)
        return {r[0] for r in con.execute(
            'SELECT rowid FROM ayahs_fts WHERE ayahs_fts MATCH ?', (expr,))}

    def new_search(query, scope):
        terms = [t for t in norm(query).split(' ') if t]
        bqs = [query_base(t, scope) for t in terms]
        cands = candidates(terms, scope)
        return {gid for gid in cands if ayah_matches(gid, bqs, scope)}

    def gt_scan(query, scope):
        terms = [t for t in norm(query).split(' ') if t]
        bqs = [query_base(t, scope) for t in terms]
        return {gid for gid in ayahs if ayah_matches(gid, bqs, scope)}

    def name(gid):
        s, a, _, _ = ayahs[gid]
        return '%d:%d' % (s, a)

    failures = []
    n_pass = 0
    print()
    print('%-18s %6s %6s %6s | %6s %6s %6s | %s' % (
        'query', 'GTq', 'newQ', 'missQ', 'GTt', 'newT', 'missT', 'verdict'))
    for q, r in results.items():
        gq = gt_scan(q, 'quran')
        nq = new_search(q, 'quran')
        gt = gt_scan(q, 'tafsir')
        nt = new_search(q, 'tafsir')
        ok = (len(gq) == r['gt_quran'] == len(nq) and not (gq - nq)
              and len(gt) == r['gt_tafsir'] == len(nt) and not (gt - nt)
              and len(nq) == r['new_quran'] and len(nt) == r['new_tafsir'])
        if ok:
            n_pass += 1
        else:
            failures.append((q, 'GTq=%d newQ=%d missQ=%s GTt=%d newT=%d missT=%s '
                             'recorded newQ=%d newT=%d' % (
                                 len(gq), len(nq), sorted(name(g) for g in gq - nq),
                                 len(gt), len(nt), sorted(name(g) for g in gt - nt),
                                 r['new_quran'], r['new_tafsir'])))
        print('%-18s %6d %6d %6d | %6d %6d %6d | %s' % (
            q, len(gq), len(nq), len(gq - nq),
            len(gt), len(nt), len(gt - nt), 'PASS' if ok else 'FAIL'))

    # ---- false-positive sources must stay absent ----
    print()
    fp_ok = True
    for q, gid_s, label in [('انت', (4, 103), 'كانت 4:103'),
                            ('سم', (1, 1), 'بسم 1:1'),
                            ('تابا', (4, 103), 'كتابا 4:103')]:
        gid = next(g for g, (s, a, _, _) in ayahs.items() if (s, a) == gid_s)
        nq = new_search(q, 'quran')
        in_new = gid in nq
        in_gt = gid in gt_scan(q, 'quran')
        ok = (not in_new) and (not in_gt)
        fp_ok = fp_ok and ok
        print('FP %-6s %-12s in_new=%s in_GT=%s %s' % (
            q, label, in_new, in_gt, 'PASS' if ok else 'FAIL'))
        if not ok:
            failures.append((q, 'FP source %s present' % label))

    # ---- short words vs the old index (documented -1 tafsir cases) ----
    print()
    short_ok = True
    for q, old in gt_data['old_A'].items():
        if q not in ('موسي', 'يوم', 'قال', 'ما'):
            continue
        nq = new_search(q, 'quran')
        nt = new_search(q, 'tafsir')
        new_u = len(nq | nt)
        ok = (new_u - old) in (0, -1)  # يوم/ما are -1 (tafsir only, documented)
        short_ok = short_ok and ok
        print('SHORT %-6s old(A)=%d new_unscoped=%d diff=%+d %s' % (
            q, old, new_u, new_u - old, 'PASS' if ok else 'FAIL'))
        if not ok:
            failures.append((q, 'short-word diff out of range'))

    con.close()
    print()
    print('queries: %d/%d PASS' % (n_pass, len(results)))
    print('lexicon counts: %s' % ('PASS' if lex_ok else 'FAIL'))
    print('ayah text sha256: %s' % ('PASS' if text_ok else 'FAIL'))
    print('false-positive checks: %s' % ('PASS' if fp_ok else 'FAIL'))
    print('short-word checks: %s' % ('PASS' if short_ok else 'FAIL'))
    all_ok = (n_pass == len(results) and lex_ok and text_ok and fp_ok
              and short_ok)
    if all_ok:
        print('RESULT: ALL CHECKS PASSED')
        return 0
    print('RESULT: FAILURES:')
    for q, why in failures:
        print('  - %s: %s' % (q, why))
    return 1


if __name__ == '__main__':
    sys.exit(main())
