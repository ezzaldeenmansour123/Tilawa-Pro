import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../db.dart';
import 'hifz_store.dart';

/// صفحة خطط الحفظ والتكرار المتباعد — تلاوة برو.
///
/// ملاحظة معمارية مقصودة: هذه الصفحة مكتفية ذاتياً (لا تستورد main.dart)
/// فلا حلقة اعتماد معه؛ تعرض نص الآيات بخط أميري مباشرة من قاعدة
/// البيانات عبر Repo.i، وتستخدم ألوان هوية التطبيق من core/theme.dart.
/// التقييم فيها ذاتي صريح من المستخدم (سهل / صعب / أعد) — لا يوجد
/// تصحيح صوتي آلي هنا؛ محرك التسميع الذكي غير مدمج بعد (قرار GO معلّق).

class HifzPage extends StatelessWidget {
  const HifzPage({super.key, required this.store});
  final HifzStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('خطط الحفظ')),
      body: AnimatedBuilder(
        animation: store,
        builder: (c, _) {
          final plan = store.activePlan;
          return ListView(
            padding: const EdgeInsets.fromLTRB(spacePage, 8, spacePage, 24),
            children: [
              const _SelfAssessmentNote(),
              const SizedBox(height: spaceSection),
              if (plan == null) ...[
                const Text(
                  'لا توجد خطة حفظ نشطة بعد. أنشئ خطتك الأولى — '
                  'حدّد نطاق السور والآيات وهدفك اليومي.',
                  style: TextStyle(fontSize: 14, height: 1.8, color: muted),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  onPressed: () => _openCreatePlan(c),
                  icon: Icons.add_rounded,
                  label: 'إنشاء خطة حفظ',
                ),
              ] else ...[
                _PlanProgressCard(store: store, plan: plan),
                const SizedBox(height: spaceSection),
                _TodaySection(store: store, plan: plan),
                const SizedBox(height: spaceSection),
                _DueSection(store: store, plan: plan),
                const SizedBox(height: spaceSection),
                _StatsCard(store: store),
                const SizedBox(height: spaceSection),
                SecondaryButton(
                  onPressed: () => _openCreatePlan(c),
                  icon: Icons.add_rounded,
                  label: 'خطة جديدة (توقف الحالية)',
                ),
              ],
              if (store.plans.length > 1) ...[
                const SizedBox(height: 18),
                const SectionHeader(title: 'خططك السابقة'),
                const SizedBox(height: 8),
                for (final p in store.plans.where((p) => !p.active))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TilawaCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: ListTile(
                        title: Text(p.name),
                        subtitle: Text(
                            'من سورة ${Repo.i.surah(p.startSurah)?.nameAr ?? ''} '
                            'إلى سورة ${Repo.i.surah(p.endSurah)?.nameAr ?? ''}'),
                        trailing: TextButton(
                          onPressed: () => store.setPlanActive(p.id, true),
                          child: const Text('تفعيل'),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _openCreatePlan(BuildContext c) async {
    await showModalBottomSheet(
      context: c,
      isScrollControlled: true,
      builder: (_) => _CreatePlanSheet(store: store),
    );
  }
}

/// عرض آية واحدة من قاعدة البيانات حرفياً (خط أميري، بلا تحويل للنص).
Widget _ayahTile(Ayah a) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AyahText(text: a.text, fontSize: 17, height: 1.9),
      const SizedBox(height: 6),
      Text('سورة ${a.surahName} • آية ${a.ayah}',
          style: const TextStyle(fontSize: 12, color: gold)),
    ],
  );
}

/// تنبيه صريح في الواجهة: لا تصحيح آلي هنا — التقييم ذاتي.
/// النص حرفي كما كان؛ أُعيد تقديمه فقط عبر InfoNote (خلفية goldLight).
class _SelfAssessmentNote extends StatelessWidget {
  const _SelfAssessmentNote();
  @override
  Widget build(BuildContext context) {
    return const InfoNote(
      message: 'التقييم هنا ذاتي: أنت من يقيّم حفظك (سهل / صعب / أعد) بعد '
          'التسميع على نفسك أو على معلمك. لا يوجد تصحيح صوتي آلي في '
          'هذه الوحدة — محرك التسميع الذكي غير مدمج بعد.',
    );
  }
}

class _PlanProgressCard extends StatelessWidget {
  const _PlanProgressCard({required this.store, required this.plan});
  final HifzStore store;
  final HifzPlan plan;

  @override
  Widget build(BuildContext context) {
    final p = store.progressOf(plan);
    final s1 = Repo.i.surah(plan.startSurah);
    final s2 = Repo.i.surah(plan.endSurah);
    return TilawaCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const CircleAvatar(
              radius: 20,
              backgroundColor: tealLight,
              child: Icon(Icons.menu_book_rounded, color: teal, size: 22),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(plan.name,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            Text('${(p.ratio * 100).round()}٪',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: brandPrimary)),
          ]),
          const SizedBox(height: 12),
          TilawaProgressBar(value: p.ratio, color: teal),
          const SizedBox(height: 8),
          Text(
            'حفظت ${p.memorized} من ${p.total} آية — '
            'من سورة ${s1?.nameAr ?? ''} آية ${plan.startAyah} '
            'إلى سورة ${s2?.nameAr ?? ''} آية ${plan.endAyah}. '
            'هدفك اليومي: ${plan.dailyAyahs} ${plan.dailyAyahs == 1 ? 'آية' : 'آيات'}.',
            style: const TextStyle(fontSize: 13, height: 1.7, color: muted),
          ),
        ]));
  }
}

