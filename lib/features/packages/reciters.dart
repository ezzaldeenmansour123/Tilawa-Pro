// سجل القرّاء الـ17 — تلاوة
//
// المصدر: تدقيق 2026-11-25 (AUDIT §6.2) + تقرير Phase 0 (§7) +
// إعادة تأكيد حيّة في 2026-11-25 (انظر RECITERS_PACKAGES.md §1).
// القائمة محفوظة كما هي — لم يُضف قارئ ولم يُحذف قارئ.
//
// قواعد هذا الملف:
// - أسماء مجلدات EveryAyah حرفية من recitations.js الحي (2026-11-25).
// - معرّفات islamic.network حرفية من api.alquran.cloud الحي (2026-11-25).
// - «مكتمل» تعني 6236 آية آيةً بآية من مصدر واحد على الأقل.
// - لا أسماء وهمية ولا تسجيلات تجريبية. المستثنَون (مصطفى إسماعيل
//   جزئي، إدريس أبكر غير موجود، السديس+الشريم المشترك غير موجود
//   نقياً) غير موجودين في هذه القائمة أصلاً.

/// قارئ واحد من الـ17.
class ReciterEntry {
  /// معرّف مستقر في التطبيق (كما في lib/db.dart الحالي).
  final String id;

  /// الاسم العربي.
  final String nameAr;

  /// مجلد EveryAyah الحرفي (الجودة الأساسية).
  final String everyayahFolder;

  /// جودة EveryAyah الأساسية.
  final String everyayahBitrate;

  /// إصدار islamic.network آيةً بآية، أو null إن لم يوجد.
  final String? islamicNetworkEdition;

  /// نوع الإصدار في API الحي: versebyverse / surahbysurah / غائب.
  /// ملاحظة: ar.minshawi وar.abdulbasitmurattal نوعهما في API
  /// "translation" رغم أنهما آيةً بآية فعلاً (شذوذ موثّق، لا حكم نقص).
  final String islamicNetworkType;

  /// المصدر الأول المعتمد لهذا القارئ في التطبيق.
  final String primarySource;

  /// حالة الاكتمال (6236 آية).
  final String completenessAr;

  /// ملاحظات موثّقة (جودة، ترخيص، قيود).
  final String notes;

  const ReciterEntry({
    required this.id,
    required this.nameAr,
    required this.everyayahFolder,
    required this.everyayahBitrate,
    required this.islamicNetworkEdition,
    required this.islamicNetworkType,
    required this.primarySource,
    required this.completenessAr,
    required this.notes,
  });
}

