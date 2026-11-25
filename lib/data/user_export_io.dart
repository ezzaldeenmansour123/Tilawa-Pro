// ─────────────────────────────────────────────────────────────────────────────
// تصدير/استيراد بيانات المستخدم — محوّل الإدخال/الإخراج (Flutter)
// الملف: lib/data/user_export_io.dart
// ─────────────────────────────────────────────────────────────────────────────
// الحالة: كود جاهز للاختبار على الجهاز — «لم يُختبر بعد» على جهاز حقيقي
// (لا Flutter/Dart SDK في بيئة الإعداد؛ المنطق النقي مُختبَر محلياً بمرآة
// Python في test_export.py — انظر phase1/EXPORT_IMPORT.md).
//
// يربط المنطق النقي في user_export.dart بـ:
//   - SharedPreferences بمفاتيح UserData الحرفية (lib/main.dart:111–203)،
//   - ملفات JSON في مجلد دعم التطبيق (path_provider).
//
// قواعد الأمان المطبَّقة هنا:
//   1. التحقق المسبق (dry-run) قبل أي كتابة — ملف مرفوض = صفر كتابة.
//   2. الاستبدال يتطلب confirmReplace == true وإلا رُفض قبل الكتابة.
//   3. نسخة احتياطية تلقائية للحالة الحالية قبل أي استبدال، تُعاد قراءتها
//      والتحقق منها قبل المتابعة.
//   4. كتابة ذرية لملف التصدير (tmp ثم rename) + إعادة قراءة وتحقق.
//   5. بعد كل كتابة في prefs: إعادة قراءة ومقارنة سجلاً بسجلاً؛
//      عند عدم التطابق تُستعاد النسخة الاحتياطية ويُرمى استثناء.
//   6. لا يمسّ هذا الكود مفاتيح الإعدادات الثمانية ولا lib_sha إطلاقاً.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_export.dart';

/// نتيجة استيراد ناجح (تُعرض على المستخدم).
class ImportReport {
  final ImportMode mode;
  final UserExportData imported;
  final List<QuarantinedRecord> quarantined;
  final List<String> warnings;

  /// مسار النسخة الاحتياطية التلقائية (في وضع الاستبدال فقط).
  final String? backupPath;

  const ImportReport({
    required this.mode,
    required this.imported,
    this.quarantined = const [],
    this.warnings = const [],
    this.backupPath,
  });
}

/// خدمة التصدير/الاستيراد. تُبنى بمثيل SharedPreferences ومجلد الدعم
/// لتبقى قابلة للاختبار (في الإنتاج: القيم الافتراضية عبر getInstance).
class UserExportService {
  final SharedPreferences prefs;
  final Directory supportDir;

  UserExportService({required this.prefs, required this.supportDir});

