# قائمة رفع تلاوة برو إلى GitHub — UPLOAD MANIFEST

> **لقطة بتاريخ 2026-11-25 ~12:55 Asia/Aden.** الشجرة تُبنى فيها مسارات
> متوازية؛ إن ظهرت ملفات جديدة بعد هذا التاريخ فهي خارج هذه القائمة
> وتحتاج مراجعة قبل الرفع. القاعدة: يُرفع كل ملف مصدر في القائمة أدناه،
> ولا يُرفع أي ملف مولَّد أو مؤقت أو نسخة احتياطية.
>
> طريقة الرفع: من المتصفح المتصل بحساب ezzaldeenmansour123 إلى المستودع
> **https://github.com/ezzaldeenmansour123/Tilawa-Pro** (فرع main)، فوق
> الملفات العشرة الحالية (v1.0.0، آخر commit `3458056`). لا تُنشأ مستودعات
> جديدة. بعد الرفع يُشغَّل سير `build-pro.yml` (يدوياً أو بالدفع) وينشر
> `Tilawa-Pro.apk` بالوسم `pro-build-N`.
>
> **تحديث 13:05**: اسم حزمة Dart صار `tilawa_pro` (كان `tilawa`) — غيّره
> المسار الموازي في `pubspec.yaml` وحدّث كل الاستيرادات؛ وتحقق منه هنا
> (`flutter pub get` + analyze صفر + test أخضر). اسم الحزمة يطابق الآن
> معرّف التطبيق المقترح، لكن قرار الـ applicationId نفسه ما زال معلّقاً
> كما في §3.2.

## 1. ما يُرفع (80 ملفاً)

### الجذر (8)

- `.gitignore` — يستثني المولَّدات؛ `pubspec.lock` **غير** مستثناة عمداً (انظر §3).
- `.github/workflows/build-pro.yml` — سير بناء Pro (الجديد، الأساسي).
- `.github/workflows/build.yml` — سير تلاوة v1.0.0 الأصلية؛ **معطَّل عن
  الدفع** (workflow_dispatch فقط) حتى لا يبني نسخة قديمة.
- `.github/workflows/split-check.yml` — حارس فروع feature (analyze + test).
- `analysis_options.yaml` — يستثني `docs/**` من التحليل (مرجع غير كود).
- `pubspec.yaml` — الإصدار `1.1.0+1`؛ تبعية جديدة واحدة: `file_picker ^8.1.2`.
- `pubspec.lock` — مثبَّت بعد بناء أخضر محلي (انظر §3).
- `README.md` — **تنبيه**: كتبه مسار موازٍ ويصف نطاقاً أوسع (محرك + معجم
  مدمجان) غير متحقق في `lib/` بعد — انظر BUILD_REPORT §6 قبل الاعتماد عليه.
- `NOTICE.md` — التراخيص والنِّسَب (جديد).

### الأصول (3)

- `assets/.gitkeep`
- `assets/packages/reciter-afasy-fatiha-64-manifest.json` — الحزمة الوحيدة
  الجاهزة (الفاتحة، العفاسي، 64kbps، 378,661 بايت، 7 ملفات موثقة).
- `assets/web/tilawa.html` — صفحة حاوية المحرك (1.5 KB، من المسار الموازي؛
  غير موصولة بالتطبيق بعد).

### التوثيق (12)

- `docs/SEARCH_FTS3_PENDING.md` — حالة المعجم المعلّقة وشرطاها (جديد).
- `docs/phase0-1/` — تقارير المرحلتين 0 و1 التسعة (AUDIT، PLAN، PHASE0_REPORT،
  PHASE1_REPORT، DECISIONS_REPORT، SPLIT_PLAN، MIGRATION_PLAN،
  MUSHAF_IMAGES_VERIFICATION، POC_YAZINSAI_DESIGN).
- `docs/reference/dart_lexicon_proposal.dart` — مرجع برمجي للمعجم (غير موصول).
- `BUILD_REPORT_2026-11-25.md` — تقرير هذا البناء (جديد، في الجذر).
- `UPLOAD_MANIFEST.md` — هذا الملف.

### كود التطبيق `lib/` (22)

- `lib/main.dart` (4,561 سطراً) — التطبيق المدمج + ربط الحزم/التصدير/الحفظ/المشغل.
- `lib/db.dart` (515) — قاعدة البيانات + إعادة تصدير النماذج.
- `lib/tajweed.dart` (158) — فهرس أحكام التجويد (بلا تلوين مدمج).
- `lib/core/theme.dart` — الألوان وbuildTheme والرسامون.
- `lib/data/models.dart` — النماذج (Surah/Ayah/Ijaz/Reciter + القوائم).
- `lib/data/user_export.dart` + `lib/data/user_export_io.dart` — منطق
  التصدير/الاستيراد وخدمته.
- `lib/features/memorization/hifz_store.dart` + `hifz_page.dart` — خطط
  الحفظ والتكرار المتباعد (جديد، موصول من المزيد).
- `lib/features/packages/` — `package_models.dart`، `package_catalog.dart`،
  `download_manager.dart`، `reciters.dart` (17 قارئاً موثقاً)،
  `packages_page.dart` (جديد، موصول من الإعدادات).
- `lib/features/data/export_page.dart` — صفحة نسخ احتياطي كاملة (من المسار
  الموازي؛ **غير موصولة** بأي تنقّل بعد).
