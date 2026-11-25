#!/usr/bin/env python3
"""فحص الآية الغائبة في islamic.network — الحصري والمنشاوي (والبصفر 192).

الوضع: لم يُنفَّذ هذا الفحص في Phase 1، ولم تُحدَّد الآية الغائبة.
هذا السكربت هو الطريقة الموثقة لتحديدها في Phase 2 — لا يُشغَّل هنا
لأنه يتطلب 6,236 طلب HEAD لكل إصدار/جودة (12,472 طلباً للإصدارين)،
ولأن هذه البيئة لا تنفّذ فحص CDN بهذا الحجم عبر أدوات النص.

لماذا لا توجد طريقة نصية أقصر؟ (موثّق في RECITERS_PACKAGES.md §2)
  - ملف العدّ الوحيد المنشور (risan: data/audio/islamic_network_by_ayah.json)
    يسجّل العدد فقط (6235) لا هوية الآية.
  - فهرس CDN الرسمي (cdn.txt) يسرد الإصدارات والجودات فقط.
  - API ‏api.alquran.cloud يسرد الإصدارات فقط؛ ولا قائمة آيات فيه
    تعكس وجود ملفات CDN.
  - لا مصدر منشور آخر يسمّي الآية (بحث وب 2026-11-25).

الطريقة (الوحيدة الصحيحة):
  لكل إصدار (ar.husary وar.minshawi ‏128kbps، واختيارياً ar.abdullahbasfar
  ‏192kbps الذي سجّل 6235 أيضاً):
    1. لكل رقم عام N من 1 إلى 6236: طلب HEAD على
       https://cdn.islamic.network/quran/audio/{bitrate}/{edition}/{N}.mp3
    2. سجّل N التي تعيد غير 200 (404 عادةً) — المتوقع رقم واحد فقط.
    3. حوّل N إلى سورة:آية عبر جدول ayahsPerSurah (المجموع 6236 —
       منسوخ من everyayah.com/data/recitations.js؛ متحقق محلياً).
    4. تحقق متقاطع: اطلب الملف نفسه من EveryAyah بصيغة SSSAAA
       (يجب أن يكون 200 — EveryAyah مكتمل) واطلب N-1 وN+1 من
       islamic.network (يجب أن يكونا 200) لاستبعاد خطأ شبكة عابر.
    5. أعد الفحص بعد 24 ساعة قبل تثبيت النتيجة (قد يكون الغياب
       عطلاً مؤقتاً في CDN لا نقصاً دائماً).

قواعد التشغيل (إلزامية):
  - مهلة 10 ثوانٍ للطلب، وإعادة محاولة واحدة فقط بعد 2 ثانية.
  - لا تزامن مفرط: 8 طلبات متوازية كحد أقصى، وفاصل 50ms بين الدفعات —
    CDN خدمة مجانية، لا يُغمر.
  - نقطة تفتيش: يُحفظ التقدم في ملف JSON بعد كل 500 رقم، ليُستأنف
    الفحص من حيث توقف دون إعادة كل شيء.
  - لا تنزيل لأي ملف صوتي كامل — HEAD فقط (أو GET بنطاق بايت واحد
    إن رفض الخادم HEAD).
  - المخرجات: missing_<edition>_<bitrate>.json فيه: الرقم العام،
    سورة:آية، رمزا حالة HTTP في الفحصين، وتاريخ الفحص.

التشغيل (في Phase 2، من بيئة فيها شبكة):
    python3 tools/probe_missing_ayah.py --edition ar.husary --bitrate 128
    python3 tools/probe_missing_ayah.py --edition ar.minshawi --bitrate 128
    python3 tools/probe_missing_ayah.py --edition ar.abdullahbasfar --bitrate 192

الاعتماديات: مكتبة قياسية فقط (urllib).
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

AYAHS_PER_SURAH = [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128,
    111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73,
    54, 45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60,
    49, 62, 55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52,
    44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19,
    26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3,
    6, 3, 5, 4, 5, 6,
]
assert sum(AYAHS_PER_SURAH) == 6236, "جدول آيات السور لا يجمع 6236"
assert len(AYAHS_PER_SURAH) == 114

CDN_TEMPLATE = "https://cdn.islamic.network/quran/audio/{bitrate}/{edition}/{n}.mp3"
EVERYAYAH_TEMPLATE = "https://everyayah.com/data/{folder}/{sss}{aaa}.mp3"


def global_to_surah_ayah(n):
    remaining = n
    for i, count in enumerate(AYAHS_PER_SURAH):
        if remaining <= count:
            return i + 1, remaining
        remaining -= count
    raise ValueError(n)


def head_status(url, timeout=10):
    """يعيد رمز HTTP أو None عند خطأ شبكة (يُعاد فحصه لاحقاً)."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return None


def probe(edition, bitrate, folder, checkpoint_path):
    done = {}
    if os.path.exists(checkpoint_path):
        with open(checkpoint_path, encoding="utf-8") as f:
            done = {int(k): v for k, v in json.load(f).items()}
    todo = [n for n in range(1, 6237) if n not in done]
    print(f"الإصدار {edition} ‏{bitrate}: المتبقي {len(todo)} من 6236 "
          f"(المحفوظ {len(done)})")

    def check_one(n):
        url = CDN_TEMPLATE.format(bitrate=bitrate, edition=edition, n=n)
        status = head_status(url)
        if status is None:
            time.sleep(2)
            status = head_status(url)
        return n, status

    with ThreadPoolExecutor(max_workers=8) as pool:
        for i, (n, status) in enumerate(pool.map(check_one, todo)):
            done[n] = status
            if (i + 1) % 500 == 0:
                with open(checkpoint_path, "w", encoding="utf-8") as f:
                    json.dump(done, f)
                print(f"  ... {len(done)}/6236")
            time.sleep(0.05)
    with open(checkpoint_path, "w", encoding="utf-8") as f:
        json.dump(done, f)
    return done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--edition", required=True)
    ap.add_argument("--bitrate", required=True)
    ap.add_argument("--everyayah-folder", default=None,
                    help="مجلد EveryAyah للتحقق المتقاطع")
    args = ap.parse_args()

    ckpt = f"checkpoint_{args.edition}_{args.bitrate}.json"
    done = probe(args.edition, args.bitrate, args.everyayah_folder, ckpt)
    missing = sorted(n for n, s in done.items() if s != 200)
    unknown = sorted(n for n, s in done.items() if s is None)
    print(f"\nالغائبة (غير 200): {missing}")
    print(f"بلا جواب شبكي (تُعاد): {unknown}")
    result = {
        "edition": args.edition,
        "bitrate": args.bitrate,
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "total_checked": len(done),
        "missing_global_numbers": missing,
        "missing_surah_ayah": [
            {"global": n, "surah": s, "ayah": a}
            for n in missing
            for (s, a) in [global_to_surah_ayah(n)]
        ],
        "no_network_answer": unknown,
    }
    out = f"missing_{args.edition}_{args.bitrate}.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    print(f"حُفظت النتيجة في {out}")

    # تحقق متقاطع اختياري للغائبة عبر EveryAyah.
    if args.everyayah_folder and missing:
        for n in missing:
            s, a = global_to_surah_ayah(n)
            url = EVERYAYAH_TEMPLATE.format(
                folder=args.everyayah_folder,
                sss=str(s).zfill(3), aaa=str(a).zfill(3))
            print(f"  EveryAyah {s}:{a} -> HTTP {head_status(url)}"
                  f" (المتوقع 200)")
    return 0 if not unknown else 2


if __name__ == "__main__":
    sys.exit(main())
