#!/usr/bin/env python3
"""Build the token lexicon (FTS3) from QAC v0.4 morphology + FTS columns.

Adapted for Tilawa Pro from the verified Phase-1 prototype
(~/workspace/tilawa/phase1/fts3/build_lexicon.py — run 5, 41 queries,
missing=0; see ~/workspace/tilawa/phase1/fts3/LEXICON_RESULTS.md).
The logic is unchanged; only the paths are parameterised so CI can
build the tables from scratch, and the QAC import now comes from
tools/build_db.py (same norm() / _strip_prefix() as the DB builder).

Design (full rationale in LEXICON_RESULTS.md):
  * One lexicon row per SURFACE token (normalized, simple-clean spelling
    as stored in the FTS column): surface -> base.
  * Quran surfaces: base from QAC v0.4 segmentation, anchored to the
    FTS token's own spelling (solves L3: dagger-alef divergence).
    base = FTS token minus its QAC PREFIX segments (by length), except
    when the QAC lemma shows an initial-alef elision
    (lemma == 'ا'+stemform or 'ال'+stemform: بسم->اسم, لله->الله,
    وابن->ابن), where base = norm(lemma).
  * Surface-level map = DOMINANT QAC analysis per surface (ties -> the
    analysis with the fewest prefix strips, i.e. the longest base).
    Ambiguity is real (لما 41x ل+ما vs 33x particle; ورد 1x/1x) and is
    counted and listed, not hidden.
  * Tafsir surfaces + any unaligned Quran surface: fallback rule —
    compound/ال strips unconditional (safe); single-letter strip iff
    the remainder is a known base AND the surface is not itself a
    known base. This is what makes كانت/بسم/كتابا/وعد/فارض stay whole
    while لموسى/ويوم/وقالوا/بصابرين strip.
  * Query-side base: same function — known surface -> its base;
    known base -> itself; else recursive fallback stripping.

Usage:
  build_lexicon.py <db> <quran-morphology.txt> [--out <out.db>]
      [--json <lexicon.json>]
  Without --out the lexicon tables are built IN PLACE in <db>.
  Without --json no lexicon.json audit file is written.

Inputs (read-only for the alignment read): the app DB (must be the
verified 6,236-ayah build) and quran-morphology.txt (QAC v0.4).
Outputs: the same DB + lexicon, lexicon_tafsir, lexicon_extra,
lexicon_meta tables; optionally lexicon.json (surface -> {base, votes}
+ multi-analysis surfaces + anomalies + per-occurrence token_base).

Fetching quran-morphology.txt for CI (see tools/build_db.py):
  The official QAC download page requires an e-mail form (HTTP 302),
  so CI fetches the pinned mirror and verifies its SHA-256:
    curl -L -o quran-morphology.txt \
      https://raw.githubusercontent.com/mustafa0x/quran-morphology/8f38b39/quran-morphology.txt
    # expected SHA-256: 742bfac59941b2cb09736d5b7aae694af50792261fb8450cbf6afafcc340645f
  The build FAILS if the hash does not match. Never fetch an
  unpinned / unverified copy.

LICENCE — READ BEFORE SHIPPING:
  The lexicon tables are DERIVED from Quranic Arabic Corpus v0.4,
  which is GNU GPL (corpus.quran.com). Attribution to QAC is
  REQUIRED in the app (README.md "المصادر والتراخيص" + the in-app
  About/Settings screen — see the wiring snippet in the lexicon
  report). Because the tables are a derivation, not a verbatim copy,
  LEGAL CONFIRMATION for shipping them is STILL PENDING — this is
  recorded in lexicon_meta ('license_status' = 'pending') and must
  be resolved before a release that distributes the tables.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_db import norm, _strip_prefix as _strip_prefix_old  # noqa: E402

COMPOUND = ('وال', 'فال', 'بال', 'لل', 'كال')
SINGLE = ('و', 'ف', 'ب', 'ل', 'ك')
LOG = []

QAC_SHA256 = '742bfac59941b2cb09736d5b7aae694af50792261fb8450cbf6afafcc340645f'
QAC_MIRROR = 'mustafa0x/quran-morphology @ 8f38b39'


def log(s):
    LOG.append(s)
    print(s)


def key(s):
    """Alignment key: build_db norm(), then collapse hamza seats
    (ئ->ء, ؤ->ا, ء->ا), delete every alef, collapse doubled letters.
    Collapses dagger-alef / hamza-on-line / shadda-vs-double-letter
    spelling differences between Uthmani (QAC) and simple-clean (FTS)
    without ever touching the Quranic text itself (keys only).
    Spaces are dropped: one QAC word form ('إِلْ يَاسِينَ') contains
    a space where simple-clean has two tokens."""
    s = norm(s).replace(' ', '')
    s = s.replace('\u0626', '\u0621').replace('\u0624', 'ا').replace('\u0621', 'ا')
    s = s.replace('ا', '')
    out = []
    for ch in s:
        if not out or out[-1] != ch:
            out.append(ch)
    return ''.join(out)


def reconstruct_originals(column):
    toks = [t for t in (column or '').split(' ') if t]
    orig = []
    for i, t in enumerate(toks):
        if i > 0 and _strip_prefix_old(toks[i - 1]) == t:
            # Chain rescue: a token that is the strip of its predecessor
            # is a COPY — unless the NEXT token is its own strip, which
            # proves it was itself stored as an original (a copy is
            # never followed by its own strip). Without this, chains
            # eat real words: 7:21 tafsir «لكما كما ما قلت» dropped
            # both «كما» and «ما» (لكما->كما->ما), losing the real
            # «كما» (base ما) for query ما; 28:45 «ولكنا لكنا كنا نا»
            # dropped «لكنا» and «كنا» the same way. A false rescue
            # can only duplicate a match the old index already has
            # (the rescued token exists in the FTS column as a stored
            # copy), so this is strictly safer than dropping.
            if i + 1 < len(toks) and _strip_prefix_old(t) == toks[i + 1]:
                orig.append(t)
                continue
            continue
        orig.append(t)
    return orig


def lemma_of(segs):
    # the STEM's lemma, not a prefix particle's (بسم's segments carry
    # LEM:ب on the prefix and LEM:اسم on the stem — the first is wrong)
    for sg in segs:
        if seg_is_pref(sg):
            continue
        m = re.search(r'LEM:([^|]+)', sg['feats'])
        if m:
            return norm(m.group(1))
    for sg in segs:
        m = re.search(r'LEM:([^|]+)', sg['feats'])
        if m:
            return norm(m.group(1))
    return None


def seg_is_pref(sg):
    return 'PREF' in sg['feats']


def key2(s):
    """Fuzzy key for repair only: key() with ي/و also collapsed to
    (deleted) alef, plus the two systematic Uthmani spelling
    alternations: ص/س (يبصط/يبسط، بصطه/بسطه) and the idgham نل->ل
    (والو = وأن لو، 72:16). Reconciles ا/ي/و alternations between
    Uthmani and simple-clean (ابراهم/ابراهيم، ميكيل/ميكال،
    اشتريه/اشتراه، فسويهن/فسواهن). Never used as the primary key —
    only to pair a word when exact keys fail and the alignment
    resyncs right after."""
    s = norm(s).replace(' ', '')
    s = s.replace('\u0626', '\u0621').replace('\u0624', 'ا').replace('\u0621', 'ا')
    s = s.replace('ص', 'س')
    s = s.replace('ي', 'ا').replace('و', 'ا').replace('ا', '')
    s = s.replace('نل', 'ل')
    out = []
    for ch in s:
        if not out or out[-1] != ch:
            out.append(ch)
    return ''.join(out)


def key_nc(s):
    """key() without run-collapsing. Needed when comparing a single
    word against the CONCATENATION of two tokens (c12/c21): collapsing
    would erase the word boundary — e.g. key('الرسول'+'الا') collapsed
    to 'لرسول', identical to key('الرسول'), a false 1:2 match."""
    s = norm(s).replace(' ', '')
    s = s.replace('\u0626', '\u0621').replace('\u0624', 'ا').replace('\u0621', 'ا')
    s = s.replace('ا', '')
    return s


def key2_nc(s):
    """key2() without run-collapsing (same boundary reason)."""
    s = norm(s).replace(' ', '')
    s = s.replace('\u0626', '\u0621').replace('\u0624', 'ا').replace('\u0621', 'ا')
    s = s.replace('ص', 'س')
    s = s.replace('ي', 'ا').replace('و', 'ا').replace('ا', '')
    s = s.replace('نل', 'ل')
    return s


def _first_ok(t, r):
    """First-character compatibility for the prefix-strip verification:
    the remainder must start with the same letter as the stem (modulo
    hamza seats). Without it, key()'s alef erasure lets a strip eat
    the stem's own initial alef (آلله -> لله instead of الله,
    10:59/27:59). A length guard cannot do this job: the dagger-alef
    in QAC's spelling (رحمان) legitimately makes `rest` longer than
    the token remainder (رحمن)."""
    if not t or not r:
        return False

    def fc(c):
        return 'ا' if c in 'اأإآءئؤ' else c

    return fc(t[0]) == fc(r[0])


def base_from_qac(token, segs, fuzzy=False):
    """Base for ONE FTS token aligned to (part of) one QAC word.
    segs = the QAC segments aligned to this token (in order).
    Returns (base, ok, stem, lemma, elided). ok=False flags a case
    where the QAC prefix does not anchor to the token spelling.
    Verification uses key() normally, key2() for fuzzy pairs."""
    pref = ''.join(norm(sg['form']) for sg in segs if seg_is_pref(sg))
    # 'STEM' is NOT a reliable marker in QAC feats (لله's stem segment
    # is 'PN|ROOT:أله|LEM:اللَّه|GEN', بسم's is 'N ROOT:سمو|...'):
    # stem = every non-prefix segment that is not a suffix attachment
    stem = ''.join(norm(sg['form']) for sg in segs
                   if not seg_is_pref(sg) and 'SUFF' not in sg['feats'])
    rest = ''.join(norm(sg['form']) for sg in segs if not seg_is_pref(sg))
    lem = lemma_of(segs)
    elided = False
    if not rest:
        # the token is a bare prefix particle (يا in يا+قوم, و/ف as
        # separate tokens): it IS its own base, never empty
        return token, True, stem, lem, False
    if lem and stem and (lem == 'ا' + stem or lem == 'ال' + stem):
        return lem, True, stem, lem, True
    # assimilated ال after ل (لِلَّذِينَ / لِلَّتِي): the stem lost its
    # initial alef and the two lams merged, so the stem is لذين/لتي
    # while the word is الذين/التي. The lemma is the singular الذي, so
    # the generic elision rule above cannot see it. Guarded to tokens
    # starting with لل so the dual اللذين (a single stem اللذين) is
    # untouched.
    if stem in ('لذين', 'لتي') and token.lstrip('وف').startswith('لل'):
        return 'ا' + stem, True, stem, lem, True
    if not pref:
        return token, True, stem, lem, False
    vk = key2 if fuzzy else key
    # find how many token chars the prefix covers: raw match first
    # (hamza-on-line ء in QAC == ا in the token), else key match.
    # Verification compares against `rest` (stem + any suffixes, e.g.
    # والمؤمنين -> مؤمنين, not مؤمن) and requires first-character
    # compatibility (see _first_ok).
    pref2 = pref.replace('\u0621', 'ا')
    if token.startswith(pref2):
        k = len(pref2)
        if _first_ok(token[k:], rest) and vk(token[k:]) == vk(rest):
            return token[k:], True, stem, lem, False
    for k in range(1, len(token) + 1):
        if (vk(token[:k]) == vk(pref) and _first_ok(token[k:], rest)
                and vk(token[k:]) == vk(rest)):
            return token[k:], True, stem, lem, False
    return token, False, stem, lem, False


def _split_segments(toks, segs):
    """Split one QAC word's segments across 2+ FTS tokens by key
    (exact, then key2). The LAST token absorbs all remaining segments
    (they can only be its suffixes — e.g. ياصيحبي -> يا + صاحبي,
    where the trailing 1S pronoun suffix belongs to صاحبي). Returns
    list of segment-groups or None."""
    groups = []
    si = 0
    for ti, t in enumerate(toks):
        if ti == len(toks) - 1:
            g = segs[si:]
            if not g:
                return None
            joined = ''.join(norm(x['form']) for x in g)
            if key(joined) != key(t) and key2(joined) != key2(t):
                return None
            groups.append(g)
            si = len(segs)
            continue
        g = []
        ok = False
        while si < len(segs):
            g.append(segs[si])
            si += 1
            if key(''.join(norm(x['form']) for x in g)) == key(t):
                ok = True
                break
        if not ok:
            si -= len(g)
            g = []
            while si < len(segs):
                g.append(segs[si])
                si += 1
                if key2(''.join(norm(x['form']) for x in g)) == key2(t):
                    ok = True
                    break
            if not ok:
                return None
        groups.append(g)
    if si != len(segs):
        return None
    return groups


def _strip_chain(w):
    """Repeated old-strip results: ولكنا -> [لكنا, كنا, نا]. Used to
    recognise a QAC word the FTS reconstruction dropped (28:45)."""
    out = []
    cur = w
    while True:
        s = _strip_prefix_old(cur)
        if not s or s == cur:
            return out
        out.append(s)
        cur = s


def align_ayah(qac_words, fts_tokens):
    """DP alignment of one ayah's QAC words to its FTS tokens.
    Moves: 1 QAC : 1 FTS (exact key cost 0 / fuzzy key2 cost 1),
    1 : 2 (joined Uthmani word, e.g. ياقوم -> يا + قوم),
    2 : 1 (reconstruction dropped a word, e.g. 28:45 ولكنا + كنا).
    No skips: an unalignable word fails the whole ayah (fallback
    bases for its tokens). Returns list of (fts_token, segs, fuzzy)
    or None on failure."""
    INF = float('inf')
    n, m = len(qac_words), len(fts_tokens)
    qw_key = [key(''.join(norm(x['form']) for x in segs)) for segs in qac_words]
    qw_key2 = [key2(''.join(norm(x['form']) for x in segs)) for segs in qac_words]
    qw_key_nc = [key_nc(''.join(norm(x['form']) for x in segs)) for segs in qac_words]
    qw_key2_nc = [key2_nc(''.join(norm(x['form']) for x in segs)) for segs in qac_words]
    ft_key = [key(t) for t in fts_tokens]
    ft_key2 = [key2(t) for t in fts_tokens]
    ft_key_nc = [key_nc(t) for t in fts_tokens]
    ft_key2_nc = [key2_nc(t) for t in fts_tokens]

    def c11(i, j):
        if qw_key[i] == ft_key[j] and qw_key[i] != '':
            return 0
        if qw_key2[i] == ft_key2[j] and qw_key2[i] != '':
            return 1
        return INF

    def c12(i, j):  # qac i -> fts j-1, j (no-collapse keys: the word
        # boundary must survive, else الرسول+الا == الرسول)
        if j < 1:
            return INF
        cat = fts_tokens[j - 1] + fts_tokens[j]
        if qw_key_nc[i] == key_nc(cat) and qw_key_nc[i] != '':
            return 0
        if qw_key2_nc[i] == key2_nc(cat) and qw_key2_nc[i] != '':
            return 1
        return INF

    def c13(i, j):  # qac i -> fts j-2, j-1, j (joined vocative
        # يبنؤم -> يا + ابن + ام, 20:94). Same no-collapse rule.
        if j < 2:
            return INF
        cat = fts_tokens[j - 2] + fts_tokens[j - 1] + fts_tokens[j]
        if qw_key_nc[i] == key_nc(cat) and qw_key_nc[i] != '':
            return 0
        if qw_key2_nc[i] == key2_nc(cat) and qw_key2_nc[i] != '':
            return 1
        return INF

    def c21(i, j):  # qac i-1, i -> fts j: the FTS reconstruction
        # dropped a word (28:45 ولكنا + كنا -> ولكنا). The token must
        # match the FIRST QAC word, and the absorbed second word must
        # be in the token's old-strip chain (كنا <- لكنا <- ولكنا).
        if i < 1:
            return INF
        first = ''.join(norm(x['form']) for x in qac_words[i - 1])
        second = ''.join(norm(x['form']) for x in qac_words[i])
        tok = fts_tokens[j]
        if second not in _strip_chain(tok):
            return INF
        if key_nc(first) == ft_key_nc[j] and ft_key_nc[j] != '':
            return 1
        if key2_nc(first) == ft_key2_nc[j] and ft_key2_nc[j] != '':
            return 1
        return INF

    dp = [[INF] * (m + 1) for _ in range(n + 1)]
    bt = [[None] * (m + 1) for _ in range(n + 1)]
    dp[0][0] = 0
    for i in range(n + 1):
        for j in range(m + 1):
            if dp[i][j] == INF:
                continue
            if i < n and j < m:
                c = c11(i, j)
                if c < INF and dp[i][j] + c < dp[i + 1][j + 1]:
                    dp[i + 1][j + 1] = dp[i][j] + c
                    bt[i + 1][j + 1] = ('11', i, j, c)
            if i < n and j + 1 < m:
                c = c12(i, j + 1)
                if c < INF and dp[i][j] + c < dp[i + 1][j + 2]:
                    dp[i + 1][j + 2] = dp[i][j] + c
                    bt[i + 1][j + 2] = ('12', i, j, c)
            if i < n and j + 2 < m:
                c = c13(i, j + 2)
                if c < INF and dp[i][j] + c < dp[i + 1][j + 3]:
                    dp[i + 1][j + 3] = dp[i][j] + c
                    bt[i + 1][j + 3] = ('13', i, j, c)
            if i + 1 < n and j < m:
                c = c21(i + 1, j)
                if c < INF and dp[i][j] + c < dp[i + 2][j + 1]:
                    dp[i + 2][j + 1] = dp[i][j] + c
                    bt[i + 2][j + 1] = ('21', i, j, c)
    if dp[n][m] == INF:
        return None, None
    steps = []
    i, j = n, m
    while (i, j) != (0, 0):
        kind, pi, pj, c = bt[i][j]
        steps.append((kind, pi, pj, c))
        if kind == '11':
            i, j = pi, pj
        elif kind == '12':
            i, j = pi, pj
        else:
            i, j = pi, pj
    steps.reverse()
    res = []
    absorbed = []   # QAC words the FTS reconstruction dropped (2:1
    # moves, e.g. 28:45 كنا): real tokens of the ayah that no FTS
    # token spells — recorded so the filter can see them
    for kind, pi, pj, c in steps:
        fuzzy = (c == 1)
        if kind == '11':
            res.append((fts_tokens[pj], qac_words[pi], fuzzy))
        elif kind == '12':
            groups = _split_segments(fts_tokens[pj:pj + 2], qac_words[pi])
            if groups is None:
                return None, None
            for t, g in zip(fts_tokens[pj:pj + 2], groups):
                res.append((t, g, fuzzy))
        elif kind == '13':
            groups = _split_segments(fts_tokens[pj:pj + 3], qac_words[pi])
            if groups is None:
                return None, None
            for t, g in zip(fts_tokens[pj:pj + 3], groups):
                res.append((t, g, fuzzy))
        else:  # 21: two QAC words cover one FTS token; the token
            # takes the FIRST word's segments (e.g. 28:45 ولكنا);
            # the absorbed word's base lives on its own surfaces.
            res.append((fts_tokens[pj], qac_words[pi], fuzzy))
            absorbed.append(''.join(norm(x['form'])
                                    for x in qac_words[pi + 1]))
    return res, absorbed

def build_lexicon(db_path, qac_path, out_path=None, json_path=None):
    """Build the lexicon tables from QAC + the FTS columns of db_path.

    If out_path is given, db_path is copied there first and the tables
    are built in the copy; otherwise they are built in place in db_path.
    Returns a dict of build stats. Raises SystemExit on any mismatch
    (wrong QAC hash, wrong ayah count, integrity failure).
    """
    global LOG
    LOG = []
    target = out_path or db_path
    if out_path:
        shutil.copyfile(db_path, out_path)

    qac_bytes = open(qac_path, 'rb').read()
    qac_sha = hashlib.sha256(qac_bytes).hexdigest()
    if qac_sha != QAC_SHA256:
        print('ERROR: quran-morphology.txt SHA-256 mismatch: got %s, '
              'expected %s (pinned mirror %s)' % (qac_sha, QAC_SHA256, QAC_MIRROR))
        sys.exit(1)
    db_sha = hashlib.sha256(open(db_path, 'rb').read()).hexdigest()

    con = sqlite3.connect('file:%s?mode=ro' % db_path, uri=True)
    assert con.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    ayahs = {}
    id_of = {}
    for gid, s, a, ncol, tcol in con.execute(
            'SELECT ayahs_fts.rowid, ayahs.surah, ayahs.ayah, ayahs_fts.norm, ayahs_fts.tafsir '
            'FROM ayahs_fts JOIN ayahs ON ayahs.id = ayahs_fts.rowid ORDER BY ayahs_fts.rowid'):
        ayahs[gid] = (s, a, reconstruct_originals(ncol), reconstruct_originals(tcol))
        id_of[(s, a)] = gid
    if len(ayahs) != 6236:
        print('ERROR: expected 6236 ayahs, got %d' % len(ayahs))
        sys.exit(1)
    log('ayahs=%d' % len(ayahs))

    # ---- parse QAC ----
    qac = defaultdict(list)   # (s,a) -> list of (w, segs)
    with open(qac_path, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            loc, form, tag, feats = line.rstrip('\n').split('\t')
            s, a, w, _seg = (int(x) for x in loc.split(':'))
            if form == '':
                # 208 empty segments, all PRON|SUFF|1S (elided possessive
                # ي, e.g. يا قومِ): no spelling, nothing to align
                continue
            qac[(s, a)].append((w, {'form': form, 'tag': tag, 'feats': feats}))
    qac_words = {}
    for (s, a), items in qac.items():
        by_w = defaultdict(list)
        for w, sg in items:
            by_w[w].append(sg)
        words = []
        for w in sorted(by_w):
            segs = by_w[w]
            if len(segs) == 1 and ' ' in norm(segs[0]['form']):
                # one QAC "word" whose form contains a space
                # (37:130 إِلْ يَاسِينَ, single segment): split into
                # pseudo-words so each aligns to one FTS token
                for part in norm(segs[0]['form']).split(' '):
                    words.append([dict(segs[0], form=part)])
            else:
                words.append(segs)
        qac_words[(s, a)] = words

    # ---- align + per-token bases (Quran) ----
    votes = defaultdict(Counter)   # surface -> Counter(base)
    anomalies = []
    aligned_ayahs = 0
    fuzzy_pairs = Counter()
    token_base = {}   # (gid, idx) -> base (per-occurrence, for audit)
    extra = {}        # gid -> [absorbed QAC words, e.g. 28:45 كنا]
    for gid, (s, a, toks, _t) in sorted(ayahs.items()):
        al, absorbed = align_ayah(qac_words[(s, a)], toks)
        if al is None:
            anomalies.append('%d:%d toks=%s qac=%s' % (
                s, a, ' '.join(toks),
                ' | '.join(''.join(norm(x['form']) for x in segs) for segs in qac_words[(s, a)])))
            continue
        aligned_ayahs += 1
        if absorbed:
            extra[gid] = absorbed
        for idx, (tok, segs, fuzzy) in enumerate(al):
            base, ok, stem, lem, elided = base_from_qac(tok, segs, fuzzy)
            if fuzzy:
                fuzzy_pairs[(tok, ''.join(norm(x['form']) for x in segs))] += 1
            if not ok:
                anomalies.append('%d:%d prefix-mismatch tok=%s segs=%s' % (
                    s, a, tok, '+'.join(norm(x['form']) for x in segs)))
            votes[tok][base] += 1
            token_base[(gid, idx)] = base
    log('aligned ayahs: %d / %d' % (aligned_ayahs, len(ayahs)))
    log('fuzzy (key2) pairs: %d distinct, %d total' % (
        len(fuzzy_pairs), sum(fuzzy_pairs.values())))
    for (tok, qacw), n in sorted(fuzzy_pairs.items(), key=lambda kv: -kv[1])[:20]:
        log('  FUZZY %-10s <- QAC %-10s x%d' % (tok, qacw, n))
    log('alignment anomalies: %d' % len(anomalies))
    for an in anomalies[:15]:
        log('  ANOMALY: ' + an)
    if len(anomalies) > 15:
        log('  ... +%d more (see build log file)' % (len(anomalies) - 15))

    # ---- surface -> base by dominant vote (ties: longest base) ----
    lex = {}
    multi = {}
    for surf, c in votes.items():
        top = max(c.values())
        cands = sorted([b for b, n in c.items() if n == top], key=lambda b: (-len(b), b))
        lex[surf] = cands[0]
        if len(c) > 1:
            multi[surf] = dict(c)
    log('Quran surfaces with a QAC base: %d' % len(lex))
    log('surfaces with >1 distinct QAC base: %d' % len(multi))
    for surf in sorted(multi, key=lambda x: -sum(multi[x].values()))[:25]:
        log('  MULTI %-10s %s' % (surf, multi[surf]))
    # elision cases: base differs from surface only via lemma; list them
    # by re-deriving: surfaces whose base is not a suffix-strip of them
    odd = {t: b for t, b in lex.items()
           if b != t and not t.endswith(b) and b not in ('', t)}
    log('bases that are NOT a suffix of their surface (elision etc.): %d' % len(odd))
    for t in sorted(odd)[:40]:
        log('  ODD %-10s -> %s' % (t, odd[t]))

    bases = set(lex.values())
    log('distinct bases (Quran): %d' % len(bases))

    # ---- fallback segmentation (tafsir surfaces + unaligned) ----
    def fallback_base(w, known=None):
        # compound / ال strips are safe and unconditional (as in v2)
        known = bases if known is None else known
        for p in COMPOUND:
            if w.startswith(p) and len(w) - len(p) >= 2:
                return w[len(p):]
        if w.startswith('ال') and len(w) - 2 >= 3:
            return w[2:]
        # single-letter: only if the remainder is a known base AND the
        # surface is not itself a known base (kills كانت/بسم/كتابا/وعد/
        # فارض; keeps لموسى/ويوم/وقالوا/بصابرين)
        for p in SINGLE:
            if w.startswith(p) and len(w) - 1 >= 2:
                r = w[1:]
                if r in known and w not in known:
                    return r
        return w

    # tafsir surfaces — two passes. Pass 1 uses Quran bases only.
    # Pass 2 extends the known bases with the pass-1 tafsir bases, so
    # a tafsir word whose bare form occurs in tafsir (مالكهم، مالهم،
    # مادتها، مانع) also strips its prefix when prefixed (ومالكهم…).
    # Pass 2 changes are logged separately for the mis-strip audit.
    taf_surf = Counter()
    for _, (_, _, _, ttoks) in ayahs.items():
        for t in ttoks:
            taf_surf[t] += 1
    log('distinct tafsir surfaces: %d' % len(taf_surf))
    taf_lex = {}
    taf_fallback = 0
    for surf in taf_surf:
        if surf in lex:
            taf_lex[surf] = lex[surf]
        else:
            taf_lex[surf] = fallback_base(surf)
            taf_fallback += 1
    log('tafsir surfaces covered by Quran lexicon: %d; by fallback: %d' % (
        len(taf_surf) - taf_fallback, taf_fallback))
    fb_changed = {s: b for s, b in taf_lex.items() if s in taf_surf and s not in lex and b != s}
    log('fallback actually stripped %d tafsir-only surfaces, e.g. %s' % (
        len(fb_changed), dict(list(sorted(fb_changed.items()))[:15])))
    bases2 = bases | {b for s, b in taf_lex.items()
                     if b != s or (s[0] not in SINGLE
                                   and not s.startswith(COMPOUND))}
    # NB: the identity mappings must NOT pollute the known bases: a
    # pass-1 identity base of a surface that LOOKS prefixed (ومالكهم)
    # is not evidence that the surface is a word — it only means the
    # strip was blocked. Only stripped bases (b != s) and identity
    # bases of unprefixed surfaces (مالكهم، مانع) count as known.
    changed2 = {}
    for surf in taf_surf:
        if surf in lex:
            continue
        b2 = fallback_base(surf, bases2)
        if b2 != taf_lex[surf]:
            changed2[surf] = (taf_lex[surf], b2)
            taf_lex[surf] = b2
    _new_strips = {s: v for s, v in changed2.items() if v[1] != s}
    _un_strips = {s: v for s, v in changed2.items() if v[1] == s}
    log('pass-2 tafsir re-strip: %d surfaces changed (%d newly stripped, '
        '%d un-stripped); newly stripped e.g. %s; un-stripped e.g. %s' % (
            len(changed2), len(_new_strips), len(_un_strips),
            dict(list(sorted(_new_strips.items(),
                             key=lambda kv: -taf_surf[kv[0]])[:15])),
            dict(list(sorted(_un_strips.items(),
                             key=lambda kv: -taf_surf[kv[0]])[:15]))))
    # unaligned Quran surfaces (if any) also get the fallback
    all_q = Counter()
    for _, (_, _, toks, _) in ayahs.items():
        for t in toks:
            all_q[t] += 1
    missing_q = [t for t in all_q if t not in lex]
    log('Quran surfaces without QAC base: %d %s' % (len(missing_q), missing_q[:10]))
    for t in missing_q:
        lex[t] = fallback_base(t)

    # ---- write outputs ----
    ocon = sqlite3.connect(target)
    ocon.execute('DROP TABLE IF EXISTS lexicon')
    ocon.execute('CREATE TABLE lexicon(surface TEXT PRIMARY KEY, base TEXT, '
                 'votes INTEGER, source TEXT)')
    ocon.execute('CREATE INDEX idx_lex_base ON lexicon(base)')
    rows = []
    for surf, base in sorted(lex.items()):
        rows.append((surf, base, sum(votes[surf].values()) if surf in votes else 0,
                     'qac' if surf in votes else 'fallback'))
    ocon.executemany('INSERT INTO lexicon VALUES(?,?,?,?)', rows)
    ocon.execute('DROP TABLE IF EXISTS lexicon_tafsir')
    ocon.execute('CREATE TABLE lexicon_tafsir(surface TEXT PRIMARY KEY, base TEXT, source TEXT)')
    ocon.executemany('INSERT INTO lexicon_tafsir VALUES(?,?,?)',
                     [(s, b, 'qac' if s in lex and s in votes else 'fallback')
                      for s, b in sorted(taf_lex.items())])
    ocon.execute('DROP TABLE IF EXISTS lexicon_extra')
    ocon.execute('CREATE TABLE lexicon_extra(ayah_id INTEGER, token TEXT, '
                 'PRIMARY KEY(ayah_id, token))')
    ocon.executemany('INSERT INTO lexicon_extra VALUES(?,?)',
                     [(gid, tok) for gid, toks in sorted(extra.items())
                      for tok in toks])
    ocon.execute('DROP TABLE IF EXISTS lexicon_meta')
    ocon.execute('CREATE TABLE lexicon_meta(key TEXT PRIMARY KEY, value TEXT)')
    ocon.executemany('INSERT INTO lexicon_meta VALUES(?,?)', [
        ('base_db_sha256', db_sha),
        ('qac_sha256', qac_sha),
        ('qac_source', 'Quranic Arabic Corpus v0.4 (GPL), mirror %s' % QAC_MIRROR),
        ('aligned_ayahs', str(aligned_ayahs)),
        ('quran_surfaces', str(len(lex))),
        ('multi_analysis_surfaces', str(len(multi))),
        ('tafsir_surfaces', str(len(taf_lex))),
        ('extra_originals', str(sum(len(v) for v in extra.values()))),
        ('built_by', 'tools/build_lexicon.py (Tilawa Pro)'),
        ('license_status',
         'PENDING legal confirmation for shipping QAC-derived tables; '
         'QAC v0.4 is GPL — attribution to corpus.quran.com required'),
    ])
    ocon.commit()
    assert ocon.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    ocon.close()
    con.close()
    if json_path:
        with open(json_path, 'w', encoding='utf-8') as f:
            json.dump({'lexicon': {s: {'base': b, 'votes': dict(votes[s]) if s in votes else {}}
                                   for s, b in sorted(lex.items())},
                       'multi_analysis': multi,
                       'anomalies': anomalies,
                       'token_base': {'%d:%d' % (gid, idx): b
                                      for (gid, idx), b in sorted(token_base.items())},
                       'extra_originals': {str(gid): toks
                                           for gid, toks in sorted(extra.items())}},
                      f, ensure_ascii=False, indent=1)
    # sanity: show the key cases
    for t in ['كانت', 'بسم', 'كتابا', 'تابا', 'سم', 'انت', 'لموسي', 'وموسي',
              'ويوم', 'وقالوا', 'فقال', 'بصابرين', 'الصابرين', 'فارض', 'وعد',
              'لما', 'مما', 'كما', 'موسي', 'يوم', 'قال', 'ما', 'الرحمن', 'لله',
              'الذين', 'فكانت', 'وكانت', 'وانتم', 'لسميع', 'بمؤمنين']:
        if t in lex:
            log('  LEX %-10s -> %-10s %s' % (t, lex[t], dict(votes[t]) if t in votes else 'fallback'))
        else:
            log('  LEX %-10s MISSING (tafsir-only? %s)' % (t, t in taf_lex))
    log('WROTE %s (lexicon rows=%d)' % (target, len(rows)))
    return {'target': target, 'lexicon_rows': len(rows),
            'tafsir_rows': len(taf_lex), 'aligned_ayahs': aligned_ayahs,
            'anomalies': len(anomalies), 'multi_analysis': len(multi),
            'qac_sha256': qac_sha, 'base_db_sha256': db_sha}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Build lexicon tables into a Tilawa DB.')
    ap.add_argument('db', help='app DB (6236 ayahs, FTS columns present)')
    ap.add_argument('qac', help='quran-morphology.txt (QAC v0.4, SHA-256 verified)')
    ap.add_argument('--out', help='output DB (default: build in place in <db>)')
    ap.add_argument('--json', help='optional lexicon.json audit output')
    args = ap.parse_args()
    build_lexicon(args.db, args.qac, out_path=args.out, json_path=args.json)
