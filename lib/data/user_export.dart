// ─────────────────────────────────────────────────────────────────────────────
// تصدير/استيراد بيانات المستخدم — «تلاوة» (Phase 1)
// الملف: lib/data/user_export.dart  (منطق نقي — بلا Flutter وبلا IO)
// ─────────────────────────────────────────────────────────────────────────────
// الحالة: كود جاهز للاختبار على الجهاز — «لم يُختبر بعد» على جهاز حقيقي
// (لا Flutter/Dart SDK في بيئة الإعداد؛ المنطق نفسه مُختبَر محلياً بمرآة
// Python في test_export.py — انظر phase1/EXPORT_IMPORT.md).
//
// المصدر الموثَّق للحقول: lib/main.dart — صنف UserData (الأسطر 111–203)
//   و AppSettings للإعدادات (لا تُصدَّر) — انظر EXPORT_IMPORT.md §1.
// صيغة الملف متوافقة مع MIGRATION_PLAN_2026-11-25.md §4.2 مع إضافتين:
//   (1) حقل sha256 اختياري لسلامة الحمولة، (2) وضعا استيراد: دمج (افتراضي)
//   واستبدال (يتطلب تأكيداً صريحاً + نسخة احتياطية تلقائية).
//
// الاعتماديات: dart:convert + package:crypto (موجودة أصلاً في pubspec.yaml
// ^3.0.6). لا حزمة جديدة.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:crypto/crypto.dart';

/// اسم الصيغة — يجب أن يطابق حرفياً، وإلا يُرفض الملف.
const String kExportFormat = 'tilawa-user-export';

/// إصدار الصيغة الوحيد المدعوم حالياً.
const int kExportFormatVersion = 1;

/// حدود موثَّقة من الكود:
/// - معرّف الآية العالمي 1..6236 (build_db.py: total='6236').
/// - الربع في الختمة 1..240، والقيمة 241 تعني «الختمة مكتملة»
///   (UserData.completeWird — main.dart:189: clamp(1, 241)).
/// - السجل سقفه 100 (UserData.touch — main.dart:176).
const int kMinAyahId = 1;
const int kMaxAyahId = 6236;
const int kMinKhatmahQuarter = 1;
const int kMaxKhatmahQuarter = 241;
const int kMaxHistory = 100;

/// معرّفات القرّاء الـ17 الموثقين (db.dart:78–84 للسبعة الأوائل،
/// وfeatures/packages/reciters.dart للعشرة الجدد — قائمة reciters17).
/// أي معرّف قارئ آخر في ملف مستورَد يُعزَل (quarantine) ولا يُستورَد.
/// قرار موثق 2026-11-25 (بناء تلاوة برو الكامل): وُسّعت المجموعة من 7
/// إلى 17 لأن العشرة الجدد موثقو الاكتمال (6236 آية) في سجل التطبيق
/// نفسه، فإسقاطهم عند الاستيراد كان فقدان بيانات لا حماية.
const Set<String> kKnownReciterIds = {
  'afasy',
  'husary',
  'basit',
  'minshawi',
  'sudais',
  'muaiqly',
  'shuraym',
  'shaatree',
  'fares',
  'dussary',
  'rifai',
  'qatami',
  'ali_jaber',
  'basfar',
  'ajamy',
  'ghamadi',
  'budair',
};

/// وضع الاستيراد.
enum ImportMode {
  /// دمج آمن (الافتراضي): لا يحذف أي سجل موجود أبداً.
  /// - المفضلة: اتحاد مع حفظ ترتيب الموجود أولاً ثم إلحاق الجديد.
  /// - السجل: الأحدث أولاً — المستورَد أولاً ثم الموجود غير المكرر، بسقف 100.
  /// - الوسوم/الملاحظات: المستورَد يغلب على المفتاح نفسه فقط؛
  ///   المفاتيح الغائبة عن الملف تبقى كما هي (لا تُمسح).
  /// - الختمة: الأكبر بين الحالية والمستورَدة (التقدم لا يتراجع).
  /// - القرّاء المفضلون: اتحاد مع حفظ الترتيب. warsh_ready: OR منطقي.
  merge,

  /// استبدال كامل: يحذف كل بيانات المستخدم الحالية ويضع مكانها ملف
  /// التصدير. يتطلب تأكيداً صريحاً (confirmReplace == true) وإلا رُفض،
  /// ويتطلب نسخة احتياطية تلقائية للحالة الحالية قبل الكتابة
  /// (ينفذها محوّل IO في user_export_io.dart، لا هذا الملف).
  replace,
}

