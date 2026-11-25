import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const _SelfAssessmentNote(),
              const SizedBox(height: 14),
              if (plan == null) ...[
                const Text(
                  'لا توجد خطة حفظ نشطة بعد. أنشئ خطتك الأولى — '
                  'حدّد نطاق السور والآيات وهدفك اليومي.',
                  style: TextStyle(fontSize: 14, height: 1.8),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _openCreatePlan(c),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('إنشاء خطة حفظ'),
                ),
              ] else ...[
                _PlanProgressCard(store: store, plan: plan),
                const SizedBox(height: 14),
                _TodaySection(store: store, plan: plan),
                const SizedBox(height: 14),
                _DueSection(store: store, plan: plan),
                const SizedBox(height: 14),
                _StatsCard(store: store),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () => _openCreatePlan(c),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('خطة جديدة (توقف الحالية)'),
                ),
              ],
              if (store.plans.length > 1) ...[
                const SizedBox(height: 18),
                const Text('خططك السابقة',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                for (final p in store.plans.where((p) => !p.active))
                  ListTile(
                    title: Text(p.name),
                    subtitle: Text(
                        'من سورة ${Repo.i.surah(p.startSurah)?.nameAr ?? ''} '
                        'إلى سورة ${Repo.i.surah(p.endSurah)?.nameAr ?? ''}'),
                    trailing: TextButton(
                      onPressed: () => store.setPlanActive(p.id, true),
                      child: const Text('تفعيل'),
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

/// بطاقة محلية بهوية التطبيق (لا تعتمد على softCard في main.dart
/// تفادياً لحلقة استيراد).
Widget _hifzCard(BuildContext c, {required Widget child}) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: dark ? const Color(0xFF1C2B33) : Colors.white,
      borderRadius: BorderRadius.circular(24),
      boxShadow: [
        BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4)),
      ],
    ),
    child: child,
  );
}

/// عرض آية واحدة من قاعدة البيانات حرفياً (خط أميري، بلا تحويل للنص).
Widget _ayahTile(Ayah a) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(a.text,
          style: const TextStyle(
              fontSize: 17, height: 1.9, fontWeight: FontWeight.w600, fontFamily: 'Amiri')),
      const SizedBox(height: 6),
      Text('سورة ${a.surahName} • آية ${a.ayah}',
          style: const TextStyle(fontSize: 12, color: gold)),
    ],
  );
}

/// تنبيه صريح في الواجهة: لا تصحيح آلي هنا — التقييم ذاتي.
class _SelfAssessmentNote extends StatelessWidget {
  const _SelfAssessmentNote();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: goldLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: gold),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'التقييم هنا ذاتي: أنت من يقيّم حفظك (سهل / صعب / أعد) بعد '
              'التسميع على نفسك أو على معلمك. لا يوجد تصحيح صوتي آلي في '
              'هذه الوحدة — محرك التسميع الذكي غير مدمج بعد.',
              style: TextStyle(fontSize: 12.5, height: 1.7),
            ),
          ),
        ],
      ),
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
    return _hifzCard(context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.menu_book_rounded, color: teal),
            const SizedBox(width: 8),
            Expanded(
              child: Text(plan.name,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            Text('${(p.ratio * 100).round()}٪',
                style: const TextStyle(fontWeight: FontWeight.w700, color: gold)),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
                value: p.ratio, minHeight: 8,
                backgroundColor: tealLight, color: teal),
          ),
          const SizedBox(height: 8),
          Text(
            'حفظت ${p.memorized} من ${p.total} آية — '
            'من سورة ${s1?.nameAr ?? ''} آية ${plan.startAyah} '
            'إلى سورة ${s2?.nameAr ?? ''} آية ${plan.endAyah}. '
            'هدفك اليومي: ${plan.dailyAyahs} ${plan.dailyAyahs == 1 ? 'آية' : 'آيات'}.',
            style: const TextStyle(fontSize: 13, height: 1.7),
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
      return _hifzCard(context,
          child: const Text('أتممت كل آيات نطاق هذه الخطة — تقبّل الله. '
              'يمكنك إنشاء خطة جديدة لنطاق آخر.',
              style: TextStyle(fontSize: 13, height: 1.7)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('حفظ اليوم',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Chip(label: Text('${fresh.length} آية')),
      ]),
      const SizedBox(height: 6),
      const Text('اقرأ الآيات من المصحف واحفظها، ثم اضغط «حفظتها» '
          'ليُجدول التطبيق أول مراجعة لها بعد 3 أيام.',
          style: TextStyle(fontSize: 13, height: 1.7)),
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: () async {
          await store.markMemorized(
              plan, fresh.map((a) => a.id).toList());
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('سُجّل حفظ اليوم — ستُراجَع بعد 3 أيام إن شاء الله')));
          }
        },
        icon: const Icon(Icons.check_circle_rounded),
        label: const Text('حفظتها'),
      ),
      const SizedBox(height: 14),
      for (final a in fresh)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _hifzCard(context, child: _ayahTile(a)),
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
        Chip(label: Text(due.isEmpty ? 'لا شيء مستحق' : '${due.length} آية')),
      ]),
      const SizedBox(height: 10),
      if (due.isEmpty)
        const Text('لا مراجعات مستحقة اليوم.',
            style: TextStyle(fontSize: 13, height: 1.7))
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
    return _hifzCard(context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ayahTile(ayah),
          const SizedBox(height: 8),
          Row(children: [
            if (status != null) Chip(label: Text(status.label)),
            const SizedBox(width: 6),
            if (item != null)
              Expanded(
                child: Text(
                    'الفاصل الحالي: ${item.intervalDays} ${item.intervalDays == 1 ? 'يوم' : 'أيام'} — قيّم حفظك لتُجدول المراجعة التالية.',
                    style: const TextStyle(fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 8),
          const Text('كيف كان حفظك؟ قيّم نفسك بصدق:',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.again),
                child: const Text('أعد'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.hard),
                child: const Text('صعب'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () => store.reviewAyah(plan, ayah.id, HifzRating.easy),
                child: const Text('سهل'),
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
    final s = store.stats(days: 7);
    return _hifzCard(context,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.bar_chart_rounded, color: sky),
            SizedBox(width: 8),
            Text('آخر 7 أيام — من سجلك أنت فقط',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          Text('مراجعات: ${s.total} — سهل: ${s.easy}، صعب: ${s.hard}، أعد: ${s.again}.',
              style: const TextStyle(fontSize: 13, height: 1.7)),
          Text('أيام متتالية راجعت فيها: ${s.streakDays}.',
              style: const TextStyle(fontSize: 13, height: 1.7)),
        ]));
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
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            FilledButton(
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
              child: const Text('حفظ الخطة'),
            ),
          ],
        ),
      ),
    );
  }
}
