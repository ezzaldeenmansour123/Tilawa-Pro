// Setup / start screen: the gate before any session.
//
// This screen NEVER starts a session itself. Pressing «ابدأ التسميع» runs
// a gated checklist, in order, and only navigates to the real session page
// (session_screen.dart) when every component is ready:
//   1. model installed + SHA-verified (modelManager.status),
//   2. WASM runtime files present (ortWasmReady),
//   3. microphone permission (request once when denied; when permanently
//      denied the system dialog will never appear again, so the screen
//      shows a button that opens the app settings instead),
//   4. engine loaded (skipped when already loaded with the same tier),
//   5. passage text loaded from the engine's own reference.
// Every failure lands in a visible error card with an actionable message.
// The button always responds: loading spinner while working, disabled
// only while loading — never silent (the poc-11 bug).

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../progress_store.dart';
import '../session_logic.dart';
import '../speech_engine.dart';
import '../surah_names.dart';
import '../webview_engine.dart';
import 'logs_screen.dart';
import 'model_screen.dart';
import 'session_screen.dart';

class PresetPassage {
  const PresetPassage(this.label, this.passage);
  final String label;
  final Passage passage;
}

const kPresets = [
  PresetPassage('الفاتحة (1:1–7)', Passage(surah: 1, fromAyah: 1, toAyah: 7)),
  PresetPassage('آية الكرسي (2:255)', Passage(surah: 2, fromAyah: 255, toAyah: 255)),
  PresetPassage('الإخلاص (112:1–4)', Passage(surah: 112, fromAyah: 1, toAyah: 4)),
  PresetPassage('الملك (67:1–5)', Passage(surah: 67, fromAyah: 1, toAyah: 5)),
];

class RecitationScreen extends StatefulWidget {
  const RecitationScreen(
      {super.key, required this.engine, required this.progressStore});
  final WebViewEngine engine;

  /// Local progress store, created once in main.dart.
  final ProgressStore progressStore;
  @override
  State<RecitationScreen> createState() => _RecitationScreenState();
}

class _RecitationScreenState extends State<RecitationScreen> {
  String _tier = 'lite';
  RecitationMode _mode = RecitationMode.lookUp;
  int _presetIndex = 0;
  bool _custom = false;
  int _surah = 1;
  int _from = 1;
  int _to = 7;

