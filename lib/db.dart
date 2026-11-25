import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

/// Must stay identical to norm() in tools/build_db.py.
/// Uthmani spelling: the dagger alef (U+0670) is a letter, not a mark:
/// "وٰ" is pronounced as a long "a" (الصلوة = الصلاة), a bare dagger alef
/// is an alef (عِظَٰمًا = عظامًا), but after ى it is only a length mark
/// (أَوۡحَىٰ = أوحى). The FTS index is built from the simple-clean text
/// (standard spelling), so these rules matter for queries typed in
/// Uthmani spelling and for the I'jaz quote check.
String normalizeAr(String s) {
  s = s.replaceAll('\u0648\u0670', 'ا').replaceAll('\u0649\u0670', 'ى').replaceAll('\u0670', 'ا');
  s = s.replaceAll(RegExp(r'[\u064B-\u065F\u06D6-\u06ED\u0640]'), '');
  s = s.replaceAll(RegExp(r'[إأآٱ]'), 'ا').replaceAll('ى', 'ي').replaceAll('ة', 'ه');
  s = s.replaceAll(RegExp(r'[^\u0621-\u064A\u0660-\u0669a-zA-Z0-9\s]'), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Builds an FTS5 MATCH expression: every query term matches with or without
/// the "ال" prefix, so «النيات» also finds «بالنيات» and «نيات».
/// Terms are ANDed (explicit AND: FTS5 rejects implicit AND between two
/// parenthesised groups); variants of one term are ORed.
String _searchExpr(String normed) {
  final groups = <String>[];
  for (final t in normed.split(' ')) {
    if (t.isEmpty) continue;
    final variants = <String>{t};
    if (t.startsWith('ال') && t.length > 4) {
      variants.add(t.substring(2));
    } else {
      variants.add('ال$t');
    }
    groups.add('(${variants.map((v) => '"$v"*').join(' OR ')})');
  }
  return groups.join(' AND ');
}

class Surah {
  final int id, ayahCount, juzStart;
  final String nameAr, nameShort, nameEn, revelation;
  const Surah(this.id, this.nameAr, this.nameShort, this.nameEn, this.revelation,
      this.ayahCount, this.juzStart);
}

class Ayah {
  final int id, surah, ayah, juz, hizb, quarter, page;
  final bool sajda;
  final String text, surahName;
  const Ayah(this.id, this.surah, this.ayah, this.text, this.juz, this.hizb,
      this.quarter, this.page, this.sajda, this.surahName);
}

class Ijaz {
  final int id, surah, ayah;
  final String title, ayahRef, text, source;
  const Ijaz(this.id, this.title, this.ayahRef, this.surah, this.ayah, this.text, this.source);
}

/// A reciter whose per-ayah MP3s are served by EveryAyah (folder verified
/// 2026-11-23 in https://everyayah.com/data/recitations.js).
/// [folder] is the EveryAyah subfolder; [fallbackEdition] is the
/// cdn.islamic.network edition used when EveryAyah fails.
class Reciter {
  final String id, nameAr, folder;
  final String? fallbackEdition;
  const Reciter(this.id, this.nameAr, this.folder, [this.fallbackEdition]);
}

const reciters = [
  Reciter('afasy', 'مشاري راشد العفاسي', 'Alafasy_64kbps', 'ar.alafasy'),
  Reciter('husary', 'محمود خليل الحصري', 'Husary_64kbps', 'ar.husary'),
  Reciter('basit', 'عبد الباسط عبد الصمد', 'Abdul_Basit_Murattal_64kbps', 'ar.abdulbasitmurattal'),
  Reciter('minshawi', 'محمد صديق المنشاوي', 'Minshawy_Murattal_128kbps', 'ar.minshawi'),
  Reciter('sudais', 'عبد الرحمن السديس', 'Abdurrahmaan_As-Sudais_64kbps', 'ar.abdulrahmanalsudais'),
  Reciter('muaiqly', 'ماهر المعيقلي', 'Maher_AlMuaiqly_64kbps', 'ar.maheralmuaiqly'),
  Reciter('shuraym', 'سعود الشريم', 'Saood_ash-Shuraym_64kbps', 'ar.saoodashshuraym'),
];

/// Offline tafsirs bundled in the app.
const offlineTafsirs = [
  ('muyassar', 'التفسير الميسر'),
  ('jalalayn', 'تفسير الجلالين'),
  ('saadi', 'تفسير السعدي'),
];

/// Big tafsirs fetched per ayah from Quran.com API v4 (online only, cached).
/// IDs verified 2026-11-23 against https://api.quran.com/api/v4/resources/tafsirs.
const onlineTafsirs = [
  (14, 'تفسير ابن كثير'),
  (15, 'تفسير الطبري'),
  (90, 'تفسير القرطبي'),
];

const _cols =
    'a.id AS id, a.surah AS surah, a.ayah AS ayah, a.text AS text, a.juz AS juz, '
    'a.hizb AS hizb, a.quarter AS quarter, a.page AS page, a.sajda AS sajda, '
    's.name_short AS sname';
const _join = 'JOIN surahs s ON s.id=a.surah';

Ayah _a(Row r) => Ayah(
      r['id'] as int,
      r['surah'] as int,
      r['ayah'] as int,
      r['text'] as String,
      r['juz'] as int,
      r['hizb'] as int,
      r['quarter'] as int,
      r['page'] as int,
      (r['sajda'] as int) == 1,
      r['sname'] as String,
    );

List<Ayah> _searchSync(String p, String q) {
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    final n = normalizeAr(q);
    if (n.isEmpty) return [];
    ResultSet rs;
    final ref = RegExp(r'^(\d{1,3})\s*:\s*(\d{1,3})$').firstMatch(n);
    if (ref != null) {
      // "2:255" -> the exact ayah
      rs = db.select('SELECT $_cols FROM ayahs a $_join WHERE a.surah=? AND a.ayah=?',
          [int.parse(ref.group(1)!), int.parse(ref.group(2)!)]);
    } else {
      final expr = _searchExpr(n);
      rs = db.select(
          'SELECT $_cols FROM ayahs_fts JOIN ayahs a ON a.id=ayahs_fts.rowid $_join '
          'WHERE ayahs_fts MATCH ? ORDER BY rank LIMIT 50',
          [expr]);
    }
    return rs.map(_a).toList();
  } finally {
    db.dispose();
  }
}

Future<String> _sha(String p) async => (await sha256.bind(File(p).openRead()).first).toString();

String _quick(String p) {
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    return db.select('PRAGMA quick_check').first.values.first.toString();
  } finally {
    db.dispose();
  }
}

