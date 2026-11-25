#!/usr/bin/env python3
"""محاكاة محلية لمنطق مدير التنزيلات — تلاوة (Phase 1).

ما تختبره هذه المحاكاة فعلاً (مكتبة قياسية فقط، بلا شبكة، بلا ملفات
صوتية حقيقية — ملفات اختبار مولّدة محلياً في /tmp):
  1. تنزيل مجزّأ مع استئناف: مقاطعة بعد N بايت ثم إكمال عبر Range.
  2. تحقق SHA-256 لكل ملف + تحقق كامل الحزمة.
  3. كشف ملف تالف (قلب بايت واحد) ورفضه ثم إعادة تنزيله.
  4. حذف حزمة + احتساب المساحة المستخدمة.
  5. قارئ غير مكتمل: ملف غائب واحد يمنع وسم «مكتمل» (محاكاة ثغرة 6235).

ما لا تختبره: كود Dart نفسه (download_manager.dart) — لا Dart SDK هنا.
المنطق المنسوخ هنا مرآة حرفية لتصميم Dart (Range + ‎.part + SHA-256
+ تحقق قبل وسم installed)، لا بديل عنه. كود Dart «لم يُختبر بعد».

التشغيل: python3 tools/simulate_download.py
الخروج 0 = كل الفحوص ناجحة.
"""

import hashlib
import json
import os
import random
import shutil
import sys
import tempfile

PASS = 0


def check(name, cond, detail=""):
    global PASS
    assert cond, f"FAIL: {name} {detail}"
    PASS += 1
    print(f"  PASS: {name}" + (f" — {detail}" if detail else ""))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


# --- مرآة مصغّرة لمنطق Dart: خادم وهمي يدعم Range -------------------------
class FakeServer:
    """ملفات المصدر + دعم Range (206) أو تجاهله (200)."""

    def __init__(self, files, honor_range=True):
        self.files = files  # path -> bytes
        self.honor_range = honor_range

    def get(self, path, start=0):
        data = self.files[path]
        if start > 0 and self.honor_range:
            return 206, data[start:]
        if start > 0 and not self.honor_range:
            return 200, data  # تجاهل Range: يعيد الملف كاملاً
        return 200, data


# --- مرآة مصغّرة لمنطق Dart: التنزيل --------------------------------------
def download_file(pkg_dir, manifest_file, server, interrupt_after=None):
    """ينزّل ملفاً واحداً مع استئناف ‎.part. يعيد عدد بايتات الحزمة المنزّلة."""
    path = manifest_file["path"]
    target = os.path.join(pkg_dir, path)
    part = target + ".part"
    os.makedirs(os.path.dirname(target), exist_ok=True)
    downloaded = os.path.getsize(part) if os.path.exists(part) else 0
    if os.path.exists(target):
        if (os.path.getsize(target) == manifest_file["sizeBytes"]
                and sha256_file(target) == manifest_file["sha256"]):
            return manifest_file["sizeBytes"]  # مكتمل ومتحقق: يُتخطى
        os.remove(target)
    if downloaded > manifest_file["sizeBytes"]:
        os.remove(part)
        downloaded = 0
    status, data = server.get(path, start=downloaded)
    if downloaded > 0 and status == 200:
        os.remove(part)  # الخادم تجاهل Range: إعادة من الصفر
        downloaded = 0
        status, data = server.get(path, start=0)
    mode = "ab" if downloaded > 0 else "wb"
    written = 0
    with open(part, mode) as f:
        for i in range(0, len(data), 4096):
            chunk = data[i:i + 4096]
            if interrupt_after is not None and written + len(chunk) > interrupt_after:
                cut = interrupt_after - written
                if cut > 0:
                    f.write(chunk[:cut])
                f.flush()
                raise InterruptedError("محاكاة انقطاع")
            f.write(chunk)
            written += len(chunk)
    os.rename(part, target)
    if sha256_file(target) != manifest_file["sha256"]:
        os.remove(target)
        raise ValueError(f"فشل تحقق SHA-256 للملف {path}")
    return manifest_file["sizeBytes"]


def verify_package(pkg_dir, manifest):
    missing = []
    for mf in manifest["files"]:
        target = os.path.join(pkg_dir, mf["path"])
        if (not os.path.exists(target)
                or os.path.getsize(target) != mf["sizeBytes"]
                or sha256_file(target) != mf["sha256"]):
            missing.append(mf["path"])
    return missing


def used_bytes(pkg_dir):
    total = 0
    for root, _, files in os.walk(pkg_dir):
        for name in files:
            if name != "registry.json":
                total += os.path.getsize(os.path.join(root, name))
    return total


