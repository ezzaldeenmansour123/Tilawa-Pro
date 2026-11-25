import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../db.dart';

/// وحدة خطط الحفظ والتكرار المتباعد — تلاوة برو.
/// محلية بالكامل (SharedPreferences + قاعدة SQLite الموجودة)، بلا إنترنت،
/// وبلا أي تصحيح آلي للتسميع: التقييم ذاتي يصرّح به المستخدم.
/// مفاتيح التخزين كلها بالبادئة `hifz_` ولا تمس أي مفتاح موجود
/// (favs/history/tags/notes/khatmah_q/warsh_ready/fav_reciters/wird_q/...).

/// تقييم المستخدم الذاتي لحفظه في مراجعة واحدة.
enum HifzRating { again, hard, easy }

extension HifzRatingLabel on HifzRating {
  String get label => switch (this) {
        HifzRating.again => 'أعد',
        HifzRating.hard => 'صعب',
        HifzRating.easy => 'سهل',
      };
}

/// مستوى الحفظ — مطابق لمستويات PLAN §4 القسم 4.
enum HifzStatus { fresh, learning, reviewing, mastered, urgent }

extension HifzStatusLabel on HifzStatus {
  String get label => switch (this) {
        HifzStatus.fresh => 'جديد',
        HifzStatus.learning => 'قيد الحفظ',
        HifzStatus.reviewing => 'قيد المراجعة',
        HifzStatus.mastered => 'متقن',
        HifzStatus.urgent => 'يحتاج مراجعة عاجلة',
      };
}

