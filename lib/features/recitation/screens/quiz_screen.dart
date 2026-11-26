// Tasmee' quiz page (mockup screen 1 — «اختبار التلاوة»).
//
// The entry point of the tasmee' section: 5 «complete the ayah»
// questions. Each question shows the beginning of an ayah (from the
// app's own Quran DB, display only) and hides the rest; the user recites
// the completion by voice — a REAL session through the shared gate
// (session_starter.dart: model → WASM → mic → engine load → passage),
// exam mode, text hidden — or answers without voice, which reveals the
// full ayah and is recorded as such, NEVER counted as correct.
//
// Question sources, in order (see tasmee_progress.buildQuizQuestions):
// ayahs with repeated confirmed errors, then the last reviewed passage,
// then the ready-made passages (Al-Fatiha) when there is no history.
// The source line on this page says which one applied — honestly.

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../../db.dart';
import '../../memorization/hifz_store.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../session_starter.dart';
import '../speech_engine.dart';
import '../surah_names.dart';
import '../tasmee_progress.dart';
import '../webview_engine.dart';
import 'mistakes_screen.dart';
import 'recitation_screen.dart';
import 'tasmee_progress_screen.dart';

class _QuizOutcome {
  const _QuizOutcome({
    required this.byVoice,
    this.matchPercent,
    this.errorCount,
  });

  final bool byVoice;
  final double? matchPercent;
  final int? errorCount;
}

class TasmeeQuizScreen extends StatefulWidget {
  const TasmeeQuizScreen({
    super.key,
    required this.engine,
    required this.progressStore,
    required this.hifz,
  });

  final WebViewEngine engine;
  final ProgressStore progressStore;
  final HifzStore hifz;

  @override
  State<TasmeeQuizScreen> createState() => _TasmeeQuizScreenState();
}

