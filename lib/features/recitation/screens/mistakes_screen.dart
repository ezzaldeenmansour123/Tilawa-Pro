// My mistakes page (mockup screen 6 — «أخطائي»).
//
// Lists the confirmed tasmee' mistakes recorded by ProgressStore, grouped
// by error class. All four engine classes are MEMORIZATION mistakes, so
// every group sits under one «أخطاء الحفظ» heading — the mockup's
// «النطق» / «التجويد» groups cannot be filled with real data: the engine
// does not measure pronunciation or tajweed, so no such mistakes are ever
// recorded or shown (see the note on this page).
//
// The 3-in-a-row rule is real: a mistake is cleared only after the word
// is matched in 3 consecutive sessions without a confirmed error there
// (ProgressStore._updateMistakes). The streak bar on each row shows the
// live count; deleting a record is an explicit user action.

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../models.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../session_starter.dart';
import '../speech_engine.dart';
import '../surah_names.dart';
import '../webview_engine.dart';

class MistakesScreen extends StatefulWidget {
  const MistakesScreen({
    super.key,
    required this.engine,
    required this.progressStore,
  });

  final WebViewEngine engine;
  final ProgressStore progressStore;

  @override
  State<MistakesScreen> createState() => _MistakesScreenState();
}

class _MistakesScreenState extends State<MistakesScreen> {
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.progressStore.load();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _reRecite(StoredMistake m) async {
    setState(() => _error = null);
    final out = await startRecitationSession(
      context: context,
      engine: widget.engine,
      progressStore: widget.progressStore,
      passage: Passage(surah: m.surah, fromAyah: m.ayah, toAyah: m.ayah),
      mode: RecitationMode.lookUp,
      tier: widget.progressStore.lastTier,
    );
    // A finished session updates the streaks in ProgressStore; reload so
    // the bars and the cleared section reflect it.
    await _load();
    if (mounted && out.error != null) {
      setState(() => _error = out.error);
    }
  }

  Future<void> _delete(StoredMistake m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الخطأ؟'),
        content: Text(
          'سيُحذف سجل «سورة ${surahName(m.surah)}، الآية ${m.ayah}» '
          'نهائياً من سجل أخطائك.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.progressStore.deleteMistake(m.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.progressStore.openMistakes;
    final cleared = widget.progressStore.clearedMistakes;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('أخطائي')),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(spacePage),
                children: [
                  Text(
                    open.isEmpty
                        ? 'لا توجد أخطاء لم تُصحَّح بعد.'
                        : '${open.length} ${open.length == 1 ? 'خطأ' : open.length == 2 ? 'خطآن' : 'أخطاء'} لم تُصحَّح بعد.',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'الخطأ يُصحَّح بعد 3 مرات صحيحة في صف واحد: كل مرة '
                    'تسمّع فيها الآية دون هذا الخطأ تُحسب مرة صحيحة، وأي '
                    'تكرار للخطأ يعيد العدّ من الصفر.',
                    style: TextStyle(color: muted),
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    ErrorCard(message: _error),
                    const SizedBox(height: 12),
                  ],
                  const InfoNote(
                    message: 'المحرك يصحح الحفظ فقط — لا تُسجَّل أخطاء '
                        'نطق أو تجويد لأنه لا يقيسهما.',
                    icon: Icons.info_outline_rounded,
                  ),
                  const SizedBox(height: 12),
                  if (open.isEmpty && cleared.isEmpty)
                    const EmptyState(
                      icon: Icons.check_circle_outline,
                      text: 'لا توجد أخطاء مسجلة بعد — ستظهر هنا الأخطاء '
                          'المؤكدة من جلسات التسميع.',
                    )
                  else ...[
                    const SectionHeader(title: 'أخطاء الحفظ'),
                    const SizedBox(height: 8),
                    ..._buildGroups(open),
                    if (cleared.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const SectionHeader(title: 'أخطاء صُححت'),
                      const SizedBox(height: 8),
                      ...cleared.map(_buildClearedRow),
                    ],
                  ],
                ],
              ),
      ),
    );
  }

  List<Widget> _buildGroups(List<StoredMistake> open) {
    const order = [
      ErrorClass.wrongWord,
      ErrorClass.omittedWord,
      ErrorClass.addedWord,
      ErrorClass.skippedPassage,
    ];
    final out = <Widget>[];
    for (final cls in order) {
      final group = open.where((m) => m.errorClass == cls).toList();
      if (group.isEmpty) continue;
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: StatusChip(
            tone: StatusTone.error,
            label: errorClassLabel(cls),
          ),
        ),
      );
      out.addAll(group.map(_buildMistakeRow));
      out.add(const SizedBox(height: 8));
    }
    return out;
  }

  Widget _buildMistakeRow(StoredMistake m) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TilawaCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'سورة ${surahName(m.surah)}، آية ${m.ayah} — '
                    'الكلمة ${m.word}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'تكرر ${m.count} ${m.count == 1 ? 'مرة' : m.count == 2 ? 'مرتين' : 'مرات'}'
                    ' • صحيحة متتالية: ${m.correctStreak}/$kMistakeClearStreak',
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 6),
                  TilawaProgressBar(
                    value: m.correctStreak / kMistakeClearStreak,
                    color: success,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.play_arrow, color: brandPrimary),
              tooltip: 'إعادة تسميع الآية',
              onPressed: () => _reRecite(m),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: muted),
              tooltip: 'حذف السجل',
              onPressed: () => _delete(m),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClearedRow(StoredMistake m) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TilawaCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: success),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'سورة ${surahName(m.surah)}، آية ${m.ayah} — '
                'الكلمة ${m.word} • صُحح بعد ${m.count} '
                '${m.count == 1 ? 'مرة' : 'مرات'}',
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: muted),
              tooltip: 'حذف السجل',
              onPressed: () => _delete(m),
            ),
          ],
        ),
      ),
    );
  }
}
