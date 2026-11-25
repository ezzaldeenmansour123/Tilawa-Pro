// ─────────────────────────────────────────────────────────────────────────────
// صفحة النسخ الاحتياطي والاستعادة — تلاوة برو
//
// واجهة فوق المنطق الموجود في lib/data/user_export.dart (نقي) و
// lib/data/user_export_io.dart (ملفات + SharedPreferences). لا تعيد
// كتابة المنطق ولا تغيّر الصيغة؛ تعرض فقط ما يفعله المنطق.
//
// ما يُصدَّر (صيغة v1 — tilawa-user-export):
//   المفضلة، السجل، الوسوم، الملاحظات، ربع الختمة، القرّاء المفضلون،
///   علم جاهزية ورش. ما لا يُصدَّر في v1: الإعدادات (الثمانية مفاتيح
//   + lib_sha) وخطط الحفظ (مفاتيح hifz_* المنفصلة) — تُعرض هذه الحدود
//   صراحةً في الصفحة بدل إيهام المستخدم بشمولها.
//
// الاستيراد: اختيار ملف JSON من الجهاز (file_picker) أو من ملفات
// التصدير/النسخ المحفوظة في مجلد التطبيق، ثم تحقق مسبق (dry-run)
// يُعرض قبل أي كتابة، ثم تأكيد صريح. وضع الدمج افتراضي (لا يحذف
// سجلاً)؛ وضع الاستبدال يتطلب تأكيداً صريحاً ويكتب نسخة احتياطية
// تلقائية للحالة الحالية أولاً (ينفذها UserExportService).
// ─────────────────────────────────────────────────────────────────────────────
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/user_export.dart';
import '../../data/user_export_io.dart';

/// صفحة النسخ الاحتياطي والاستعادة.
///
/// تُبنى بخدمة جاهزة؛ مصنع الإنتاج [ExportPage.create] يبني الخدمة
/// من SharedPreferences + مجلد دعم التطبيق.
class ExportPage extends StatefulWidget {
  final UserExportService service;

  /// إصدار التطبيق الذي يُكتب في ملف التصدير (اختياري).
  final String? appVersion;

  const ExportPage({required this.service, this.appVersion, super.key});

  /// مصنع الإنتاج: خدمة من SharedPreferences + مجلد الدعم.
  static Future<ExportPage> create({String? appVersion}) async {
    final service = await UserExportService.create();
    return ExportPage(service: service, appVersion: appVersion);
  }

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  bool _busy = false;
  String? _error;
  String? _notice;

  /// ملفات تصدير محفوظة في مجلد الدعم (tilawa-user-export-*.json).
  List<File> _savedExports = [];

  /// نسخ احتياطية تلقائية (backups/pre-import-*.json)، الأحدث أولاً.
  List<File> _backups = [];

  UserExportData get _current => widget.service.readCurrent();

  @override
  void initState() {
    super.initState();
    _refreshLocalFiles();
  }

