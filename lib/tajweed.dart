/// أحكام التجويد — فهرس القواعد ونموذج بيانات التلوين (Phase 1).
///
/// ملف Dart نقي (بلا استيراد Flutter) ليبقى قابلاً للاختبار دون واجهة.
///
/// # حالة البيانات — اقرأ قبل الاستخدام
/// مصدر بيانات مواضع الأحكام هو مشروع `cpfair/quran-tajweed`
/// (ملف `output/tajweed.hafs.uthmani-pause-sajdah.json`)، مرخّص
/// Creative Commons Attribution 4.0 (CC BY 4.0) — الترخيص موثّق،
/// والاستخدام يتطلب الإسناد (انظر [tajweedAttribution]).
///
/// لكن **لا توجد بيانات مضمّنة في هذا الملف ولا في التطبيق**:
/// إزاحات ذلك المشروع مبنية على نص تنزيل Uthmani من عام 2017، بينما
/// نص هذا التطبيق هو تنزيل Uthmani v1.1، وقد ثبت اختلاف بنيوي واحد
/// على الأقل (نص 2017 يُلحق البسملة بأول آية في كل سورة، وقاعدة
/// التطبيق لا تفعل)، إضافة إلى تحذير المشروع نفسه من تغيّر ترميز
/// علامات الوقف/التنوين منذ 2017. تطبيق الإزاحات دون محاذاة قد
/// يلوّن الحرف الخطأ — لذلك لا تُدمج البيانات قبل أن يمرّ فحص
/// المحاذاة `tools/verify_tajweed.py` على الآيات الـ 6,236 كلها.
///
/// ما يقدّمه هذا الملف الآن:
/// 1. فهرس الأحكام الـ 18 (رواية حفص عن عاصم فقط، بلا خلط روايات)
///    مع تعريف موجز لكل حكم ولون مقترح لمفتاح الألوان.
/// 2. نموذج [TajweedAnnotation] و[TajweedData] الذي ستُملأ به
///    البيانات بعد التحقق، مع حارس [tajweedOffsetsFit] الذي يرفض
///    أي إزاحة خارج حدود نص الآية.
/// 3. [loadTajweedData] التي تعيد حاليًا بيانات غير متاحة — تتبدّل
///    إلى تحميل ملف البيانات بعد التحقق، لا قبله.
///
/// لا يولّد هذا الملف نصًا قرآنيًا ولا يعدّله: التلوين (عند تفعيله)
/// يغيّر لون عرض الحروف فقط، والنص المعروض يبقى `Ayah.text` حرفيًا.
library;

/// حكم تجويد واحد: معرّفه كما في بيانات cpfair، واسمه العربي،
/// وتعريف موجز، ولون العرض المقترح (ARGB).
class TajweedRule {
  final String id;
  final String nameAr;
  final String definition;
  final int color;
  const TajweedRule(this.id, this.nameAr, this.definition, this.color);
}

/// الأحكام الـ 18 من `cpfair/quran-tajweed` (رواية حفص عن عاصم).
/// التعريفات موجزة من كتب التجويد المعروفة، والألوان لوحة تقليدية
/// مقترحة لمفتاح الألوان — لا علاقة لها ببيانات المواضع نفسها.
const tajweedRules = <TajweedRule>[
  TajweedRule('ghunnah', 'الغُنّة',
      'غُنّة في النون والميم المشددتين، وفي الإدغام بغنة والإخفاء، تُنطق من الخيشوم بمقدار حركتين.',
      0xFFE67E22),
  TajweedRule('ikhfa', 'الإخفاء الحقيقي',
      'إخفاء النون الساكنة أو التنوين عند حروف الإخفاء الخمسة عشر مع غنة.', 0xFF2E86C1),
  TajweedRule('ikhfa_shafawi', 'الإخفاء الشفوي',
      'إخفاء الميم الساكنة عند الباء مع غنة.', 0xFF5DADE2),
  TajweedRule('idghaam_ghunnah', 'الإدغام بغنة',
      'إدغام النون الساكنة أو التنوين في أحد حروف (ينمو) مع غنة.', 0xFF27AE60),
  TajweedRule('idghaam_no_ghunnah', 'الإدغام بغير غنة',
      'إدغام النون الساكنة أو التنوين في اللام أو الراء بغير غنة.', 0xFF16A085),
  TajweedRule('idghaam_shafawi', 'الإدغام الشفوي',
      'إدغام الميم الساكنة في الميم مع غنة.', 0xFF8E44AD),
  TajweedRule('idghaam_mutajanisayn', 'إدغام المتجانسين',
      'إدغام حرفين متجانسين: اتحدا مخرجًا واختلفا صفةً.', 0xFF7D3C98),
  TajweedRule('idghaam_mutaqaribayn', 'إدغام المتقاربين',
      'إدغام حرفين متقاربين في المخرج والصفة.', 0xFF6C3483),
  TajweedRule('iqlab', 'الإقلاب',
      'قلب النون الساكنة أو التنوين ميمًا عند الباء مع غنة.', 0xFFC0392B),
  TajweedRule('qalqalah', 'القلقلة',
      'اضطراب صوت الحرف الساكن من حروف (قطب جد) عند النطق به.', 0xFF935116),
  TajweedRule('madd_2', 'المد الطبيعي (حركتان)',
      'مد طبيعي بمقدار حركتين.', 0xFF1A5276),
  TajweedRule('madd_246', 'المد العارض / مد اللين (2 أو 4 أو 6)',
      'مد عارض للسكون أو مد لين، يُمد حركتين أو أربعًا أو ستًا.', 0xFF7E5109),
  TajweedRule('madd_6', 'المد اللازم (6 حركات)',
      'مد لازم بمقدار ست حركات.', 0xFF7B241C),
  TajweedRule('madd_munfasil', 'المد المنفصل (4 أو 5 حركات)',
      'مد منفصل: حرف مد بعده همزة في كلمة أخرى، يُمد أربعًا أو خمسًا.', 0xFF1E8449),
  TajweedRule('madd_muttasil', 'المد المتصل (4 أو 5 حركات)',
      'مد متصل: حرف مد بعده همزة في الكلمة نفسها، يُمد أربعًا أو خمسًا.', 0xFF148F77),
  TajweedRule('hamzat_wasl', 'همزة الوصل',
      'همزة وصل تُنطق عند الابتداء وتسقط وصلًا.', 0xFF616A6B),
  TajweedRule('lam_shamsiyyah', 'اللام الشمسية',
      'لام (أل) لا تُنطق وتُدغم في الحرف الشمسي بعدها.', 0xFFB7950B),
  TajweedRule('silent', 'حروف لا تُنطق',
      'حروف تُكتب ولا تُنطق في القراءة.', 0xFF979A9A),
];

