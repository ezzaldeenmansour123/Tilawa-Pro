// نماذج بيانات تلاوة — نُقلت حرفياً من lib/db.dart (الأسطر 46-100) في التزام 07204f14.
// مسودة Phase 1 (2026-11-25): لم يُتحقق من التجميع — لا Flutter/Dart SDK في هذه البيئة.
// كود نقي 100%: بلا Flutter وبلا استيرادات؛ لا يعتمد على شيء.
// ملاحظة: معرّف القرطبي 90 في onlineTafsirs غير موثَّق (Phase 0) — القيمة مثبَّتة كما هي ولا يُدَّعى صحتها.

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
