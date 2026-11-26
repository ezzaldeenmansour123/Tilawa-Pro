// Progress page (mockup screen 2 — «التقدم»).
//
// Every number comes from real stores: HifzStore (plans, items, reviews),
// ProgressStore (sessions, review dates) and quiz completions. Nothing
// is hardcoded: an empty store shows an honest empty state, never the
// mockup's numbers.
//
// What the mockup shows that this app does NOT have:
// - «الأهداف والبطاقات» (badges): the app has no badge system, so no
//   badge count is invented. The daily goal of the active plan is shown
//   instead, with today's real progress toward it.
// - The 7-day chart counts distinct ayahs reviewed per day (tasmee'
//   sessions + hifz reviews), not a single invented series.

import 'package:material_ui/material_ui.dart';

import '../../../core/theme.dart';
import '../../../core/widgets.dart';
import '../../../db.dart';
import '../../memorization/hifz_page.dart';
import '../../memorization/hifz_store.dart';
import '../progress_store.dart';
import '../surah_names.dart';
import '../tasmee_progress.dart';
import '../webview_engine.dart';
import 'ayah_review_screen.dart';
import 'mistakes_screen.dart';
import 'recitation_screen.dart';

class TasmeeProgressScreen extends StatefulWidget {
  const TasmeeProgressScreen({
    super.key,
    required this.engine,
    required this.progressStore,
    required this.hifz,
  });

  final WebViewEngine engine;
  final ProgressStore progressStore;
  final HifzStore hifz;

  @override
  State<TasmeeProgressScreen> createState() => _TasmeeProgressScreenState();
}

