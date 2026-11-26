// Ayah review page (mockup screen 4 — «مراجعة الآية»).
//
// Shows ONE ayah with its words highlighted from a real session result:
// matched (green), confirmed error (red), needs re-check (yellow).
// The legend says exactly that — «حفظ / خطأ / ملاحظة» — NOT tajweed:
// the engine detects memorization mistakes only (see session_logic.dart),
// so no tajweed claim is shown anywhere here.
//
// The «listened N seconds» line of the mockup cannot be filled honestly:
// no per-ayah listening time is recorded. What IS shown is the whole
// session's duration, labelled as such. When opened without a session
// result (e.g. from the hifz map), the words are unmarked and the ayah
// text comes from the app's own Quran DB.

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../../db.dart';
import '../models.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../session_starter.dart';
import '../speech_engine.dart';
import '../surah_names.dart';
import '../webview_engine.dart';

class AyahReviewScreen extends StatefulWidget {
  const AyahReviewScreen({
    super.key,
    required this.surah,
    required this.ayah,
    this.result,
    this.words,
    required this.engine,
    required this.progressStore,
  });

  final int surah;
  final int ayah;

  /// The session this review comes from (null when opened from the
  /// hifz map without a session).
  final SessionResult? result;

  /// Passage words from engine.passageWords(), fromAyah..toAyah in
  /// order (only when [result] is given). When null, the ayah text is
  /// loaded from the app's own Quran DB instead.
  final List<List<String>>? words;

  final WebViewEngine engine;
  final ProgressStore progressStore;

  @override
  State<AyahReviewScreen> createState() => _AyahReviewScreenState();
}

