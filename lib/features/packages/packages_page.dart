// ─────────────────────────────────────────────────────────────────────────────
// صفحة الحزم والتنزيلات — تلاوة برو
//
// تعرض الحزم الاختيارية من الكتالوج (package_catalog.dart) مع حجم كل حزمة
// قبل التنزيل، وتدير التنزيل عبر DownloadManager (استئناف Range + تحقق
// SHA-256 + سجل محلي). لا تنزيل في الخلفية ولا اتصال دون طلب المستخدم.
//
// الصدق في العرض:
// - الحزمة الوحيدة الجاهزة فعلاً للتنزيل الآن هي نموذج الفاتحة للعفاسي
//   (manifest حقيقي في assets/packages، 7 ملفات موثقة بالبصمات).
// - باقي مدخلات الكتالوج (10) بلا manifest منشور بعد، فتُعرض «قيد الإعداد»
//   دون زر تنزيل — لا يُعرض زر وهمي.
// - حزمتا نموذج التسميع (ai-model-lite/full) معلّقتان: المحرك غير مدمج
//   قبل قرار GO موثّق بعد اختبار الهاتف (انظر docs/phase0-1).
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'download_manager.dart';
import 'package_catalog.dart';
import 'package_models.dart';

/// معرّف الحزمة الوحيدة الجاهزة (manifest منشور في الأصول).
const String kFatihaPackageId = 'reciter-afasy-fatiha-64';
const String kFatihaManifestAsset =
    'assets/packages/reciter-afasy-fatiha-64-manifest.json';

class PackagesPage extends StatefulWidget {
  const PackagesPage({super.key});

  @override
  State<PackagesPage> createState() => _PackagesPageState();
}

