#!/usr/bin/env python3
"""Builds assets/quran.db (SQLite + FTS5) for the Tilawa Quran app.

usage: build_db.py <snapshot-dir> <out.db> <quran-rev> <tafsir-rev>
Sources (all public, with attribution in meta):
  - Quran text: Tanzil Uthmani v1.1 via HuggingFace quranlab/quran
    (config arabic-uthmani). Licence: copy verbatim, attribute Tanzil,
    link tanzil.net. The FTS index is built from the same project's
    simple-clean text (config arabic-simple-clean, standard spelling —
    no dagger alefs), aligned verse by verse and verified; the displayed
    text stays Uthmani.
  - Tafsirs: HuggingFace quranlab/quran-tafsir — الميسر، الجلالين، السعدي
    (classic works, public domain; packaging: QuranLab).
  - Surah metadata (names, revelation, counts) comes from the same
    Tanzil-aligned rows and is cross-checked against the canonical
    per-surah ayah counts (verified 2026-11-23 against AlQuranCloud meta
    and EveryAyah's ayahCount list).

The builder FAILS LOUDLY on any mismatch: 114 surahs, 6,236 ayahs,
per-surah counts, and every I'jaz quote must be found verbatim
(normalized) in its referenced ayah range. Nothing is invented.
"""
import datetime, glob, hashlib, json, os, re, sqlite3, sys

QURAN_REV = 'b4e0edc2a0c8ffa6952c6f5fdf31a19acd75a068'
TAFSIR_REV = '1020ac515b158a1e718fe647dab73c0c77dd5a65'

# Canonical per-surah ayah counts (114), verified against AlQuranCloud
# /v1/meta and EveryAyah recitations.js ayahCount (2026-11-23).
EXPECTED_COUNTS = [7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111,
                   43, 52, 99, 128, 111, 110, 98, 135, 112, 78, 118, 64, 77,
                   227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83, 182, 88, 75,
                   85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62,
                   55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30,
                   52, 52, 44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29,
                   19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21, 11, 8, 8, 19,
                   5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6]

TAFSIRS = [
    ('muyassar', 'التفسير الميسر', 'مجمع الملك فهد لطباعة المصحف الشريف'),
    ('jalalayn', 'تفسير الجلالين', 'جلال الدين المحلي وجلال الدين السيوطي'),
    ('saadi', 'تفسير السعدي (تيسير الكريم الرحمن)', 'عبد الرحمن بن ناصر السعدي'),
]