def make_manifest(files):
    return {
        "id": "test-surah-002",
        "kind": "reciter",
        "version": "1",
        "files": [
            {"path": p, "sizeBytes": len(b),
             "sha256": sha256_bytes(b)} for p, b in files.items()
        ],
    }


def main():
    random.seed(20261125)
    tmp = tempfile.mkdtemp(prefix="tilawa-dl-sim-")
    print(f"مجلد الاختبار: {tmp}")
    try:
        # بيانات اختبار: 3 ملفات (محاكاة 3 آيات من سورة).
        src = {
            "002/002001.mp3": os.urandom(20000),
            "002/002002.mp3": os.urandom(35000),
            "002/002003.mp3": os.urandom(12000),
        }
        manifest = make_manifest(src)
        pkg = os.path.join(tmp, "packages", "test-surah-002")
        os.makedirs(pkg, exist_ok=True)
        server = FakeServer(src)

        # 1. تنزيل مع مقاطعة واستئناف.
        print("== 1. استئناف بعد مقاطعة ==")
        try:
            download_file(pkg, manifest["files"][0], server,
                          interrupt_after=8000)
            raise AssertionError("كان يجب أن تنقطع المحاكاة")
        except InterruptedError:
            pass
        part = os.path.join(pkg, "002/002001.mp3.part")
        check("ملف ‎.part محفوظ بعد المقاطعة",
              os.path.exists(part) and os.path.getsize(part) == 8000,
              f"الحجم {os.path.getsize(part)} بايت")
        n = download_file(pkg, manifest["files"][0], server)
        check("الاستئناف أكمل الملف (Range)",
              n == 20000 and sha256_file(
                  os.path.join(pkg, "002/002001.mp3")) ==
              manifest["files"][0]["sha256"])

        # 2. تنزيل باقي الملفات + تحقق كامل الحزمة.
        print("== 2. اكتمال الحزمة والتحقق ==")
        for mf in manifest["files"][1:]:
            download_file(pkg, mf, server)
        missing = verify_package(pkg, manifest)
        check("تحقق الحزمة كاملة: لا ملفات غائبة/تالفة", missing == [])

        # 3. خادم يتجاهل Range: ‎.part يُعاد من الصفر لا يُلحق فوقه.
        print("== 3. خادم يتجاهل Range ==")
        pkg2 = os.path.join(tmp, "packages", "test-surah-003")
        os.makedirs(os.path.join(pkg2, "002"), exist_ok=True)
        with open(os.path.join(pkg2, "002/002001.mp3.part"), "wb") as f:
            f.write(src["002/002001.mp3"][:5000])
        server_no_range = FakeServer(src, honor_range=False)
        download_file(pkg2, manifest["files"][0], server_no_range)
        check("أُعيد الملف من الصفر عند تجاهل Range",
              sha256_file(os.path.join(pkg2, "002/002001.mp3")) ==
              manifest["files"][0]["sha256"])

        # 4. ملف تالف يُكتشف ويُرفض ثم يُعاد تنزيله.
        print("== 4. كشف التلف وإعادة التنزيل ==")
        target = os.path.join(pkg, "002/002002.mp3")
        with open(target, "r+b") as f:
            f.seek(100)
            f.write(b"\x00")
        missing = verify_package(pkg, manifest)
        check("التحقق كشف الملف التالف", missing == ["002/002002.mp3"],
              f"الغائب: {missing}")
        os.remove(target)
        download_file(pkg, manifest["files"][1], server)
        check("إعادة التنزيل أصلحت الملف",
              verify_package(pkg, manifest) == [])

        # 5. قارئ غير مكتمل: ملف غائب واحد يمنع وسم «مكتمل».
        print("== 5. قيد 6235: آية غائبة تمنع الاكتمال ==")
        os.remove(os.path.join(pkg, "002/002003.mp3"))
        missing = verify_package(pkg, manifest)
        check("آية غائبة واحدة = الحزمة غير مكتملة",
              missing == ["002/002003.mp3"])
        check("الحزمة لا تُوسم installed مع آية غائبة",
              len(missing) != 0)

        # 6. حذف حزمة + المساحة.
        print("== 6. الحذف والمساحة ==")
        before = used_bytes(os.path.join(tmp, "packages"))
        check("المساحة المستخدمة > 0 قبل الحذف", before > 0,
              f"{before} بايت")
        shutil.rmtree(pkg)
        check("الحذف أزال مجلد الحزمة", not os.path.exists(pkg))
        after = used_bytes(os.path.join(tmp, "packages"))
        check("المساحة انخفضت بعد الحذف", after < before,
              f"{after} بايت")
        print(f"\nالنتيجة: {PASS} ناجح، 0 فاشل — ALL DOWNLOAD SIMULATION TESTS PASSED")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