class _AyahReviewScreenState extends State<AyahReviewScreen> {
  late int _ayah;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ayah = widget.ayah;
  }

  List<String> _ayahWords() {
    final r = widget.result;
    final words = widget.words;
    if (r != null && words != null) {
      final idx = _ayah - r.fromAyah;
      if (idx >= 0 && idx < words.length) return words[idx];
    }
    final a = Repo.i.ayahByRef(widget.surah, _ayah);
    if (a == null) return [];
    return a.text.split(' ').where((w) => w.isNotEmpty).toList();
  }

  WordMark _markOf(int wordIndex) {
    final r = widget.result;
    if (r == null) return WordMark.notReviewed;
    final word = wordIndex + 1;
    if (r.errors.any((e) =>
        e.location.surah == widget.surah &&
        e.location.ayah == _ayah &&
        e.location.word == word)) {
      return WordMark.error;
    }
    final key = '${widget.surah}:$_ayah:$word';
    if (r.matchedWordKeys.contains(key)) return WordMark.matched;
    if (r.needsReviewWordKeys.contains(key)) return WordMark.needsReview;
    return WordMark.notReviewed;
  }

  Color _wordBackground(WordMark mark) => switch (mark) {
        WordMark.matched => wordMatchedBg,
        WordMark.error => wordErrorBg,
        WordMark.needsReview => wordReviewBg,
        WordMark.notReviewed => Colors.transparent,
      };

  List<CheckerEvent> get _ayahErrors {
    final r = widget.result;
    if (r == null) return [];
    return r.errors
        .where((e) =>
            e.location.surah == widget.surah && e.location.ayah == _ayah)
        .toList();
  }

  List<int> get _reviewedAyahs => widget.result?.reviewedAyahs ?? [_ayah];

  String _durationText(Duration d) {
    if (d.inMinutes > 0) {
      return '${d.inMinutes} دقيقة ${d.inSeconds % 60} ثانية';
    }
    return '${d.inSeconds} ثانية';
  }

  Future<void> _reRecite() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    final out = await startRecitationSession(
      context: context,
      engine: widget.engine,
      progressStore: widget.progressStore,
      passage: Passage(surah: widget.surah, fromAyah: _ayah, toAyah: _ayah),
      mode: RecitationMode.lookUp,
      tier: widget.progressStore.lastTier,
    );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _error = out.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final words = _ayahWords();
    final idx = _reviewedAyahs.indexOf(_ayah);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('مراجعة الآية')),
        body: ListView(
          padding: const EdgeInsets.all(spacePage),
          children: [
            _buildHeader(r),
            const SizedBox(height: 12),
            if (_error != null) ...[
              ErrorCard(message: _error),
              const SizedBox(height: 12),
            ],
            TilawaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'سورة ${surahName(widget.surah)} — الآية $_ayah',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  if (words.isEmpty)
                    const Text(
                      'تعذّر تحميل نص الآية.',
                      style: TextStyle(color: muted),
                    )
                  else
                    Wrap(
                      children: [
                        for (var wi = 0; wi < words.length; wi++)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: _wordBackground(_markOf(wi)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              words[wi],
                              style: const TextStyle(
                                fontSize: 26,
                                height: 2.0,
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
            const SizedBox(height: 12),
            _buildLegend(),
            const SizedBox(height: 12),
            _buildErrors(words),
            if (r == null) ...[
              const InfoNote(
                message: 'فُتحت هذه الآية من خريطة الحفظ بلا جلسة تسميع، '
                    'لذلك تظهر كلماتها بلا تظليل. سمّعها لتظهر نتيجة التتبع هنا.',
                icon: Icons.info_outline_rounded,
              ),
              const SizedBox(height: 12),
            ],
            if (_reviewedAyahs.length > 1) _buildPrevNext(idx),
            const SizedBox(height: 12),
            PrimaryButton(
              onPressed: _starting ? null : _reRecite,
              icon: _starting ? null : Icons.mic,
              label: _starting ? 'جارٍ الفحص…' : 'أعد تسميع هذه الآية',
            ),
            const SizedBox(height: 12),
            const Text(
              'الألوان للحفظ فقط: الكلمة الخضراء طابقها المحرك، والحمراء '
              'خطأ مؤكد، والصفراء تحتاج إعادة تحقق. المحرك لا يقيّم '
              'التجويد أو مخارج الحروف.',
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(SessionResult? r) {
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
                  'آيات للمراجعة: ${r?.reviewedAyahs.length ?? 1}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  r == null
                      ? 'سورة ${surahName(widget.surah)} — الآية $_ayah'
                      : 'مدة جلسة التسميع: ${_durationText(r.duration)}',
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

  Widget _buildLegend() {
    Widget chip(String label, Color bg) => Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radiusChip),
          ),
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('حفظ (مطابقة)', wordMatchedBg),
        chip('خطأ مؤكد', wordErrorBg),
        chip('ملاحظة', wordReviewBg),
      ],
    );
  }

  Widget _buildErrors(List<String> words) {
    final errors = _ayahErrors;
    if (errors.isEmpty) {
      if (widget.result == null) return const SizedBox.shrink();
      return const TilawaCard(
        child: Row(
          children: [
            Icon(Icons.check_circle, color: success),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'لا توجد أخطاء مؤكدة في هذه الآية في هذه الجلسة — أحسنت.',
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
          'الأخطاء في هذه الآية:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        ...errors.map((e) {
          final correct = e.location.word >= 1 &&
                  e.location.word <= words.length
              ? words[e.location.word - 1]
              : '—';
          // Confidence only when the session actually observed the word
          // (keyed "surah:ayah:word" in the result); null otherwise —
          // no fake numbers are ever shown.
          final conf =
              widget.result?.confidenceByWord[e.location.toString()];
          return ListTile(
            leading: const Icon(Icons.error, color: error),
            title: Text(
              '${errorClassLabel(e.errorClass)} — الكلمة ${e.location.word}: '
              '«$correct»',
            ),
            subtitle: conf != null
                ? Text(
                    'الثقة عند الملاحظة: ${(conf * 100).toStringAsFixed(0)}%')
                : null,
          );
        }),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildPrevNext(int idx) {
    return Row(
      children: [
        Expanded(
          child: SecondaryButton(
            onPressed: idx > 0
                ? () => setState(() => _ayah = _reviewedAyahs[idx - 1])
                : null,
            icon: Icons.arrow_back,
            label: 'الآية السابقة',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SecondaryButton(
            onPressed: idx >= 0 && idx < _reviewedAyahs.length - 1
                ? () => setState(() => _ayah = _reviewedAyahs[idx + 1])
                : null,
            icon: Icons.arrow_forward,
            label: 'الآية التالية',
          ),
        ),
      ],
    );
  }
}
