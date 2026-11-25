// كتالوج الحزم الاختيارية — تلاوة
//
// كل حجم هنا إما «مقيس/منشور» بمصدر مذكور، أو «تقديري» من الخطة
// المعتمدة مع وسمه تقديرياً صراحةً. لا أرقام مخترعة.
// القاعدة التصميمية: الحجم الحقيقي الذي يراه المستخدم قبل التنزيل
// هو مجموع ملفات الـ manifest المنشور وقت البناء، لا هذه الأرقام.
// هذه الأرقام للتخطيط والعرض الأولي فقط.
//
// مصادر الأرقام:
// - [S1] التدقيق AUDIT_2026-11-25 §1 و§6 و§7.2.
// - [S2] المخطط PLAN_2026-11-25 §3.3.
// - [S3] تقرير Phase 0 — §5 (صور المصحف) و§7 (القرّاء).
// - [S4] بطاقات Maqra على Hugging Face (أُعيدت قراءتها 2026-11-25).

import 'package_models.dart';

/// مصدر الرقم — يُعرض معه دائماً فلا يُقرأ تقديرٌ كأنه مقيس.
enum SizeSource {
  /// رقم منشور/مقيس بمصدر مذكور في [sizeNote].
  measured,

  /// تقدير من الخطة المعتمدة — يُؤكَّد عند بناء الحزمة.
  estimated,

  /// غير معروف إطلاقاً — لا رقم.
  unknown,
}

/// بند كتالوج واحد: حزمة اختيارية بحجم معلن قبل التنزيل.
class CatalogPackage {
  /// معرّف الحزمة (يطابق PackageManifest.id عند البناء).
  final String id;

  final PackageKind kind;

  final String titleAr;

  /// الحجم بالبايت إن عُرف، وإلا null.
  final int? sizeBytes;

  /// نطاق تقديري نصاً عند غياب رقم دقيق، مثل «≈ 300–900 MB».
  final String? estimatedRangeAr;

  final SizeSource sizeSource;

  /// مصدر الرقم حرفياً (مثلاً «PLAN §3.3»).
  final String sizeNote;

  /// هل الحزمة داخل APK؟ كل حزم هذا الكتالوج: لا — عند الطلب فقط.
  final bool inApk = false;

  /// حالة الترخيص/النسبة المختصرة.
  final String licenseNote;

  const CatalogPackage({
    required this.id,
    required this.kind,
    required this.titleAr,
    required this.sizeBytes,
    required this.estimatedRangeAr,
    required this.sizeSource,
    required this.sizeNote,
    required this.licenseNote,
  });