/// خريطة سريعة من معرّف الحكم إلى قاعدته.
final tajweedRuleById = {for (final r in tajweedRules) r.id: r};

/// نص الإسناد المطلوب عند عرض بيانات التجويد أو تضمينها
/// (شرط رخصة CC BY 4.0).
const tajweedAttribution =
    'مصدر بيانات مواضع الأحكام (عند تضمينها بعد التحقق): مشروع '
    'quran-tajweed لـ Collin Fair (github.com/cpfair/quran-tajweed)، '
    'برخصة Creative Commons Attribution 4.0 International (CC BY 4.0). '
    'البيانات مبنية على معلومات من ReciteQuran.com ومصاحف التجويد '
    'لدار المعرفة وغيرها، وهي لرواية حفص عن عاصم فقط. نص القرآن نفسه '
    'من مشروع تنزيل (tanzil.net) كما هو موثق في صفحة المكتبة والمصادر.';

/// موضع حكم تجويد واحد داخل آية: إزاحتا البداية والنهاية هما إزاحتا
/// مواضع الحروف (codepoints) داخل نص الآية — في الإحداثيات نفسها
/// التي يعرّفها ملف بيانات cpfair بعد محاذاته مع نص التطبيق.
class TajweedAnnotation {
  final int surah;
  final int ayah;
  final String rule;
  final int start;
  final int end;
  const TajweedAnnotation(this.surah, this.ayah, this.rule, this.start, this.end);

  /// معرّف الآية العام (1..6236) كما في جدول ayahs — يُحسب من
  /// (surah, ayah) خارج هذا الملف عند التحميل.
  @override
  String toString() => 'TajweedAnnotation($surah:$ayah $rule $start..$end)';
}

/// بيانات تلوين التجويد لآيات المصحف.
///
/// [available] يبقى false حتى تُدمج بيانات موثّقة المحاذاة.
/// [byAyahId] يربط المعرّف العام للآية بقائمة مواضع أحكامها.
class TajweedData {
  final Map<int, List<TajweedAnnotation>> byAyahId;
  final bool available;
  final String status;
  const TajweedData(
      {required this.byAyahId, required this.available, required this.status});

  /// الحالة الحالية: لا بيانات مضمّنة — التلوين متوقف.
  factory TajweedData.unavailable() => const TajweedData(
        byAyahId: {},
        available: false,
        status: 'بيانات التجويد غير مضمّنة بعد — بانتظار التحقق من '
            'المحاذاة مع نص التطبيق (tools/verify_tajweed.py).',
      );

  List<TajweedAnnotation> annotationsFor(int ayahId) => byAyahId[ayahId] ?? const [];

  int get annotationCount =>
      byAyahId.values.fold(0, (n, l) => n + l.length);
}

/// حارس الحدود: هل تقع كل إزاحة داخل نص الآية، وهل معرّف الحكم
/// معروف؟ أي فشل هنا يعني أن البيانات لا تُطبَّق على هذا النص.
/// (لا يتحقق من صحة الحكم تجويديًا — تلك مهمة فحص المحاذاة
/// في tools/verify_tajweed.py — بل يمنع فقط التلوين خارج النص.)
bool tajweedOffsetsFit(String text, List<TajweedAnnotation> annotations) {
  final len = text.runes.length;
  for (final a in annotations) {
    if (!tajweedRuleById.containsKey(a.rule)) return false;
    if (a.start < 0 || a.end < a.start || a.end > len) return false;
  }
  return true;
}

/// تحميل بيانات التجويد.
/// حاليًا: لا يوجد ملف بيانات مضمّن، فتعيد بيانات غير متاحة.
/// بعد اكتمال التحقق تُبدَّل هذه الدالة بتحميل ملف البيانات
/// الموثّق (JSON مضغوط في الأصول) والتحقق من حدوده عبر
/// [tajweedOffsetsFit] قبل أي استخدام.
Future<TajweedData> loadTajweedData() async => TajweedData.unavailable();