class _TasmeeQuizScreenState extends State<TasmeeQuizScreen> {
  bool _loaded = false;
  List<QuizQuestion> _questions = [];
  Set<QuizQuestionSource> _sources = {};
  int _index = 0;
  List<_QuizOutcome?> _outcomes = [];
  bool _revealed = false;
  bool _busy = false;
  String _busyLabel = 'جارٍ الفحص…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    await widget.progressStore.load();
    await widget.hifz.load();
    final built = buildQuizQuestions(
      errorAyahs: widget.progressStore.topErrorAyahs(limit: 10),
      lastPassage: widget.progressStore.lastPassage,
      wordCountOf: (s, a) => _ayahWords(s, a).length,
    );
    if (mounted) {
      setState(() {
        // Keep the user's in-progress answers when the questions did
        // not change (e.g. returning from the progress page mid-quiz);
        // reset them only on an explicit restart or a new question set.
        final same = !reset &&
            _questions.length == built.questions.length &&
            _questions.asMap().entries.every(
                (e) => e.value == built.questions[e.key]);
        _questions = built.questions;
        _sources = built.sources;
        if (!same) {
          _outcomes = List.filled(built.questions.length, null);
          _index = 0;
          _revealed = false;
        }
        _loaded = true;
      });
    }
  }

  List<String> _ayahWords(int surah, int ayah) {
    final a = Repo.i.ayahByRef(surah, ayah);
    if (a == null) return [];
    return a.text.split(' ').where((w) => w.isNotEmpty).toList();
  }

  bool get _done =>
      _questions.isNotEmpty && _outcomes.every((o) => o != null);

  QuizQuestion get _current => _questions[_index];

  Future<void> _answerByVoice() async {
    if (_busy || _done) return;
    final q = _current;
    setState(() {
      _busy = true;
      _busyLabel = 'جارٍ الفحص…';
      _error = null;
    });
    final out = await startRecitationSession(
      context: context,
      engine: widget.engine,
      progressStore: widget.progressStore,
      passage: Passage(surah: q.surah, fromAyah: q.ayah, toAyah: q.ayah),
      mode: RecitationMode.exam,
      tier: widget.progressStore.lastTier,
      returnResult: true,
      onLoadingLabel: (label) {
        if (mounted) setState(() => _busyLabel = label);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = out.error;
    });
    if (out.result != null) {
      _recordOutcome(_QuizOutcome(
        byVoice: true,
        matchPercent: out.result!.matchPercent,
        errorCount: out.result!.errorCount,
      ));
    }
    // A null result means the user backed out of the session: the
    // question stays unanswered, no outcome is recorded.
  }

  void _answerWithoutVoice() {
    if (_done) return;
    setState(() => _revealed = true);
  }

  void _recordOutcome(_QuizOutcome outcome) async {
    final isLast = _index >= _questions.length - 1;
    setState(() {
      _outcomes[_index] = outcome;
      _revealed = false;
      if (!isLast) _index++;
    });
    if (isLast) {
      await widget.progressStore.recordQuizCompletion();
    }
  }

  void _restart() {
    setState(() => _error = null);
    _load(reset: true);
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => page),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('اختبار التلاوة'),
          actions: [
            IconButton(
              icon: const Icon(Icons.bar_chart),
              tooltip: 'التقدم',
              onPressed: () => _open(TasmeeProgressScreen(
                engine: widget.engine,
                progressStore: widget.progressStore,
                hifz: widget.hifz,
              )),
            ),
          ],
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : _questions.isEmpty
                ? const EmptyState(
                    icon: Icons.quiz_outlined,
                    text: 'تعذّر تحميل أسئلة الاختبار — تحقق من تثبيت '
                        'المكتبة وحاول مجدداً.',
                  )
                : ListView(
                    padding: const EdgeInsets.all(spacePage),
                    children: [
                      if (_done) _buildSummary() else _buildQuestion(),
                      const SizedBox(height: 12),
                      _buildLinks(),
                    ],
                  ),
      ),
    );
  }

  Widget _buildQuestion() {
    final q = _current;
    final words = _ayahWords(q.surah, q.ayah);
    final shownCount = (words.length / 2).ceil().clamp(1, words.length);
    final shown = words.take(shownCount).join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            StatusChip(
              tone: StatusTone.info,
              label: 'السؤال ${_index + 1} من ${_questions.length}',
            ),
            const SizedBox(width: 8),
            const StatusChip(tone: StatusTone.ok, label: 'أكمل الآية'),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'أكمل تلاوة الآية الكريمة',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        TilawaCard(
          child: Column(
            children: [
              AyahText(
                text: _revealed ? words.join(' ') : '$shown …',
                fontSize: 24,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'سورة ${surahName(q.surah)} — الآية ${q.ayah}',
                style: const TextStyle(color: muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          quizSourceLabel(_sources),
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted),
        ),
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            onTap: _busy ? null : _answerByVoice,
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _busy ? muted : brandPrimary,
                boxShadow: [
                  BoxShadow(
                    color: brandPrimary.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(38),
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 3,
                      ),
                    )
                  : const Icon(Icons.mic, color: Colors.white, size: 52),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _busy ? _busyLabel : 'اضغط على الدائرة وتل تلاوتك',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        const Text(
          'صوتك لا يغادر جهازك — يُحلَّل على هاتفك فقط.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          ErrorCard(message: _error),
          const SizedBox(height: 8),
          SecondaryButton(
            label: 'فتح إعداد التسميع',
            icon: Icons.settings,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecitationScreen(
                  engine: widget.engine,
                  progressStore: widget.progressStore,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_revealed) ...[
          const InfoNote(
            message: 'أُظهرت الآية كاملة — هذه الإجابة بدون صوت لا تُحتسب '
                'نتيجة، وستنتقل للسؤال التالي.',
            icon: Icons.volume_off_rounded,
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            onPressed: () =>
                _recordOutcome(const _QuizOutcome(byVoice: false)),
            icon: Icons.arrow_back,
            label: 'التالي',
          ),
        ] else
          SecondaryButton(
            label: 'أجب بدون صوت',
            icon: Icons.volume_off_rounded,
            onPressed: _busy ? null : _answerWithoutVoice,
          ),
      ],
    );
  }

  Widget _buildSummary() {
    final voiceCount = _outcomes.where((o) => o?.byVoice == true).length;
    final errorTotal = _outcomes.fold<int>(
        0, (a, o) => a + (o?.errorCount ?? 0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TilawaCard(
          child: Column(
            children: [
              const Icon(Icons.emoji_events_rounded,
                  color: gold, size: 48),
              const SizedBox(height: 8),
              const Text(
                'اكتمل الاختبار',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'أجبت بصوتك على $voiceCount من ${_questions.length} أسئلة'
                ' • أخطاء مؤكدة: $errorTotal',
                textAlign: TextAlign.center,
                style: const TextStyle(color: muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ...List.generate(_questions.length, (i) {
          final q = _questions[i];
          final o = _outcomes[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TilawaCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    o?.byVoice == true
                        ? (o!.errorCount == 0
                            ? Icons.check_circle
                            : Icons.error)
                        : Icons.volume_off_rounded,
                    color: o?.byVoice == true
                        ? (o!.errorCount == 0 ? success : error)
                        : muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'سورة ${surahName(q.surah)} — الآية ${q.ayah}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    o?.byVoice == true
                        ? (o!.matchPercent == null
                            ? 'صوت — بلا بيانات'
                            : 'مطابقة ${o.matchPercent!.toStringAsFixed(0)}٪')
                        : 'بدون صوت',
                    style: const TextStyle(color: muted),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        PrimaryButton(
          onPressed: () => _open(MistakesScreen(
            engine: widget.engine,
            progressStore: widget.progressStore,
          )),
          icon: Icons.list_alt,
          label: 'مراجعة الأخطاء',
        ),
        const SizedBox(height: 8),
        SecondaryButton(
          onPressed: _restart,
          icon: Icons.replay,
          label: 'إعادة الاختبار',
        ),
      ],
    );
  }

  Widget _buildLinks() {
    return Row(
      children: [
        Expanded(
          child: SecondaryButton(
            label: 'التقدم',
            icon: Icons.bar_chart,
            onPressed: () => _open(TasmeeProgressScreen(
              engine: widget.engine,
              progressStore: widget.progressStore,
              hifz: widget.hifz,
            )),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SecondaryButton(
            label: 'أخطائي',
            icon: Icons.list_alt,
            onPressed: () => _open(MistakesScreen(
              engine: widget.engine,
              progressStore: widget.progressStore,
            )),
          ),
        ),
      ],
    );
  }
}