final _stop = {
  'في', 'من', 'ما', 'هو', 'هي', 'هل', 'عن', 'على', 'الى', 'إلى', 'ان', 'أن', 'انه', 'هذا', 'هذه', 'ذلك', 'كيف', 'لماذا',
  'متى', 'اين', 'أين', 'ماذا', 'الذي', 'التي', 'كان', 'يكون', 'اية', 'آية', 'ايات', 'آيات', 'الاية', 'الآية',
  'سورة', 'سور', 'السورة', 'تفسير', 'معنى', 'فوائد', 'الفرق', 'بين', 'و', 'او', 'أو', 'لي', 'هناك',
  'ورد', 'وردت', 'عنه', 'بها', 'به', 'له', 'لها',
  'اريد', 'اعطني', 'ابحث', 'ارني', 'اظهر', 'اعرض', 'هات', 'احضر', 'اذكر', 'اورد'
}.map(normalizeAr).toSet();

/// Topic words of a question: normalized words minus stopwords.
List<String> _topicWords(String q) =>
    normalizeAr(q).split(' ').where((t) => t.length > 1 && !_stop.contains(t)).toList();

List<Ayah> _askSync(String p, String q) {
  final words = _topicWords(q);
  if (words.isEmpty) return [];
  final variants = <String>{};
  for (final t in words) {
    variants.add(t);
    if (t.startsWith('ال') && t.length > 4) {
      variants.add(t.substring(2));
    } else {
      variants.add('ال$t');
    }
  }
  final expr = variants.map((t) => '"$t"*').join(' OR ');
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    final out = <Ayah>[];
    final seen = <int>{};
    // 1) A surah whose name contains the topic: its opening ayahs are
    // about the topic (e.g. «الرحمن» -> سورة الرحمن).
    final matched = <int>{};
    for (final s in db.select('SELECT id, name_short FROM surahs')) {
      final t = normalizeAr(s['name_short'] as String);
      for (final w in words) {
        final bare = w.startsWith('ال') && w.length > 2 ? w.substring(2) : w;
        if (t.contains(w) || t.contains(bare)) {
          matched.add(s['id'] as int);
          break;
        }
      }
    }
    if (matched.isNotEmpty) {
      final ph = List.filled(matched.length, '?').join(',');
      final crs = db.select(
          'SELECT $_cols FROM ayahs a $_join WHERE a.surah IN ($ph) ORDER BY a.surah, a.ayah LIMIT 3',
          matched.toList());
      for (final r in crs) {
        final a = _a(r);
        if (seen.add(a.id)) out.add(a);
      }
    }
    // 2) Full-text search fills the rest, best match first.
    final rs = db.select(
        'SELECT $_cols FROM ayahs_fts JOIN ayahs a ON a.id=ayahs_fts.rowid $_join '
        'WHERE ayahs_fts MATCH ? ORDER BY bm25(ayahs_fts, 1.0, 3.0) LIMIT 12',
        [expr]);
    for (final r in rs) {
      if (out.length >= 6) break;
      final a = _a(r);
      if (seen.add(a.id)) out.add(a);
    }
    return out;
  } finally {
    db.dispose();
  }
}

