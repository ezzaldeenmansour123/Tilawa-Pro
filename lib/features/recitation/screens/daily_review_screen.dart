// Daily review page (mockup screen 5 — «مراجعة يومية»).
//
// «اختبار اليوم» is complete when the user did any tasmee' session today
// or completed a full quiz today (ProgressStore.quizDoneToday) — that is
// the stated rule, not a guess. All counts come from the real stores
// (ProgressStore sessions, HifzStore reviews/items, open mistakes).
// «ابدأ التسميع» opens the setup screen; «ابدأ اختبار اليوم» opens the
// 5-question quiz.

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../../db.dart';
import '../../memorization/hifz_store.dart';
import '../progress_store.dart';
import '../tasmee_progress.dart';
import '../webview_engine.dart';
import 'mistakes_screen.dart';
import 'quiz_screen.dart';
import 'recitation_screen.dart';
import 'tasmee_progress_screen.dart';

class DailyReviewScreen extends StatefulWidget {
  const DailyReviewScreen({
    super.key,
    required this.engine,
    required this.progressStore,
    required this.hifz,
  });

  final WebViewEngine engine;
  final ProgressStore progressStore;
  final HifzStore hifz;

  @override
  State<DailyReviewScreen> createState() => _DailyReviewScreenState();
}

class _DailyReviewScreenState extends State<DailyReviewScreen> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.progressStore.load();
    await widget.hifz.load();
    if (mounted) setState(() => _loaded = true);
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
    if (!_loaded) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('مراجعة يومية')),
          body: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final sessions = widget.progressStore.sessions;
    final reviews = widget.hifz.reviews;
    final now = DateTime.now();
    final todayCount = todayReviewedAyahs(
      sessions: sessions,
      reviews: reviews,
      now: now,
      ayahIdOf: (s, a) => Repo.i.ayahByRef(s, a)?.id,
    );
    final streak = combinedStreakDays(
      sessions: sessions,
      reviews: reviews,
      quizDates: widget.progressStore.quizCompletionDates,
      now: now,
    );
    final today = _dayOnly(now);
    final sessionToday = sessions.any(
        (s) => _dayOnly(s.result.endedAt) == today);
    final doneToday =
        sessionToday || widget.progressStore.quizDoneToday;
    final plan = widget.hifz.activePlan;
    final openMistakes = widget.progressStore.openMistakes.length;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مراجعة يومية'),
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
        body: ListView(
          padding: const EdgeInsets.all(spacePage),
          children: [
            _buildTodayTest(doneToday),
            const SizedBox(height: 12),
            _buildStatRow(todayCount, streak, plan),
            const SizedBox(height: 12),
            _buildMistakesCard(openMistakes),
            const SizedBox(height: 12),
            _buildVoiceCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildTodayTest(bool doneToday) {
    return TilawaCard(
      gradient: const LinearGradient(
        colors: [brandPrimary, brandPrimaryDark],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'اختبار اليوم',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  doneToday
                      ? 'أكملت مراجعة اليوم — أحسنت.'
                      : 'لم تكمل مراجعة اليوم بعد.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 200,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: brandPrimaryDark,
                    ),
                    onPressed: () => _open(TasmeeQuizScreen(
                      engine: widget.engine,
                      progressStore: widget.progressStore,
                      hifz: widget.hifz,
                    )),
                    child: Text(doneToday
                        ? 'إعادة اختبار اليوم'
                        : 'ابدأ اختبار اليوم'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: doneToday
                  ? success
                  : Colors.white.withValues(alpha: 0.25),
            ),
            child: Icon(
              doneToday ? Icons.check : Icons.quiz_outlined,
              color: Colors.white,
              size: 32,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(int todayCount, int streak, HifzPlan? plan) {
    return Row(
      children: [
        Expanded(
          child: StatTile(
            value: '$todayCount',
            label: 'آيات تمت مراجعتها',
            icon: Icons.book,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StatTile(
            value: '$streak',
            label: 'يوم متواصل',
            icon: Icons.local_fire_department,
            color: streak > 0 ? warning : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StatTile(
            value: plan == null ? '—' : '$todayCount/${plan.dailyAyahs}',
            label: 'الأهداف للمراجعات',
            icon: Icons.flag,
          ),
        ),
      ],
    );
  }

  Widget _buildMistakesCard(int openMistakes) {
    return TilawaCard(
      onTap: () => _open(MistakesScreen(
        engine: widget.engine,
        progressStore: widget.progressStore,
      )),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: pinkSoft,
            ),
            child: const Icon(Icons.error_outline_rounded, color: error),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مراجعة الأخطاء',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                Text(
                  openMistakes == 0
                      ? 'لا توجد أخطاء مسجلة — أحسنت.'
                      : 'راجع ${openMistakes == 1 ? 'الآية التي فيها خطأ' : 'الآيات التي فيها أخطاء'} '
                          'وصححها قبل أن تتراكم.',
                  style: const TextStyle(color: muted),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_left, color: muted),
        ],
      ),
    );
  }

  Widget _buildVoiceCard() {
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'التلاوة بصوتك',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'استمع بالتلاوة وتابع علاماتك.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            onPressed: () => _open(RecitationScreen(
              engine: widget.engine,
              progressStore: widget.progressStore,
            )),
            icon: Icons.mic,
            label: 'ابدأ التسميع',
          ),
        ],
      ),
    );
  }
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
