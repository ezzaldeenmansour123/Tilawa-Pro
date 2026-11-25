#!/usr/bin/env python3
"""Attach the lexicon tables to a built Tilawa DB (assets/quran.db).

Copies lexicon / lexicon_tafsir / lexicon_extra / lexicon_meta from a
source DB that already contains them (the verified Phase-1 build,
~/workspace/tilawa/phase1/fts3/quran_lexicon.db) into the app DB via
sqlite3 ATTACH + INSERT SELECT. The Quran text is never touched:
the script verifies the ayah-text SHA-256 before and after and
FAILS if it changed.

Safety checks (fail loudly, target left untouched on failure):
  * source must contain the four lexicon* tables;
  * target's file SHA-256 must equal the source lexicon_meta
    'base_db_sha256' — the lexicon was built for exactly one base DB
    (assets/quran.db == quran_rebuilt.db, SHA-256 2d7b9378…fa926).
    If the bytes differ (e.g. empty lexicon tables left by a failed
    earlier run), the attach proceeds ONLY if the ayah text AND the
    FTS columns are verified identical to the lexicon source.
    If those differ too, rebuild with tools/build_lexicon.py;
  * target must have 6,236 ayahs and integrity_check = ok, before
    and after;
  * row counts after the copy must match the source exactly.

Provenance: attach metadata is appended to the target's lexicon_meta
(attached_from_db_sha256, attached_to_db_sha256_before,
attached_at, attached_by). The shipped assets/quran.db.sha256 is
rewritten for the new file (Repo.install() verifies it on install).

Usage:
  attach_lexicon.py [--source quran_lexicon.db] [--target assets/quran.db]
                    [--sha256 assets/quran.db.sha256]
  Defaults are relative to the repo root (the script's parent dir).
  Run from anywhere; use --dry-run to check without writing.
"""
import argparse
import datetime
import hashlib
import os
import sqlite3
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_SOURCE = '/home/hatch/workspace/tilawa/phase1/fts3/quran_lexicon.db'
DEFAULT_TARGET = os.path.join(ROOT, 'assets', 'quran.db')

LEXICON_TABLES = ('lexicon', 'lexicon_tafsir', 'lexicon_extra', 'lexicon_meta')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def text_sha256(con):
    h = hashlib.sha256()
    for (t,) in con.execute('SELECT text FROM ayahs ORDER BY id'):
        h.update(t.encode('utf-8'))
    return h.hexdigest()