class TafsirHit {
  final Ayah ayah;
  final String source, sourceName, snippet;
  const TafsirHit(this.ayah, this.source, this.sourceName, this.snippet);
}

/// بحث نصي في التفاسير المدمجة (الميسر/الجلالين/السعدي) — مطابقة كلمات
/// في نص التفسير، مع إعادة الآية ونص التفسير المختصر.
/// كل كلمة تُطابَق بصيغتها الأصلية وبصيغتها المجرّدة (لأن ة/ه وى/ي
/// قد تختلفان بين إدخال المستخدم ونص التفسير).
List<TafsirHit> _searchTafsirSync(String p, String q) {
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    final words = q
        .split(' ')
        .map((w) => w
            .trim()
            .replaceAll(RegExp(r'[\u064B-\u065F\u06D6-\u06ED\u0640]'), ''))
        .where((w) => w.length > 1)
        .toList();
    if (words.isEmpty) return [];
    final clauses = <String>[];
    final args = <String>[];
    for (final w in words) {
      final variants = <String>{w, normalizeAr(w)};
      if (variants.length == 1) {
        clauses.add('t.text LIKE ?');
        args.add('%${variants.first}%');
      } else {
        clauses.add('(t.text LIKE ? OR t.text LIKE ?)');
        args.addAll(variants.map((v) => '%$v%'));
      }
    }
    final cond = clauses.join(' AND ');
    final rs = db.select(
        'SELECT $_cols, t.source AS source, t.text AS ttext FROM tafsir t '
        'JOIN ayahs a ON a.surah=t.surah AND a.ayah=t.ayah $_join '
        'WHERE $cond LIMIT 30',
        args);
    final names = {for (final (id, n) in offlineTafsirs) id: n};
    return [
      for (final r in rs)
        TafsirHit(
          _a(r),
          r['source'] as String,
          names[r['source'] as String] ?? (r['source'] as String),
          ((r['ttext'] as String).length > 200
                  ? (r['ttext'] as String).substring(0, 200)
                  : (r['ttext'] as String))
              .trim(),
        ),
    ];
  } finally {
    db.dispose();
  }
}

/// آيات مشابهة لآية معطاة: تشترك معها في ألفاظها (عبر فهرس FTS5)،
/// مرتبة بالأهمية، بلا الآية نفسها.
List<Ayah> _relatedSync(String p, Ayah a) {
  final db = sqlite3.open(p, mode: OpenMode.readOnly);
  try {
    final words = normalizeAr(a.text)
        .split(' ')
        .where((t) => t.length > 2 && !_stop.contains(t))
        .toSet()
        .toList()
      ..sort((x, y) => y.length.compareTo(x.length));
    if (words.isEmpty) return [];
    final variants = <String>{};
    for (final t in words.take(6)) {
      variants.add(t);
      if (t.startsWith('ال') && t.length > 4) {
        variants.add(t.substring(2));
      } else {
        variants.add('ال$t');
      }
    }
    final expr = variants.map((t) => '"$t"*').join(' OR ');
    final rs = db.select(
        'SELECT $_cols FROM ayahs_fts JOIN ayahs a ON a.id=ayahs_fts.rowid $_join '
        'WHERE ayahs_fts MATCH ? AND a.id != ? ORDER BY bm25(ayahs_fts, 1.0, 3.0) LIMIT 3',
        [expr, a.id]);
    return rs.map(_a).toList();
  } finally {
    db.dispose();
  }
}

String _stripHtml(String s) =>
    s.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&nbsp;', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

class Repo {
  Repo._();
  static final Repo i = Repo._();
  Database? _db;
  Database get db => _db!;

  Future<String> path() async {
    final d = await getApplicationSupportDirectory();
    return '${d.path}${Platform.pathSeparator}quran.db';
  }

  Future<String> _cachePath() async {
    final d = await getApplicationSupportDirectory();
    return '${d.path}${Platform.pathSeparator}cache.db';
  }