  Future<void> _refreshLocalFiles() async {
    final dir = widget.service.supportDir;
    final exports = <File>[];
    final backups = <File>[];
    try {
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('tilawa-user-export-')) exports.add(e);
      }
      final bDir = Directory('${dir.path}/backups');
      if (await bDir.exists()) {
        await for (final e in bDir.list()) {
          if (e is File && e.path.endsWith('.json')) backups.add(e);
        }
      }
    } catch (_) {
      // مجلد الدعم غير قابل للقراءة: تُعرض القوائم فارغة ولا يُسقط التحميل.
    }
    Future<int> mtime(File f) async {
      try {
        return (await f.stat()).modified.millisecondsSinceEpoch;
      } catch (_) {
        return 0;
      }
    }

    final exportTimes = <File, int>{};
    for (final f in exports) {
      exportTimes[f] = await mtime(f);
    }
    exports.sort((a, b) => exportTimes[b]!.compareTo(exportTimes[a]!));
    final backupTimes = <File, int>{};
    for (final f in backups) {
      backupTimes[f] = await mtime(f);
    }
    backups.sort((a, b) => backupTimes[b]!.compareTo(backupTimes[a]!));
    if (mounted) {
      setState(() {
        _savedExports = exports;
        _backups = backups;
      });
    }
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

  Future<String> _fileDate(File f) async {
    try {
      final s = await f.stat();
      final m = s.modified;
      return '${m.year}-${m.month.toString().padLeft(2, '0')}-'
          '${m.day.toString().padLeft(2, '0')} '
          '${m.hour.toString().padLeft(2, '0')}:'
          '${m.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  void _setBusy(bool b) {
    if (mounted) setState(() => _busy = b);
  }

  void _showError(String e) {
    if (mounted) {
      setState(() {
        _error = e;
        _notice = null;
      });
    }
  }

  void _showNotice(String n) {
    if (mounted) {
      setState(() {
        _notice = n;
        _error = null;
      });
    }
  }

  // ── التصدير ────────────────────────────────────────────────────────────

  Future<void> _export() async {
    _setBusy(true);
    try {
      final file = await widget.service
          .exportToFile(appVersion: widget.appVersion);
      await _refreshLocalFiles();
      if (!mounted) return;
      _showNotice('حُفظت نسختك في: ${_fileName(file)}');
      final share = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تم التصدير'),
          content: Text(
              'ملف النسخة الاحتياطية:\n${file.path}\n\nيمكنك مشاركته أو حفظه خارج التطبيق (بريد، تخزين سحابي، جهاز آخر).'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إغلاق'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('مشاركة الملف'),
            ),
          ],
        ),
      );
      if (share == true) {
        await Share.shareXFiles(
          [XFile(file.path)],
          subject: 'نسخة احتياطية من بيانات تلاوة',
          text: 'نسخة احتياطية من بياناتك في تطبيق تلاوة '
              '(${_fileName(file)}).',
        );
      }
    } catch (e) {
      _showError('فشل التصدير: $e');
    } finally {
      _setBusy(false);
    }
  }

  // ── الاستيراد ──────────────────────────────────────────────────────────

  Future<void> _pickAndImport() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'اختر ملف نسخة احتياطية (tilawa-user-export-*.json)',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) {
      _showError('تعذّرت قراءة مسار الملف المختار.');
      return;
    }
    await _previewAndImport(File(path));
  }

  /// تحقق مسبق + حوار تأكيد (أعداد/تحذيرات/معزولات + وضع الاستيراد)
  /// ثم الاستيراد الفعلي. لا كتابة قبل تأكيد المستخدم.
  Future<void> _previewAndImport(File file) async {
    _setBusy(true);
    ExportValidation validation;
    try {
      validation = await widget.service.previewImport(file);
    } catch (e) {
      _setBusy(false);
      _showError('تعذّرت قراءة الملف: $e');
      return;
    }
    _setBusy(false);
    if (!mounted) return;
    if (!validation.isValid || validation.data == null) {
      _showError('رُفض الملف: ${validation.rejectionReason ?? 'غير صالح'} '
          '— لم يُكتب شيء.');
      return;
    }
    final data = validation.data!;
    var mode = ImportMode.merge;
    var confirmReplace = false;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('استيراد نسخة احتياطية'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('الملف: ${_fileName(file)}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text('ما سيُستورَد:\n'
                    '• مفضلة: ${data.favorites.length}\n'
                    '• سجل: ${data.history.length}\n'
                    '• وسوم: ${data.tags.length} • ملاحظات: ${data.notes.length}\n'
                    '• قرّاء مفضلون: ${data.favReciters.length}\n'
                    '• ربع الختمة: ${data.khatmahQuarter}'),
                if (validation.warnings.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('تحذيرات:\n${validation.warnings.join('\n')}',
                      style: const TextStyle(color: Colors.orange)),
                ],
                if (validation.quarantined.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      'سجلات معزولة (لن تُستورَد): '
                      '${validation.quarantined.length}',
                      style: const TextStyle(color: Colors.red)),
                ],
                const SizedBox(height: 12),
                const Text('وضع الاستيراد:',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                RadioGroup<ImportMode>(
                  groupValue: mode,
                  onChanged: (v) =>
                      setDialogState(() => mode = v ?? ImportMode.merge),
                  child: const Column(
                    children: [
                      RadioListTile<ImportMode>(
                        title: Text('دمج (آمن — الافتراضي)'),
                        subtitle: Text('لا يحذف أي سجل موجود أبداً'),
                        value: ImportMode.merge,
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<ImportMode>(
                        title: Text('استبدال كامل'),
                        subtitle: Text(
                            'يحذف بياناتك الحالية ويضع مكانها الملف — '
                            'مع نسخة احتياطية تلقائية قبلها'),
                        value: ImportMode.replace,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                if (mode == ImportMode.replace)
                  CheckboxListTile(
                    title: const Text(
                        'أفهم أن الاستبدال يحذف بياناتي الحالية '
                        '(مع نسخة احتياطية تلقائية)'),
                    value: confirmReplace,
                    onChanged: (v) =>
                        setDialogState(() => confirmReplace = v ?? false),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (mode == ImportMode.replace && !confirmReplace) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text(
                          'الاستبدال يتطلب تأكيداً صريحاً — فعّل مربع التأكيد.')));
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('استيراد'),
            ),
          ],
        ),
      ),
    );
    if (proceed != true) return;
    _setBusy(true);
    try {
      final report = await widget.service.importFile(
        file,
        mode: mode,
        confirmReplace: mode == ImportMode.replace && confirmReplace,
      );
      await _refreshLocalFiles();
      if (!mounted) return;
      _showNotice('تم الاستيراد (${mode == ImportMode.merge ? 'دمج' : 'استبدال'}): '
          '${report.imported.favorites.length} مفضلة، '
          '${report.imported.history.length} في السجل، '
          '${report.quarantined.length} سجلاً معزولاً.'
          '${report.backupPath != null ? '\nنسخة احتياطية تلقائية: '
              '${report.backupPath!.split(Platform.pathSeparator).last}' : ''}');
    } catch (e) {
      _showError('فشل الاستيراد: $e');
    } finally {
      _setBusy(false);
    }
  }

  // ── العرض ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      appBar: AppBar(title: const Text('نسخ احتياطي واستعادة')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('بياناتك ملكك',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                SizedBox(height: 6),
                Text(
                    'صدّر بياناتك إلى ملف JSON يمكنك مشاركته أو حفظه خارج التطبيق، واستعدها على أي جهاز. كل شيء محلي — لا حساب ولا خادم.',
                    style: TextStyle(fontSize: 13, height: 1.9)),
                SizedBox(height: 6),
                Text(
                    'ما يُصدَّر: المفضلة، السجل، الوسوم، الملاحظات، ربع الختمة، القرّاء المفضلون، جاهزية ورش. ما لا يشمله ملف التصدير (صيغة v1): الإعدادات وخطط الحفظ — تبقى محلية على هذا الجهاز.',
                    style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.8)),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Card(
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(fontSize: 13, height: 1.8)),
            ),
          ),
        ],
        if (_notice != null) ...[
          const SizedBox(height: 10),
          Card(
            color: Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_notice!, style: const TextStyle(fontSize: 13, height: 1.8)),
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text('بياناتك الحالية',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
                'مفضلة: ${current.favorites.length} • '
                'سجل: ${current.history.length} • '
                'وسوم: ${current.tags.length} • '
                'ملاحظات: ${current.notes.length}\n'
                'ربع الختمة: ${current.khatmahQuarter} • '
                'قرّاء مفضلون: ${current.favReciters.length} • '
                'ورش جاهزة: ${current.warshReady ? 'نعم' : 'لا'}',
                style: const TextStyle(fontSize: 13, height: 1.9)),
          ),
        ),
        const SizedBox(height: 16),
        const Text('تصدير',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.upload_rounded),
            label: const Text('تصدير نسخة احتياطية الآن'),
          ),
        ),
        const SizedBox(height: 16),
        const Text('استيراد',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _pickAndImport,
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('اختيار ملف نسخة احتياطية من الجهاز'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
            'يُتحقق من الملف قبل أي كتابة، وتُعرض أعداده وتحذيراته، والاستبدال الكامل يتطلب تأكيداً صريحاً ويكتب نسخة احتياطية تلقائية لحالتك الحالية أولاً.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
        const SizedBox(height: 16),
        const Text('آخر نسخة احتياطية',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (_backups.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                  'لا نسخ احتياطية تلقائية بعد — تُنشأ نسخة تلقائياً قبل أي استبدال كامل.',
                  style: TextStyle(fontSize: 13, height: 1.8)),
            ),
          )
        else
          FutureBuilder<String>(
            future: _fileDate(_backups.first),
            builder: (c, snap) => Card(
              child: ListTile(
                leading: const Icon(Icons.history_rounded),
                title: Text(_fileName(_backups.first)),
                subtitle: Text('آخر نسخة تلقائية: ${snap.data ?? ''}'),
                onTap: () => _previewAndImport(_backups.first),
              ),
            ),
          ),
        if (_savedExports.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('ملفات تصدير محفوظة في التطبيق',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          for (final f in _savedExports)
            FutureBuilder<String>(
              future: _fileDate(f),
              builder: (c, snap) => Card(
                child: ListTile(
                  leading: const Icon(Icons.description_rounded),
                  title: Text(_fileName(f)),
                  subtitle: Text(snap.data ?? ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.share_rounded),
                    tooltip: 'مشاركة',
                    onPressed: _busy
                        ? null
                        : () => Share.shareXFiles([XFile(f.path)]),
                  ),
                  onTap: () => _previewAndImport(f),
                ),
              ),
            ),
        ],
        if (_busy) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
      ]),
    );
  }
}