- `lib/features/recitation/` (14 ملفاً: event_log، local_server،
  model_manager، models، progress_store، session_logic، speech_engine،
  surah_names، webview_engine + screens الخمس) — كود محرك التسميع من
  Tilawa-PoC (من المسار الموازي؛ **غير موصول** بـ main.dart بعد، بانتظار GO).
- `lib/search/lexicon_search.dart` — تنفيذ البحث المعجمي (من المسار الموازي؛
  **غير موصول** بـ db.dart بعد، بانتظار شرطي الدمج).

### الاختبارات `test/` (7)

- `test/models_test.dart`، `test/theme_test.dart`،
  `test/download_manager_test.dart` (بما فيه اختبار `globalAyahToSurahAyah`
  الجديد)، `test/packages_export_test.dart` (من المسار الموازي — اختبارات
  حية بخادم HTTPS محلي)، `test/session_logic_test.dart` (من المسار الموازي)،
  `test/lexicon_test.dart` (من المسار الموازي)، `test/local_server_test.dart`
  (من المسار الموازي).

### الأدوات `tools/` (13) و`web/` (3) و`phase0/` (3)

- `tools/build_db.py`، `tools/make_icon.py`، `tools/probe_missing_ayah.py`،
  `tools/simulate_download.py`، `tools/test_migration.py`،
  `tools/verify_text.py`، `tools/verify_tajweed.py` (من v1.0.0/Phase 0-1).
- `tools/attach_lexicon.py`، `tools/build_lexicon.py`،
  `tools/verify_lexicon.py`، `tools/download_assets.py`،
  `tools/copy_recitation_from_poc.py` (من المسار الموازي؛ **غير موصولة**
  بسير البناء بعد).
- `web/build.mjs`، `web/package.json`، `web/src/bridge.js` (مصادر حزمة
  محرك التسميع، من المسار الموازي؛ غير مبنية في CI بعد).
- `phase0/fts_test.py`، `phase0/FTS_TEST_RESULTS.md`،
  `phase0/fts_test_output.txt` (أدلة اختبار FTS في Phase 0).

## 2. ما لا يُرفع إطلاقاً

| المسار | السبب |
|---|---|
| `assets/quran.db` (42.1 MB) + `assets/quran.db.sha256` | مولَّدان في CI من بيانات مثبّتة (build_db.py) |
| `assets/fonts/` (Amiri-Regular/Bold) | مولَّدان في CI (تنزيل من google/fonts) |
| `lib/main.dart.orig`، `lib/db.dart.orig` | نسخ تراجع للدمج، ليست مصدراً |
| `.dart_tool/`، `build/` | مولَّدات محلية |
| `tools/__pycache__/` | بايت كود Python مؤقت |
| `web/node_modules/` | تُولَّد بـ `npm install` في CI (فارغة حالياً) |
| `data_dir.txt`، `ANALYZE_FRESH.txt`، `ANALYZE_FINAL.txt`، `TEST_FINAL.txt` | مخلفات محلية (مسار بيانات HF + سجلات تحليل/اختبار) |
| أي ملف `*.tmp` أو `*.part` أو `*.corrupt-*` | مؤقتات |

## 3. قرارات موثقة في هذه القائمة

1. **`pubspec.lock` يُرفع**: بعد بناء أخضر محلي (analyze صفر + test أخضر)،
   يُثبَّت القفل لتثبيت إصدارات التبعيات (درس من Tilawa-PoC). أُزيل سطره من
   `.gitignore` لهذا الغرض.
2. **`applicationId` المقترح لـ Pro هو `com.tilawa.app.tilawa_pro`**
   (مستقل بجانب تلاوة الأصلية `com.tilawa.app.tilawa`): مكتوب في
   `build-pro.yml` مع تعليق «قرار معلّق» — **يجب أن يؤكده المالك قبل أول
   تشغيل**؛ لا يُغيَّر بعد أول إصدار مثبَّت. معرّف تلاوة الأصلية وتوقيعها
   لا يُمسان إطلاقاً.
3. **لا keystore ولا توقيع إصدار في هذه الشجرة**: الـ APK من CI موقَّع
   بمفتاح تصحيح (كما في v1.0.0) إلى أن يُحسم التوقيع مع المالك (التصدير/
   الاستيراد أولاً، انظر PHASE0_REPORT).
4. **ملفات المسار الموازي تُرفع كما هي** (مذكورة أعلاه كـ «من المسار
   الموازي») لأن حذفها محظور، لكنها **غير موصولة** ولا تُفعَّل في CI —
   تفعيلها قرار منفصل للمالك (انظر BUILD_REPORT §5–§6).

## 4. بعد الرفع — تحقق

1. تأكد أن عدد الملفات في المستودع يطابق القائمة (80) وأن لا أثر لملفات §2.
2. شغّل `build-pro.yml` (Actions → Build Tilawa Pro APK → Run workflow).
3. يجب أن تنجح الخطوات بالترتيب: بيانات ← قاعدة ← خطوط ← `flutter create`
   ← `pub get` ← `flutter test` ← `flutter analyze` ← بناء APK ← نشر
   `Tilawa-Pro.apk` بالوسم `pro-build-N`.
4. نزّل الـ APK على S22 Ultra وثبّته **بجانب** تلاوة الأصلية (لا يستبدلها).
5. اختبار أولي على الهاتف: فتح التطبيق، المصحف النصي 604 صفحات، البحث،
   التلاوة (سرعة/تكرار/نوم)، الحزم (تنزيل الفاتحة)، التصدير/الاستيراد،
   خطط الحفظ — ثم بروتوكول 30 جلسة لمحرك التسميع (منفصل، في PoC).
