#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_migration.py — اختبار محلي لمنطق ترحيل بيانات مستخدم Tilawa
(SharedPreferences JSON  →  SQLite user.db) + النسخ الاحتياطي والاستعادة.

طبيعة هذا السكربت:
- مرآة Python حرفية للتصميم المقترح في MIGRATION_PLAN_2026-11-25.md
  (نفس DDL، نفس ترتيب الخطوات، نفس قواعد التحقق). هو ليس كود Dart نفسه:
  لا Flutter/Dart في هذه البيئة، والاختبار النهائي للكود الحقيقي يكون
  عبر `flutter test` على جهاز/CI.
- يعمل حصرياً على بيانات عينة اصطناعية في مجلد مؤقت (/tmp/tilawa_mig_test).
  لا يقرأ ولا يكتب ولا يمسّ أي ملف في ~/workspace/tilawa ولا أي DB حقيقية.
- مكتبة قياسية فقط (sqlite3 / json / hashlib / shutil).

ما يختبره:
  1. migrate_0_to_1: نقل favs/history/tags/notes/khatmah_q/warsh_ready/
     fav_reciters + lib_sha من prefs إلى user.db مع تحقق سجلاً بسجل.
  2. النسخة الاحتياطية من JSON القديم قبل أي حذف + إعادة قراءتها ومطابقتها.
  3. عزل السجلات التالفة (JSON معطوب، معرّف آية غير موجود، قيمة غير رقمية)
     في الحجر الصحي دون إيقاف الترحيل.
  4. تصدير/استيراد JSON يملكه المستخدم (ذهاباً وإياباً) مع تطابق كامل.
  5. الاستبدال الذري لمكتبة quran.db (ملف مؤقت + تحقق SHA + إعادة تسمية)،
     وحالة فشل SHA (الملف القديم يبقى سليماً).
  6. تعطل في منتصف الترحيل (بعد COMMIT وقبل تنظيف prefs): إعادة التشغيل
     خاملة (idempotent) — بلا تكرار وبلا فقد.
  7. الحفاظ على ترتيب القوائم (favs بترتيب الإضافة، history الأحدث أولاً).

الاستخدام:  python3 tools/test_migration.py
الخروج: 0 عند نجاح كل الفحوص، 1 عند أي فشل.
"""

import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))


# ── مخطط quran.db الحقيقي (من tools/build_db.py:205-214, 331-333) ──────────
QURAN_SCHEMA = """
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
CREATE INDEX idx_a_surah ON ayahs(surah, ayah);
CREATE INDEX idx_a_quarter ON ayahs(quarter);
CREATE INDEX idx_t_ayah ON tafsir(surah, ayah);
"""

# ── مخطط user.db المقترح (من MIGRATION_PLAN_2026-11-25.md §2) ─────────────
USER_SCHEMA = """
CREATE TABLE user_meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE favorites(
  ayah_id INTEGER PRIMARY KEY, position INTEGER NOT NULL, created_at TEXT NOT NULL);