/// سجل معزول: قيمة رُفضت أثناء التحقق مع سببها، دون إيقاف الاستيراد.
class QuarantinedRecord {
  final String field;
  final Object? value;
  final String reason;
  const QuarantinedRecord(this.field, this.value, this.reason);

  Map<String, Object?> toJson() =>
      {'field': field, 'value': value, 'reason': reason};
}

/// نتيجة التحقق المسبق (dry-run) — لا تكتب شيئاً.
class ExportValidation {
  /// true إذا كان الملف صالحاً للاستيراد (قد تكون فيه سجلات معزولة).
  final bool isValid;

  /// سبب الرفض الكامل إن كان isValid == false (وإلا null).
  final String? rejectionReason;

  /// البيانات الصالحة المستخرجة (null إن رُفض الملف كاملاً).
  final UserExportData? data;

  /// السجلات المعزولة أثناء التحقق (لا تُستورَد).
  final List<QuarantinedRecord> quarantined;

  /// تحذيرات غير مانعة (مثال: ملف قديم بلا sha256).
  final List<String> warnings;

  /// أعداد السجلات الصالحة، للعرض على المستخدم قبل التأكيد.
  Map<String, int> get counts => data == null
      ? const {}
      : {
          'favorites': data!.favorites.length,
          'history': data!.history.length,
          'tags': data!.tags.length,
          'notes': data!.notes.length,
          'fav_reciters': data!.favReciters.length,
        };

  const ExportValidation({
    required this.isValid,
    this.rejectionReason,
    this.data,
    this.quarantined = const [],
    this.warnings = const [],
  });

  factory ExportValidation.rejected(String reason) =>
      ExportValidation(isValid: false, rejectionReason: reason);
}

/// بيانات المستخدم القابلة للتصدير/الاستيراد — صورة واحدة متسقة.
class UserExportData {
  /// معرّفات آيات مفضلة، بترتيب الإضافة (كما في UserData.ids).
  final List<int> favorites;

  /// معرّفات آيات في السجل، الأحدث أولاً (كما في UserData.history).
  final List<int> history;

  /// وسم واحد لكل آية (كما في UserData.tags).
  final Map<int, String> tags;

  /// ملاحظة واحدة لكل آية (كما في UserData.notes).
  final Map<int, String> notes;

  /// الربع الحالي في الختمة 1..241 (241 = مكتملة).
  final int khatmahQuarter;

  /// معرّفات القرّاء المفضلين، بترتيب الإضافة.
  final List<String> favReciters;

  /// علم جاهزية حزمة ورش.
  final bool warshReady;

  const UserExportData({
    this.favorites = const [],
    this.history = const [],
    this.tags = const {},
    this.notes = const {},
    this.khatmahQuarter = 1,
    this.favReciters = const [],
    this.warshReady = false,
  });

  /// الحالة الفارغة (تثبيت جديد بلا بيانات).
  factory UserExportData.empty() => const UserExportData();

  /// التمثيل القانوني (canonical) للحمولة — مفاتيح مرتبة، بلا مسافات —
  /// وهو ما يُحسب عليه sha256. الترتيب القانوني محدد بدقة ليتطابق مع
  /// مرآة Python حرفياً:
  /// - مفاتيح المستوى الأعلى أبجدياً: favorites, fav_reciters, history,
  ///   khatmah_q, notes, tags, warsh_ready.
  /// - مفاتيح الوسوم/الملاحظات رقمياً تصاعدياً (2، 7، 255 — لا معجمياً).
  /// ملاحظة: jsonEncode في Dart لا يهرّب الحروف غير ASCII، فيطابق
  /// ensure_ascii=False في Python.
  Map<String, Object?> _canonicalDataMap() => {
        'favorites': favorites,
        'fav_reciters': favReciters,
        'history': history,
        'khatmah_q': khatmahQuarter,
        'notes': _sortedStringKeyMap(notes),
        'tags': _sortedStringKeyMap(tags),
        'warsh_ready': warshReady,
      };

  /// يبني خريطة مفاتيحها نصية مرتبة رقمياً تصاعدياً.
  static Map<String, String> _sortedStringKeyMap(Map<int, String> m) {
    final keys = m.keys.toList()..sort();
    return {for (final k in keys) '$k': m[k]!};
  }