  Future<bool> isInstalled() async {
    final f = File(await path());
    if (!f.existsSync() || f.lengthSync() < 1000000) return false;
    try {
      final t = sqlite3.open(f.path, mode: OpenMode.readOnly);
      final n = t.select('SELECT COUNT(*) AS c FROM ayahs').first['c'] as int;
      t.dispose();
      return n == 6236;
    } catch (_) {
      return false;
    }
  }

  /// Copies the bundled library to local storage (atomic: temp file + rename).
  Future<void> install(void Function(double) onProgress) async {
    final data = await rootBundle.load('assets/quran.db');
    final p = await path();
    final tmp = File('$p.tmp');
    final sink = tmp.openWrite();
    final total = data.lengthInBytes;
    const chunk = 1 << 20;
    for (var o = 0; o < total; o += chunk) {
      final e = min(o + chunk, total);
      sink.add(data.buffer.asUint8List(data.offsetInBytes + o, e - o));
      await sink.flush();
      onProgress(e / total);
    }
    await sink.close();
    final expected = (await rootBundle.loadString('assets/quran.db.sha256')).trim();
    final tp = tmp.path;
    final got = await Isolate.run(() => _sha(tp));
    if (got != expected) {
      tmp.deleteSync();
      throw Exception('فشل التحقق من سلامة ملف المكتبة (SHA-256)');
    }
    await tmp.rename(p);
    if (!await isInstalled()) {
      File(p).deleteSync();
      throw Exception('ملف المكتبة تالف');
    }
    (await SharedPreferences.getInstance()).setString('lib_sha', expected);
  }

  /// true إذا كانت المكتبة المدمجة في هذا الإصدار تختلف عن المثبتة.
  Future<bool> needsUpdate() async {
    final expected = (await rootBundle.loadString('assets/quran.db.sha256')).trim();
    return (await SharedPreferences.getInstance()).getString('lib_sha') != expected;
  }

  /// يقارن بصمة SHA-256 للمكتبة المثبتة مع البصمة المدمجة في التطبيق.
  Future<bool> verifyHash() async {
    final p = await path();
    final expected = (await rootBundle.loadString('assets/quran.db.sha256')).trim();
    return await Isolate.run(() => _sha(p)) == expected;
  }

  Future<String> quickCheck() async {
    final p = await path();
    return Isolate.run(() => _quick(p));
  }

  Future<int> sizeBytes() async => File(await path()).lengthSync();

  Future<List<Ayah>> ask(String q) async {
    final p = await path();
    return Isolate.run(() => _askSync(p, q));
  }

  /// بحث في نصوص التفاسير المدمجة.
  Future<List<TafsirHit>> searchTafsir(String q) async {
    final p = await path();
    return Isolate.run(() => _searchTafsirSync(p, q));
  }

  /// آيات مشابهة لآية معطاة (ألفاظ وموضوع مشترك).
  Future<List<Ayah>> related(Ayah a) async {
    final p = await path();
    return Isolate.run(() => _relatedSync(p, a));
  }

  /// Topic words detected in a question (for the assistant's reply).
  static List<String> topic(String q) => _topicWords(q);

  Future<void> open() async {
    _db ??= sqlite3.open(await path(), mode: OpenMode.readOnly);
  }

  List<Surah> surahs() => db
      .select('SELECT id, name_ar, name_short, name_en, revelation, ayah_count, juz_start '
          'FROM surahs ORDER BY id')
      .map((r) => Surah(r['id'] as int, r['name_ar'] as String, r['name_short'] as String,
          r['name_en'] as String, r['revelation'] as String, r['ayah_count'] as int,
          r['juz_start'] as int))
      .toList();