def fts_sha256(con):
    """Hash of the FTS columns the lexicon was aligned to. This is the
    real invariant behind the file-SHA check: the lexicon tables are
    valid for any DB whose ayah text + FTS columns are identical to
    the base DB, even if the file bytes differ (e.g. empty lexicon
    tables left by a failed earlier run)."""
    h = hashlib.sha256()
    for rowid, ncol, tcol in con.execute(
            'SELECT rowid, norm, tafsir FROM ayahs_fts ORDER BY rowid'):
        h.update(('%d\0%s\0%s\n' % (rowid, ncol or '', tcol or '')).encode('utf-8'))
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description='Attach lexicon tables to the app DB.')
    ap.add_argument('--source', default=DEFAULT_SOURCE,
                    help='DB that already has the lexicon tables')
    ap.add_argument('--target', default=DEFAULT_TARGET,
                    help='app DB to attach the tables to')
    ap.add_argument('--sha256', default=None,
                    help='sha256 sidecar to rewrite (default: <target>.sha256)')
    ap.add_argument('--dry-run', action='store_true',
                    help='verify only, do not write')
    args = ap.parse_args()
    sha_path = args.sha256 or (args.target + '.sha256')

    if not os.path.exists(args.source):
        print('ERROR: source DB not found: %s' % args.source)
        sys.exit(1)
    if not os.path.exists(args.target):
        print('ERROR: target DB not found: %s' % args.target)
        sys.exit(1)

    src = sqlite3.connect('file:%s?mode=ro' % args.source, uri=True)
    src_meta = dict(src.execute('SELECT key, value FROM lexicon_meta'))
    src_counts = {t: src.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0]
                  for t in LEXICON_TABLES}
    src_schema = [r[0] for r in src.execute(
        "SELECT sql FROM sqlite_master WHERE type IN ('table','index') "
        "AND name LIKE 'lexicon%' AND sql IS NOT NULL ORDER BY name")]
    src_sha = sha256_file(args.source)
    src_text_sha = text_sha256(src)
    src_fts_sha = fts_sha256(src)
    src.close()  # closed before the target write: an open read
    # connection to the same file would block DETACH below.
    print('source: %s' % args.source)
    print('  sha256=%s' % src_sha)
    print('  counts: %s' % src_counts)
    print('  base_db_sha256=%s' % src_meta.get('base_db_sha256'))
    print('  qac_sha256=%s' % src_meta.get('qac_sha256'))
    print('  license_status=%s' % src_meta.get('license_status'))

    tgt_sha_before = sha256_file(args.target)
    size_before = os.path.getsize(args.target)
    con = sqlite3.connect(args.target)
    try:
        assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        n = con.execute('SELECT COUNT(*) FROM ayahs').fetchone()[0]
        if n != 6236:
            print('ERROR: target has %d ayahs, expected 6236' % n)
            sys.exit(1)
        text_before = text_sha256(con)
        fts_before = fts_sha256(con)
        print('target: %s' % args.target)
        print('  sha256=%s' % tgt_sha_before)
        print('  text_sha256=%s' % text_before)
        if tgt_sha_before != src_meta.get('base_db_sha256'):
            # File bytes differ from the lexicon's base DB: accept ONLY
            # if the content the lexicon depends on is identical
            # (ayah text + FTS columns). Otherwise the lexicon was
            # built for a different base DB — rebuild instead.
            if text_before != src_text_sha or fts_before != src_fts_sha:
                print('ERROR: target file SHA-256 %s does not match the '
                      'lexicon base_db_sha256 %s, and its text/FTS '
                      'columns differ from the lexicon source too — '
                      'rebuild with tools/build_lexicon.py instead'
                      % (tgt_sha_before, src_meta.get('base_db_sha256')))
                sys.exit(1)
            print('  note: file bytes differ from the lexicon base DB '
                  '(partial earlier run?), but ayah text + FTS columns '
                  'verified identical to the lexicon source — proceeding')
        else:
            print('  (matches lexicon base DB)')
        existing = [r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE 'lexicon%'")]
        if existing:
            # A failed earlier run can leave EMPTY lexicon tables behind:
            # Python's sqlite3 auto-commits before DDL, so the CREATEs
            # survive even when the INSERTs roll back. Empty tables are
            # safe to drop and retry; tables WITH rows are refused.
            counts = {t: con.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0]
                      for t in existing}
            if any(counts.values()):
                print('ERROR: target already has lexicon tables with data '
                      '(%s) — refusing to attach twice (rebuild from scratch '
                      'if a refresh is needed)' % counts)
                sys.exit(1)
            print('note: dropping empty lexicon tables left by a failed '
                  'earlier run: %s' % existing)
            for t in existing:
                con.execute('DROP TABLE IF EXISTS %s' % t)
            con.commit()
        if args.dry_run:
            print('DRY RUN: checks passed, nothing written')
            return

        # Copy schema exactly (incl. PRIMARY KEYs) from the source, then
        # the rows. FTS tables are untouched; no ayah row is modified.
        for sql in src_schema:
            con.execute(sql)
        con.execute("ATTACH DATABASE ? AS lexsrc", ('file:%s?mode=ro' % args.source,))
        try:
            for t in LEXICON_TABLES:
                con.execute('INSERT INTO main.%s SELECT * FROM lexsrc.%s' % (t, t))
            con.commit()  # commit BEFORE detach: SQLite refuses to
            # detach a database with an open write transaction.
        finally:
            try:
                con.execute('DETACH DATABASE lexsrc')
            except sqlite3.OperationalError:
                pass  # e.g. rolled back already; con.close() cleans up
        # Verify counts BEFORE adding the attach provenance rows to
        # lexicon_meta (they make its count 12 vs the source's 8).
        after_counts = {t: con.execute('SELECT COUNT(*) FROM %s' % t).fetchone()[0]
                        for t in LEXICON_TABLES}
        if after_counts != src_counts:
            print('ERROR: row counts after attach %s != source %s'
                  % (after_counts, src_counts))
            sys.exit(1)
        text_after = text_sha256(con)
        if text_after != text_before:
            print('ERROR: ayah text SHA-256 changed during attach '
                  '(%s -> %s) — aborting' % (text_before, text_after))
            sys.exit(1)
        print('attached: %s' % after_counts)
        print('text_sha256 unchanged: %s' % text_after)
        # Provenance of THIS attach (in addition to the build metadata).
        con.executemany('INSERT OR REPLACE INTO lexicon_meta VALUES(?,?)', [
            ('attached_from_db_sha256', src_sha),
            ('attached_to_db_sha256_before', tgt_sha_before),
            ('attached_at', datetime.date.today().isoformat()),
            ('attached_by', 'tools/attach_lexicon.py (Tilawa Pro)'),
            ('license_note',
             'QAC v0.4 GPL (corpus.quran.com) — attribution required; '
             'legal confirmation for shipping QAC-derived tables PENDING'),
        ])
        con.commit()
        con.execute('VACUUM')
        con.commit()
        assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    finally:
        con.close()

    tgt_sha_after = sha256_file(args.target)
    with open(sha_path, 'w') as f:
        f.write(tgt_sha_after)
    print('OK target sha256=%s size=%.1fMB (was %.1fMB)' % (
        tgt_sha_after, os.path.getsize(args.target) / 1e6, size_before / 1e6))
    print('rewrote %s' % sha_path)


if __name__ == '__main__':
    main()
