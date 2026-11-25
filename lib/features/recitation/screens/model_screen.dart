// Model status screen: install state, download, backend, offline note.
//
// The card always shows: not installed / downloading n% (x of y MB) /
// installed (tier, version, size, short SHA-256) / load failed (reason).
// Recitation cannot start before "installed".

import 'package:material_ui/material_ui.dart';

import '../model_manager.dart';
import '../speech_engine.dart';
import '../webview_engine.dart';

class ModelScreen extends StatefulWidget {
  const ModelScreen(
      {super.key,
      required this.manager,
      required this.engine,
      this.initialTier = 'lite'});
  final ModelManager manager;
  final WebViewEngine engine;

  /// Tier shown first (e.g. when opened from the packages page).
  final String initialTier;
  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  String _tier = 'lite';
  ModelInfo? _info;
  double? _progress;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tier = widget.initialTier;
    _refresh();
  }

  Future<void> _refresh() async {
    final info = await widget.manager.status(_tier);
    if (mounted) setState(() => _info = info);
  }

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _message = null;
    });
    try {
      await widget.manager.download(
        tier: _tier,
        onProgress: (f) => setState(() => _progress = f),
      );
      setState(() => _message = 'تم التنزيل والتحقق من البصمة بنجاح.');
    } on SpeechEngineException catch (e) {
      // Cancelled downloads keep their .part file: the next download
      // resumes from it instead of starting over (Phase 2, 2.5).
      setState(() => _message = e.reason == 'cancelled'
          ? 'أُلغي التنزيل — ما نُزّل محفوظ وسيُستأنف من حيث توقف عند التنزيل التالي.'
          : 'فشل التنزيل: $e');
    } finally {
      setState(() => _busy = false);
      await _refresh();
    }
  }

  void _cancel() {
    widget.manager.cancelDownload();
    setState(() => _message = 'جارٍ إيقاف التنزيل…');
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final asset = _tier == 'lite' ? kLiteModel : kFullModel;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'lite', label: Text('lite — 24.7 MB')),
              ButtonSegment(value: 'full', label: Text('full — 67.8 MB')),
            ],
            selected: {_tier},
            onSelectionChanged: (s) async {
              setState(() => _tier = s.first);
              await _refresh();
            },
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: info == null
                  ? const CircularProgressIndicator()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'الحالة: ${_statusLabel(info.status)}',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text('النموذج: ${asset.modelId}@${asset.version}'),
                        Text(
                            'الحجم: ${(asset.bytes / 1048576).toStringAsFixed(1)} MB'),
                        Text('SHA-256: ${asset.sha256.substring(0, 12)}…'),
                        if (info.version != null)
                          Text('المثبَّت: ${info.version}'),
                        Text(
                            'ملفات تشغيل المحرك (WASM): ${info.ortBytes == null || info.ortBytes == 0 ? 'غير منزَّلة بعد' : '${(info.ortBytes! / 1048576).toStringAsFixed(1)} MB'}'),
                        if (info.referenceOk == true)
                          const Text(
                              'المرجع: متحقَّق منه (6236 آية، SHA-256 مطابقة)'),
                        if (info.wasmOk == true)
                          const Text(
                              'ملفات التشغيل: متحقَّق منها (الحجم + SHA-256)'),
                        if (info.bundleOk == false)
                          const Text(
                              'حزمة المحرك (bundle.js): غير موجودة في هذا البناء — التسميع غير متاح',
                              style: TextStyle(color: Colors.red)),
                        if (info.error != null)
                          Text('الخطأ: ${info.error}',
                              style: const TextStyle(color: Colors.red)),
                        if (_progress != null && _busy)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(value: _progress),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _download,
            icon: const Icon(Icons.download),
            label: Text(_busy
                ? 'جارٍ التنزيل — ${((_progress ?? 0) * 100).toStringAsFixed(0)}%'
                : 'تنزيل النموذج ($_tier) + ملفات التشغيل والتحقق منها'),
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _cancel,
              icon: const Icon(Icons.cancel),
              label: const Text('إلغاء التنزيل (يُستأنف لاحقاً من حيث توقف)'),
            ),
          ],
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_message!),
            ),
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'دون إنترنت: بعد التنزيل الأول يعمل التسميع كاملاً في وضع '
                'الطيران. إن ظهر أي طلب شبكة أثناء جلسة طيران فهذه نتيجة '
                'فشل لمعيار «دون إنترنت» — دوّنها في تقرير النتائج.\n\n'
                'الخلفية (wasm/webgpu/cpu) تظهر في بطاقة الجلسة بعد أول '
                'تحميل للنموذج، وتُسجَّل في السجل تلقائياً.',
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('تحديث الحالة'),
          ),
        ],
      ),
    );
  }

  String _statusLabel(ModelStatus s) => switch (s) {
        ModelStatus.notInstalled => 'غير مثبَّت',
        ModelStatus.downloading => 'جارٍ التنزيل',
        ModelStatus.ready => 'مثبَّت — جاهز',
        ModelStatus.failed => 'فشل التحميل',
      };
}
