// نماذج مدير الحزم — تلاوة
//
// Pure Dart — بلا اعتماد على Flutter، ليكون قابلاً للاختبار بـ `dart test`
// دون واجهة. يعتمد فقط على `dart:convert` و`package:crypto` (موجودة
// أصلاً في pubspec.yaml الخاص بتطبيق تلاوة).
//
// الحالة: كود مكتوب في 2026-11-25 ولم يُختبر بعد — لا على جهاز ولا بـ
// `dart test` (لا Dart/Flutter SDK في هذه البيئة). انظر DESIGN.md.

import 'dart:convert';

/// أنواع الحزم الاختيارية (الخطة §3.3 + التدقيق §7.2).
enum PackageKind {
  /// صفحات مصحف المدينة (صور 604) — التخطيط النصي (<1MB) في DB أصلاً
  /// وليس حزمة تنزيل.
  mushafImages,

  /// حزمة قارئ واحد (قرآن كامل بجودة واحدة) أو سورة واحدة منه.
  reciter,

  /// تفسير كبير واحد (ابن كثير / الطبري / القرطبي) — حزمة مستقلة.
  tafsir,

  /// ترجمة واحدة (لغة واحدة).
  translation,

  /// نموذج التسميع المحلي (yazinsai lite/full + ملف المرجع).
  aiModel,

  /// دروس (تجويد / نورانية / أطفال) — نص + صوت أمثلة.
  lessons,

  /// حزمة ورش (موجودة أصلاً: 1.6MB — تُدار هنا للتوحيد لا لإعادة التنزيل).
  warsh,
}

/// حالة الحزمة كما يراها المستخدم — ومنها حالة «متوفر دون إنترنت».
enum PackageStatus {
  /// غير مثبّتة إطلاقاً.
  notInstalled,

  /// تنزيل جارٍ الآن.
  downloading,

  /// تنزيل متوقف مؤقتاً (ملفات ‎.part محفوظة وقابلة للاستئناف).
  paused,

  /// جارٍ التحقق من سلامة الملفات (SHA-256).
  verifying,

  /// مثبّتة ومتحقَّق منها بالكامل — متوفرة دون إنترنت.
  installed,

  /// مثبّتة جزئياً: بعض الملفات موجودة وبعضها غائب/تالف.
  /// لا تُعرض كمكتملة، ولا يُحذف ما نُزّل منها تلقائياً.
  incomplete,

  /// فشل التنزيل أو التحقق (مع رسالة خطأ محفوظة في السجل).
  failed,
}

/// ملف واحد داخل حزمة.
class PackageFile {
  /// مسار نسبي داخل مجلد الحزمة، مثل `002/002255.mp3`.
  /// يُرفض أي مسار فيه `..` أو مسار مطلق (انظر [PackageManifest]).
  final String path;

  /// الحجم المتوقع بالبايت (من الـ manifest المنشور).
  final int sizeBytes;

  /// بصمة SHA-256 السداسية عشرية (64 حرفاً) — إلزامية لكل ملف.
  final String sha256;

  /// الرابط الأساسي للملف.
  final String sourceUrl;

  /// رابط احتياطي لنفس الملف (مضيف أو جودة أخرى) — يُستخدم عند
  /// فشل المصدر الأساسي، وهو ما يغطي ثغرة الآية الغائبة في
  /// islamic.network (انظر reciters.dart).
  final String? fallbackUrl;

  const PackageFile({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.sourceUrl,
    this.fallbackUrl,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'sourceUrl': sourceUrl,
        if (fallbackUrl != null) 'fallbackUrl': fallbackUrl,
      };

  factory PackageFile.fromJson(Map<String, dynamic> json) => PackageFile(
        path: json['path'] as String,
        sizeBytes: json['sizeBytes'] as int,
        sha256: json['sha256'] as String,
        sourceUrl: json['sourceUrl'] as String,
        fallbackUrl: json['fallbackUrl'] as String?,
      );
}

/// بيان الحزمة (manifest) — يُنشر مع الحزمة ويُعرض حجمه للمستخدم
/// قبل أي تنزيل. لا يُبنى أي ملف صوت/صورة داخل APK أبداً.
class PackageManifest {
  /// معرّف مستقر، مثل `reciter-husary-128` أو `mushaf-images-2600`.
  final String id;

  final PackageKind kind;

  /// إصدار الحزمة (يُرفع عند أي تغيير محتوى؛ التحديث لا يحذف
  /// المثبّت حتى يكتمل البديل ويُتحقق منه).
  final String version;

  /// العنوان العربي المعروض، مثل «الحصري — مرتل 128kbps (كامل)».
  final String titleAr;

  /// وصف قصير + المصدر + الترخيص/النسبة (يُعرض قبل التنزيل).
  final String sourceNote;

  /// كل ملفات الحزمة. الحجم الكلي = مجموع [PackageFile.sizeBytes].
  final List<PackageFile> files;

  /// عدد الآيات التي تغطيها الحزمة (للقرّاء: 6236 عند الاكتمال).
  /// `null` لغير حزم القرّاء.
  final int? ayahCount;

  /// آيات معروفة الغياب عند المصدر الأساسي (مثلاً ثغرة 6235 في
  /// islamic.network) — تُملأ من التحقق، لا تُخترع.
  final List<String> knownMissingUpstream;