  /// بصمة SHA-256 السداسية للحمولة القانونية.
  String get sha256 =>
      sha256Hex(jsonEncode(_canonicalDataMap(), toEncodable: (e) => e));

  /// ملف التصدير الكامل كما يُكتب على القرص.
  Map<String, Object?> toExportJson({String? appVersion}) => {
        'format': kExportFormat,
        'format_version': kExportFormatVersion,
        'exported_at': DateTime.now().toIso8601String(),
        if (appVersion != null) 'app_version': appVersion,
        'sha256': sha256,
        'data': _canonicalDataMap(),
      };

  /// نص JSON لملف التصدير.
  String toExportString({String? appVersion}) =>
      jsonEncode(toExportJson(appVersion: appVersion));

  // ── الدمج الآمن (لا يحذف سجلاً موجوداً أبداً) ──────────────────────────
  UserExportData mergeWith(UserExportData incoming) {
    // المفضلة: الموجود أولاً بترتيبه، ثم الجديد غير المكرر.
    final favs = [...favorites];
    for (final id in incoming.favorites) {
      if (!favs.contains(id)) favs.add(id);
    }
    // السجل: المستورَد أولاً (الأحدث)، ثم الموجود غير المكرر، بسقف 100.
    final hist = [...incoming.history];
    for (final id in history) {
      if (!hist.contains(id)) hist.add(id);
    }
    final histCapped =
        hist.length > kMaxHistory ? hist.sublist(0, kMaxHistory) : hist;
    // الوسوم/الملاحظات: المستورَد يغلب على المفتاح نفسه فقط.
    final mergedTags = {...tags, ...incoming.tags};
    final mergedNotes = {...notes, ...incoming.notes};
    return UserExportData(
      favorites: favs,
      history: histCapped,
      tags: mergedTags,
      notes: mergedNotes,
      // التقدم لا يتراجع: الأكبر بين الحالي والمستورَد.
      khatmahQuarter: incoming.khatmahQuarter > khatmahQuarter
          ? incoming.khatmahQuarter
          : khatmahQuarter,
      favReciters: [
        ...favReciters,
        ...incoming.favReciters.where((r) => !favReciters.contains(r)),
      ],
      warshReady: warshReady || incoming.warshReady,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UserExportData &&
      _listEq(favorites, other.favorites) &&
      _listEq(history, other.history) &&
      _mapEq(tags, other.tags) &&
      _mapEq(notes, other.notes) &&
      khatmahQuarter == other.khatmahQuarter &&
      _listEq(favReciters, other.favReciters) &&
      warshReady == other.warshReady;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(favorites),
        Object.hashAll(history),
        Object.hashAll(tags.entries.map((e) => '${e.key}:${e.value}')),
        Object.hashAll(notes.entries.map((e) => '${e.key}:${e.value}')),
        khatmahQuarter,
        Object.hashAll(favReciters),
        warshReady,
      );

  static bool _listEq<T>(List<T> a, List<T> b) =>
      a.length == b.length &&
      a.asMap().entries.every((e) => e.value == b[e.key]);

  static bool _mapEq<K, V>(Map<K, V> a, Map<K, V> b) =>
      a.length == b.length &&
      a.entries.every((e) => b[e.key] == e.value);
}

/// يحسب SHA-256 السداسي لنص UTF-8 (غلاف صغير فوق package:crypto
/// ليسهل اختبار المنطق ومرآته في Python).
String sha256Hex(String input) =>
    sha256.convert(utf8.encode(input)).toString();

// ── التحقق المسبق (dry-run): يقرأ نص ملف ولا يكتب شيئاً ──────────────────

/// يحلّل نص ملف تصدير ويتحقق منه كاملاً قبل أي كتابة.
/// يُرجع [ExportValidation]: إما صالحاً (+ بيانات + معزولات + تحذيرات)
/// أو مرفوضاً كاملاً مع سبب واضح.
ExportValidation validateExportText(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (e) {
    return ExportValidation.rejected('ملف JSON غير صالح: $e');
  }
  if (decoded is! Map<String, dynamic>) {
    return ExportValidation.rejected('ملف التصدير ليس كائن JSON.');
  }
  return validateExportJson(decoded);
}

/// التحقق من كائن JSON محلَّل (يفصل التحليل عن التحقق ليسهل الاختبار).
ExportValidation validateExportJson(Map<String, dynamic> json) {
  // 1. الصيغة.
  if (json['format'] != kExportFormat) {
    return ExportValidation.rejected(
        'صيغة غير معروفة: ${json['format']} (المتوقع "$kExportFormat").');
  }
  // 2. الإصدار: توافق مع الإصدارات — 1 فقط مدعوم؛ الأحدث يُرفض صراحةً
  // (لا يُفسَّر تخميناً)، والأقدم غير موجود أصلاً.
  final version = json['format_version'];
  if (version is! int) {
    return ExportValidation.rejected('حقل format_version مفقود أو ليس عدداً.');
  }
  if (version > kExportFormatVersion) {
    return ExportValidation.rejected(
        'ملف التصدير من إصدار أحدث ($version) — حدِّث التطبيق أولاً.');
  }
  if (version < kExportFormatVersion) {
    return ExportValidation.rejected(
        'ملف التصدير من إصدار قديم غير مدعوم ($version).');
  }
  // 3. الحمولة موجودة وكائن.
  final dataRaw = json['data'];
  if (dataRaw is! Map<String, dynamic>) {
    return ExportValidation.rejected('حقل data مفقود أو ليس كائناً.');
  }

  final warnings = <String>[];
  final quarantined = <QuarantinedRecord>[];

  // 4. سلامة الحمولة: sha256 إن وُجد يجب أن يطابق؛ وإن غاب (ملفات قديمة
  // من خطة الترحيل §4.2 بلا بصمة) يُقبل مع تحذير + تحقق بنيوي كامل.
  final claimed = json['sha256'];
  if (claimed is String) {
    final recomputed = _checksumOfDataMap(dataRaw);
    if (claimed.toLowerCase() != recomputed) {
      return ExportValidation.rejected(
          'بصمة SHA-256 لا تطابق محتوى الملف — الملف تالف أو معدل.');
    }
  } else {
    warnings.add('الملف بلا بصمة SHA-256 (صيغة قديمة) — تم التحقق البنيوي فقط.');
  }

  // 5. تحقق بنيوي حقلاً بحقلاً؛ الفاسد يُعزَل ولا يوقف الاستيراد.
  // الحقل الغائب كلياً يُعامل كفارغ مع تحذير (لا بصمت — حتى لا يُخفى فقد).
  List<int> favs =
      _validAyahIdList(dataRaw['favorites'], 'favorites', quarantined, warnings);
  List<int> hist =
      _validAyahIdList(dataRaw['history'], 'history', quarantined, warnings);
  if (hist.length > kMaxHistory) {
    warnings.add('السجل في الملف أطول من $kMaxHistory — قُصّ إلى $kMaxHistory.');
    hist = hist.sublist(0, kMaxHistory);
  }
  // إزالة تكرار مع حفظ أول ظهور وترتيبه.
  favs = _dedupKeepOrder(favs, 'favorites', quarantined);
  hist = _dedupKeepOrder(hist, 'history', quarantined);

  final tags =
      _validAyahStringMap(dataRaw['tags'], 'tags', quarantined, warnings);
  final notes =
      _validAyahStringMap(dataRaw['notes'], 'notes', quarantined, warnings);

  int khatmah = 1;
  final khatmahRaw = dataRaw['khatmah_q'];
  if (khatmahRaw == null) {
    warnings.add('حقل khatmah_q غائب — استُخدم الافتراضي 1.');
  } else if (khatmahRaw is int &&
      khatmahRaw >= kMinKhatmahQuarter &&
      khatmahRaw <= kMaxKhatmahQuarter) {
    khatmah = khatmahRaw;
  } else {
    quarantined.add(QuarantinedRecord('khatmah_q', khatmahRaw,
        'خارج النطاق $kMinKhatmahQuarter..$kMaxKhatmahQuarter أو ليس عدداً'));
  }

  final reciters = <String>[];
  final recRaw = dataRaw['fav_reciters'];
  if (recRaw == null) {
    warnings.add('حقل fav_reciters غائب — استُخدمت قائمة فارغة.');
  } else if (recRaw is List) {
    for (final r in recRaw) {
      if (r is String && kKnownReciterIds.contains(r)) {
        if (!reciters.contains(r)) reciters.add(r);
      } else {
        quarantined.add(
            QuarantinedRecord('fav_reciters', r, 'معرّف قارئ غير معروف'));
      }
    }
  } else {
    quarantined.add(QuarantinedRecord(
        'fav_reciters', recRaw, 'ليس قائمة — تجوهل الحقل كاملاً'));
  }

  bool warsh = false;
  final warshRaw = dataRaw['warsh_ready'];
  if (warshRaw == null) {
    warnings.add('حقل warsh_ready غائب — استُخدم false.');
  } else if (warshRaw is bool) {
    warsh = warshRaw;
  } else {
    quarantined.add(
        QuarantinedRecord('warsh_ready', warshRaw, 'ليس قيمة منطقية'));
  }

  return ExportValidation(
    isValid: true,
    data: UserExportData(
      favorites: favs,
      history: hist,
      tags: tags,
      notes: notes,
      khatmahQuarter: khatmah,
      favReciters: reciters,
      warshReady: warsh,
    ),
    quarantined: quarantined,
    warnings: warnings,
  );
}

/// يعيد حساب بصمة الحمولة من خريطة data الخام كما وردت في الملف،
/// بإعادة بنائها قانونياً بالترتيب نفسه الذي يستخدمه المصدِّر
/// (مفاتيح عليا أبجدية؛ مفاتيح الوسوم/الملاحظات رقمية تصاعدياً).
String _checksumOfDataMap(Map<String, dynamic> dataRaw) {
  final canonical = <String, Object?>{};
  for (final k in [
    'favorites',
    'fav_reciters',
    'history',
    'khatmah_q',
    'notes',
    'tags',
    'warsh_ready',
  ]) {
    if (!dataRaw.containsKey(k)) continue;
    final v = dataRaw[k];
    if ((k == 'notes' || k == 'tags') && v is Map) {
      // إعادة ترتيب المفاتيح رقمياً تصاعدياً (غير الرقمي يأتي أخيراً معجمياً).
      final entries = v.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse('${a.key}');
          final bi = int.tryParse('${b.key}');
          if (ai != null && bi != null) return ai.compareTo(bi);
          if (ai != null) return -1;
          if (bi != null) return 1;
          return '${a.key}'.compareTo('${b.key}');
        });
      canonical[k] = {for (final e in entries) '${e.key}': e.value};
    } else {
      canonical[k] = v;
    }
  }
  return sha256Hex(jsonEncode(canonical));
}