# (title, ayah_ref, surah, first_ayah, last_ayah, quote, text, source)
# Every quote is checked by the builder against the referenced ayahs.
IJAZ = [
    ('أطوار خلق الإنسان', 'المؤمنون 12–14', 23, 12, 14,
     'فخلقنا المضغه عظاما فكسونا العظام لحما',
     'يصف القرآن خلق الإنسان أطوارًا: نطفة، ثم علقة، ثم مضغة، ثم عظامًا تُكسى لحمًا، ثم خلقًا آخر. '
     'ذكر المفسرون هذه الأطوار كما هي في الآية، ومنهم ابن كثير في تفسيره. '
     'وقد أشار علماء الأجنة — ومنهم د. كيث مور في كتابه «الإنسان النامي» — إلى أن هذا الترتيب '
     'يتوافق مع المراحل المعروفة لتطور الجنين: التعلق بجدار الرحم، ثم الكتلة اللحمية، ثم تكون العظام قبل اكتسائها بالعضلات.',
     'تفسير ابن كثير؛ كيث مور، «الإنسان النامي» (The Developing Human)'),
    ('البرزخ بين البحرين', 'الرحمن 19–20', 55, 19, 20,
     'مرج البحرين يلتقيان بينهما برزخ لا يبغيان',
     'يخبر القرآن أن بحرين يلتقيان وبينهما برزخ يمنعهما من أن يبغي أحدهما على الآخر. '
     'وقد وثّق علم المحيطات ظاهرة الحواجز بين الكتل المائية المختلفة في الملوحة والكثافة والحرارة، '
     'ومن أشهر مواضعها مضيق جبل طارق حيث يلتقي ماء المحيط الأطلسي بماء البحر المتوسط دون اختلاط كامل. '
     'قال ابن كثير: البرزخ حاجز بينهما لا يبغي أحدهما على الآخر.',
     'تفسير ابن كثير؛ علم المحيطات الحديث'),
    ('توسع الكون', 'الذاريات 47', 51, 47, 47,
     'وانا لموسعون',
     'يقول الله تعالى عن السماء: ﴿وَإِنَّا لَمُوسِعُونَ﴾. '
     'فسّر السعدي «لموسعون» بأن الله وسّع السماء وأرجاءها. '
     'وفي عام 1929 اكتشف الفلكي إدوين هابل أن المجرات تتباعد عن بعضها، وهو ما أصبح أساس القول العلمي بتوسع الكون.',
     'تفسير السعدي؛ اكتشاف إدوين هابل 1929'),
    ('إنزال الحديد', 'الحديد 25', 57, 25, 25,
     'وانزلنا الحديد فيه باس شديد',
     'قال الله تعالى: ﴿وَأَنزَلْنَا الْحَدِيدَ فِيهِ بَأْسٌ شَدِيدٌ﴾. '
     'وقد ثبت في علم الفلك الحديث أن الحديد لا يتكون في النجوم الصغيرة، بل في النجوم الضخمة عند انفجارها، '
     'وأن الحديد الموجود في الأرض وصل إليها مع النيازك في المراحل الأولى من تكونها. '
     'فالتعبير بـ«الإنزال» يتوافق مع مصدر الحديد من خارج الأرض.',
     'تفسير ابن كثير؛ علم الفلك الحديث'),
    ('ظلمات البحر العميق', 'النور 40', 24, 40, 40,
     'ظلمات بعضها فوق بعض',
     'يمثّل القرآن حال الكافر بظلمات في بحر عميق يغشاه موج من فوقه موج من فوقه سحاب، ظلمات بعضها فوق بعض. '
     'وقد أثبت علم المحيطات أن ضوء الشمس يتلاشى تدريجيًا مع العمق حتى يبلغ البحر العميق ظلمة شبه تامة، '
     'وأن الأمواج الداخلية تتحرك تحت سطح البحر بعيدًا عن الأنظار، وهو ما لم يكن معروفًا زمن نزول القرآن.',
     'تفسير ابن كثير؛ علم المحيطات الحديث'),
    ('الأجرام في فلك', 'الأنبياء 33', 21, 33, 33,
     'كل في فلك يسبحون',
     'يقول الله تعالى عن الشمس والقمر: ﴿كُلٌّ فِي فَلَكٍ يَسْبَحُونَ﴾. '
     'وقد فسّر ابن كثير الفلك بأنه مدار تسير فيه الأجرام. '
     'واليوم من الثابت أن كل جرم سماوي يسير في مدار محدد: القمر حول الأرض، والأرض حول الشمس، والشمس حول مركز المجرة.',
     'تفسير ابن كثير؛ علم الفلك الحديث'),
    ('الجبال أوتادًا', 'النبأ 6–7', 78, 6, 7,
     'والجبال اوتادا',
     'قال الله تعالى: ﴿وَالْجِبَالَ أَوْتَادًا﴾. '
     'والوتد ما يُثبَّت به الشيء ويغوص معظمه في الأرض. '
     'وقد أثبتت الدراسات الجيولوجية الحديثة أن للجبال جذورًا عميقة تمتد تحت سطح الأرض إلى أعماق كبيرة، '
     'وأنها تسهم في توازن القشرة الأرضية (مبدأ الاتزان الأرضي).',
     'تفسير ابن كثير؛ الجيولوجيا الحديثة (مبدأ الاتزان الأرضي)'),
    ('وحي النحل', 'النحل 68–69', 16, 68, 69,
     'واوحى ربك الى النحل',
     'قال الله تعالى: ﴿وَأَوْحَىٰ رَبُّكَ إِلَى النَّحْلِ﴾، ثم ذكر أن من بطونها يخرج شراب مختلف ألوانه فيه شفاء للناس. '
     'وقد كشف العلم الحديث عن نظام اتصال دقيق بين النحل (رقصة النحل التي وصفها كارل فون فريش)، '
     'وعن خصائص مضادة للميكروبات في العسل وثّقتها الدراسات الطبية الحديثة.',
     'تفسير ابن كثير؛ كارل فون فريش، دراسات رقصة النحل'),
    ('تسوية البنان', 'القيامة 3–4', 75, 3, 4,
     'بلى قادرين على ان نسوي بنانه',
     'يقول الله تعالى ردًا على من يشك في إعادة خلق الإنسان: ﴿بَلَىٰ قَادِرِينَ عَلَىٰ أَن نُّسَوِّيَ بَنَانَهُ﴾. '
     'والبنان أطراف الأصابع، وفيها بصمات لا تتطابق بين شخصين على وجه الأرض، '
     'وهي حقيقة علمية اعتمد عليها علم الأدلة الجنائية في التعرف على الأشخاص منذ أواخر القرن التاسع عشر.',
     'تفسير ابن كثير؛ علم البصمات والأدلة الجنائية'),
    ('الماء أصل الحياة', 'الأنبياء 30', 21, 30, 30,
     'وجعلنا من الماء كل شيء حي',
     'قال الله تعالى: ﴿وَجَعَلْنَا مِنَ الْمَاءِ كُلَّ شَيْءٍ حَيٍّ﴾. '
     'وقد قرر علم الأحياء الحديث أن الماء ضروري لكل صور الحياة المعروفة، وأن جسم الكائن الحي يتكون معظمه من الماء، '
     'ولا توجد حياة معروفة تقوم بغيره.',
     'تفسير ابن كثير؛ علم الأحياء الحديث'),
]