CREATE INDEX idx_fav_position ON favorites(position);
CREATE TABLE notes(
  ayah_id INTEGER PRIMARY KEY, body TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE tags(
  ayah_id INTEGER PRIMARY KEY, tag TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE history(
  ayah_id INTEGER PRIMARY KEY, position INTEGER NOT NULL, visited_at TEXT NOT NULL);
CREATE INDEX idx_hist_position ON history(position);
CREATE TABLE khatmah(
  id INTEGER PRIMARY KEY CHECK(id=1),
  quarter INTEGER NOT NULL CHECK(quarter BETWEEN 1 AND 241),
  updated_at TEXT NOT NULL);
CREATE TABLE fav_reciters(reciter_id TEXT PRIMARY KEY, position INTEGER NOT NULL);
CREATE TABLE flags(key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

MIGRATED_KEYS = ["favs", "history", "tags", "notes", "khatmah_q",
                 "warsh_ready", "fav_reciters", "lib_sha"]
SETTINGS_KEYS = ["mode", "font", "amiri", "reciter", "reminder",
                 "rem_hour", "rem_min", "wird_q"]


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def build_sample_quran_db(path):
    """quran.db عينة بالمخطط الحقيقي: سورتان، آيات 1..300 (تكفي للتحقق)."""
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.executescript(QURAN_SCHEMA)
    con.execute("INSERT INTO surahs VALUES(1,'الفاتحة','الفاتحة','Al-Fatiha','مكية',7,1)")
    con.execute("INSERT INTO surahs VALUES(2,'البقرة','البقرة','Al-Baqara','مدنية',286,1)")
    for gid in range(1, 301):
        surah = 1 if gid <= 7 else 2
        ayah = gid if surah == 1 else gid - 7
        con.execute("INSERT INTO ayahs VALUES(?,?,?,?,?,?,?,?,?)",
                    (gid, surah, ayah, f"نص آية عينة {gid}", 1, 1, 1, 1, 0))
        con.execute("INSERT INTO ayahs_fts(rowid, norm, tafsir) VALUES(?,?,?)",
                    (gid, f"نص ايه عينه {gid}", ""))
    con.executemany("INSERT INTO meta VALUES(?,?)", [
        ("source", "sample-only"), ("total", "6236"), ("surahs", "114")])
    con.commit()
    con.close()


def sample_prefs():
    """قيم SharedPreferences كما يخزنها التطبيق فعلاً (main.dart:126-142)."""
    return {
        # بيانات مستخدم (ستُرحَّل):
        "favs": ["2", "255", "7", "2", "99999"],          # مكرر + معرّف غير موجود
        "history": ["255", "2", "7", "88888", "abc"],     # غير موجود + غير رقمي
        "tags": '{"2": "تجويد", "7": "حفظ", "99999": "تالف"}',
        "notes": '{"2": "ملاحظة أولى", "255": "ملاحظة ثانية"}',
        "khatmah_q": 42,
        "warsh_ready": True,
        "fav_reciters": ["afasy", "husary"],
        "lib_sha": "a" * 64,
        # إعدادات (تبقى في prefs ولا تُرحَّل):
        "mode": 0, "font": 26.0, "amiri": True, "reciter": "afasy",
        "reminder": False, "rem_hour": 7, "rem_min": 0, "wird_q": 1,
    }


def sample_prefs_corrupt_tags():
    p = sample_prefs()
    p["tags"] = "{json معطوب"
    return p


# ── منطق الترحيل (مرآة للتصميم المقترح في Dart) ────────────────────────────

def backup_prefs(prefs, backup_path):
    """نسخة احتياطية من JSON القديم قبل أي حذف، مع إعادة قراءة ومطابقة."""
    raw = {k: prefs[k] for k in MIGRATED_KEYS if k in prefs}
    payload = {"format": "tilawa-prefs-backup", "format_version": 1,
               "raw": raw, "sha256": None}
    blob = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
    payload["sha256"] = hashlib.sha256(blob).hexdigest()
    with open(backup_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    # إعادة قراءة والتحقق:
    with open(backup_path, encoding="utf-8") as f:
        back = json.load(f)
    assert back["raw"] == raw, "backup read-back mismatch"
    return back


def migrate_0_to_1(prefs, quran_db, user_db, backup_path, now="2026-11-25T05:30:00+03:00",
                   crash_after_commit=False):
    """ترحيل الإرث (v0: لا user.db) إلى v1. يعيد تقريراً. خامل عند إعادة التشغيل."""
    report = {"quarantine": [], "inserted": {}, "backup": backup_path}
    if os.path.exists(user_db):
        con = sqlite3.connect(user_db)
        row = con.execute(
            "SELECT value FROM user_meta WHERE key='schema_version'").fetchone()
        con.close()
        if row and row[0] == "1":
            # إعادة تشغيل بعد تعطل سابق: تحقق ثم أكمل تنظيف prefs فقط.
            report["already_migrated"] = True
            return _finish_cleanup(prefs, report)
        os.remove(user_db)  # ملف ناقص بلا schema_version: أعد من الصفر.

    backup_prefs(prefs, backup_path)
    qcon = sqlite3.connect(f"file:{quran_db}?mode=ro", uri=True)
    valid_ids = {r[0] for r in qcon.execute("SELECT id FROM ayahs")}
    qcon.close()

    def parse_id_list(key):
        out, seen = [], set()
        for s in prefs.get(key) or []:
            try:
                i = int(s)
            except (TypeError, ValueError):
                report["quarantine"].append((key, s, "not-an-int"))
                continue
            if i in seen:
                report["quarantine"].append((key, s, "duplicate"))
                continue
            seen.add(i)
            if i not in valid_ids:
                report["quarantine"].append((key, s, "ayah-not-in-quran-db"))
                continue
            out.append(i)
        return out

    def parse_id_map(key):
        out = {}
        try:
            m = json.loads(prefs.get(key) or "{}")
        except json.JSONDecodeError:
            report["quarantine"].append((key, prefs.get(key), "corrupt-json"))
            return out
        for k, v in m.items():
            try:
                i = int(k)
            except (TypeError, ValueError):
                report["quarantine"].append((key, k, "not-an-int"))
                continue
            if i not in valid_ids:
                report["quarantine"].append((key, k, "ayah-not-in-quran-db"))
                continue
            out[i] = v
        return out

    favs = parse_id_list("favs")
    history = parse_id_list("history")
    tags = parse_id_map("tags")
    notes = parse_id_map("notes")
    khatmah_q = prefs.get("khatmah_q", 1)
    if not isinstance(khatmah_q, int) or not 1 <= khatmah_q <= 241:
        report["quarantine"].append(("khatmah_q", khatmah_q, "out-of-range"))
        khatmah_q = 1
    fav_reciters = [r for r in (prefs.get("fav_reciters") or []) if isinstance(r, str)]
    warsh_ready = bool(prefs.get("warsh_ready", False))
    lib_sha = prefs.get("lib_sha", "")

    if os.path.exists(user_db):
        os.remove(user_db)
    con = sqlite3.connect(user_db)
    try:
        con.execute("BEGIN IMMEDIATE")
        con.executescript(USER_SCHEMA)
        for pos, aid in enumerate(favs):
            con.execute("INSERT INTO favorites VALUES(?,?,?)", (aid, pos, now))
        for aid, body in notes.items():
            con.execute("INSERT INTO notes VALUES(?,?,?)", (aid, body, now))
        for aid, tag in tags.items():
            con.execute("INSERT INTO tags VALUES(?,?,?)", (aid, tag, now))
        for pos, aid in enumerate(history):
            con.execute("INSERT INTO history VALUES(?,?,?)", (aid, pos, now))
        con.execute("INSERT INTO khatmah VALUES(1,?,?)", (khatmah_q, now))
        for pos, rid in enumerate(fav_reciters):
            con.execute("INSERT INTO fav_reciters VALUES(?,?)", (rid, pos))
        con.execute("INSERT INTO flags VALUES('warsh_ready',?)",
                    ("1" if warsh_ready else "0",))
        con.executemany("INSERT INTO user_meta VALUES(?,?)", [
            ("schema_version", "1"),
            ("lib_sha", lib_sha),
            ("migrated_from_prefs", "1"),
            ("migrated_at", now),
            ("prefs_backup", os.path.basename(backup_path)),
        ])
        con.commit()
    except Exception:
        con.rollback()
        con.close()
        os.remove(user_db)
        raise
    con.close()

    # تحقق سجلاً بسجل قبل أي حذف من prefs:
    _verify_user_db(user_db, favs, history, tags, notes, khatmah_q,
                    fav_reciters, warsh_ready, lib_sha)
    report["inserted"] = {"favorites": len(favs), "history": len(history),
                          "tags": len(tags), "notes": len(notes),
                          "fav_reciters": len(fav_reciters),
                          "khatmah_q": khatmah_q}
    if crash_after_commit:
        raise RuntimeError("SIMULATED CRASH after COMMIT, before prefs cleanup")
    return _finish_cleanup(prefs, report)


def _finish_cleanup(prefs, report):
    for k in MIGRATED_KEYS:
        prefs.pop(k, None)
    report["prefs_cleaned"] = True
    return report


def _verify_user_db(user_db, favs, history, tags, notes, khatmah_q,
                    fav_reciters, warsh_ready, lib_sha):
    con = sqlite3.connect(f"file:{user_db}?mode=ro", uri=True)
    assert [r[0] for r in con.execute(
        "SELECT ayah_id FROM favorites ORDER BY position")] == favs
    assert [r[0] for r in con.execute(
        "SELECT ayah_id FROM history ORDER BY position")] == history
    assert dict(con.execute("SELECT ayah_id, tag FROM tags")) == tags
    assert dict(con.execute("SELECT ayah_id, body FROM notes")) == notes
    assert con.execute("SELECT quarter FROM khatmah WHERE id=1").fetchone()[0] == khatmah_q
    assert [r[0] for r in con.execute(
        "SELECT reciter_id FROM fav_reciters ORDER BY position")] == fav_reciters
    assert con.execute("SELECT value FROM flags WHERE key='warsh_ready'").fetchone()[0] == (
        "1" if warsh_ready else "0")
    assert con.execute("SELECT value FROM user_meta WHERE key='schema_version'").fetchone()[0] == "1"
    assert con.execute("SELECT value FROM user_meta WHERE key='lib_sha'").fetchone()[0] == lib_sha
    assert con.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    con.close()


def dump_user_db(user_db):
    con = sqlite3.connect(f"file:{user_db}?mode=ro", uri=True)
    d = {
        "favorites": [r[0] for r in con.execute("SELECT ayah_id FROM favorites ORDER BY position")],
        "history": [r[0] for r in con.execute("SELECT ayah_id FROM history ORDER BY position")],
        "tags": dict(con.execute("SELECT ayah_id, tag FROM tags")),
        "notes": dict(con.execute("SELECT ayah_id, body FROM notes")),
        "khatmah_q": con.execute("SELECT quarter FROM khatmah WHERE id=1").fetchone()[0],
        "fav_reciters": [r[0] for r in con.execute("SELECT reciter_id FROM fav_reciters ORDER BY position")],
        "warsh_ready": con.execute("SELECT value FROM flags WHERE key='warsh_ready'").fetchone()[0] == "1",
    }
    con.close()
    return d


def export_user_data(user_db):
    d = dump_user_db(user_db)
    return {"format": "tilawa-user-export", "format_version": 1,
            "exported_at": "2026-11-25T05:30:00+03:00", "data": d}


def import_user_data(user_db, payload, quran_db, now="2026-11-25T05:30:00+03:00"):
    """استيراد مع تحقق مسبق + نسخة احتياطية تلقائية قبل الاستبدال + كتابة ذرية."""
    assert payload.get("format") == "tilawa-user-export" and payload.get("format_version") == 1
    d = payload["data"]
    qcon = sqlite3.connect(f"file:{quran_db}?mode=ro", uri=True)
    valid_ids = {r[0] for r in qcon.execute("SELECT id FROM ayahs")}
    qcon.close()
    for aid in d["favorites"] + d["history"] + list(d["tags"]) + list(d["notes"]):
        assert aid in valid_ids, f"ayah {aid} not in quran.db"
    assert 1 <= d["khatmah_q"] <= 241
    tmp = user_db + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    con = sqlite3.connect(tmp)
    con.executescript(USER_SCHEMA)
    for pos, aid in enumerate(d["favorites"]):
        con.execute("INSERT INTO favorites VALUES(?,?,?)", (aid, pos, now))
    for aid, body in d["notes"].items():
        con.execute("INSERT INTO notes VALUES(?,?,?)", (aid, body, now))
    for aid, tag in d["tags"].items():
        con.execute("INSERT INTO tags VALUES(?,?,?)", (aid, tag, now))
    for pos, aid in enumerate(d["history"]):
        con.execute("INSERT INTO history VALUES(?,?,?)", (aid, pos, now))
    con.execute("INSERT INTO khatmah VALUES(1,?,?)", (d["khatmah_q"], now))
    for pos, rid in enumerate(d["fav_reciters"]):
        con.execute("INSERT INTO fav_reciters VALUES(?,?)", (rid, pos))
    con.execute("INSERT INTO flags VALUES('warsh_ready',?)",
                ("1" if d["warsh_ready"] else "0",))
    con.execute("INSERT INTO user_meta VALUES('schema_version','1')")
    con.execute("INSERT INTO user_meta VALUES('lib_sha','')")
    con.commit()
    assert con.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    con.close()
    os.replace(tmp, user_db)  # ذري: إعادة تسمية فقط بعد التحقق


def atomic_replace_library(installed, new_bytes, expected_sha):
    """مرآة لـ Repo.install() في db.dart: ملف مؤقت + تحقق SHA + إعادة تسمية."""
    tmp = installed + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new_bytes)
    got = sha256_file(tmp)
    if got != expected_sha:
        os.remove(tmp)
        raise ValueError("SHA-256 mismatch")
    os.replace(tmp, installed)
    return got


# ── تنفيذ الفحوص ────────────────────────────────────────────────────────────

def main():
    tmp = tempfile.mkdtemp(prefix="tilawa_mig_test_")
    print(f"workdir (synthetic data only): {tmp}")
    quran_db = os.path.join(tmp, "quran.db")
    user_db = os.path.join(tmp, "user.db")
    backup_path = os.path.join(tmp, "prefs_backup_20261125_053000.json")
    build_sample_quran_db(quran_db)

    print("\n== 1. migrate_0_to_1: نقل + تحقق سجلاً بسجل ==")
    prefs = sample_prefs()
    rep = migrate_0_to_1(prefs, quran_db, user_db, backup_path)
    check("favorites = 3 (مكرر + غير موجود عُزلا)", rep["inserted"]["favorites"] == 3,
          str(rep["inserted"]))
    check("history = 3 (غير موجود + غير رقمي عُزلا)", rep["inserted"]["history"] == 3)
    check("tags = 2, notes = 2", rep["inserted"]["tags"] == 2 and rep["inserted"]["notes"] == 2)
    check("khatmah_q = 42 محفوظ", rep["inserted"]["khatmah_q"] == 42)
    check("fav_reciters = 2", rep["inserted"]["fav_reciters"] == 2)
    check("الحجر الصحي = 5 سجلات", len(rep["quarantine"]) == 5, str(rep["quarantine"]))
    check("ترتيب favs محفوظ [2,255,7]",
          dump_user_db(user_db)["favorites"] == [2, 255, 7])
    check("ترتيب history محفوظ [255,2,7] (الأحدث أولاً)",
          dump_user_db(user_db)["history"] == [255, 2, 7])
    check("وسم/ملاحظة الآية 2 سليمة",
          dump_user_db(user_db)["tags"].get(2) == "تجويد"
          and dump_user_db(user_db)["notes"].get(2) == "ملاحظة أولى")

    print("\n== 2. النسخة الاحتياطية قبل الحذف ==")
    check("ملف النسخة موجود", os.path.exists(backup_path))
    with open(backup_path, encoding="utf-8") as f:
        back = json.load(f)
    check("النسخة تحتوي كل مفاتيح prefs الأصلية",
          set(back["raw"]) == set(MIGRATED_KEYS))
    check("النسخة تحتفظ بالقيم الخام حتى التالفة",
          back["raw"]["favs"] == ["2", "255", "7", "2", "99999"])
    check("مفاتيح prefs المُرحَّلة حُذفت بعد التحقق",
          not any(k in prefs for k in MIGRATED_KEYS))
    check("مفاتيح الإعدادات لم تُمسّ",
          all(k in prefs for k in SETTINGS_KEYS) and prefs["reciter"] == "afasy")

    print("\n== 3. JSON معطوب في tags: يُعزل ولا يوقف الترحيل ==")
    user_db2 = os.path.join(tmp, "user2.db")
    prefs2 = sample_prefs_corrupt_tags()
    rep2 = migrate_0_to_1(prefs2, quran_db, user_db2,
                          os.path.join(tmp, "prefs_backup_corrupt.json"))
    check("الترحيل أكمل رغم JSON المعطوب",
          rep2["inserted"]["favorites"] == 3 and rep2["inserted"]["notes"] == 2)
    check("tags كلها في الحجر (0 مدخلة)",
          rep2["inserted"]["tags"] == 0
          and any(q[0] == "tags" and q[2] == "corrupt-json" for q in rep2["quarantine"]))
    check("النسخة الاحتياطية حفظت السلسلة المعطوبة حرفياً",
          json.load(open(os.path.join(tmp, "prefs_backup_corrupt.json"),
                         encoding="utf-8"))["raw"]["tags"] == "{json معطوب")

    print("\n== 4. تصدير/استيراد JSON يملكه المستخدم ==")
    payload = export_user_data(user_db)
    before = dump_user_db(user_db)
    os.remove(user_db)
    import_user_data(user_db, payload, quran_db)
    after = dump_user_db(user_db)
    check("الاستيراد يعيد كل السجلات مطابقةً", before == after, str(after))
    check("لا ملف .tmp متبقٍ بعد الاستيراد", not os.path.exists(user_db + ".tmp"))

    print("\n== 5. الاستبدال الذري للمكتبة (quran.db) ==")
    installed = os.path.join(tmp, "installed_quran.db")
    shutil.copyfile(quran_db, installed)
    old_sha = sha256_file(installed)
    new_bytes = b"NEW-LIBRARY-BYTES" * 1000
    new_sha = hashlib.sha256(new_bytes).hexdigest()
    atomic_replace_library(installed, new_bytes, new_sha)
    check("استبدال ناجح: SHA الجديد مطابق",
          sha256_file(installed) == new_sha and not os.path.exists(installed + ".tmp"))
    try:
        atomic_replace_library(installed, b"tampered", "0" * 64)
        check("SHA خاطئ يرفض الاستبدال", False)
    except ValueError:
        check("SHA خاطئ يرفض الاستبدال", True)
    check("الملف المثبت لم يتغير بعد فشل SHA",
          sha256_file(installed) == new_sha and not os.path.exists(installed + ".tmp"))

    print("\n== 6. تعطل بعد COMMIT وقبل تنظيف prefs: إعادة تشغيل خاملة ==")
    user_db3 = os.path.join(tmp, "user3.db")
    prefs3 = sample_prefs()
    try:
        migrate_0_to_1(prefs3, quran_db, user_db3,
                       os.path.join(tmp, "prefs_backup_crash.json"),
                       crash_after_commit=True)
        check("محاكاة التعطل رُفعت فعلاً", False)
    except RuntimeError:
        check("محاكاة التعطل رُفعت فعلاً", True)
    check("بعد التعطل: user.db مكتمل v1", dump_user_db(user_db3)["favorites"] == [2, 255, 7])
    check("بعد التعطل: prefs ما زالت سليمة (لم يُحذف شيء)",
          prefs3.get("favs") == ["2", "255", "7", "2", "99999"])
    rep3 = migrate_0_to_1(prefs3, quran_db, user_db3,
                          os.path.join(tmp, "prefs_backup_crash.json"))
    check("إعادة التشغيل اكتشفت الترحيل وأكملت التنظيف",
          rep3.get("already_migrated") is True and rep3.get("prefs_cleaned") is True)
    check("بلا تكرار بعد إعادة التشغيل",
          dump_user_db(user_db3)["favorites"] == [2, 255, 7]
          and len(dump_user_db(user_db3)["history"]) == 3)
    check("prefs نُظفت في المحاولة الثانية",
          not any(k in prefs3 for k in MIGRATED_KEYS))

    print(f"\n== النتيجة: {len(PASS)} ناجح، {len(FAIL)} فاشل ==")
    if FAIL:
        print("FAILED:", FAIL)
        return 1
    print("ALL MIGRATION TESTS PASSED")
    print(f"(بيانات العينة فقط في {tmp} — تُحذف تلقائياً مع /tmp؛ لم يُمس أي ملف حقيقي)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