class _PackagesPageState extends State<PackagesPage> {
  DownloadManager? _manager;
  PackageManifest? _fatiha;
  bool _loading = true;
  String? _error;
  String? _notice;
  int _usedBytes = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final support = await getApplicationSupportDirectory();
      final manager = DownloadManager(
          packagesDir: Directory('${support.path}/packages'));
      await manager.init();
      final raw = await rootBundle.loadString(kFatihaManifestAsset);
      final manifest = PackageManifest.fromJsonString(raw);
      final used = await manager.usedBytes();
      if (!mounted) return;
      setState(() {
        _manager = manager;
        _fatiha = manifest;
        _usedBytes = used;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذّر تجهيز مدير الحزم: $e';
        _loading = false;
      });
    }
  }

  PackageRecord? get _fatihaRecord {
    final m = _manager;
    if (m == null) return null;
    for (final r in m.records) {
      if (r.manifest.id == kFatihaPackageId) return r;
    }
    return null;
  }

  Future<void> _refreshUsed() async {
    final m = _manager;
    if (m == null) return;
    final used = await m.usedBytes();
    if (mounted) setState(() => _usedBytes = used);
  }

  void _onProgress(DownloadProgress p) {
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    final m = _manager;
    final manifest = _fatiha;
    if (m == null || manifest == null) return;
    setState(() {
      _error = null;
      _notice = null;
    });
    try {
      await m.download(manifest, onProgress: _onProgress);
      final ok = await m.verify(kFatihaPackageId);
      await _refreshUsed();
      if (!mounted) return;
      setState(() {
        _notice = ok
            ? 'اكتمل التنزيل وتحققت البصمات — الحزمة متوفرة دون إنترنت.'
            : 'اكتمل التنزيل لكن التحقق فشل — راجع الحالة أدناه.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل التنزيل: $e');
      await _refreshUsed();
    }
  }

  Future<void> _pause() async {
    await _manager?.pause(kFatihaPackageId);
    if (mounted) setState(() {});
  }

  Future<void> _resume() async {
    final m = _manager;
    if (m == null) return;
    setState(() => _error = null);
    try {
      await m.resume(kFatihaPackageId, onProgress: _onProgress);
      final ok = await m.verify(kFatihaPackageId);
      await _refreshUsed();
      if (!mounted) return;
      setState(() {
        _notice = ok ? 'اكتمل الاستئناف وتحققت البصمات.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل الاستئناف: $e');
    }
  }

  Future<void> _verify() async {
    final m = _manager;
    if (m == null) return;
    final ok = await m.verify(kFatihaPackageId);
    if (!mounted) return;
    setState(() {
      _notice = ok
          ? 'كل الملفات سليمة — البصمات مطابقة.'
          : 'التحقق فشل — بعض الملفات غائب أو تالف. أعد التنزيل.';
      _error = null;
    });
  }

  Future<void> _delete() async {
    final m = _manager;
    if (m == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الحزمة؟'),
        content: const Text(
            'سيُحذف مجلد الحزمة كاملاً من جهازك. يمكنك تنزيلها مجدداً لاحقاً.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (confirm != true) return;
    await m.delete(kFatihaPackageId);
    await _refreshUsed();
    if (!mounted) return;
    setState(() {
      _notice = 'حُذفت الحزمة من جهازك.';
      _error = null;
    });
  }

  String _statusText(PackageRecord? r) {
    if (r == null) return 'غير مثبّتة';
    switch (r.status) {
      case PackageStatus.notInstalled:
        return 'غير مثبّتة';
      case PackageStatus.downloading:
        return 'جارٍ التنزيل… ${(r.progress * 100).round()}٪';
      case PackageStatus.paused:
        return 'متوقفة مؤقتاً — ${(r.progress * 100).round()}٪ (قابلة للاستئناف)';
      case PackageStatus.verifying:
        return 'جارٍ التحقق من البصمات…';
      case PackageStatus.installed:
        return 'مثبّتة ومتحقَّق منها — متوفرة دون إنترنت';
      case PackageStatus.incomplete:
        return 'مثبّتة جزئياً — بعض الملفات غائب أو تالف';
      case PackageStatus.failed:
        return 'فشل التنزيل${r.lastError != null ? ': ${r.lastError}' : ''}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الحزم والتنزيلات')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
              _introCard(),
              if (_error != null) ...[
                const SizedBox(height: 10),
                _messageCard(_error!, isError: true),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 10),
                _messageCard(_notice!, isError: false),
              ],
              const SizedBox(height: 16),
              const Text('جاهزة للتنزيل الآن',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              _fatihaCard(),
              const SizedBox(height: 18),
              const Text('قيد الإعداد',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text(
                  'هذه الحزم بلا manifest منشور بعد، فلا زر تنزيل لها حتى يُنشر manifest موثّق بالحجوم والبصمات.',
                  style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
              const SizedBox(height: 8),
              for (final p in packageCatalog) _pendingCard(p),
              const SizedBox(height: 16),
              Text('المساحة المستخدمة للحزم: ${formatBytes(_usedBytes)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
    );
  }

  Widget _introCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('الحزم اختيارية',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          SizedBox(height: 6),
          Text(
              'التطبيق الأساسي يعمل كاملاً دون إنترنت. الحزم الإضافية تُنزَّل عند طلبك فقط، ويُعرض حجمها قبل التنزيل، ويمكن إيقافها واستئنافها وحذفها. لا تنزيل في الخلفية ولا اتصال دون إذنك.',
              style: TextStyle(fontSize: 13, height: 1.9)),
        ]),
      ),
    );
  }

  Widget _messageCard(String text, {required bool isError}) {
    return Card(
      color: isError ? Colors.red.shade50 : Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text, style: const TextStyle(fontSize: 13, height: 1.8)),
      ),
    );
  }

  Widget _fatihaCard() {
    final manifest = _fatiha;
    if (manifest == null) {
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('تعذّر تحميل manifest حزمة الفاتحة من الأصول.')));
    }
    final r = _fatihaRecord;
    final status = _statusText(r);
    final progress = r?.progress ?? 0.0;
    final showProgress = r != null &&
        (r.status == PackageStatus.downloading ||
            r.status == PackageStatus.paused ||
            r.status == PackageStatus.verifying);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(manifest.titleAr,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              '${formatBytes(manifest.totalBytes)} • ${manifest.files.length} ملفات • المصدر: EveryAyah (64kbps)',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text('الحالة: $status',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          if (showProgress) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (r == null || r.status == PackageStatus.notInstalled)
              FilledButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download_rounded),
                label: Text('تنزيل (${formatBytes(manifest.totalBytes)})'),
              ),
            if (r?.status == PackageStatus.downloading)
              FilledButton.icon(
                onPressed: _pause,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('إيقاف مؤقت'),
              ),
            if (r?.status == PackageStatus.paused ||
                r?.status == PackageStatus.failed ||
                r?.status == PackageStatus.incomplete)
              FilledButton.icon(
                onPressed: _resume,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('استئناف'),
              ),
            if (r?.status == PackageStatus.installed)
              FilledButton.icon(
                onPressed: _verify,
                icon: const Icon(Icons.verified_rounded),
                label: const Text('تحقق من البصمات'),
              ),
            if (r != null && r.status != PackageStatus.notInstalled)
              OutlinedButton.icon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_rounded),
                label: const Text('حذف'),
              ),
          ]),
          if (r?.status == PackageStatus.installed) ...[
            const SizedBox(height: 8),
            const Text('ملفات الفاتحة السبع للعفاسي متوفرة دون إنترنت وتُستخدم عند تشغيل السورة.',
                style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
          ],
        ]),
      ),
    );
  }

  Widget _pendingCard(CatalogPackage p) {
    final isAi = p.kind == PackageKind.aiModel;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.titleAr,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('الحجم: ${p.displaySize}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(p.licenseNote,
              style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
          const SizedBox(height: 6),
          Chip(
            label: Text(isAi
                ? 'معلّقة — محرك التسميع غير مدمج قبل قرار GO بعد اختبار الهاتف'
                : 'قيد الإعداد — لا يوجد manifest منشور بعد'),
          ),
        ]),
      ),
    );
  }
}
