// Session page: the real recitation session.
//
// Navigation: the setup screen (recitation_screen.dart) checks everything
// (model, WASM, mic permission, engine load) and THEN pushes this page.
// This page starts the engine session, shows the passage, and ends with a
// results page (results_screen.dart).
//
// Rules this page never breaks:
// - Ayah text comes from engine.passageWords() only (the engine's own
//   ref-v2.json) — never typed, never invented.
// - A word is green ONLY when the engine observed it (locked, confidence
//   >= 0.6). Red ONLY for a CONFIRMED checker event. Yellow for
//   `uncertain` (re-check, never an error). Anything else is unmarked:
//   an ayah with no position events is "not reviewed", never "correct".
// - No tajweed / makharij claims anywhere: the engine detects
//   memorization mistakes only (see session_logic.dart).
// - Pause/resume is honest: the engine has no pause. Pausing ends the
//   engine session (mic off, session ended) and resuming starts a NEW
//   engine session on the same passage; the log stays open, segment
//   boundaries are recorded, and matched words are de-duplicated across
//   segments (see WebViewEngine.endSegment).
// - Only one recording session can run: WebViewEngine.startSession throws
//   while another session is live, and this page guards its own phases.

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../models.dart';
import '../progress_store.dart';
import '../session_logic.dart';
import '../speech_engine.dart';
import '../surah_names.dart';
import '../webview_engine.dart';
import 'results_screen.dart';