class _TodaySection extends StatelessWidget {
  const _TodaySection({required this.store, required this.plan});
  final HifzStore store;
  final HifzPlan plan;

  @override
  Widget build(BuildContext context) {
    final fresh = store.todaysNew(plan);
    if (fresh.isEmpty) {
      return const TilawaCard(
          child: Text('أتممت كل آيات نطاق هذه الخطة — تقبّل الله. '
              'يمكنك إنشاء خطة جديدة لنطاق آخر.',
              style: TextStyle(fontSize: 13, height: 1.7)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('حفظ اليوم',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        StatusChip(label: '${fresh.length} آية', tone: StatusTone.info),
      ]),
      const SizedBox(height: 6),
      const Text('اقرأ الآيات من المصحف واحفظها، ثم اضغط «حفظتها» '
          'ليُجدول التطبيق أول مراجعة لها بعد 3 أيام.',
          style: TextStyle(fontSize: 13, height: 1.7, color: muted)),
      const SizedBox(height: 10),
      PrimaryButton(
        onPressed: () async {
          await store.markMemorized(
              plan, fresh.map((a) => a.id).toList());
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('سُجّل حفظ اليوم — ستُراجَع بعد 3 أيام إن شاء الله')));
          }
        },
        icon: Icons.check_circle_rounded,
        label: 'حفظتها',
      ),
      const SizedBox(height: 14),
      for (final a in fresh)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TilawaCard(child: _ayahTile(a)),
        ),
    ]);
  }
}

class _DueSection extends StatelessWidget {
  const _DueSection({required this.store, required this.plan});
  final HifzStore store;
  final HifzPlan plan;

  @override
  Widget build(BuildContext context) {
    final due = store.dueToday(plan);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('مراجعة اليوم',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        StatusChip(
            label: due.isEmpty ? 'لا شيء مستحق' : '${due.length} آية',
            tone: due.isEmpty ? StatusTone.neutral : StatusTone.warn),
      ]),
      const SizedBox(height: 10),
      if (due.isEmpty)
        const Text('لا مراجعات مستحقة اليوم.',
            style: TextStyle(fontSize: 13, height: 1.7, color: muted))
      else
        for (final a in due)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _DueAyahCard(store: store, plan: plan, ayah: a),
          ),
    ]);
  }
}

class _DueAyahCard extends StatelessWidget {
  const _DueAyahCard(
      {required this.store, required this.plan, required this.ayah});
  final HifzStore store;
  final HifzPlan plan;
  final Ayah ayah;