/// القرّاء الـ17 — الترتيب: السبعة الحاليون أولاً ثم العشرة الجدد.
const List<ReciterEntry> reciters17 = [
  ReciterEntry(
    id: 'afasy',
    nameAr: 'مشاري راشد العفاسي',
    everyayahFolder: 'Alafasy_128kbps',
    everyayahBitrate: '128kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.alafasy',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes: 'EveryAyah: 6348 ملفاً (6236 آية + 112 بسملة). islamic.network ‏128: 6236.',
  ),
  ReciterEntry(
    id: 'husary',
    nameAr: 'محمود خليل الحصري (مرتل)',
    everyayahFolder: 'Husary_128kbps',
    everyayahBitrate: '128kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.husary',
    islamicNetworkType: 'versebyverse',
    primarySource: 'EveryAyah أولاً',
    completenessAr: 'مكتمل عبر EveryAyah — 6236 آية',
    // القيد القائم: islamic.network ‏128 فيه 6235 آية فقط (آية واحدة
    // غائبة، لم يمكن تحديدها — انظر RECITERS_PACKAGES.md §2).
    notes:
        'قيد: ar.husary في islamic.network ‏128 = 6235 آية (مصدر العدّ risan، أُعيد تأكيده 2026-11-25)؛ وفي ‏64 = 6236 كاملة. Maqra: 6237 ملفاً، 0 غائبة upstream. لذلك EveryAyah أولاً.',
  ),
  ReciterEntry(
    id: 'basit',
    nameAr: 'عبد الباسط عبد الصمد (مرتل)',
    everyayahFolder: 'Abdul_Basit_Murattal_192kbps',
    everyayahBitrate: '192kbps',
    islamicNetworkEdition: 'ar.abdulbasitmurattal',
    islamicNetworkType: 'translation (شذوذ في API — آيةً بآية فعلاً)',
    primarySource: 'EveryAyah أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'islamic.network ‏192: 6236. نوع الإصدار في API هو translation لا versebyverse؛ يُفحص بطلب الآيتين 1 و6236 من CDN قبل الاعتماد عليه احتياطياً.',
  ),
  ReciterEntry(
    id: 'minshawi',
    nameAr: 'محمد صديق المنشاوي (مرتل)',
    everyayahFolder: 'Minshawy_Murattal_128kbps',
    everyayahBitrate: '128kbps (يوجد مجوَّد 192، و16/32 أيضاً)',
    islamicNetworkEdition: 'ar.minshawi',
    islamicNetworkType: 'translation (شذوذ في API — آيةً بآية فعلاً)',
    primarySource: 'EveryAyah أولاً',
    completenessAr: 'مكتمل عبر EveryAyah — 6236 آية',
    // القيد القائم: islamic.network ‏128 فيه 6235 آية فقط (آية واحدة
    // غائبة، لم يمكن تحديدها — انظر RECITERS_PACKAGES.md §2).
    notes:
        'قيد: ar.minshawi في islamic.network ‏128 = 6235 آية (مصدر العدّ risan، أُعيد تأكيده 2026-11-25)؛ ولا إصدار مرتل له بـ64. Maqra: 6349 ملفاً، 0 غائبة upstream. لذلك EveryAyah أولاً.',
  ),
  ReciterEntry(
    id: 'sudais',
    nameAr: 'عبد الرحمن السديس',
    everyayahFolder: 'Abdurrahmaan_As-Sudais_192kbps',
    everyayahBitrate: '192kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.abdurrahmaansudais',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'تنبيه إملائي: lib/db.dart الحالي يستخدم fallback باسم ar.abdulrahmanalsudais (بهجاء مختلف) — يُتحقق منه في Phase 2 ولا يُعتمد هنا.',
  ),
  ReciterEntry(
    id: 'muaiqly',
    nameAr: 'ماهر المعيقلي',
    everyayahFolder: 'MaherAlMuaiqly128kbps',
    everyayahBitrate: '128kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.mahermuaiqly',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'مجلد 128 بلا شرطات سفلية (MaherAlMuaiqly128kbps) خلافاً لمجلد 64. islamic.network ‏128: 6236؛ ‏64: 6232 (4 غائبة — الجودة الثانوية فقط).',
  ),
  ReciterEntry(
    id: 'shuraym',
    nameAr: 'سعود الشريم',
    everyayahFolder: 'Saood_ash-Shuraym_128kbps',
    everyayahBitrate: '128kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.saoodshuraym',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes: 'EveryAyah: 6355 ملفاً (6236 آية + 114 بسملة + 5 ملفات إضافية).',
  ),
  ReciterEntry(
    id: 'shaatree',
    nameAr: 'أبو بكر الشاطري',
    everyayahFolder: 'Abu_Bakr_Ash-Shaatree_128kbps',
    everyayahBitrate: '128kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.shaatree',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes: 'EveryAyah: 6350 ملفاً (6236 + 114 بسملة). islamic.network ‏128: 6236.',
  ),
  ReciterEntry(
    id: 'fares',
    nameAr: 'فارس عباد',
    everyayahFolder: 'Fares_Abbad_64kbps',
    everyayahBitrate: '64kbps فقط',
    islamicNetworkEdition: 'ar.faresabbad',
    islamicNetworkType: 'surahbysurah (سور فقط — لا آيةً بآية)',
    primarySource: 'EveryAyah فقط آيةً بآية',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6350 ملفاً، 0 غائبة. islamic.network سور فقط — لا يصلح احتياطياً آيةً بآية. بلا ترخيص موثَّق (EveryAyah بلا شروط منشورة).',
  ),
  ReciterEntry(
    id: 'dussary',
    nameAr: 'ياسر الدوسري',
    everyayahFolder: 'Yasser_Ad-Dussary_128kbps',
    everyayahBitrate: '128kbps',
    islamicNetworkEdition: 'ar.yasseraldossari',
    islamicNetworkType: 'surahbysurah (سور فقط — لا آيةً بآية)',
    primarySource: 'EveryAyah فقط آيةً بآية',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6350 ملفاً، 0 غائبة. islamic.network سور فقط. بلا ترخيص موثَّق.',
  ),
  ReciterEntry(
    id: 'rifai',
    nameAr: 'هاني الرفاعي',
    everyayahFolder: 'Hani_Rifai_192kbps',
    everyayahBitrate: '192kbps (يوجد 64 أيضاً)',
    islamicNetworkEdition: 'ar.hanirifai',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6236 ملفاً فقط — بلا ملفات بسملة SSS000 إطلاقاً (لا يؤثر على التشغيل آيةً بآية). islamic.network ‏192: 6236.',
  ),
  ReciterEntry(
    id: 'qatami',
    nameAr: 'ناصر القطامي',
    everyayahFolder: 'Nasser_Alqatami_128kbps',
    everyayahBitrate: '128kbps',
    islamicNetworkEdition: 'ar.nasseralqatami',
    islamicNetworkType: 'surahbysurah (سور فقط — لا آيةً بآية)',
    primarySource: 'EveryAyah فقط آيةً بآية',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6350 ملفاً، 0 غائبة. islamic.network سور فقط. بلا ترخيص موثَّق.',
  ),
  ReciterEntry(
    id: 'ali_jaber',
    nameAr: 'علي جابر',
    everyayahFolder: 'Ali_Jaber_64kbps',
    everyayahBitrate: '64kbps فقط',
    islamicNetworkEdition: null,
    islamicNetworkType: 'غائب إطلاقاً من قائمة API الحية',
    primarySource: 'EveryAyah فقط',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6349 ملفاً (6236 + 113 بسملة)، 0 غائبة. لا إصدار له في islamic.network إطلاقاً — بلا ترخيص موثَّق وبلا احتياطي.',
  ),
  ReciterEntry(
    id: 'basfar',
    nameAr: 'عبد الله بصفر',
    everyayahFolder: 'Abdullah_Basfar_192kbps',
    everyayahBitrate: '192kbps (يوجد 32/64 أيضاً)',
    islamicNetworkEdition: 'ar.abdullahbasfar',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل عبر EveryAyah — 6236 آية',
    // اكتشاف جديد في هذه الجولة (لم يذكره التدقيق ولا Phase 0):
    // ar.abdullahbasfar في islamic.network ‏192 = 6235 آية.
    notes:
        'جديد: ar.abdullahbasfar في islamic.network ‏192 = 6235 آية (ملف العدّ نفسه، أُعيد تأكيده 2026-11-25)؛ وفي ‏64 = 6236 كاملة. هوية الآية الغائبة لم يمكن تحديدها أيضاً. EveryAyah ‏192: 6236 آية + 78 بسملة فقط (6314 ملفاً)؛ وMD5 لهذا المجلد = 0 (تحقق بايت-بايت فقط).',
  ),
  ReciterEntry(
    id: 'ajamy',
    nameAr: 'أحمد بن علي العجمي',
    everyayahFolder: 'ahmed_ibn_ali_al_ajamy_128kbps',
    everyayahBitrate: '128kbps',
    islamicNetworkEdition: 'ar.ahmedajamy',
    islamicNetworkType: 'versebyverse',
    primarySource: 'islamic.network أولاً',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'المجلد بحروف صغيرة حرفياً (ahmed_ibn_ali_al_ajamy_128kbps) — وله بديلان آخران في EveryAyah يجب عدم الخلط بهما. islamic.network ‏128: 6236.',
  ),
  ReciterEntry(
    id: 'ghamadi',
    nameAr: 'سعد الغامدي',
    everyayahFolder: 'Ghamadi_40kbps',
    everyayahBitrate: '40kbps فقط — أدنى جودة في القائمة',
    islamicNetworkEdition: null,
    islamicNetworkType: 'غائب إطلاقاً من قائمة API الحية',
    primarySource: 'EveryAyah فقط',
    completenessAr: 'مكتمل لكن بجودة منخفضة — 6236 آية',
    notes:
        'EveryAyah: 6347 ملفاً (6236 + 111 بسملة)، 0 غائبة. لا نسخة أعلى من 40kbps. بلا ترخيص موثَّق وبلا احتياطي.',
  ),
  ReciterEntry(
    id: 'budair',
    nameAr: 'صلاح البدير',
    everyayahFolder: 'Salah_Al_Budair_128kbps',
    everyayahBitrate: '128kbps',
    islamicNetworkEdition: 'ar.salahalbudair',
    islamicNetworkType: 'surahbysurah (سور فقط — لا آيةً بآية)',
    primarySource: 'EveryAyah فقط آيةً بآية',
    completenessAr: 'مكتمل — 6236 آية',
    notes:
        'EveryAyah: 6350 ملفاً، 0 غائبة. islamic.network سور فقط. بلا ترخيص موثَّق.',
  ),
];