  Surah? surah(int id) {
    final rs = db.select('SELECT id, name_ar, name_short, name_en, revelation, ayah_count, '
        'juz_start FROM surahs WHERE id=?', [id]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return Surah(r['id'] as int, r['name_ar'] as String, r['name_short'] as String,
        r['name_en'] as String, r['revelation'] as String, r['ayah_count'] as int,
        r['juz_start'] as int);
  }

  List<Ayah> ayahsOf(int surah) => db
      .select('SELECT $_cols FROM ayahs a $_join WHERE a.surah=? ORDER BY a.ayah', [surah])
      .map(_a)
      .toList();

  Ayah? ayahById(int id) {
    final rs = db.select('SELECT $_cols FROM ayahs a $_join WHERE a.id=?', [id]);
    return rs.isEmpty ? null : _a(rs.first);
  }

  Ayah? ayahByRef(int surah, int ayah) {
    final rs = db
        .select('SELECT $_cols FROM ayahs a $_join WHERE a.surah=? AND a.ayah=?', [surah, ayah]);
    return rs.isEmpty ? null : _a(rs.first);
  }

  int? neighbor(Ayah a, int delta) {
    final rs = db.select('SELECT id FROM ayahs WHERE id=?', [a.id + delta]);
    return rs.isEmpty ? null : rs.first['id'] as int;
  }

  /// All ayahs of one hizb quarter (1..240).
  List<Ayah> ayahsInQuarter(int quarter) => db
      .select('SELECT $_cols FROM ayahs a $_join WHERE a.quarter=? ORDER BY a.id', [quarter])
      .map(_a)
      .toList();

  /// Tafsir texts of one ayah, keyed by source id.
  Map<String, String> tafsirOf(int surah, int ayah) {
    final rs = db.select(
        'SELECT source, text FROM tafsir WHERE surah=? AND ayah=?', [surah, ayah]);
    return {for (final r in rs) r['source'] as String: r['text'] as String};
  }

  /// A big tafsir (Ibn Kathir / Tabari / Qurtubi) for one ayah, fetched from
  /// Quran.com API v4 when online and cached locally. Returns null offline
  /// or when the source has no text for the ayah. The caller must label
  /// the result as online (متصل بالإنترنت).
  Future<String?> onlineTafsir(int sourceId, int surah, int ayah) async {
    final cp = await _cachePath();
    final cdb = sqlite3.open(cp);
    try {
      cdb.execute('CREATE TABLE IF NOT EXISTS online_tafsir'
          '(surah INTEGER, ayah INTEGER, source INTEGER, text TEXT, fetched_at TEXT, '
          'PRIMARY KEY(surah, ayah, source))');
      final hit = cdb.select(
          'SELECT text FROM online_tafsir WHERE surah=? AND ayah=? AND source=?',
          [surah, ayah, sourceId]);
      if (hit.isNotEmpty) return hit.first['text'] as String;
    } finally {
      cdb.dispose();
    }
    try {
      final res = await http
          .get(Uri.parse('https://api.quran.com/api/v4/tafsirs/$sourceId/by_ayah/$surah:$ayah'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final tafsir = body['tafsir'] as Map<String, dynamic>?;
      final raw = tafsir?['text'] as String?;
      if (raw == null || raw.trim().isEmpty) return null;
      final text = _stripHtml(raw);
      if (text.isEmpty) return null;
      final cdb2 = sqlite3.open(cp);
      try {
        cdb2.execute(
            'INSERT OR REPLACE INTO online_tafsir VALUES(?,?,?,?,?)',
            [surah, ayah, sourceId, text, DateTime.now().toIso8601String()]);
      } finally {
        cdb2.dispose();
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  Ayah? daily() {
    const cond = 'length(text) BETWEEN 40 AND 400';
    final cnt = db.select('SELECT COUNT(*) AS c FROM ayahs WHERE $cond').first['c'] as int;
    if (cnt == 0) return null;
    final now = DateTime.now();
    final day = now.difference(DateTime(now.year, 1, 1)).inDays + now.year * 7;
    final rs = db.select(
        'SELECT $_cols FROM ayahs a $_join WHERE a.id = '
        '(SELECT id FROM ayahs WHERE $cond ORDER BY id LIMIT 1 OFFSET ?)',
        [(day * 97) % cnt]);
    return rs.isEmpty ? null : _a(rs.first);
  }

  List<Ijaz> ijazList() => db
      .select('SELECT id, title, ayah_ref, surah, ayah, text, source FROM ijaz ORDER BY id')
      .map((r) => Ijaz(r['id'] as int, r['title'] as String, r['ayah_ref'] as String,
          r['surah'] as int, r['ayah'] as int, r['text'] as String, r['source'] as String))
      .toList();

  Ijaz? ijazById(int id) {
    final rs = db.select(
        'SELECT id, title, ayah_ref, surah, ayah, text, source FROM ijaz WHERE id=?', [id]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return Ijaz(r['id'] as int, r['title'] as String, r['ayah_ref'] as String,
        r['surah'] as int, r['ayah'] as int, r['text'] as String, r['source'] as String);
  }

  Map<String, String> meta() =>
      {for (final r in db.select('SELECT key,value FROM meta')) r['key'] as String: r['value'] as String};

  Future<List<Ayah>> search(String q) async {
    final p = await path();
    return Isolate.run(() => _searchSync(p, q));
  }
}