  /// نص الحجم المعروض للمستخدم قبل التنزيل.
  String get displaySize {
    if (sizeBytes != null) return formatBytes(sizeBytes!);
    if (estimatedRangeAr != null) return estimatedRangeAr!;
    return 'غير معروف — يُعلن عند توفر الـ manifest';
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// كتالوج الحزم الاختيارية السبع (الخطة §3.3) + ورش.
const List<CatalogPackage> packageCatalog = [
  CatalogPackage(
    id: 'mushaf-images-2600',
    kind: PackageKind.mushafImages,
    titleAr: 'صفحات مصحف المدينة — صور 604 (2600×4206)',
    sizeBytes: 120 * 1024 * 1024,
    estimatedRangeAr: '≈ 120 MB',
    sizeSource: SizeSource.measured,
    sizeNote:
        '‏[S3] Phase 0 §5: «≈120MB» تنزيل مضغوط (وثائق Mihrab)؛ والمخرجات الخام ≈600MB لكل عرض (وثائق quran.com-images). التخطيط النصي البديل <1MB وهو في DB أصلاً وليس حزمة.',
    licenseNote:
        'مجمع الملك فهد — إعادة توزيع رقمي مجاني مشمولة بالنص المنشور؛ الحق المحفوظ الوحيد الطباعة الورقية التجارية داخل المملكة. يُنصح بتأكيد كتابي لأن صفحة الشروط الرسمية 404 (Phase 0 §5). نسبة واضحة داخل التطبيق إلزامية.',
  ),
  CatalogPackage(
    id: 'reciter-full',
    kind: PackageKind.reciter,
    titleAr: 'قارئ واحد — قرآن كامل آيةً بآية (جودة واحدة)',
    sizeBytes: null,
    estimatedRangeAr: '≈ 300–900 MB حسب الجودة وسرعة القارئ',
    sizeSource: SizeSource.estimated,
    sizeNote:
        '‏[S2] PLAN §3.3: قرآن كامل ≈300–900MB؛ سورة واحدة ≈5–30MB. مرساتان منشورتان [S4] تتجاوزان النطاق: الحصري 128 = 2357 MiB، والمنشاوي مرتل 128 = 1588 MiB (بطاقتا Maqra، 2026-11-25) — فالنطاق تقديري ويُعتمَد حجم الـ manifest عند البناء. لا تُعرض أرقام فردية مخترعة لبقية القرّاء.',
    licenseNote:
        'islamic.network: إعادة توزيع مجانية غير تجارية مع بقاء الحقوق للقرّاء وخطر طلب الإزالة. EveryAyah: بلا شروط منشورة (UNKNOWN). نسبة القارئ والمصدر إلزامية؛ لا تعديل؛ لا ملفات داخل APK.',
  ),
  CatalogPackage(
    id: 'tafsir-ibn-kathir',
    kind: PackageKind.tafsir,
    titleAr: 'تفسير ابن كثير (حزمة مستقلة)',
    sizeBytes: null,
    estimatedRangeAr: '≈ 10–25 MB نص + FTS',
    sizeSource: SizeSource.estimated,
    sizeNote:
        '‏[S2] PLAN §3.3 / [S1] AUDIT §7.2: «يُؤكَّد» عند البناء. المصدر: QuranLab بعد قراءة LICENSES.md لكل config؛ QF API عرض فقط وتخزين ≤7 أيام — لا يُضمَّن دائماً.',
    licenseNote: 'عمل كلاسيكي في الملك العام؛ الطبعة الرقمية لها شروطها — تُقرأ قبل التضمين.',
  ),
  CatalogPackage(
    id: 'tafsir-tabari',
    kind: PackageKind.tafsir,
    titleAr: 'تفسير الطبري (حزمة مستقلة)',
    sizeBytes: null,
    estimatedRangeAr: '≈ 10–25 MB نص + FTS',
    sizeSource: SizeSource.estimated,
    sizeNote: '‏[S2] PLAN §3.3 / [S1] AUDIT §7.2: «يُؤكَّد» عند البناء. القناة نفسها كابن كثير.',
    licenseNote: 'عمل كلاسيكي في الملك العام؛ الطبعة الرقمية لها شروطها — تُقرأ قبل التضمين.',
  ),
  CatalogPackage(
    id: 'tafsir-qurtubi',
    kind: PackageKind.tafsir,
    titleAr: 'تفسير القرطبي (حزمة مستقلة)',
    sizeBytes: null,
    estimatedRangeAr: '≈ 10–25 MB نص + FTS',
    sizeSource: SizeSource.estimated,
    sizeNote:
        '‏[S2] PLAN §3.3: «يُؤكَّد». قيد: معرّف القرطبي 90 في QF غير موثَّق (AUDIT §6.4) — لا يُستخدم قبل إعادة التحقق من /resources/tafsirs.',
    licenseNote: 'عمل كلاسيكي في الملك العام؛ الطبعة الرقمية لها شروطها — تُقرأ قبل التضمين.',
  ),
  CatalogPackage(
    id: 'translation-en-sahih',
    kind: PackageKind.translation,
    titleAr: 'الترجمة الإنجليزية — Sahih International',
    sizeBytes: null,
    estimatedRangeAr: '≈ 1–3 MB لكل لغة',
    sizeSource: SizeSource.estimated,
    sizeNote:
        '‏[S2] PLAN §3.3: كل لغة ≈1–3MB. [S1] AUDIT §6.3: تقدير عام لترجمات JSON.',
    licenseNote:
        'ليست ملكاً عاماً ولا CC — استعمال غير تجاري حرفي مع الإسناد ورابط Tanzil؛ يُنصح بإذن كتابي من Saheeh International / Dar Abul-Qasim قبل الدمج.',
  ),
  CatalogPackage(
    id: 'ai-model-lite',
    kind: PackageKind.aiModel,
    titleAr: 'نموذج التسميع — خفيف (yazinsai lite 1.x)',
    sizeBytes: 24650054 + 4700000,
    estimatedRangeAr: '≈ 29.4 MB (24.7 نموذج + 4.7 مرجع)',
    sizeSource: SizeSource.measured,
    sizeNote:
        '‏[S1] AUDIT §6.1: lite ‏24,650,054 بايت (spliced-clean-lite@1-int8) + مرجع ref-v2.json ‏4.7MB. حجم ONNX Runtime غير معروف قبل PoC — يُقاس ويُدوَّن.',
    licenseNote:
        'كود MIT؛ أوزان 1.x ‏CC BY 4.0 (نسبة Tilawa tilawa.dev + tlog/QUD/muaalem/quran-transcript/icefall/Tanzil)؛ 1.x فقط؛ الميزة مجانية بلا إعلانات؛ تحقق SHA-256 إلزامي.',
  ),
  CatalogPackage(
    id: 'ai-model-full',
    kind: PackageKind.aiModel,
    titleAr: 'نموذج التسميع — كامل (yazinsai full 1.x)',
    sizeBytes: 67759744 + 4700000,
    estimatedRangeAr: '≈ 72.5 MB (67.8 نموذج + 4.7 مرجع)',
    sizeSource: SizeSource.measured,
    sizeNote:
        '‏[S1] AUDIT §6.1: full ‏67,759,744 بايت (spliced-clean@1-int8) + مرجع 4.7MB. حجم ONNX Runtime غير معروف قبل PoC.',
    licenseNote: 'كما في lite — 1.x فقط، CC BY 4.0 مع النسبة، مجاني بلا إعلانات.',
  ),
  CatalogPackage(
    id: 'lessons-bundle',
    kind: PackageKind.lessons,
    titleAr: 'الدروس — تجويد + نورانية + أطفال (نص + صوت أمثلة)',
    sizeBytes: null,
    estimatedRangeAr: '≈ 5–20 MB',
    sizeSource: SizeSource.estimated,
    sizeNote: '‏[S2] PLAN §3.3: «≈5–20MB». محتوى مرخَّص فقط — لا محتوى بلا ترخيص.',
    licenseNote: 'حسب كل درس — لا محتوى بلا مصدر وترخيص موثَّقين.',
  ),
  CatalogPackage(
    id: 'warsh-package',
    kind: PackageKind.warsh,
    titleAr: 'حزمة ورش عن نافع',
    sizeBytes: 1600000,
    estimatedRangeAr: '≈ 1.6 MB',
    sizeSource: SizeSource.measured,
    sizeNote:
        '‏[S1] AUDIT §2: حزمة اختيارية موجودة أصلاً 1.6MB (114 سورة، 6214 آية) من quran-json.risanb.com. تُدار هنا للتوحيد؛ لا إعادة تنزيل لمن ثبّتها.',
    licenseNote: 'نسبة المصدر في التطبيق (Qur\'anpedia / quran-json.risanb.com).',
  ),
];

/// الحزمة الأساسية (ليست اختيارية — داخل APK).
/// للتخطيط فقط: APK الحالي 70.1MB [S1]؛ الهدف بعد تقسيم المعالجات ≈48MB.
class CorePackageInfo {
  static const String currentApkSize = '70.1 MB (build-7)';
  static const String targetApkSize = '≈ 48 MB بعد تقسيم المعالجات (AAB/split)';
  static const String dbSize = 'assets/quran.db ‏40.2 MB خام / 10.9 MB مضغوط';
}