  ModelInfo? _modelInfo;
  bool _wasmReady = false;
  MicPermissionState _micState = MicPermissionState.unknown;
  bool _loading = false;
  String _loadingLabel = 'جارٍ الفحص…';
  String? _error;
  int? _lastLoadMs;
  bool _progressLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadProgress();
    _refreshStatus();
  }

  Future<void> _loadProgress() async {
    await widget.progressStore.load();
    if (mounted) setState(() => _progressLoaded = true);
  }

  Future<void> _refreshStatus() async {
    final info = await widget.engine.modelManager.status(_tier);
    final wasm = await widget.engine.modelManager.ortWasmReady();
    final perm = await Permission.microphone.status;
    if (!mounted) return;
    setState(() {
      _modelInfo = info;
      _wasmReady = wasm;
      _micState = micPermissionState(perm);
    });
  }

  Passage get _passage => _custom
      ? Passage(surah: _surah, fromAyah: _from, toAyah: _to)
      : kPresets[_presetIndex].passage;

  String get _passageLabel => _custom
      ? 'سورة ${surahName(_surah)} — الآيات $_from–$_to'
      : kPresets[_presetIndex].label;

  bool get _engineReady =>
      widget.engine.isLoaded && widget.engine.loadedTier == _tier;

  Future<void> _start() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadingLabel = 'جارٍ فحص الجاهزية…';
      _error = null;
    });
    try {
      // 1. Model installed + verified.
      final info = await widget.engine.modelManager.status(_tier);
      if (mounted) setState(() => _modelInfo = info);
      if (info.status != ModelStatus.ready) {
        if (mounted) {
          setState(() => _error =
              'النموذج غير جاهز: ${info.error ?? 'غير مثبَّت'} — '
              'نزّله أولاً من صفحة «النموذج».');
        }
        return;
      }
      // 2. WASM runtime files.
      final wasm = await widget.engine.modelManager.ortWasmReady();
      if (mounted) setState(() => _wasmReady = wasm);
      if (!wasm) {
        if (mounted) {
          setState(() => _error =
              'ملفات تشغيل المحرك (WASM) غير موجودة — '
              'نزّلها من صفحة «النموذج» (زر التنزيل يشملها).');
        }
        return;
      }
      // 3. Microphone permission.
      var micState = micPermissionState(await Permission.microphone.status);
      if (!micState.canStart && micState.canRequestAgain) {
        micState =
            micPermissionState(await Permission.microphone.request());
      }
      if (mounted) setState(() => _micState = micState);
      if (!micState.canStart) {
        if (mounted) setState(() => _error = micState.message);
        return;
      }
      // 4. Engine load (skip when already loaded with this tier).
      int? loadMs;
      if (!_engineReady) {
        if (mounted) {
          setState(() => _loadingLabel = 'جارٍ تحميل النموذج…');
        }
        final t0 = DateTime.now();
        // onStage mirrors the engine's progress step by step, so a hang
        // is visible (which stage it stuck on) instead of a blind wait
        // — the poc-12 phone failure waited 120 s with no clue.
        await widget.engine.load(
          tier: _tier,
          onStage: (label) {
            if (mounted) setState(() => _loadingLabel = label);
          },
        );
        loadMs = DateTime.now().difference(t0).inMilliseconds;
        if (mounted) setState(() => _lastLoadMs = loadMs);
      } else {
        loadMs = _lastLoadMs;
      }
      // 5. Passage text from the engine's own reference.
      final passage = _passage;
      final words = widget.engine.passageWords(passage);
      if (words == null) {
        if (mounted) {
          setState(() => _error = 'تعذّر تحميل نص المقطع من المرجع.');
        }
        return;
      }
      // 6. Navigate to the real session page.
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SessionScreen(
            engine: widget.engine,
            passage: passage,
            mode: _mode,
            tier: _tier,
            words: words,
            progressStore: widget.progressStore,
            loadMs: loadMs,
          ),
        ),
      );
      await _refreshStatus();
    } on SpeechEngineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = 'خطأ غير متوقع: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSettings() async {
    await openAppSettings();
    await _refreshStatus();
  }

  void _applyResume() {
    final p = widget.progressStore.lastPassage;
    if (p == null) return;
    setState(() {
      _custom = true;
      _surah = p.surah;
      _from = p.fromAyah;
      _to = p.toAyah;
      _mode = widget.progressStore.lastMode;
      _tier = widget.progressStore.lastTier;
    });
  }

  void _applyErrorAyahs() {
    final top = widget.progressStore.topErrorAyahs(limit: 10);
    if (top.isEmpty) return;
    final surah = top.first.$1;
    final same = top.where((e) => e.$1 == surah).map((e) => e.$2).toList()
      ..sort();
    setState(() {
      _custom = true;
      _surah = surah;
      _from = same.first;
      _to = same.last;
      _mode = RecitationMode.lookUp;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildChecklist(),
          const SizedBox(height: 12),
          _buildModePicker(),
          const SizedBox(height: 12),
          _buildTierPicker(),
          const SizedBox(height: 12),
          _buildPassagePicker(),
          const SizedBox(height: 12),
          if (_progressLoaded) _buildResumeCard(),
          if (_progressLoaded) const SizedBox(height: 12),
          if (_error != null) _buildErrorCard(),
          if (_error != null) const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _start,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.mic),
            label: Text(_loading ? _loadingLabel : 'ابدأ التسميع'),
          ),
          const SizedBox(height: 8),
          // Pro has no tabs (unlike the PoC): the model-download page and
          // the session-log page are pushed from here instead.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ModelScreen(
                        manager: widget.engine.modelManager,
                        engine: widget.engine,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.memory),
                  label: const Text('النموذج والتنزيل'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LogsScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.list_alt),
                  label: const Text('سجلات الجلسات'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'يعمل التسميع كاملاً دون إنترنت بعد التنزيل الأول. الصوت لا '
            'يغادر جهازك. تصحيح الكلمات فقط — المحرك لا يقيّم التجويد أو '
            'مخارج الحروف.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _checkRow({
    required String title,
    required String subtitle,
    required bool ok,
    required bool unknown,
  }) {
    final icon = unknown
        ? Icons.help_outline
        : ok
            ? Icons.check_circle
            : Icons.error;
    final color = unknown
        ? Colors.grey
        : ok
            ? Colors.green
            : Colors.red;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(subtitle),
      dense: true,
    );
  }

  Widget _buildChecklist() {
    final info = _modelInfo;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            _checkRow(
              title: 'النموذج ($_tier)',
              subtitle: info == null
                  ? 'جارٍ الفحص…'
                  : switch (info.status) {
                      ModelStatus.ready =>
                        'مثبَّت — جاهز (${info.version ?? ''})',
                      ModelStatus.notInstalled => 'غير مثبَّت',
                      ModelStatus.failed =>
                        'فشل التحميل: ${info.error ?? ''}',
                      ModelStatus.downloading => 'جارٍ التنزيل…',
                    },
              ok: info?.status == ModelStatus.ready,
              unknown: info == null,
            ),
            _checkRow(
              title: 'ملفات تشغيل المحرك (WASM)',
              subtitle:
                  _wasmReady ? 'موجودة — جاهزة' : 'غير منزَّلة بعد',
              ok: _wasmReady,
              unknown: info == null,
            ),
            _checkRow(
              title: 'المحرك',
              subtitle: _engineReady
                  ? 'محمَّل (${widget.engine.loadedTier})'
                  : 'غير محمَّل بعد — يُحمَّل عند بدء التسميع',
              ok: _engineReady,
              unknown: false,
            ),
            _checkRow(
              title: 'الميكروفون',
              subtitle: _micState.message,
              ok: _micState.canStart,
              unknown: _micState == MicPermissionState.unknown,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _refreshStatus,
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث الحالة'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModePicker() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('وضع التسميع',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<RecitationMode>(
              segments: RecitationMode.values
                  .map((m) => ButtonSegment(
                      value: m, label: Text(m.label)))
                  .toList(),
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 8),
            Text(_mode.description,
                style: const TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildTierPicker() {
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'lite', label: Text('lite — 24.7 MB')),
        ButtonSegment(value: 'full', label: Text('full — 67.8 MB')),
      ],
      selected: {_tier},
      onSelectionChanged: (s) async {
        setState(() => _tier = s.first);
        await _refreshStatus();
      },
    );
  }

  Widget _buildPassagePicker() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('المقطع',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: _custom ? -1 : _presetIndex,
              isExpanded: true,
              items: [
                for (var i = 0; i < kPresets.length; i++)
                  DropdownMenuItem(value: i, child: Text(kPresets[i].label)),
                const DropdownMenuItem(value: -1, child: Text('مخصص…')),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  if (v == -1) {
                    _custom = true;
                  } else {
                    _custom = false;
                    _presetIndex = v;
                  }
                });
              },
            ),
            if (_custom) ...[
              const SizedBox(height: 8),
              DropdownButton<int>(
                value: _surah,
                isExpanded: true,
                items: [
                  for (var s = 1; s <= 114; s++)
                    DropdownMenuItem(
                        value: s,
                        child: Text('سورة ${surahName(s)} ($s)')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  final max = surahAyahCount(v);
                  setState(() {
                    _surah = v;
                    _from = 1;
                    _to = max;
                  });
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<int>(
                      value: _from,
                      isExpanded: true,
                      items: [
                        for (var a = 1; a <= surahAyahCount(_surah); a++)
                          DropdownMenuItem(value: a, child: Text('من آية $a')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _from = v;
                          if (_to < _from) _to = _from;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<int>(
                      value: _to,
                      isExpanded: true,
                      items: [
                        for (var a = _from;
                            a <= surahAyahCount(_surah);
                            a++)
                          DropdownMenuItem(value: a, child: Text('إلى آية $a')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => _to = v);
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text('المقطع المختار: $_passageLabel'),
          ],
        ),
      ),
    );
  }

  Widget _buildResumeCard() {
    final last = widget.progressStore.lastPassage;
    final topErrors = widget.progressStore.topErrorAyahs(limit: 5);
    if (last == null && topErrors.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('التقدم المحفوظ',
                style: TextStyle(fontWeight: FontWeight.bold)),
            if (last != null) ...[
              const SizedBox(height: 8),
              Text(
                'آخر مراجعة: سورة ${surahName(last.surah)} — الآيات '
                '${last.fromAyah}–${last.toAyah}'
                '${widget.progressStore.lastDate != null ? ' • ${widget.progressStore.lastDate!.day}/${widget.progressStore.lastDate!.month}/${widget.progressStore.lastDate!.year}' : ''}',
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _applyResume,
                icon: const Icon(Icons.play_arrow),
                label: const Text('استئناف آخر مراجعة'),
              ),
            ],
            if (topErrors.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('آيات تتكرر فيها الأخطاء:'),
              for (final e in topErrors)
                Text(
                    '• سورة ${surahName(e.$1)}، الآية ${e.$2} — ${e.$3} مرات'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _applyErrorAyahs,
                icon: const Icon(Icons.replay),
                label: const Text('تسميع آيات الأخطاء'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_micState.needsAppSettings) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.settings),
                label: const Text('فتح إعدادات التطبيق'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