  /// مصنع الإنتاج: SharedPreferences + getApplicationSupportDirectory.
  static Future<UserExportService> create() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationSupportDirectory();
    return UserExportService(prefs: prefs, supportDir: dir);
  }

  // ── القراءة: الحالة الحالية من prefs (متسامحة — لا ترمي) ──────────────
  //
  // ملاحظة موثَّقة: UserData.load() الحالي (main.dart:120–132) يرمي إن كان
  // JSON الوسوم/الملاحظات معطوباً أو عنصر قائمة ليس عدداً (int.parse).
  // هذه القراءة متسامحة عمداً: الفاسد يُعزَل ويُدوَّن، ولا يُسقط التحميل.

  UserExportData readCurrent() {
    final quarantined = <QuarantinedRecord>[];
    return UserExportData(
      favorites: _readIdList('favs', quarantined),
      history: _readIdList('history', quarantined),
      tags: _readStringMap('tags', quarantined),
      notes: _readStringMap('notes', quarantined),
      khatmahQuarter: _readKhatmah(),
      favReciters: _readReciters(quarantined),
      warshReady: prefs.getBool('warsh_ready') ?? false,
    );
  }

  List<int> _readIdList(String key, List<QuarantinedRecord> quarantined) {
    final out = <int>[];
    for (final s in prefs.getStringList(key) ?? const []) {
      final id = int.tryParse(s);
      if (id == null || id < kMinAyahId || id > kMaxAyahId) {
        quarantined.add(QuarantinedRecord(key, s, 'قيمة غير صالحة في prefs'));
      } else if (!out.contains(id)) {
        out.add(id);
      }
    }
    return out;
  }

  Map<int, String> _readStringMap(
      String key, List<QuarantinedRecord> quarantined) {
    final raw = prefs.getString(key);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final out = <int, String>{};
      for (final e in m.entries) {
        final id = int.tryParse(e.key);
        if (id == null ||
            id < kMinAyahId ||
            id > kMaxAyahId ||
            e.value is! String) {
          quarantined.add(
              QuarantinedRecord(key, e.key, 'إدخال غير صالح في prefs'));
        } else {
          out[id] = e.value as String;
        }
      }
      return out;
    } catch (_) {
      // JSON معطوب كلياً: الخريطة كلها تُعزل (كما في خطة الترحيل §3.3)؛
      // السلسلة الخام تبقى في prefs حتى يكتب المستخدم قيمة جديدة.
      quarantined.add(QuarantinedRecord(key, raw, 'JSON معطوب في prefs'));
      return {};
    }
  }

  int _readKhatmah() {
    final q = prefs.getInt('khatmah_q') ?? 1;
    return (q >= kMinKhatmahQuarter && q <= kMaxKhatmahQuarter) ? q : 1;
  }

  List<String> _readReciters(List<QuarantinedRecord> quarantined) {
    final out = <String>[];
    for (final r in prefs.getStringList('fav_reciters') ?? const []) {
      if (kKnownReciterIds.contains(r) && !out.contains(r)) {
        out.add(r);
      } else {
        quarantined
            .add(QuarantinedRecord('fav_reciters', r, 'معرّف قارئ غير معروف'));
      }
    }
    return out;
  }

  // ── الكتابة: تحفظ UserExportData في prefs بالشكل الخام نفسه ────────────
  // الشكل الخام مطابق تماماً لما يكتبه UserData._save() (main.dart:135–143)
  // لتبقى القراءة الحالية في التطبيق صالحة دون أي تعديل فيها.

  Future<void> _save(UserExportData data) async {
    await prefs.setStringList(
        'favs', data.favorites.map((e) => '$e').toList());
    await prefs.setStringList(
        'history', data.history.map((e) => '$e').toList());
    await prefs.setString('tags',
        jsonEncode({for (final e in data.tags.entries) '${e.key}': e.value}));
    await prefs.setString('notes',
        jsonEncode({for (final e in data.notes.entries) '${e.key}': e.value}));
    await prefs.setInt('khatmah_q', data.khatmahQuarter);
    await prefs.setBool('warsh_ready', data.warshReady);
    await prefs.setStringList('fav_reciters', data.favReciters);
  }

  /// يعيد قراءة prefs ويقارنها بالمتوقع سجلاً بسجلاً.
  bool _verifySaved(UserExportData expected) => readCurrent() == expected;

  // ── التصدير ────────────────────────────────────────────────────────────

  /// يصدّر كل بيانات المستخدم الحالية إلى ملف JSON في مجلد الدعم،
  /// ويعيد الملف. الكتابة ذرية (tmp ثم rename) ثم إعادة قراءة وتحقق.
  /// اسم الملف: tilawa-user-export-YYYYMMDD-HHMMSS.json
  Future<File> exportToFile({String? appVersion}) async {
    final data = readCurrent();
    final stamp = _stamp(DateTime.now());
    final file = File('${supportDir.path}/tilawa-user-export-$stamp.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data.toExportString(appVersion: appVersion));
    // تحقق: أعد قراءة الملف المؤقت وطابق بصمته قبل إعادة التسمية.
    final check = validateExportText(await tmp.readAsString());
    if (!check.isValid || check.data != data) {
      await tmp.delete();
      throw Exception('فشل التحقق من ملف التصدير قبل حفظه — لم يُكتب شيء.');
    }
    await tmp.rename(file.path);
    return file;
  }

  // ── الاستيراد ──────────────────────────────────────────────────────────

  /// تحقق مسبق (dry-run) من ملف دون أي كتابة — للعرض على المستخدم أولاً.
  Future<ExportValidation> previewImport(File file) async {
    final text = await file.readAsString();
    return validateExportText(text);
  }

  /// يستورد ملف تصدير بعد التحقق المسبق.
  /// - الملف المرفوض: يُرمى استثناء ولا يُكتب شيء إطلاقاً.
  /// - وضع الدمج (الافتراضي): لا يحذف سجلاً موجوداً أبداً.
  /// - وضع الاستبدال: يتطلب [confirmReplace] == true، ويكتب نسخة احتياطية
  ///   تلقائية للحالة الحالية أولاً (backups/pre-import_*.json) ويتحقق
  ///   منها؛ عند أي فشل بعد الكتابة تُستعاد النسخة ويُرمى استثناء.
  Future<ImportReport> importFile(
    File file, {
    ImportMode mode = ImportMode.merge,
    bool confirmReplace = false,
  }) async {
    final validation = await previewImport(file);
    if (!validation.isValid || validation.data == null) {
      throw Exception(
          'رُفض ملف الاستيراد: ${validation.rejectionReason ?? 'غير صالح'}');
    }
    final incoming = validation.data!;

    if (mode == ImportMode.replace && !confirmReplace) {
      throw Exception(
          'الاستبدال الكامل يتطلب تأكيداً صريحاً من المستخدم — لم يُكتب شيء.');
    }

    String? backupPath;
    if (mode == ImportMode.replace) {
      backupPath = await _writeAutoBackup();
    }

    final current = readCurrent();
    final target =
        mode == ImportMode.merge ? current.mergeWith(incoming) : incoming;

    try {
      await _save(target);
    } catch (e) {
      if (backupPath != null) await _restoreBackup(File(backupPath));
      rethrow;
    }
    if (!_verifySaved(target)) {
      if (backupPath != null) await _restoreBackup(File(backupPath));
      throw Exception(
          'فشل التحقق بعد الكتابة — استُعيدت البيانات السابقة من النسخة الاحتياطية.');
    }

    return ImportReport(
      mode: mode,
      imported: incoming,
      quarantined: validation.quarantined,
      warnings: validation.warnings,
      backupPath: backupPath,
    );
  }

  // ── النسخ الاحتياطي التلقائي قبل الاستبدال ─────────────────────────────

  /// يكتب الحالة الحالية إلى backups/pre-import_*.json ويعيد مساره،
  /// بعد إعادة قراءته والتحقق من مطابقته للحالة الحالية.
  Future<String> _writeAutoBackup() async {
    final dir = Directory('${supportDir.path}/backups');
    await dir.create(recursive: true);
    final stamp = _stamp(DateTime.now());
    final file = File('${dir.path}/pre-import-$stamp.json');
    final data = readCurrent();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data.toExportString());
    final check = validateExportText(await tmp.readAsString());
    if (!check.isValid || check.data != data) {
      await tmp.delete();
      throw Exception('فشل كتابة النسخة الاحتياطية — أُلغي الاستيراد.');
    }
    await tmp.rename(file.path);
    // احتفاظ: آخر 3 نسخ تلقائية فقط (كما في خطة الترحيل §4.1).
    await _pruneBackups(dir, keep: 3);
    return file.path;
  }

  Future<void> _pruneBackups(Directory dir, {int keep = 3}) async {
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    while (files.length > keep) {
      await files.removeAt(0).delete();
    }
  }

  /// يستعيد حالة من ملف نسخة احتياطية (بعد تحققه المسبق).
  Future<void> _restoreBackup(File backupFile) async {
    final validation = await previewImport(backupFile);
    if (!validation.isValid || validation.data == null) {
      throw Exception('ملف النسخة الاحتياطية نفسه غير صالح — لا يمكن الاستعادة.');
    }
    await _save(validation.data!);
  }

  String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}-'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  String _two(int n) => n.toString().padLeft(2, '0');
}
