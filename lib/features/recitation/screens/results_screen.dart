// Session results page: shown after a session ends (mockup screen 3 —
// «نتيجة التسميع»).
//
// Everything here is computed from the engine's own events (see
// session_logic.dart): matched words, confirmed errors, words needing
// review, and the text-match percentage.
//
// Honesty rules this page never breaks:
// - The big ring is the TEXT-MATCH percentage only (matched words /
//   words of the reviewed ayahs). It is labelled «نسبة المطابقة النصية»,
//   never «الإتقان» as a whole, and never a fake 0%: when no ayah was
//   reviewed it shows «لا توجد بيانات».
// - The mockup's «النطق» and «التجويد» bars are shown as NOT MEASURED:
//   the engine detects memorization mistakes only (wrong/omitted/added
//   words, skipped passage). It does NOT detect tajweed or makharij, so
//   no invented percentage is ever shown for them. Only the «الحفظ»
//   (text match) bar carries a real number.
// - Tapping a reviewed ayah opens the ayah-review page with the same
//   session result (word-level highlighting).

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../models.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../surah_names.dart';
import '../webview_engine.dart';
import 'ayah_review_screen.dart';
import 'session_screen.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({
    super.key,
    required this.result,
    required this.words,
    required this.engine,
    required this.progressStore,
    this.returnResult = false,
  });

  final SessionResult result;

  /// Passage words from engine.passageWords(), fromAyah..toAyah in order.
  final List<List<String>> words;
  final WebViewEngine engine;
  final ProgressStore progressStore;

  /// When true (the quiz flow), the return button pops WITH the result
  /// so the caller can record the question's outcome.
  final bool returnResult;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _saved = false;

  /// Ayah-list tab: 'all' | 'errors' | 'review'.
  String _tab = 'all';

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

  WordMark _markOf(RefWord ref) {
    final r = widget.result;
    if (r.errors.any((e) => e.location == ref)) return WordMark.error;
    if (r.matchedWordKeys.contains(ref.toString())) return WordMark.matched;
    if (r.needsReviewWordKeys.contains(ref.toString())) {
      return WordMark.needsReview;
    }
    return WordMark.notReviewed;
  }

  Color _wordBackground(WordMark mark) => switch (mark) {
        WordMark.matched => wordMatchedBg,
        WordMark.error => wordErrorBg,
        WordMark.needsReview => wordReviewBg,
        WordMark.notReviewed => Colors.transparent,
      };

  /// Ayahs containing at least one word needing re-check.
  Set<int> get _reviewAyahs {
    final out = <int>{};
    for (final k in widget.result.needsReviewWordKeys) {
      final parts = k.split(':');
      if (parts.length == 3) {
        final a = int.tryParse(parts[1]);
        if (a != null) out.add(a);
      }
    }
    return out;
  }

  List<int> get _visibleAyahs {
    final r = widget.result;
    return switch (_tab) {
      'errors' => r.errorAyahs,
      'review' => r.reviewedAyahs.where(_reviewAyahs.contains).toList(),
      _ => r.reviewedAyahs,
    };
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
    final nested = await Navigator.push<SessionResult?>(
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
          returnResult: widget.returnResult,
        ),
      ),
    );
    if (nested != null && widget.returnResult && mounted) {
      Navigator.pop(context, nested);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('نتيجة التسميع')),
        body: ListView(
          padding: const EdgeInsets.all(spacePage),
          children: [
            _buildHeader(r),
            const SizedBox(height: 12),
            _buildMastery(r),
            const SizedBox(height: 12),
            _buildScoreBoxes(r),
            const SizedBox(height: 12),
            const InfoNote(
              message: 'المحرك يصحح الحفظ فقط — النطق والتجويد لا تُقاس '
                  'في هذه النسخة، لذلك لا تظهر لهما نسب.',
              icon: Icons.info_outline_rounded,
            ),
            const SizedBox(height: 12),
            _buildTabs(r),
            const SizedBox(height: 8),
            ..._visibleAyahs.map(_buildAyahCard),
            if (_visibleAyahs.isEmpty) ...[
              const EmptyState(
                icon: Icons.check_circle_outline,
                text: 'لا توجد آيات في هذا التبويب.',
              ),
            ],
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
              onPressed: widget.returnResult
                  ? () => Navigator.pop(context, r)
                  : () =>
                      Navigator.popUntil(context, (route) => route.isFirst),
              icon: widget.returnResult ? Icons.arrow_back : Icons.home,
              label: widget.returnResult
                  ? 'العودة إلى الاختبار'
                  : 'رجوع إلى الإعداد',
            ),
            const SizedBox(height: 12),
            Text(
              _saved
                  ? 'تم حفظ النتيجة على جهازك.'
                  : 'جارٍ حفظ النتيجة…',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: _saved ? success : muted,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
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

  Widget _buildHeader(SessionResult r) {
    return TilawaCard(
      gradient: const LinearGradient(
        colors: [brandPrimary, brandPrimaryDark],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: goldSoft.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.star_rounded, color: goldSoft, size: 32),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'آيات للمراجعة: ${r.reviewedAyahs.length}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'لقد قرأت ${r.reviewedAyahs.length} آيات في هذا الاختبار',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                Text(
                  'سورة ${surahName(r.surah)} — الآيات '
                  '${r.fromAyah}–${r.toAyah} • ${r.mode.label}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMastery(SessionResult r) {
    final p = r.matchPercent;
    return TilawaCard(
      child: Row(
        children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: CircularProgressIndicator(
                    value: p == null
                        ? 0.0
                        : (p / 100).clamp(0.0, 1.0).toDouble(),
                    strokeWidth: 10,
                    backgroundColor: tealLight,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(gold),
                  ),
                ),
                Text(
                  p == null
                      ? 'لا توجد\nبيانات'
                      : '${p.toStringAsFixed(0)}٪',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'نسبة المطابقة النصية',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 4),
                Text(
                  'من كلمات الآيات التي رُوجعت فعلاً في هذه الجلسة.',
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreBoxes(SessionResult r) {
    Widget box(String label, String value, String? sub, Color color) {
      return Expanded(
        child: TilawaCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(value,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: color)),
              if (sub != null)
                Text(sub,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: muted)),
            ],
          ),
        ),
      );
    }

    final p = r.matchPercent;
    return Row(
      children: [
        box(
          'الحفظ',
          p == null ? '—' : '${p.toStringAsFixed(0)}٪',
          'مطابقة النص',
          p == null ? muted : (p >= 90 ? success : brandPrimary),
        ),
        const SizedBox(width: 8),
        box('النطق', '—', 'لا تُقاس', muted),
        const SizedBox(width: 8),
        box('التجويد', '—', 'لا تُقاس', muted),
      ],
    );
  }

  Widget _buildTabs(SessionResult r) {
    return SegmentedButton<String>(
      segments: [
        ButtonSegment(
            value: 'all',
            label: Text('الكل ${r.reviewedAyahs.length}')),
        ButtonSegment(
            value: 'errors',
            label: Text('أخطاء فقط ${r.errorAyahs.length}')),
        ButtonSegment(
            value: 'review',
            label: Text('تحتاج مراجعة ${_reviewAyahs.length}')),
      ],
      selected: {_tab},
      onSelectionChanged: (s) => setState(() => _tab = s.first),
    );
  }

  Widget _buildAyahCard(int ayah) {
    final r = widget.result;
    final idx = ayah - r.fromAyah;
    if (idx < 0 || idx >= widget.words.length) {
      return const SizedBox.shrink();
    }
    final words = widget.words[idx];
    final hasError = r.errorAyahs.contains(ayah);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TilawaCard(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AyahReviewScreen(
              surah: r.surah,
              ayah: ayah,
              result: r,
              words: widget.words,
              engine: widget.engine,
              progressStore: widget.progressStore,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Chip(label: Text('الآية $ayah')),
                const SizedBox(width: 8),
                Text(
                  hasError ? 'فيها خطأ مؤكد' : 'تمت مراجعتها',
                  style: TextStyle(
                    color: hasError ? error : success,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_left, color: muted),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              children: [
                for (var wi = 0; wi < words.length; wi++)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 3, vertical: 2),
                    decoration: BoxDecoration(
                      color: _wordBackground(RefWord(
                        surah: r.surah,
                        ayah: ayah,
                        word: wi + 1,
                      )),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      words[wi],
                      style: const TextStyle(
                        fontSize: 20,
                        height: 1.9,
                        fontFamily: 'Amiri',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
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