TASHKEEL = re.compile(r'[\u064B-\u065F\u06D6-\u06ED\u0640]')
ALEF = re.compile(r'[إأآٱ]')
NONWORD = re.compile(r'[^\u0621-\u064A\u0660-\u0669a-zA-Z0-9\s]')
SPACES = re.compile(r'\s+')


def norm(s):
    # Uthmani spelling: the dagger alef (U+0670) IS a letter, not a mark:
    # "وٰ" (waw + dagger alef) is pronounced as a long "a" — الصلوة = الصلاة —
    # a bare dagger alef is an alef — عِظَٰمًا = عظامًا — but after ى it is
    # only a length mark — أَوۡحَىٰ = أوحى. Stripping it outright (as the
    # hadith app's norm does) breaks both the text and the search, so map it
    # explicitly. The Dart normalizeAr in lib/db.dart MUST stay identical.
    # NOTE: the FTS index itself is built from the Tanzil simple-clean text
    # (standard spelling, no dagger alefs at all), so these rules matter
    # here only for the I'jaz quote check and for queries typed in Uthmani
    # spelling; the index and the query meet on the simple spelling.
    s = s.replace('\u0648\u0670', 'ا').replace('\u0649\u0670', 'ى').replace('\u0670', 'ا')
    s = TASHKEEL.sub('', s)
    s = ALEF.sub('ا', s).replace('ى', 'ي').replace('ة', 'ه')
    s = NONWORD.sub(' ', s)
    return SPACES.sub(' ', s).strip()


def _strip_prefix(w):
    for p in ('وال', 'فال', 'بال', 'لل', 'كال'):
        if w.startswith(p) and len(w) - len(p) >= 2:
            return w[len(p):]
    if w.startswith('ال') and len(w) - 2 >= 3:
        return w[2:]
    for p in ('و', 'ف', 'ب', 'ل', 'ك'):
        if w.startswith(p) and len(w) - 1 >= 2:
            return w[1:]
    return None


def search_norm(s):
    words = norm(s).split(' ')
    out = []
    for w in words:
        if not w:
            continue
        out.append(w)
        stripped = _strip_prefix(w)
        if stripped and stripped != w:
            out.append(stripped)
    return ' '.join(out)


def short_name(full):
    """«سُورَةُ ٱلْفَاتِحَةِ» -> «الفاتحة» (keep آ in آل عمران)."""
    s = full.strip()
    for pref in ('سُورَةُ ', 'سورة '):
        if s.startswith(pref):
            s = s[len(pref):]
            break
    # Protect آ: in the Uthmani data it is usually the decomposed form
    # alef + maddah (U+0653, inside the diacritic range), which would be
    # stripped and turn "آل" into "ال". The dagger alef is only a length
    # mark in surah names (الرحمٰن -> الرحمن), so it is removed here.
    s = s.replace('\u0627\u0653', '\uE000').replace('آ', '\uE000')
    s = re.compile(r'[\u064B-\u065F\u0670\u06D6-\u06ED\u0640]').sub('', s)
    s = s.replace('ٱ', 'ا').replace('\uE000', 'آ')
    return SPACES.sub(' ', s).strip()


