// Session results page: shown after a session ends.
//
// Everything here is computed from the engine's own events (see
// session_logic.dart): matched words, confirmed errors, words needing
// review, and the text-match percentage. No tajweed verdicts, no invented
// scores: when no ayah was reviewed, the percentage is shown as "no data"
// instead of a fake 0%.

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../models.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../surah_names.dart';
import '../webview_engine.dart';
import 'session_screen.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.result,
    required this.words,
    required this.engine,
    required this.progressStore,
  });

  final SessionResult result;

  /// Passage words from engine.passageWords(), fromAyah..toAyah in order.
  final List<List<String>> words;
  final WebViewEngine engine;
  final ProgressStore progressStore;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _save();
  }

  Future<void> _save() async {
    await widget.progressStore.load();
    await widget.progressStore.recordSession(widget.result);
    if (mounted) setState(() => _saved = true);
  }

  String _wordAt(RefWord ref) {
    final idx = ref.ayah - widget.result.fromAyah;
    if (idx < 0 ||
        idx >= widget.words.length ||
        ref.word < 1 ||
        ref.word > widget.words[idx].length) {
      return '—';
    }
    return widget.words[idx][ref.word - 1];
  }

  Future<void> _reReciteErrors() async {
    final range = widget.result.reReciteRange;
    if (range == null) return;
    final words = widget.engine.passageWords(range);
    if (words == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تعذّر تحميل نص آيات الأخطاء من المرجع.')),
        );
      }
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SessionScreen(
          engine: widget.engine,
          passage: range,
          // Same mode as the finished session; exam mode keeps the text
          // hidden, the other modes keep their own behaviour.
          mode: widget.result.mode,
          tier: widget.result.tier,
          words: words,
          progressStore: widget.progressStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('نتيجة الجلسة')),
        body: ListView(
          padding: const EdgeInsets.all(spacePage),
          children: [
            TilawaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'سورة ${surahName(r.surah)} — الآيات '
                    '${r.fromAyah}–${r.toAyah}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text('الوضع: ${r.mode.label} • النموذج: ${r.tier}',
                      style: const TextStyle(color: muted)),
                  Text(
                    'المدة: ${r.duration.inMinutes} دقيقة '
                    '${r.duration.inSeconds % 60} ثانية'
                    '${r.segments > 1 ? ' • المقاطع: ${r.segments}' : ''}',
                    style: const TextStyle(color: muted),
                  ),
                  Text(
                    _saved
                        ? 'تم حفظ النتيجة على جهازك.'
                        : 'جارٍ حفظ النتيجة…',
                    style: TextStyle(
                        color: _saved ? success : muted,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _statGrid(r),
            const SizedBox(height: 12),
            _errorsSection(r),
            _needsReviewSection(r),
            _notesSection(r),
            const SizedBox(height: 16),
            if (r.reReciteRange != null)
              PrimaryButton(
                onPressed: _reReciteErrors,
                icon: Icons.replay,
                label:
                    'إعادة تسميع الأخطاء (الآيات ${r.errorAyahs.first}–${r.errorAyahs.last})',
              ),
            if (r.reReciteRange != null) const SizedBox(height: 8),
            SecondaryButton(
              onPressed: () =>
                  Navigator.popUntil(context, (route) => route.isFirst),
              icon: Icons.home,
              label: 'رجوع إلى الإعداد',
            ),
            const SizedBox(height: 12),
            const Text(
              'النسبة محسوبة من الكلمات المطابقة على كلمات الآيات التي تمت '
              'مراجعتها فعلاً. الآيات التي لم يلتقط المحرك فيها أي كلمة لا '
              'تُحسب صحيحة ولا خاطئة — أعد تسميعها.',
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statGrid(SessionResult r) {
    Widget stat(String label, String value, {Color? color}) {
      return StatTile(value: value, label: label, color: color);
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.2,
      children: [
        stat('آيات تمت مراجعتها', '${r.reviewedAyahs.length}'),
        stat('كلمات مطابقة',
            '${r.matchedWords} / ${r.totalWords}'),
        stat('أخطاء مكتشفة', '${r.errorCount}',
            color: r.errorCount > 0 ? error : null),
        stat('كلمات تحتاج مراجعة', '${r.needsReviewCount}',
            color: r.needsReviewCount > 0 ? warning : null),
        stat(
          'نسبة المطابقة النصية',
          r.matchPercent == null
              ? 'لا توجد بيانات'
              : '${r.matchPercent!.toStringAsFixed(1)}٪',
          color: r.matchPercent == null
              ? null
              : r.matchPercent! >= 90
                  ? success
                  : null,
        ),
        stat(
          'آيات يُعاد تسميعها',
          r.errorAyahs.isEmpty ? 'لا شيء' : r.errorAyahs.join('، '),
        ),
      ],
    );
  }

  Widget _errorsSection(SessionResult r) {
    if (r.errors.isEmpty) {
      return const TilawaCard(
        child: Row(
          children: [
            Icon(Icons.check_circle, color: success),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'لا توجد أخطاء مؤكدة في هذه الجلسة — أحسنت.',
                style: TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'الأخطاء المكتشفة:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        ...r.errors.map((e) {
          final conf = _confidenceOf(e.location);
          return ListTile(
            leading: const Icon(Icons.error, color: error),
            title: Text(
              '${errorClassLabel(e.errorClass)} — الآية ${e.location.ayah}، '
              'الكلمة ${e.location.word}: «${_wordAt(e.location)}»',
            ),
            subtitle: conf != null
                ? Text('الثقة عند الملاحظة: ${(conf * 100).toStringAsFixed(0)}%')
                : null,
          );
        }),
      ],
    );
  }

  /// Confidence only when the session actually observed the word
  /// (keyed "surah:ayah:word" in the result); null otherwise — no fake
  /// numbers are ever shown.
  double? _confidenceOf(RefWord ref) =>
      widget.result.confidenceByWord[ref.toString()];

  Widget _needsReviewSection(SessionResult r) {
    if (r.needsReviewCount == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          'كلمات تحتاج إلى إعادة تحقق (${r.needsReviewCount}) — لم تُحسب أخطاءً:',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const Text(
          'أعد تسميعها في جلسة لاحقة؛ المحرك لم يكن واثقاً فيها.',
          style: TextStyle(color: muted),
        ),
      ],
    );
  }

  Widget _notesSection(SessionResult r) {
    if (r.notes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        ...r.notes.map((n) => ListTile(
              leading: const Icon(Icons.check_circle, color: success),
              title: Text(n),
            )),
      ],
    );
  }
}