class _TasmeeProgressScreenState extends State<TasmeeProgressScreen> {
  bool _loaded = false;
  Map<int, int> _totalByJuz = {};
  Map<int, int> _memorizedByJuz = {};
  int _memorizedAyahs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.progressStore.load();
    await widget.hifz.load();
    final totalByJuz = <int, int>{};
    try {
      final rows = Repo.i.db.select(
          'SELECT juz AS j, COUNT(*) AS c FROM ayahs GROUP BY juz');
      for (final r in rows) {
        totalByJuz[r['j'] as int] = r['c'] as int;
      }
    } catch (_) {
      // The juz card degrades to an empty state; the rest still renders.
    }
    final memorizedByJuz = <int, int>{};
    var memorized = 0;
    for (final e in widget.hifz.items.entries) {
      if (e.value.reps <= 0) continue;
      memorized++;
      final juz = Repo.i.ayahById(e.key)?.juz;
      if (juz != null) {
        memorizedByJuz[juz] = (memorizedByJuz[juz] ?? 0) + 1;
      }
    }
    if (mounted) {
      setState(() {
        _totalByJuz = totalByJuz;
        _memorizedByJuz = memorizedByJuz;
        _memorizedAyahs = memorized;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('التقدم')),
          body: const Center(child: CircularProgressIndicator()),
        ),
      );
    }
    final sessions = widget.progressStore.sessions;
    final reviews = widget.hifz.reviews;
    final now = DateTime.now();
    final daily = dailyReviewedAyahs(
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
    final todayCount = todayReviewedAyahs(
      sessions: sessions,
      reviews: reviews,
      now: now,
      ayahIdOf: (s, a) => Repo.i.ayahByRef(s, a)?.id,
    );
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('التقدم')),
        body: ListView(
          padding: const EdgeInsets.all(spacePage),
          children: [
            _buildJuzCard(),
            const SizedBox(height: 12),
            _buildWeekChart(daily, now),
            const SizedBox(height: 12),
            _buildStatRow(streak, daily.fold(0, (a, b) => a + b)),
            const SizedBox(height: 12),
            _buildDailyGoal(todayCount),
            const SizedBox(height: 12),
            _buildHifzMap(),
            const SizedBox(height: 12),
            SecondaryButton(
              label: 'أخطائي (${widget.progressStore.openMistakes.length})',
              icon: Icons.list_alt,
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MistakesScreen(
                      engine: widget.engine,
                      progressStore: widget.progressStore,
                    ),
                  ),
                );
                await _load();
              },
            ),
            const SizedBox(height: 12),
            _buildRecentSessions(),
          ],
        ),
      ),
    );
  }

  Widget _buildJuzCard() {
    final j = juzProgress(
      totalByJuz: _totalByJuz,
      memorizedByJuz: _memorizedByJuz,
    );
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: goldLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    '${j.completed.length}',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: gold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'الجزء المحفوظ',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              SecondaryButton(
                label: 'تعديل',
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => HifzPage(store: widget.hifz),
                    ),
                  );
                  await _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_memorizedAyahs == 0)
            const Text(
              'لم تسجل أي حفظ بعد — أنشئ خطة حفظ من صفحة خطط الحفظ '
              'وسجّل حفظك فيها.',
              style: TextStyle(color: muted),
            )
          else ...[
            Text(
              j.completed.isEmpty
                  ? 'لا يوجد جزء مكتمل بعد — واصل الحفظ.'
                  : j.completed.length == 1
                      ? 'جزء واحد مكتمل الحفظ.'
                      : '${j.completed.length} أجزاء مكتملة الحفظ.',
            ),
            if (j.currentJuz != null) ...[
              const SizedBox(height: 8),
              Text(
                'الجزء ${j.currentJuz}: ${j.currentMemorized} من '
                '${j.currentTotal} آية محفوظة.',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 6),
              TilawaProgressBar(
                value: j.currentTotal == 0
                    ? 0.0
                    : j.currentMemorized / j.currentTotal,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildWeekChart(List<int> daily, DateTime now) {
    final maxValue = daily.fold(0, (a, b) => a > b ? a : b);
    final total = daily.fold(0, (a, b) => a + b);
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'مراجعة آية خلال آخر 7 أيام',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                '$total',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: brandPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${daily[i]}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: maxValue == 0
                              ? 4
                              : 4 + (daily[i] / maxValue) * 84,
                          margin:
                              const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: i == 6
                                ? brandPrimary
                                : daily[i] > 0
                                    ? sky
                                    : tealLight,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          arabicWeekdayShort(
                            now.subtract(Duration(days: 6 - i)),
                          ),
                          style: const TextStyle(
                              fontSize: 11, color: muted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (total == 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'لا توجد مراجعات في آخر 7 أيام.',
                style: TextStyle(color: muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatRow(int streak, int weekReviews) {
    return Row(
      children: [
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
            value: '$weekReviews',
            label: 'مراجعات (7 أيام)',
            icon: Icons.mic,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: StatTile(
            value: '$_memorizedAyahs',
            label: 'آيات محفوظة',
            icon: Icons.book,
            color: _memorizedAyahs > 0 ? success : null,
          ),
        ),
      ],
    );
  }

  Widget _buildDailyGoal(int todayCount) {
    final plan = widget.hifz.activePlan;
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'هدف اليوم',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          if (plan == null)
            const Text(
              'لا توجد خطة حفظ نشطة — أنشئ خطة من صفحة خطط الحفظ '
              'ليظهر هدفك اليومي هنا.',
              style: TextStyle(color: muted),
            )
          else ...[
            Text('خطتك «${plan.name}»: راجعت $todayCount من '
                '${plan.dailyAyahs} آيات اليوم.'),
            const SizedBox(height: 6),
            TilawaProgressBar(
              value: plan.dailyAyahs == 0
                  ? 0.0
                  : (todayCount / plan.dailyAyahs).clamp(0.0, 1.0).toDouble(),
            ),
          ],
        ],
      ),
    );
  }

  /// Dots of the active plan's range (or the last reviewed passage when
  /// there is no plan), coloured by the real HifzStatus of each ayah.
  Widget _buildHifzMap() {
    final plan = widget.hifz.activePlan;
    final refs = <({int surah, int ayah})>[];
    final range = plan?.idRange;
    if (range != null) {
      for (var id = range.$1; id <= range.$2 && refs.length < 300; id++) {
        final a = Repo.i.ayahById(id);
        if (a != null) refs.add((surah: a.surah, ayah: a.ayah));
      }
    } else {
      final last = widget.progressStore.lastPassage;
      if (last != null) {
        for (var a = last.fromAyah;
            a <= last.toAyah && refs.length < 300;
            a++) {
          refs.add((surah: last.surah, ayah: a));
        }
      }
    }
    return TilawaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'خريطة الحفظ',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              if (plan != null)
                Text(plan.name, style: const TextStyle(color: muted)),
            ],
          ),
          const SizedBox(height: 8),
          if (refs.isEmpty)
            const Text(
              'لا توجد خطة حفظ ولا مقطع سابق — ابدأ التسميع أولاً '
              'لتظهر خريطتك هنا.',
              style: TextStyle(color: muted),
            )
          else ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final ref in refs)
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AyahReviewScreen(
                          surah: ref.surah,
                          ayah: ref.ayah,
                          engine: widget.engine,
                          progressStore: widget.progressStore,
                        ),
                      ),
                    ),
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _dotColor(ref),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Builder(builder: (_) {
              final rangeLen = plan?.idRange;
              final truncated = rangeLen != null &&
                  (rangeLen.$2 - rangeLen.$1 + 1) > 300;
              return Text(
                '${refs.length} آية معروضة'
                '${truncated ? ' (أول 300 آية من النطاق)' : ''} — اضغط أي نقطة لمراجعة الآية.',
                style: const TextStyle(fontSize: 12, color: muted),
              );
            }),
          ],
        ],
      ),
    );
  }

  Color _dotColor(({int surah, int ayah}) ref) {
    final id = Repo.i.ayahByRef(ref.surah, ref.ayah)?.id;
    final item = id == null ? null : widget.hifz.items[id];
    if (item == null) return tealLight;
    return switch (item.statusOn(DateTime.now())) {
      HifzStatus.fresh => tealLight,
      HifzStatus.learning => sky,
      HifzStatus.reviewing => gold,
      HifzStatus.mastered => success,
      HifzStatus.urgent => error,
    };
  }

  Widget _buildRecentSessions() {
    final sessions = widget.progressStore.sessions.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'سجل التلاوات الأخيرة'),
        const SizedBox(height: 8),
        if (sessions.isEmpty)
          const TilawaCard(
            child: Text(
              'لا توجد جلسات تسميع بعد — ابدأ أول جلسة من اختبار التلاوة.',
              style: TextStyle(color: muted),
            ),
          )
        else
          ...sessions.map((s) {
            final r = s.result;
            final d = r.endedAt;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TilawaCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.play_circle_fill,
                        color: brandPrimary, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'سورة ${surahName(r.surah)} — الآيات '
                            '${r.fromAyah}–${r.toAyah}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                          Text(
                            'مطابقة نصية: ${r.matchPercent == null ? 'لا توجد بيانات' : '${r.matchPercent!.toStringAsFixed(0)}٪'}'
                            ' • ${d.day}/${d.month}/${d.year}',
                            style: const TextStyle(color: muted),
                          ),
                        ],
                      ),
                    ),
                    SecondaryButton(
                      label: 'إعادة',
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RecitationScreen(
                            engine: widget.engine,
                            progressStore: widget.progressStore,
                            initialPassage: (
                              surah: r.surah,
                              fromAyah: r.fromAyah,
                              toAyah: r.toAyah,
                            ),
                            initialMode: r.mode,
                            initialTier: r.tier,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}