List<int> _validAyahIdList(Object? raw, String field,
    List<QuarantinedRecord> quarantined, List<String> warnings) {
  if (raw == null) {
    warnings.add('حقل $field غائب — استُخدمت قائمة فارغة.');
    return [];
  }
  if (raw is! List) {
    quarantined.add(
        QuarantinedRecord(field, raw, 'ليس قائمة — تجوهل الحقل كاملاً'));
    return [];
  }
  final out = <int>[];
  for (final v in raw) {
    if (v is int && v >= kMinAyahId && v <= kMaxAyahId) {
      out.add(v);
    } else {
      quarantined.add(QuarantinedRecord(
          field, v, 'معرّف آية خارج النطاق $kMinAyahId..$kMaxAyahId'));
    }
  }
  return out;
}

Map<int, String> _validAyahStringMap(Object? raw, String field,
    List<QuarantinedRecord> quarantined, List<String> warnings) {
  if (raw == null) {
    warnings.add('حقل $field غائب — استُخدمت خريطة فارغة.');
    return {};
  }
  if (raw is! Map) {
    quarantined.add(
        QuarantinedRecord(field, raw, 'ليس كائناً — تجوهل الحقل كاملاً'));
    return {};
  }
  final out = <int, String>{};
  for (final e in raw.entries) {
    final id = int.tryParse('${e.key}');
    if (id == null || id < kMinAyahId || id > kMaxAyahId) {
      quarantined.add(QuarantinedRecord(field, e.key, 'مفتاح آية غير صالح'));
      continue;
    }
    if (e.value is! String || (e.value as String).trim().isEmpty) {
      quarantined.add(QuarantinedRecord(
          field, e.key, 'قيمة فارغة أو ليست نصاً — أُسقطت'));
      continue;
    }
    out[id] = (e.value as String).trim();
  }
  return out;
}

List<int> _dedupKeepOrder(
    List<int> ids, String field, List<QuarantinedRecord> quarantined) {
  final seen = <int>{};
  final out = <int>[];
  for (final id in ids) {
    if (seen.add(id)) {
      out.add(id);
    } else {
      quarantined.add(QuarantinedRecord(field, id, 'تكرار — حُفظ أول ظهور'));
    }
  }
  return out;
}