  const PackageManifest({
    required this.id,
    required this.kind,
    required this.version,
    required this.titleAr,
    required this.sourceNote,
    required this.files,
    this.ayahCount,
    this.knownMissingUpstream = const [],
  });

  /// مجموع أحجام الملفات بالبايت — الرقم الذي يُعرض قبل التنزيل.
  int get totalBytes => files.fold<int>(0, (s, f) => s + f.sizeBytes);

  /// عدد الملفات.
  int get fileCount => files.length;

  /// تحقق دفاعي: لا مسارات مطلقة ولا `..`، ولا بصمات قصيرة،
  /// ولا روابط غير https، ولا معرّفات مكررة داخل الحزمة.
  /// أي فشل هنا = رفض الـ manifest كاملاً قبل أي تنزيل.
  void validate() {
    if (id.isEmpty || version.isEmpty || titleAr.isEmpty) {
      throw const FormatException('manifest: حقول هوية ناقصة');
    }
    final seen = <String>{};
    for (final f in files) {
      if (f.path.startsWith('/') ||
          f.path.contains('..') ||
          f.path.contains('\\')) {
        throw FormatException('manifest: مسار ملف غير آمن: ${f.path}');
      }
      if (!seen.add(f.path)) {
        throw FormatException('manifest: ملف مكرر: ${f.path}');
      }
      if (f.sizeBytes < 0 || f.sha256.length != 64) {
        throw FormatException('manifest: حجم/بصمة غير صالحة: ${f.path}');
      }
      for (final u in [f.sourceUrl, f.fallbackUrl]) {
        if (u != null && !u.startsWith('https://')) {
          throw FormatException('manifest: رابط غير https: $u');
        }
      }
    }
    if (ayahCount != null && ayahCount! <= 0) {
      throw const FormatException('manifest: ayahCount غير صالح');
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'version': version,
        'titleAr': titleAr,
        'sourceNote': sourceNote,
        'files': files.map((f) => f.toJson()).toList(),
        if (ayahCount != null) 'ayahCount': ayahCount,
        if (knownMissingUpstream.isNotEmpty)
          'knownMissingUpstream': knownMissingUpstream,
      };

  factory PackageManifest.fromJson(Map<String, dynamic> json) {
    final m = PackageManifest(
      id: json['id'] as String,
      kind: PackageKind.values.byName(json['kind'] as String),
      version: json['version'] as String,
      titleAr: json['titleAr'] as String,
      sourceNote: json['sourceNote'] as String,
      files: (json['files'] as List)
          .map((e) => PackageFile.fromJson(e as Map<String, dynamic>))
          .toList(),
      ayahCount: json['ayahCount'] as int?,
      knownMissingUpstream: (json['knownMissingUpstream'] as List?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );
    m.validate();
    return m;
  }

  String toJsonString() => jsonEncode(toJson());

  factory PackageManifest.fromJsonString(String s) =>
      PackageManifest.fromJson(jsonDecode(s) as Map<String, dynamic>);
}

/// سجل حزمة في السجل المحلي (registry): الـ manifest + حالة التشغيل.
class PackageRecord {
  final PackageManifest manifest;
  PackageStatus status;

  /// بايتات نُزّلت فعلاً (مجموع ملفات ‎.part + المكتملة).
  int downloadedBytes;

  /// آيات/ملفات غابت عند المصدر الأساسي وثبت غيابها أثناء التنزيل
  /// (تُغطى بالاحتياطي أو تبقى قيداً معلناً — لا تُخفى).
  List<String> missingUpstream;

  /// آخر خطأ (إن وُجد) — يُعرض للمستخدم حرفياً.
  String? lastError;

  DateTime? installedAt;
  DateTime? verifiedAt;

  PackageRecord({
    required this.manifest,
    this.status = PackageStatus.notInstalled,
    this.downloadedBytes = 0,
    this.missingUpstream = const [],
    this.lastError,
    this.installedAt,
    this.verifiedAt,
  });

  /// متوفرة دون إنترنت؟ فقط المثبّتة المتحقَّق منها.
  bool get availableOffline =>
      status == PackageStatus.installed && verifiedAt != null;

  /// نسبة التقدم 0..1 (من البايتات لا من عدد الملفات).
  double get progress => manifest.totalBytes == 0
      ? 0
      : (downloadedBytes / manifest.totalBytes).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'manifest': manifest.toJson(),
        'status': status.name,
        'downloadedBytes': downloadedBytes,
        'missingUpstream': missingUpstream,
        if (lastError != null) 'lastError': lastError,
        if (installedAt != null)
          'installedAt': installedAt!.toIso8601String(),
        if (verifiedAt != null) 'verifiedAt': verifiedAt!.toIso8601String(),
      };

  factory PackageRecord.fromJson(Map<String, dynamic> json) =>
      PackageRecord(
        manifest:
            PackageManifest.fromJson(json['manifest'] as Map<String, dynamic>),
        status: PackageStatus.values.byName(json['status'] as String),
        downloadedBytes: json['downloadedBytes'] as int? ?? 0,
        missingUpstream: (json['missingUpstream'] as List?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
        lastError: json['lastError'] as String?,
        installedAt: json['installedAt'] == null
            ? null
            : DateTime.parse(json['installedAt'] as String),
        verifiedAt: json['verifiedAt'] == null
            ? null
            : DateTime.parse(json['verifiedAt'] as String),
      );
}