/// خطوات الفاصل المتباعد (بالأيام) — SM-2 مبسطة.
const List<int> hifzIntervalSteps = [1, 3, 7, 15, 30];
const int hifzMaxIntervalDays = 90;
const int hifzMaxReviewsKept = 2000;

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _parseDate(String s) {
  final p = s.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

// ───────── خطة حفظ ─────────
class HifzPlan {
  final String id;
  final String name;
  final int startSurah, startAyah, endSurah, endAyah;
  final int dailyAyahs;
  final DateTime startDate;
  final bool active;
  final DateTime createdAt;

  const HifzPlan({
    required this.id,
    required this.name,
    required this.startSurah,
    required this.startAyah,
    required this.endSurah,
    required this.endAyah,
    required this.dailyAyahs,
    required this.startDate,
    required this.active,
    required this.createdAt,
  });

  /// يتحقق من النطاق ضد قاعدة البيانات (عدد آيات كل سورة) ويرجع رسالة
  /// خطأ عربية، أو null إن كان النطاق صحيحاً.
  static String? validateRange(
      int startSurah, int startAyah, int endSurah, int endAyah) {
    final s1 = Repo.i.surah(startSurah);
    final s2 = Repo.i.surah(endSurah);
    if (s1 == null || s2 == null) return 'السورة غير موجودة في المصحف.';
    if (startAyah < 1 || startAyah > s1.ayahCount) {
      return 'سورة ${s1.nameAr} فيها ${s1.ayahCount} آية فقط.';
    }
    if (endAyah < 1 || endAyah > s2.ayahCount) {
      return 'سورة ${s2.nameAr} فيها ${s2.ayahCount} آية فقط.';
    }
    if (startSurah > endSurah ||
        (startSurah == endSurah && startAyah > endAyah)) {
      return 'نهاية النطاق قبل بدايته.';
    }
    return null;
  }

  /// معرّف الآية العمومي لبداية النطاق ونهايته (معرّفات الآيات متسلسلة،
  /// فالنطاق مجال متصل من id). يرجع null إن تعذّر التحويل.
  (int, int)? get idRange {
    final a = Repo.i.ayahByRef(startSurah, startAyah);
    final b = Repo.i.ayahByRef(endSurah, endAyah);
    if (a == null || b == null || a.id > b.id) return null;
    return (a.id, b.id);
  }

  int get totalAyahs {
    final r = idRange;
    return r == null ? 0 : r.$2 - r.$1 + 1;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'startSurah': startSurah,
        'startAyah': startAyah,
        'endSurah': endSurah,
        'endAyah': endAyah,
        'dailyAyahs': dailyAyahs,
        'startDate': _fmtDate(startDate),
        'active': active,
        'createdAt': createdAt.toIso8601String(),
      };

  factory HifzPlan.fromJson(Map<String, dynamic> j) => HifzPlan(
        id: j['id'] as String,
        name: j['name'] as String,
        startSurah: j['startSurah'] as int,
        startAyah: j['startAyah'] as int,
        endSurah: j['endSurah'] as int,
        endAyah: j['endAyah'] as int,
        dailyAyahs: (j['dailyAyahs'] as int).clamp(1, 50),
        startDate: _parseDate(j['startDate'] as String),
        active: j['active'] as bool? ?? true,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );

  HifzPlan copyWith({String? name, int? dailyAyahs, bool? active}) => HifzPlan(
        id: id,
        name: name ?? this.name,
        startSurah: startSurah,
        startAyah: startAyah,
        endSurah: endSurah,
        endAyah: endAyah,
        dailyAyahs: dailyAyahs ?? this.dailyAyahs,
        startDate: startDate,
        active: active ?? this.active,
        createdAt: createdAt,
      );
}

// ───────── عنصر حفظ (آية واحدة) ─────────
class HifzItem {
  final int ayahId;
  final int step; // مؤشر في hifzIntervalSteps (0..4)
  final int intervalDays;
  final double ease;
  final int reps; // عدد المراجعات الناجحة (سهل/صعب)
  final int lapses; // عدد مرات «أعد»
  final DateTime dueDate; // تاريخ فقط
  final DateTime? lastReviewedAt;

  const HifzItem({
    required this.ayahId,
    required this.step,
    required this.intervalDays,
    required this.ease,
    required this.reps,
    required this.lapses,
    required this.dueDate,
    this.lastReviewedAt,
  });

  factory HifzItem.fresh(int ayahId, DateTime today) => HifzItem(
        ayahId: ayahId,
        step: 0,
        intervalDays: 1,
        ease: 2.5,
        reps: 0,
        lapses: 0,
        dueDate: _dateOnly(today),
        lastReviewedAt: null,
      );

  bool get isDue => !_dateOnly(DateTime.now()).isBefore(_dateOnly(dueDate));

  HifzStatus statusOn(DateTime today) {
    final t = _dateOnly(today);
    if (reps == 0) return HifzStatus.fresh;
    if (_dateOnly(dueDate).isBefore(t)) return HifzStatus.urgent;
    if (step >= 4 && reps >= 3) return HifzStatus.mastered;
    if (step >= 2) return HifzStatus.reviewing;
    return HifzStatus.learning;
  }

  /// تطبيق تقييم واحد — SM-2 مبسطة. يرجع العنصر الجديد.
  HifzItem apply(HifzRating rating, DateTime now) {
    final today = _dateOnly(now);
    var step = this.step;
    var ease = this.ease;
    var interval = intervalDays;
    var reps = this.reps;
    var lapses = this.lapses;
    switch (rating) {
      case HifzRating.easy:
        reps += 1;
        ease = (ease + 0.1).clamp(1.3, 2.5);
        if (step < hifzIntervalSteps.length - 1) {
          step += 1;
          interval = hifzIntervalSteps[step];
        } else {
          interval = (interval * 2).clamp(1, hifzMaxIntervalDays);
        }
      case HifzRating.hard:
        reps += 1;
        ease = (ease - 0.15).clamp(1.3, 2.5);
        interval = intervalDays; // إعادة بنفس الفاصل
      case HifzRating.again:
        lapses += 1;
        ease = (ease - 0.2).clamp(1.3, 2.5);
        step = 0;
        interval = 1;
    }
    return HifzItem(
      ayahId: ayahId,
      step: step,
      intervalDays: interval,
      ease: ease,
      reps: reps,
      lapses: lapses,
      dueDate: today.add(Duration(days: interval)),
      lastReviewedAt: now,
    );
  }

  Map<String, dynamic> toJson() => {
        'ayahId': ayahId,
        'step': step,
        'intervalDays': intervalDays,
        'ease': ease,
        'reps': reps,
        'lapses': lapses,
        'dueDate': _fmtDate(dueDate),
        'lastReviewedAt': lastReviewedAt?.toIso8601String(),
      };

  factory HifzItem.fromJson(Map<String, dynamic> j) => HifzItem(
        ayahId: j['ayahId'] as int,
        step: (j['step'] as int).clamp(0, hifzIntervalSteps.length - 1),
        intervalDays: j['intervalDays'] as int,
        ease: (j['ease'] as num).toDouble().clamp(1.3, 2.5),
        reps: j['reps'] as int,
        lapses: j['lapses'] as int,
        dueDate: _parseDate(j['dueDate'] as String),
        lastReviewedAt: j['lastReviewedAt'] == null
            ? null
            : DateTime.parse(j['lastReviewedAt'] as String),
      );
}

// ───────── سجل مراجعة واحد ─────────
class HifzReview {
  final String id;
  final int ayahId;
  final String planId;
  final HifzRating rating;
  final DateTime at;
  final int intervalBefore, intervalAfter;

  const HifzReview({
    required this.id,
    required this.ayahId,
    required this.planId,
    required this.rating,
    required this.at,
    required this.intervalBefore,
    required this.intervalAfter,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ayahId': ayahId,
        'planId': planId,
        'rating': rating.name,
        'at': at.toIso8601String(),
        'intervalBefore': intervalBefore,
        'intervalAfter': intervalAfter,
      };

  factory HifzReview.fromJson(Map<String, dynamic> j) => HifzReview(
        id: j['id'] as String,
        ayahId: j['ayahId'] as int,
        planId: j['planId'] as String,
        rating: HifzRating.values.byName(j['rating'] as String),
        at: DateTime.parse(j['at'] as String),
        intervalBefore: j['intervalBefore'] as int,
        intervalAfter: j['intervalAfter'] as int,
      );
}

// ───────── المخزن — نفس أسلوب UserData (SharedPreferences + ChangeNotifier) ─────────
class HifzStore extends ChangeNotifier {
  static const _schemaKey = 'hifz_schema';
  static const _plansKey = 'hifz_plans';
  static const _itemsKey = 'hifz_items';
  static const _reviewsKey = 'hifz_reviews';
  static const currentSchema = 1;

  late SharedPreferences _p;
  bool _loaded = false;
  bool get loaded => _loaded;

  List<HifzPlan> plans = [];
  Map<int, HifzItem> items = {}; // ayahId -> item
  List<HifzReview> reviews = [];

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final schema = _p.getInt(_schemaKey) ?? 0;
    if (schema == 0) await _p.setInt(_schemaKey, currentSchema);
    // مخططات مستقبلية تُرحَّل هنا (schema 1 -> 2 ...) دون مساس ببيانات المستخدم.
    try {
      final rawPlans = jsonDecode(_p.getString(_plansKey) ?? '[]') as List;
      plans = rawPlans
          .map((e) => HifzPlan.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      plans = [];
    }
    try {
      final rawItems =
          jsonDecode(_p.getString(_itemsKey) ?? '{}') as Map<String, dynamic>;
      items = {
        for (final e in rawItems.entries)
          int.parse(e.key): HifzItem.fromJson(e.value as Map<String, dynamic>)
      };
    } catch (_) {
      items = {};
    }
    try {
      final rawReviews = jsonDecode(_p.getString(_reviewsKey) ?? '[]') as List;
      reviews = rawReviews
          .map((e) => HifzReview.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      reviews = [];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    await _p.setString(
        _plansKey, jsonEncode(plans.map((p) => p.toJson()).toList()));
    await _p.setString(_itemsKey,
        jsonEncode({for (final e in items.entries) '${e.key}': e.value.toJson()}));
    await _p.setString(
        _reviewsKey, jsonEncode(reviews.map((r) => r.toJson()).toList()));
    notifyListeners();
  }

  HifzPlan? get activePlan {
    for (final p in plans) {
      if (p.active) return p;
    }
    return null;
  }

  // ── الخطط ──
  Future<String?> createPlan({
    required String name,
    required int startSurah,
    required int startAyah,
    required int endSurah,
    required int endAyah,
    required int dailyAyahs,
  }) async {
    final err = HifzPlan.validateRange(startSurah, startAyah, endSurah, endAyah);
    if (err != null) return err;
    final cleanName = name.trim();
    if (cleanName.isEmpty) return 'اكتب اسماً للخطة.';
    if (dailyAyahs < 1 || dailyAyahs > 50) {
      return 'الهدف اليومي بين آية واحدة و50 آية.';
    }
    final now = DateTime.now();
    final plan = HifzPlan(
      id: now.microsecondsSinceEpoch.toString(),
      name: cleanName,
      startSurah: startSurah,
      startAyah: startAyah,
      endSurah: endSurah,
      endAyah: endAyah,
      dailyAyahs: dailyAyahs,
      startDate: _dateOnly(now),
      active: true,
      createdAt: now,
    );
    if (plan.idRange == null) return 'تعذّر تحديد نطاق الخطة في المصحف.';
    for (var i = 0; i < plans.length; i++) {
      plans[i] = plans[i].copyWith(active: false);
    }
    plans.add(plan);
    await _save();
    return null;
  }

  Future<void> setPlanActive(String id, bool active) async {
    for (var i = 0; i < plans.length; i++) {
      final p = plans[i];
      plans[i] = p.copyWith(active: p.id == id ? active : false);
    }
    await _save();
  }

  Future<void> deletePlan(String id) async {
    plans.removeWhere((p) => p.id == id);
    await _save();
    // ملاحظة مقصودة: لا تُحذف عناصر الحفظ ومراجعاتها عند حذف خطة،
    // فهي سجل إنجاز المستخدم، لا بيانات الخطة وحدها.
  }

  // ── التقدّم: يُحسب من السجل الفعلي فقط ──
  ({int memorized, int total, double ratio}) progressOf(HifzPlan plan) {
    final r = plan.idRange;
    if (r == null) return (memorized: 0, total: 0, ratio: 0);
    final total = r.$2 - r.$1 + 1;
    var memorized = 0;
    for (var id = r.$1; id <= r.$2; id++) {
      final it = items[id];
      if (it != null && it.reps > 0) memorized++;
    }
    return (
      memorized: memorized,
      total: total,
      ratio: total == 0 ? 0 : memorized / total,
    );
  }

  /// آيات الحفظ الجديد لهذا اليوم: أول آيات بلا سجل في النطاق، بعدد الهدف اليومي.
  List<Ayah> todaysNew(HifzPlan plan) {
    final r = plan.idRange;
    if (r == null) return [];
    final out = <Ayah>[];
    for (var id = r.$1; id <= r.$2 && out.length < plan.dailyAyahs; id++) {
      if (!items.containsKey(id)) {
        final a = Repo.i.ayahById(id);
        if (a != null) out.add(a);
      }
    }
    return out;
  }

  /// المراجعات المستحقة اليوم (أو المتأخرة) داخل نطاق الخطة.
  List<Ayah> dueToday(HifzPlan plan) {
    final r = plan.idRange;
    if (r == null) return [];
    final today = _dateOnly(DateTime.now());
    final due = <Ayah>[];
    for (var id = r.$1; id <= r.$2; id++) {
      final it = items[id];
      if (it != null &&
          it.reps > 0 &&
          !_dateOnly(it.dueDate).isAfter(today)) {
        final a = Repo.i.ayahById(id);
        if (a != null) due.add(a);
      }
    }
    return due;
  }

  /// تسجيل أن المستخدم حفظ آيات جديدة (تقييم ذاتي صريح — لا تصحيح آلي).
  /// ينشئ العنصر ويقيّمه «سهل» فيُجدول أول مراجعة بعد 3 أيام (الخطوة 1).
  Future<void> markMemorized(HifzPlan plan, List<int> ayahIds) async {
    final now = DateTime.now();
    for (final id in ayahIds) {
      if (items.containsKey(id)) continue;
      final after = HifzItem.fresh(id, now).apply(HifzRating.easy, now);
      items[id] = after;
      reviews.add(HifzReview(
        id: '${now.microsecondsSinceEpoch}-$id',
        ayahId: id,
        planId: plan.id,
        rating: HifzRating.easy,
        at: now,
        intervalBefore: 0,
        intervalAfter: after.intervalDays,
      ));
    }
    _trimReviews();
    await _save();
  }

  /// تسجيل مراجعة واحدة بتقييم المستخدم الذاتي.
  Future<void> reviewAyah(HifzPlan plan, int ayahId, HifzRating rating) async {
    final now = DateTime.now();
    final before = items[ayahId] ?? HifzItem.fresh(ayahId, now);
    final after = before.apply(rating, now);
    items[ayahId] = after;
    reviews.add(HifzReview(
      id: '${now.microsecondsSinceEpoch}-$ayahId',
      ayahId: ayahId,
      planId: plan.id,
      rating: rating,
      at: now,
      intervalBefore: before.intervalDays,
      intervalAfter: after.intervalDays,
    ));
    _trimReviews();
    await _save();
  }

  void _trimReviews() {
    if (reviews.length > hifzMaxReviewsKept) {
      reviews = reviews.sublist(reviews.length - hifzMaxReviewsKept);
    }
  }

  /// إحصاءات من السجل الفعلي فقط (للتقرير الأسبوعي داخل التطبيق).
  ({int total, int easy, int hard, int again, int streakDays}) stats(
      {int days = 7}) {
    final since = _dateOnly(DateTime.now()).subtract(Duration(days: days - 1));
    final recent = reviews.where((r) => !_dateOnly(r.at).isBefore(since)).toList();
    var easy = 0, hard = 0, again = 0;
    final daysDone = <String>{};
    for (final r in reviews) {
      daysDone.add(_fmtDate(r.at));
      if (!_dateOnly(r.at).isBefore(since)) {
        switch (r.rating) {
          case HifzRating.easy: easy++;
          case HifzRating.hard: hard++;
          case HifzRating.again: again++;
        }
      }
    }
    var streak = 0;
    var d = _dateOnly(DateTime.now());
    while (daysDone.contains(_fmtDate(d))) {
      streak++;
      d = d.subtract(const Duration(days: 1));
    }
    return (
      total: recent.length,
      easy: easy,
      hard: hard,
      again: again,
      streakDays: streak,
    );
  }
}