enum SessionPhase { starting, recording, paused, ended, failed }

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.engine,
    required this.passage,
    required this.mode,
    required this.tier,
    required this.words,
    required this.progressStore,
    this.loadMs,
  });

  final WebViewEngine engine;
  final Passage passage;
  final RecitationMode mode;
  final String tier;

  /// Passage words from engine.passageWords(), one list per ayah,
  /// fromAyah..toAyah in order.
  final List<List<String>> words;
  final ProgressStore progressStore;

  /// Milliseconds the engine load took (measured by the setup screen),
  /// shown in the live stats; null when unknown.
  final int? loadMs;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  SessionPhase _phase = SessionPhase.starting;
  final WordTracker _tracker = WordTracker();
  late bool _hidden;
  double _fontSize = 26;
  StreamSubscription<Object>? _sub;
  String? _error;
  String? _sessionId;
  DateTime? _startedAt;
  DateTime? _sessionStartWall;
  int _segments = 1;
  int? _lastLatencyMs;
  int _focusedAyah = 0;
  int _visibleAyah = 0;
  DateTime? _lastPositionWall;
  bool _pulse = true;
  Timer? _ticker;
  final Map<int, GlobalKey> _ayahKeys = {};

  @override
  void initState() {
    super.initState();
    _hidden = widget.mode.textInitiallyHidden;
    _focusedAyah = widget.passage.fromAyah;
    for (var a = widget.passage.fromAyah; a <= widget.passage.toAyah; a++) {
      _ayahKeys[a] = GlobalKey();
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == SessionPhase.recording) {
        setState(() => _pulse = !_pulse);
      }
    });
    _begin();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    // If the user leaves mid-session (system back), end the engine
    // session so the mic is released and the log is closed.
    if (_phase == SessionPhase.recording || _phase == SessionPhase.paused) {
      unawaited(widget.engine.endSession());
    }
    super.dispose();
  }

  Future<void> _begin() async {
    if (widget.words.length !=
        widget.passage.toAyah - widget.passage.fromAyah + 1) {
      setState(() {
        _phase = SessionPhase.failed;
        _error = 'نص المقطع غير مكتمل من المرجع — أعد المحاولة.';
      });
      return;
    }
    try {
      _sessionId = 'rec-${DateTime.now().millisecondsSinceEpoch}';
      _startedAt = DateTime.now();
      await widget.engine.beginLog(
        sessionId: _sessionId!,
        meta: {
          'passage':
              '${widget.passage.surah}:${widget.passage.fromAyah}-${widget.passage.toAyah}',
          'mode': widget.mode.name,
          'tier': widget.tier,
          'segments': 1,
          'conditions': 'غرفة هادئة — سرعة عادية (عدّلها في السجل إن تغيّرت)',
        },
      );
      await _startSegment();
      if (mounted) setState(() => _phase = SessionPhase.recording);
    } on SpeechEngineException catch (e) {
      if (mounted) {
        setState(() {
          _phase = SessionPhase.failed;
          _error = e.toString();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = SessionPhase.failed;
          _error = 'خطأ غير متوقع: $e';
        });
      }
    }
  }

  /// Starts (or re-starts, after a pause) one engine segment on the same
  /// passage. The audio clock restarts with every segment, so the wall
  /// anchor is re-taken here for correct latency math.
  Future<void> _startSegment() async {
    _sessionStartWall = DateTime.now();
    _sub = widget.engine
        .startSession(
          mode: SessionMode.memorization,
          passage: widget.passage,
        )
        .listen(
          _onEvent,
          onError: (e) => setState(() => _error = e.toString()),
        );
  }

  void _onEvent(Object event) {
    if (event is PositionEvent) {
      final best = event.observed.isNotEmpty ? event.observed.first : null;
      if (best != null && _sessionStartWall != null) {
        final latency = DateTime.now().difference(_sessionStartWall!).inMilliseconds -
            event.timeMs;
        _lastLatencyMs = latency;
      }
      _lastPositionWall = DateTime.now();
      final newAyah = best?.ayah;
      setState(() {
        _tracker.observe(event);
        if (newAyah != null && newAyah != _visibleAyah) {
          _visibleAyah = newAyah;
          _focusedAyah = newAyah;
        }
      });
      if (newAyah != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAyah(newAyah));
      }
    } else if (event is CheckerEvent) {
      setState(() => _tracker.applyChecker(event));
    }
  }

  void _scrollToAyah(int ayah) {
    final ctx = _ayahKeys[ayah]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.15,
      );
    }
  }

  Future<void> _pause() async {
    if (_phase != SessionPhase.recording) return;
    setState(() => _phase = SessionPhase.paused);
    await _sub?.cancel();
    _sub = null;
    try {
      await widget.engine.endSegment(segment: _segments);
    } on SpeechEngineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _resume() async {
    if (_phase != SessionPhase.paused) return;
    _segments++;
    try {
      await widget.engine.appendLogMeta({
        'event': 'segment-started',
        'segment': _segments,
      });
      await _startSegment();
      if (mounted) setState(() => _phase = SessionPhase.recording);
    } on SpeechEngineException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } catch (e) {
      if (mounted) setState(() => _error = 'خطأ غير متوقع: $e');
    }
  }

  Future<void> _end() async {
    if (_phase == SessionPhase.ended) return;
    await _sub?.cancel();
    _sub = null;
    try {
      await widget.engine.endSession();
    } catch (_) {
      // Ending is best-effort; the result below is computed from the
      // events already received, so it stays valid.
    }
    if (!mounted) return;
    setState(() => _phase = SessionPhase.ended);
    final result = computeSessionResult(
      passage: widget.passage,
      words: widget.words,
      tracker: _tracker,
      mode: widget.mode,
      tier: widget.tier,
      segments: _segments,
      startedAt: _startedAt ?? DateTime.now(),
      endedAt: DateTime.now(),
    );
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ResultsScreen(
          result: result,
          words: widget.words,
          engine: widget.engine,
          progressStore: widget.progressStore,
        ),
      ),
    );
  }

  Color _wordBackground(RefWord ref) {
    switch (_tracker.markOf(ref)) {
      case WordMark.matched:
        return wordMatchedBg;
      case WordMark.error:
        return wordErrorBg;
      case WordMark.needsReview:
        return wordReviewBg;
      case WordMark.notReviewed:
        return Colors.transparent;
    }
  }

  bool _ayahReviewed(int ayah) {
    final idx = ayah - widget.passage.fromAyah;
    if (idx < 0 || idx >= widget.words.length) return false;
    for (var w = 0; w < widget.words[idx].length; w++) {
      final ref = RefWord(surah: widget.passage.surah, ayah: ayah, word: w + 1);
      if (_tracker.matched.contains(ref) ||
          _tracker.confirmedErrors.any((e) => e.location == ref)) {
        return true;
      }
    }
    return false;
  }

  String get _elapsed {
    final start = _startedAt;
    if (start == null) return '00:00';
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final caps = widget.engine.capabilities;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('جلسة التسميع'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (_phase == SessionPhase.recording ||
                  _phase == SessionPhase.paused) {
                await _end();
              } else {
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ),
        body: _phase == SessionPhase.failed
            ? _buildError()
            : ListView(
                padding: const EdgeInsets.all(spacePage),
                children: [
                  if (_error != null)
                    ErrorCard(
                      message: '$_error\nأنهِ الجلسة وأعد المحاولة.',
                    ),
                  if (_error != null) const SizedBox(height: 12),
                  _buildHeader(caps),
                  const SizedBox(height: 12),
                  _buildControls(),
                  const SizedBox(height: 12),
                  _buildLiveStats(),
                  const SizedBox(height: 12),
                  _buildZoomRow(),
                  const SizedBox(height: 8),
                  ..._buildAyahs(),
                  const SizedBox(height: 12),
                  _buildErrors(),
                  _buildNotes(),
                  const SizedBox(height: 8),
                  const Text(
                    'تصحيح الكلمات فقط — المحرك لا يقيّم التجويد أو مخارج '
                    'الحروف. التردد أو الصمت القصير لا يُحسب خطأً.',
                    style: TextStyle(color: muted),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildError() {
    return ListView(
      padding: const EdgeInsets.all(spacePage),
      children: [
        ErrorCard(message: _error ?? 'تعذّر بدء الجلسة.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back),
          label: const Text('رجوع إلى الإعداد'),
        ),
      ],
    );
  }

  Widget _buildHeader(EngineCapabilities? caps) {
    final recording = _phase == SessionPhase.recording;
    final paused = _phase == SessionPhase.paused;
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'سورة ${surahName(widget.passage.surah)} — الآيات '
            '${widget.passage.fromAyah}–${widget.passage.toAyah}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text('الوضع: ${widget.mode.label}',
              style: const TextStyle(color: muted)),
          Text(
            'النموذج: ${widget.tier} (${caps?.modelVersion ?? 'يُحمَّل…'})',
            style: const TextStyle(color: muted),
          ),
          Text(
            'المحرك: ${caps?.backend ?? '—'} • الميكروفون: مسموح',
            style: const TextStyle(color: muted),
          ),
          const SizedBox(height: 8),
          Row(
              children: [
                AnimatedOpacity(
                  opacity: recording ? (_pulse ? 1.0 : 0.25) : 1.0,
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: recording
                          ? error
                          : paused
                              ? warning
                              : muted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  recording
                      ? 'جارٍ التسجيل  •  $_elapsed'
                      : paused
                          ? 'متوقف مؤقتاً  •  $_elapsed'
                          : _phase == SessionPhase.starting
                              ? 'جارٍ بدء الجلسة…'
                              : 'الجلسة منتهية',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (recording)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _lastPositionWall == null
                      ? 'المحرك يستمع… بانتظار الصوت.'
                      : 'المحرك يستمع ويحلّل التلاوة.',
                  style: const TextStyle(color: muted),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final starting = _phase == SessionPhase.starting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrimaryButton(
          tonal: true,
          onPressed: () => setState(() => _hidden = !_hidden),
          icon: _hidden ? Icons.visibility : Icons.visibility_off,
          label: _hidden ? 'إظهار الآيات' : 'إخفاء الآيات',
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _phase == SessionPhase.recording
                  ? PrimaryButton(
                      onPressed: _pause,
                      icon: Icons.pause,
                      label: 'إيقاف مؤقت',
                    )
                  : _phase == SessionPhase.paused
                      ? PrimaryButton(
                          onPressed: _resume,
                          icon: Icons.play_arrow,
                          label: 'استئناف',
                        )
                      : PrimaryButton(
                          onPressed: null,
                          icon: Icons.mic,
                          label: starting
                              ? 'جارٍ بدء الجلسة…'
                              : 'الجلسة منتهية',
                        ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SecondaryButton(
                onPressed: (_phase == SessionPhase.recording ||
                        _phase == SessionPhase.paused)
                    ? _end
                    : null,
                icon: Icons.stop,
                label: 'إنهاء الجلسة',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLiveStats() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        StatusChip(
          tone: StatusTone.neutral,
          label: 'التتبع: ${_tracker.currentState.name} • الثقة: '
              '${(_tracker.currentConfidence * 100).toStringAsFixed(0)}%',
        ),
        StatusChip(
          tone: StatusTone.ok,
          label: 'كلمات مطابقة: ${_tracker.matched.length}',
        ),
        StatusChip(
          tone: StatusTone.error,
          label: 'أخطاء مؤكدة: ${_tracker.confirmedErrors.length}',
        ),
        StatusChip(
          tone: StatusTone.warn,
          label: 'تحتاج مراجعة: ${_tracker.needsReview.length}',
        ),
        if (widget.loadMs != null)
          StatusChip(
            tone: StatusTone.info,
            label:
                'تحميل النموذج: ${(widget.loadMs! / 1000).toStringAsFixed(1)} ث',
          ),
        if (_lastLatencyMs != null)
          StatusChip(
            tone: StatusTone.info,
            label: 'آخر تظليل: ${_lastLatencyMs}ms',
          ),
        if (_segments > 1)
          StatusChip(
            tone: StatusTone.info,
            label: 'المقاطع: $_segments',
          ),
      ],
    );
  }

  Widget _buildZoomRow() {
    return Row(
      children: [
        const Text('حجم النص:'),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: _fontSize > 18
              ? () => setState(() => _fontSize -= 2)
              : null,
          tooltip: 'تصغير النص',
        ),
        Text('${_fontSize.toInt()}'),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: _fontSize < 36
              ? () => setState(() => _fontSize += 2)
              : null,
          tooltip: 'تكبير النص',
        ),
        const Spacer(),
        SecondaryButton(
          onPressed: _focusedAyah > widget.passage.fromAyah
              ? () {
                  setState(() => _focusedAyah--);
                  _scrollToAyah(_focusedAyah);
                }
              : null,
          icon: Icons.arrow_upward,
          label: 'الآية السابقة',
        ),
        const SizedBox(width: 8),
        SecondaryButton(
          onPressed: _focusedAyah < widget.passage.toAyah
              ? () {
                  setState(() => _focusedAyah++);
                  _scrollToAyah(_focusedAyah);
                }
              : null,
          icon: Icons.arrow_downward,
          label: 'الآية التالية',
        ),
      ],
    );
  }

  List<Widget> _buildAyahs() {
    final out = <Widget>[];
    for (var ai = 0; ai < widget.words.length; ai++) {
      final ayah = widget.passage.fromAyah + ai;
      final isCurrent = _tracker.current?.ayah == ayah;
      final reviewed = _ayahReviewed(ayah);
      out.add(
        Card(
          key: _ayahKeys[ayah],
          shape: RoundedRectangleBorder(
            side: isCurrent
                ? const BorderSide(color: brandPrimary, width: 2)
                : BorderSide.none,
            borderRadius: BorderRadius.circular(radiusCardSmall),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Chip(label: Text('الآية $ayah')),
                    const SizedBox(width: 8),
                    Text(
                      reviewed ? 'تمت مراجعتها' : 'لم تُراجَع بعد',
                      style: TextStyle(
                        color: reviewed ? success : muted,
                        fontWeight:
                            reviewed ? FontWeight.w700 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_hidden)
                  const Text(
                    'الآية مخفية — سمّع غيباً، ثم أظهرها للمراجعة.',
                    style: TextStyle(color: muted, fontSize: 16),
                  )
                else
                  Wrap(
                    children: [
                      for (var wi = 0; wi < widget.words[ai].length; wi++)
                        Builder(builder: (context) {
                          final ref = RefWord(
                            surah: widget.passage.surah,
                            ayah: ayah,
                            word: wi + 1,
                          );
                          final isCurrentWord = _tracker.current == ref;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: _wordBackground(ref),
                              border: isCurrentWord
                                  ? Border.all(color: brandPrimary, width: 2)
                                  : null,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              widget.words[ai][wi],
                              style: TextStyle(fontSize: _fontSize),
                            ),
                          );
                        }),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
      out.add(const SizedBox(height: 8));
    }
    return out;
  }

  Widget _buildErrors() {
    final errors = _tracker.confirmedErrors;
    if (errors.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'أخطاء مؤكدة:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        ...errors.map((m) {
          final idx = m.location.ayah - widget.passage.fromAyah;
          String correct = '—';
          if (idx >= 0 &&
              idx < widget.words.length &&
              m.location.word >= 1 &&
              m.location.word <= widget.words[idx].length) {
            correct = widget.words[idx][m.location.word - 1];
          }
          final conf = _tracker.confidenceByWord[m.location];
          return ListTile(
            leading: const Icon(Icons.error, color: error),
            title: Text(
              '${errorClassLabel(m.errorClass)} — الآية ${m.location.ayah}، '
              'الكلمة ${m.location.word}: «$correct»',
            ),
            subtitle: conf != null
                ? Text('الثقة عند الملاحظة: ${(conf * 100).toStringAsFixed(0)}%')
                : null,
          );
        }),
      ],
    );
  }

  Widget _buildNotes() {
    if (_tracker.notes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _tracker.notes
          .map((n) => ListTile(
                leading: const Icon(Icons.help_outline, color: muted),
                title: Text(n),
              ))
          .toList(),
    );
  }
}