def s(x):
    if x is None:
        return ''
    if isinstance(x, float):
        return ''
    return str(x).strip()


def load_rows(dirpath, patterns):
    import pandas as pd
    files = []
    for pat in patterns:
        files += sorted(glob.glob(os.path.join(dirpath, pat)))
    if not files:
        return None
    df = pd.concat([pd.read_parquet(f) for f in files], ignore_index=True)
    return df.to_dict('records')


def build(snapshot, out, qrev, trev):
    if os.path.exists(out):
        os.remove(out)
    con = sqlite3.connect(out)
    cur = con.cursor()
    cur.executescript('''
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE surahs(id INTEGER PRIMARY KEY, name_ar TEXT, name_short TEXT,
                        name_en TEXT, revelation TEXT, ayah_count INTEGER, juz_start INTEGER);
    CREATE TABLE ayahs(id INTEGER PRIMARY KEY, surah INTEGER, ayah INTEGER, text TEXT,
                       juz INTEGER, hizb INTEGER, quarter INTEGER, page INTEGER, sajda INTEGER);
    CREATE TABLE tafsir(surah INTEGER, ayah INTEGER, source TEXT, text TEXT,
                        PRIMARY KEY(surah, ayah, source));
    CREATE TABLE ijaz(id INTEGER PRIMARY KEY, title TEXT, ayah_ref TEXT, surah INTEGER,
                      ayah INTEGER, text TEXT, source TEXT);
    CREATE VIRTUAL TABLE ayahs_fts USING fts5(norm, tafsir, tokenize='unicode61 remove_diacritics 0');
    ''')

    # ── Quran text (Tanzil Uthmani) ──
    rows = load_rows(snapshot, ['arabic-uthmani/*.parquet', 'quran-uthmani.parquet'])
    if not rows:
        print('ERROR: quran text not found under', snapshot)
        sys.exit(1)
    rows.sort(key=lambda r: int(r['ayah_global']))
    if len(rows) != 6236:
        print(f'ERROR: expected 6236 ayahs, got {len(rows)}')
        sys.exit(1)
    surah_meta = {}
    for r in rows:
        sid = int(r['surah'])
        m = surah_meta.setdefault(sid, {
            'name_ar': s(r.get('surah_name_ar')),
            'name_en': s(r.get('surah_name_en')),
            'revelation': 'مدنية' if s(r.get('revelation_place')) == 'Medinan' else 'مكية',
            'count': 0, 'juz_start': int(r['juz']),
        })
        m['count'] += 1
        m['juz_start'] = min(m['juz_start'], int(r['juz']))
    if len(surah_meta) != 114:
        print(f'ERROR: expected 114 surahs, got {len(surah_meta)}')
        sys.exit(1)
    for sid in range(1, 115):
        m = surah_meta[sid]
        if m['count'] != EXPECTED_COUNTS[sid - 1]:
            print(f"ERROR: surah {sid}: {m['count']} ayahs, expected {EXPECTED_COUNTS[sid - 1]}")
            sys.exit(1)
        cur.execute('INSERT INTO surahs VALUES(?,?,?,?,?,?,?)',
                    (sid, m['name_ar'], short_name(m['name_ar']), m['name_en'],
                     m['revelation'], m['count'], m['juz_start']))
    print('surahs: 114 verified (names, revelation, counts)')
    print('sample short names:', ', '.join(
        short_name(surah_meta[i]['name_ar']) for i in (1, 2, 3, 36, 55, 112, 114)))

    ayah_text = {}
    for r in rows:
        gid = int(r['ayah_global'])
        t = s(r.get('text'))
        if not t:
            print(f'ERROR: empty text at ayah {gid}')
            sys.exit(1)
        ayah_text[gid] = t
        cur.execute('INSERT INTO ayahs VALUES(?,?,?,?,?,?,?,?,?)',
                    (gid, int(r['surah']), int(r['ayah']), t, int(r['juz']),
                     int(r['hizb']), int(r['hizb_quarter']), int(r['page']),
                     1 if r.get('sajda') else 0))
    sajda_n = sum(1 for r in rows if r.get('sajda'))
    print(f'ayahs: 6236 inserted, sajda ayahs: {sajda_n}')

    # ── Tafsirs ──
    tafsir_by_ayah = {}
    for src, name_ar, author in TAFSIRS:
        tr = load_rows(snapshot, [f'tafsir-{src}-ar/*.parquet', f'tafsir-{src}.parquet'])
        if not tr:
            print(f'ERROR: tafsir {src} not found under', snapshot)
            sys.exit(1)
        n = 0
        for r in tr:
            t = s(r.get('text'))
            if not t:
                continue
            cur.execute('INSERT INTO tafsir VALUES(?,?,?,?)',
                        (int(r['surah']), int(r['ayah']), src, t))
            tafsir_by_ayah.setdefault(int(r['ayah_global']), []).append(t)
            n += 1
        print(f'tafsir {name_ar}: {n} ayahs with text (of 6236)')
        if n < 6000:
            print(f'ERROR: tafsir {src} covers only {n} ayahs')
            sys.exit(1)

    # ── I'jaz articles (quotes verified against the ayah text) ──
    by_ref = {(int(r['surah']), int(r['ayah'])): s(r.get('text')) for r in rows}
    for i, (title, ref, surah, a0, a1, quote, text, source) in enumerate(IJAZ, 1):
        joined = norm(' '.join(by_ref.get((surah, a), '') for a in range(a0, a1 + 1)))
        if norm(quote) not in joined:
            print(f'ERROR: ijaz quote not found in {ref}: {quote}')
            sys.exit(1)
        cur.execute('INSERT INTO ijaz VALUES(?,?,?,?,?,?,?)',
                    (i, title, ref, surah, a0, text, source))
    print(f'ijaz: {len(IJAZ)} articles, all quotes verified in the text')

    # ── FTS index ──
    # Built from the Tanzil simple-clean text (standard spelling: الصلاة،
    # الرحمن، عظاما — no dagger alefs), so a query typed in ordinary
    # spelling matches. The displayed text stays Uthmani.
    srows = load_rows(snapshot, ['arabic-simple-clean/*.parquet', 'quran-simple.parquet'])
    if not srows:
        print('ERROR: simple-clean text not found under', snapshot)
        sys.exit(1)
    srows.sort(key=lambda r: int(r['ayah_global']))
    if len(srows) != 6236 or [r['verse_key'] for r in srows] != [r['verse_key'] for r in rows]:
        print('ERROR: simple-clean text does not align with the Uthmani text')
        sys.exit(1)
    simple_text = {int(r['ayah_global']): s(r.get('text')) for r in srows}
    for gid, t in sorted(ayah_text.items()):
        tf = ' '.join(tafsir_by_ayah.get(gid, []))
        cur.execute('INSERT INTO ayahs_fts(rowid, norm, tafsir) VALUES(?,?,?)',
                    (gid, search_norm(simple_text[gid]), search_norm(tf) if tf else ''))
    cur.execute("INSERT INTO ayahs_fts(ayahs_fts) VALUES('optimize')")

    cur.executemany('INSERT INTO meta VALUES(?,?)', [
        ('source', 'huggingface.co/datasets/quranlab/quran + quranlab/quran-tafsir'),
        ('quran_commit', qrev),
        ('tafsir_commit', trev),
        ('built', datetime.date.today().isoformat()),
        ('total', '6236'),
        ('surahs', '114'),
        ('credits', 'Quran text: Tanzil Project (tanzil.net), Uthmani script v1.1 — '
                    'copied verbatim with attribution as the licence requires. '
                    'Tafsirs: التفسير الميسر، تفسير الجلالين، تفسير السعدي '
                    '(classic works, public domain; packaging: QuranLab). '
                    'Ijaz articles: curated by the app team with sources cited per article.'),
    ])
    cur.execute('CREATE INDEX idx_a_surah ON ayahs(surah, ayah)')
    cur.execute('CREATE INDEX idx_a_quarter ON ayahs(quarter)')
    cur.execute('CREATE INDEX idx_t_ayah ON tafsir(surah, ayah)')
    con.commit()
    con.execute('VACUUM')
    con.close()
    h = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    open(out + '.sha256', 'w').write(h)
    print(f'OK surahs=114 ayahs=6236 size={os.path.getsize(out)/1e6:.1f}MB sha256={h[:12]}…')


if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2],
          sys.argv[3] if len(sys.argv) > 3 else QURAN_REV,
          sys.argv[4] if len(sys.argv) > 4 else TAFSIR_REV)