  @override
  Widget build(BuildContext context) {
    final item = store.items[ayah.id];
    final status = item?.statusOn(DateTime.now());
    // نغمة شارة الحالة من مستوى الحفظ الحالي فقط (عرض تقديمي) —
    // لا تغيير في منطق التقييم أو الجدولة.
    final statusTone = switch (status) {
      HifzStatus.urgent => StatusTone.error,
      HifzStatus.mastered => StatusTone.ok,
      HifzStatus.reviewing => StatusTone.info,
      _ => StatusTone.neutral,
    };
    return TilawaCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ayahTile(ayah),
          const SizedBox(height: 8),
          Row(children: [
            if (status != null)
              StatusChip(label: status.label, tone: statusTone),
            const SizedBox(width: 6),
            if (item != null)
              Expanded(
                child: Text(
                    'الفاصل الحالي: ${item.intervalDays} ${item.intervalDays == 1 ? 'يوم' : 'أيام'} — قيّم حفظك لتُجدول المراجعة التالية.',
                    style: const TextStyle(fontSize: 12, color: muted)),
              ),
          ]),
          const SizedBox(height: 8),
          const Text('كيف كان حفظك؟ قيّم نفسك بصدق:',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: SecondaryButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.again),
                label: 'أعد',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SecondaryButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.hard),
                label: 'صعب',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PrimaryButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.easy),
                label: 'سهل',
              ),
            ),
          ]),
        ]));
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.store});
  final HifzStore store;

  @override
  Widget build(BuildContext context) {
    // كل القيم من store.stats(days: 7) — سجل المستخدم الفعلي فقط،
    // بلا أي رقم مُخترع أو من التصميم المرجعي.
    final s = store.stats(days: 7);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        CircleAvatar(
          radius: 20,
          backgroundColor: skyLight,
          child: Icon(Icons.bar_chart_rounded, color: skyDeep, size: 22),
        ),
        SizedBox(width: 8),
        Expanded(
          child: Text('آخر 7 أيام — من سجلك أنت فقط',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
      ]),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.9,
        children: [
          StatTile(
              value: '${s.total}',
              label: 'مراجعات',
              color: brandPrimary,
              icon: Icons.bar_chart_rounded),
          StatTile(
              value: '${s.easy}',
              label: 'سهل',
              color: success,
              icon: Icons.check_circle_rounded),
          StatTile(
              value: '${s.hard}',
              label: 'صعب',
              color: warning,
              icon: Icons.trending_up_rounded),
          StatTile(
              value: '${s.again}',
              label: 'أعد',
              color: error,
              icon: Icons.replay_rounded),
          StatTile(
              value: '${s.streakDays}',
              label: 'أيام متتالية',
              color: gold,
              icon: Icons.local_fire_department_rounded),
        ],
      ),
    ]);
  }
}

class _CreatePlanSheet extends StatefulWidget {
  const _CreatePlanSheet({required this.store});
  final HifzStore store;

  @override
  State<_CreatePlanSheet> createState() => _CreatePlanSheetState();
}

class _CreatePlanSheetState extends State<_CreatePlanSheet> {
  final _name = TextEditingController();
  final _startAyah = TextEditingController(text: '1');
  final _endAyah = TextEditingController(text: '1');
  final _daily = TextEditingController(text: '5');
  int _startSurah = 1, _endSurah = 1;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _startAyah.dispose();
    _endAyah.dispose();
    _daily.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surahs = Repo.i.surahs();
    return Padding(
      padding: EdgeInsets.only(
        left: spacePage,
        right: spacePage,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('خطة حفظ جديدة',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: 'اسم الخطة', hintText: 'مثال: حفظ جزء عمّ'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _startSurah,
              decoration: const InputDecoration(labelText: 'سورة البداية'),
              items: [
                for (final s in surahs)
                  DropdownMenuItem(value: s.id, child: Text(s.nameAr)),
              ],
              onChanged: (v) => setState(() {
                _startSurah = v ?? 1;
                if (_endSurah < _startSurah) _endSurah = _startSurah;
              }),
            ),
            TextField(
              controller: _startAyah,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'آية البداية'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _endSurah,
              decoration: const InputDecoration(labelText: 'سورة النهاية'),
              items: [
                for (final s in surahs)
                  DropdownMenuItem(value: s.id, child: Text(s.nameAr)),
              ],
              onChanged: (v) => setState(() => _endSurah = v ?? 1),
            ),
            TextField(
              controller: _endAyah,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'آية النهاية'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _daily,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'الهدف اليومي (آيات)', hintText: '5'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              ErrorCard(message: _error!),
            ],
            const SizedBox(height: 16),
            PrimaryButton(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      final err = await widget.store.createPlan(
                        name: _name.text,
                        startSurah: _startSurah,
                        startAyah: int.tryParse(_startAyah.text.trim()) ?? 0,
                        endSurah: _endSurah,
                        endAyah: int.tryParse(_endAyah.text.trim()) ?? 0,
                        dailyAyahs: int.tryParse(_daily.text.trim()) ?? 0,
                      );
                      if (!context.mounted) return;
                      if (err != null) {
                        setState(() {
                          _error = err;
                          _saving = false;
                        });
                      } else {
                        Navigator.pop(context);
                      }
                    },
              label: 'حفظ الخطة',
            ),
          ],
        ),
      ),
    );
  }
}