/// عدد الآيات القانوني الكامل (حفص).
const int kTotalAyahs = 6236;

/// عدد السور.
const int kTotalSurahs = 114;

/// عدد آيات كل سورة بالترتيب (1..114) — من everyayah.com/data/recitations.js
/// (حقل ayahCount)، والتحقق المحلي: المجموع = 6236.
/// يُستخدم لترجمة الرقم العام (1..6236 في islamic.network) إلى سورة:آية.
const List<int> ayahsPerSurah = [
  7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128,
  111, 110, 98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54,
  45, 83, 182, 88, 75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62,
  55, 78, 96, 29, 22, 24, 13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28,
  20, 56, 40, 31, 50, 40, 46, 42, 29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15,
  21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3, 9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6,
];

/// ترجمة الرقم العام (1..6236) إلى (سورة، آية). تُستخدم عند تحديد
/// الآية الغائبة في islamic.network بعد فحص CDN (انظر أداة الفحص
/// tools/probe_missing_ayah.py — لم يُنفَّذ الفحص بعد).
({int surah, int ayah}) globalAyahToSurahAyah(int globalNumber) {
  if (globalNumber < 1 || globalNumber > kTotalAyahs) {
    throw ArgumentError('رقم آية عام خارج 1..6236: $globalNumber');
  }
  var remaining = globalNumber;
  for (var s = 0; s < ayahsPerSurah.length; s++) {
    if (remaining <= ayahsPerSurah[s]) {
      return (surah: s + 1, ayah: remaining);
    }
    remaining -= ayahsPerSurah[s];
  }
  throw StateError('unreachable');
}

/// قالبا الرابطين آيةً بآية (من التدقيق §6.2 + risan):
/// EveryAyah: https://everyayah.com/data/{folder}/{SSS}{AAA}.mp3
/// islamic.network: https://cdn.islamic.network/quran/audio/{bitrate}/{edition}/{N}.mp3
/// حيث N رقم عام 1..6236، وSSS/AAA بثلاثة أرقام.
String everyayahAyahUrl(String folder, int surah, int ayah) {
  final s = surah.toString().padLeft(3, '0');
  final a = ayah.toString().padLeft(3, '0');
  return 'https://everyayah.com/data/$folder/$s$a.mp3';
}

String islamicNetworkAyahUrl(String edition, int bitrate, int globalNumber) =>
    'https://cdn.islamic.network/quran/audio/$bitrate/$edition/$globalNumber.mp3';
