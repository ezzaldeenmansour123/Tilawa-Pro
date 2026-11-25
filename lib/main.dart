import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'db.dart';
import 'core/theme.dart'; // Phase 1: الألوان + buildTheme + الرسامون/الأفاتارات
import 'tajweed.dart'; // Phase 1: فهرس أحكام التجويد + نموذج البيانات (بلا تلوين مدمج)
import 'data/user_export.dart'; // Pro: نموذج تصدير/استيراد بيانات المستخدم
import 'data/user_export_io.dart'; // Pro: خدمة التصدير/الاستيراد (ملفات + prefs)
import 'features/memorization/hifz_store.dart'; // Pro: خطط الحفظ والتكرار المتباعد (تقييم ذاتي، بلا تصحيح آلي)
import 'features/memorization/hifz_page.dart';
import 'features/packages/packages_page.dart'; // Pro: صفحة الحزم والتنزيلات
import 'features/data/export_page.dart'; // Pro: صفحة النسخ الاحتياطي والاستعادة
import 'features/recitation/model_manager.dart'; // Pro: التسميع الذكي — تنزيل النموذج والتحقق منه
import 'features/recitation/progress_store.dart'; // Pro: التسميع الذكي — حفظ التقدم
import 'features/recitation/webview_engine.dart'; // Pro: التسميع الذكي — محرك WebView
import 'features/recitation/screens/recitation_screen.dart'; // Pro: التسميع الذكي — شاشة الإعداد والبدء
import 'package:file_picker/file_picker.dart'; // Pro: اختيار ملف تصدير للاستيراد


final navKey = GlobalKey<NavigatorState>();

// ───────── الإعدادات والمفضلة (محلية) ─────────
class AppSettings extends ChangeNotifier {
  ThemeMode mode = ThemeMode.system;
  double fontSize = 26;
  bool amiri = true;
  String reciter = 'afasy';
  bool reminderOn = false;
  int reminderHour = 7, reminderMinute = 0;
  int wirdQuarters = 1; // 1 ربع حزب، 4 حزب، 8 جزء
  late SharedPreferences p;

  Reciter get reciterObj =>
      reciters.firstWhere((r) => r.id == reciter, orElse: () => reciters.first);

  Future<void> load() async {
    p = await SharedPreferences.getInstance();
    mode = ThemeMode.values[p.getInt('mode') ?? 0];
    fontSize = p.getDouble('font') ?? 26;
    amiri = p.getBool('amiri') ?? true;
    reciter = p.getString('reciter') ?? 'afasy';
    reminderOn = p.getBool('reminder') ?? false;
    reminderHour = p.getInt('rem_hour') ?? 7;
    reminderMinute = p.getInt('rem_min') ?? 0;
    wirdQuarters = p.getInt('wird_q') ?? 1;
  }

  void setMode(ThemeMode m) {
    mode = m;
    p.setInt('mode', m.index);
    notifyListeners();
  }

  void setFont(double v) {
    fontSize = v;
    p.setDouble('font', v);
    notifyListeners();
  }

  void setAmiri(bool v) {
    amiri = v;
    p.setBool('amiri', v);
    notifyListeners();
  }

  void setReciter(String id) {
    reciter = id;
    p.setString('reciter', id);
    notifyListeners();
  }

  Future<void> setReminder(bool on, {int? hour, int? minute}) async {
    reminderOn = on;
    if (hour != null) reminderHour = hour;
    if (minute != null) reminderMinute = minute;
    p.setBool('reminder', on);
    p.setInt('rem_hour', reminderHour);
    p.setInt('rem_min', reminderMinute);
    notifyListeners();
    if (on) {
      await NotificationService.requestPermissions();
      await NotificationService.scheduleDaily();
    } else {
      await NotificationService.cancelDaily();
    }
  }

  void setWirdQuarters(int n) {
    wirdQuarters = n;
    p.setInt('wird_q', n);
    notifyListeners();
  }
}

class UserData extends ChangeNotifier {
  late SharedPreferences p;
  List<int> ids = [];
  Map<int, String> tags = {}, notes = {};
  List<int> history = [];
  int khatmahQuarter = 1; // الربع الحالي في الختمة (1..240)
  bool warshReady = false;
  List<String> favReciters = []; // القرّاء المفضلون (معرّفاتهم)
  // آخر موضع قراءة (Phase 1): رقم السورة + المعرّف العام للآية + صفحة المصحف.
  // تُحفظ عند فتح آية أو تغيير صفحة المصحف، وتُستعاد من الرئيسية.
  int? lastReadSurah, lastReadAyahId, lastReadPage;

  Map<int, String> _readMap(String k) {
    final m = jsonDecode(p.getString(k) ?? '{}') as Map<String, dynamic>;
    return {for (final e in m.entries) int.parse(e.key): e.value as String};
  }

  Future<void> load() async {
    p = await SharedPreferences.getInstance();
    ids = (p.getStringList('favs') ?? []).map(int.parse).toList();
    history = (p.getStringList('history') ?? []).map(int.parse).toList();
    tags = _readMap('tags');
    notes = _readMap('notes');
    khatmahQuarter = p.getInt('khatmah_q') ?? 1;
    warshReady = p.getBool('warsh_ready') ?? false;
    favReciters = p.getStringList('fav_reciters') ?? [];
    lastReadSurah = p.getInt('read_surah');
    lastReadAyahId = p.getInt('read_ayah');
    lastReadPage = p.getInt('read_page');
  }

  void _save() {
    p.setStringList('favs', ids.map((e) => '$e').toList());
    p.setStringList('history', history.map((e) => '$e').toList());
    p.setString('tags', jsonEncode({for (final e in tags.entries) '${e.key}': e.value}));
    p.setString('notes', jsonEncode({for (final e in notes.entries) '${e.key}': e.value}));
    p.setInt('khatmah_q', khatmahQuarter);
    p.setBool('warsh_ready', warshReady);
    p.setStringList('fav_reciters', favReciters);
    if (lastReadSurah == null) {
      p.remove('read_surah');
    } else {
      p.setInt('read_surah', lastReadSurah!);
    }
    if (lastReadAyahId == null) {
      p.remove('read_ayah');
    } else {
      p.setInt('read_ayah', lastReadAyahId!);
    }
    if (lastReadPage == null) {
      p.remove('read_page');
    } else {
      p.setInt('read_page', lastReadPage!);
    }
    notifyListeners();
  }

  bool get hasReadingPosition =>
      lastReadSurah != null && lastReadAyahId != null && lastReadPage != null;

  /// حفظ آخر موضع قراءة (سورة/آية/صفحة مصحف) — يُستدعى عند فتح آية
  /// أو عند تغيير صفحة المصحف. المفاتيح جديدة (read_surah/read_ayah/
  /// read_page) ولا تمسّ أي مفتاح موجود.
  void saveReadingPosition({required int surah, required int ayahId, required int page}) {
    lastReadSurah = surah;
    lastReadAyahId = ayahId;
    lastReadPage = page;
    _save();
  }

  bool hasReciter(String id) => favReciters.contains(id);
  void toggleReciter(String id) {
    hasReciter(id) ? favReciters.remove(id) : favReciters.add(id);
    _save();
  }

  bool has(int id) => ids.contains(id);
  void toggle(int id) {
    if (has(id)) {
      ids.remove(id);
      tags.remove(id);
    } else {
      ids.add(id);
    }
    _save();
  }

  void setTag(int id, String t) {
    t.trim().isEmpty ? tags.remove(id) : tags[id] = t.trim();
    _save();
  }

  void setNote(int id, String t) {
    t.trim().isEmpty ? notes.remove(id) : notes[id] = t.trim();
    _save();
  }

  void touch(int id) {
    history.remove(id);
    history.insert(0, id);
    if (history.length > 100) history.removeRange(100, history.length);
    _save();
  }

  void clearHistory() {
    history.clear();
    _save();
  }

  Set<String> get allTags => tags.values.toSet();

  /// إتمام ورد اليوم: التقدم بمقدار الورد، وإعادة الجدولة للتذكير التالي.
  Future<void> completeWird() async {
    khatmahQuarter = (khatmahQuarter + settings.wirdQuarters).clamp(1, 241);
    _save();
    if (settings.reminderOn) await NotificationService.scheduleDaily();
  }

  void resetKhatmah() {
    khatmahQuarter = 1;
    _save();
  }

  void setWarshReady(bool v) {
    warshReady = v;
    _save();
  }
}

final settings = AppSettings();
final user = UserData();
final hifz = HifzStore(); // Pro: خطط الحفظ (مفاتيح hifz_* منفصلة تماماً)

// Pro: التسميع الذكي (محرك yazinsai/tilawa في WebView) — يُهيَّأ في main().
// إن فشلت التهيئة يبقى recitationReady=false ولا يمنع التطبيق من العمل.
late final ModelManager recitationModelManager;
late final WebViewEngine recitationEngine;
late final ProgressStore recitationProgress;
bool recitationReady = false;

// ───────── الإشعارات المحلية (تذكير الورد) ─────────
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    tz.initializeTimeZones();
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(tzInfo.identifier));
    } catch (_) {}
    await _plugin.initialize(
      settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (resp) {
        final pl = resp.payload;
        if (pl != null && pl.startsWith('ayah:')) {
          final id = int.tryParse(pl.substring(5));
          if (id != null) {
            navKey.currentState?.push(
                MaterialPageRoute(builder: (_) => AyahDetailPage(id)));
          }
        }
      },
    );
    _ready = true;
  }

  static Future<void> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  /// يجدول تذكيرًا يوميًا في وقت المستخدم، يفتح أول آية في الورد الحالي.
  static Future<void> scheduleDaily() async {
    if (!_ready) return;
    await _plugin.cancel(id: 0);
    final q = user.khatmahQuarter.clamp(1, 240);
    final first = Repo.i.ayahsInQuarter(q);
    final ayahId = first.isEmpty ? 1 : first.first.id;
    final surah = first.isEmpty ? 'الفاتحة' : first.first.surahName;
    var when = tz.TZDateTime(tz.local, DateTime.now().year, DateTime.now().month,
        DateTime.now().day, settings.reminderHour, settings.reminderMinute);
    if (when.isBefore(tz.TZDateTime.now(tz.local))) when = when.add(const Duration(days: 1));
    await _plugin.zonedSchedule(
      id: 0,
      title: 'وردك اليومي من القرآن',
      body: 'حان وقت وردك — سورة $surah. اضغط للقراءة والاستماع.',
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'tilawa_wird',
          'تذكير الورد',
          channelDescription: 'تذكير يومي بورد القرآن الكريم',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'ayah:$ayahId',
    );
  }

  static Future<void> cancelDaily() async => _plugin.cancel(id: 0);
}

// ───────── التلاوة الصوتية ─────────
class AudioService extends ChangeNotifier {
  final player = AudioPlayer();
  List<Ayah> playlist = [];
  int? currentAyahId;
  bool playing = false;
  bool loading = false;
  String? error;

  AudioService() {
    player.playerStateStream.listen((st) {
      final p = st.playing;
      if (p != playing) {
        playing = p;
        notifyListeners();
      }
    });
    player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < playlist.length) {
        currentAyahId = playlist[i].id;
        notifyListeners();
      }
    });
  }

  static String _sss(int surah) => surah.toString().padLeft(3, '0');
  static String _aaa(int ayah) => ayah.toString().padLeft(3, '0');

  static String everyAyahUrl(Reciter r, int surah, int ayah) =>
      'https://everyayah.com/data/${r.folder}/${_sss(surah)}${_aaa(ayah)}.mp3';

  static String fallbackUrl(Reciter r, int globalId) =>
      'https://cdn.islamic.network/quran/audio/64/${r.fallbackEdition ?? 'ar.alafasy'}/$globalId.mp3';

  Future<File?> _localFile(Reciter r, int surah, int ayah) async {
    final d = await getApplicationSupportDirectory();
    final f = File(
        '${d.path}${Platform.pathSeparator}audio${Platform.pathSeparator}${r.folder}'
        '${Platform.pathSeparator}${_sss(surah)}${_aaa(ayah)}.mp3');
    return f.existsSync() ? f : null;
  }

  Future<AudioSource> _sourceFor(Ayah a, Reciter r) async {
    final local = await _localFile(r, a.surah, a.ayah);
    if (local != null) return AudioSource.uri(Uri.file(local.path));
    return AudioSource.uri(Uri.parse(everyAyahUrl(r, a.surah, a.ayah)));
  }

  Future<void> playAyah(Ayah a) async {
    final r = settings.reciterObj;
    loading = true;
    error = null;
    notifyListeners();
    try {
      playlist = [a];
      currentAyahId = a.id;
      await player.setAudioSource(await _sourceFor(a, r));
      await player.setSpeed(speed);
      await player.setLoopMode(repeatMode);
      await player.play();
    } catch (_) {
      // المحاولة الثانية: المصدر الاحتياطي
      try {
        await player.setAudioSource(
            AudioSource.uri(Uri.parse(fallbackUrl(r, a.id))));
        await player.setSpeed(speed);
        await player.setLoopMode(repeatMode);
        await player.play();
      } catch (e) {
        error = 'تعذّر تشغيل الصوت — تحقق من الإنترنت.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> playSurah(int surahId, {int fromAyah = 1}) async {
    final r = settings.reciterObj;
    final ayahs = Repo.i.ayahsOf(surahId);
    if (ayahs.isEmpty) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      playlist = ayahs;
      final start = ayahs.indexWhere((a) => a.ayah >= fromAyah);
      final sources = <AudioSource>[];
      for (final a in ayahs) {
        sources.add(await _sourceFor(a, r));
      }
      await player.setAudioSources(sources, initialIndex: start < 0 ? 0 : start);
      await player.setSpeed(speed);
      await player.setLoopMode(repeatMode);
      await player.play();
    } catch (_) {
      error = 'تعذّر تشغيل التلاوة — تحقق من الإنترنت.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> next() async {
    try {
      await player.seekToNext();
    } catch (_) {}
  }

  Future<void> previous() async {
    try {
      await player.seekToPrevious();
    } catch (_) {}
  }

  Future<void> stop() async {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    sleepEndsAt = null;
    await player.stop();
    currentAyahId = null;
    playlist = [];
    notifyListeners();
  }

  // ── سرعة التشغيل والتكرار ومؤقت النوم (Pro) ──
  // السرعة والتكرار خاصيتان في just_audio تبقيان على المشغّل عبر المصادر،
  // لكن تُطبَّق صراحةً بعد كل setAudioSource تحسّباً.
  double speed = 1.0;
  LoopMode repeatMode = LoopMode.off;
  DateTime? sleepEndsAt;
  Timer? _sleepTimer;
  Timer? _sleepTicker;

  static const List<double> speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  String get speedLabel => speed == 1.0 ? '1×' : '$speed×';

  String get repeatLabel => repeatMode == LoopMode.one
      ? 'تكرار الآية'
      : repeatMode == LoopMode.all
          ? 'تكرار السورة'
          : 'بلا تكرار';

  Future<void> cycleSpeed() async {
    final i = speeds.indexOf(speed);
    final next = speeds[(i + 1) % speeds.length];
    speed = next;
    try {
      await player.setSpeed(next);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    repeatMode = repeatMode == LoopMode.off
        ? LoopMode.one
        : repeatMode == LoopMode.one
            ? LoopMode.all
            : LoopMode.off;
    try {
      await player.setLoopMode(repeatMode);
    } catch (_) {}
    notifyListeners();
  }

  /// مؤقت نوم: يوقف التلاوة بعد [d]، أو يلغي المؤقت إن كان null.
  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    if (d == null) {
      sleepEndsAt = null;
      notifyListeners();
      return;
    }
    sleepEndsAt = DateTime.now().add(d);
    _sleepTimer = Timer(d, () async {
      sleepEndsAt = null;
      // إيقاف مؤقت (pause) لا إيقاف كامل: يبقى موضع التلاوة قابلاً للاستئناف.
      await player.pause();
      notifyListeners();
    });
    // تحديث العد التنازلي المعروض كل 30 ثانية.
    _sleepTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (sleepEndsAt == null) return;
      if (DateTime.now().isAfter(sleepEndsAt!)) return;
      notifyListeners();
    });
    notifyListeners();
  }

  int get sleepMinutesLeft {
    final end = sleepEndsAt;
    if (end == null) return 0;
    final m = end.difference(DateTime.now()).inMinutes;
    return m < 0 ? 0 : m;
  }

  Future<bool> isSurahDownloaded(int surahId) async {
    final r = settings.reciterObj;
    final ayahs = Repo.i.ayahsOf(surahId);
    if (ayahs.isEmpty) return false;
    for (final a in ayahs) {
      if (await _localFile(r, a.surah, a.ayah) == null) return false;
    }
    return true;
  }

  /// تنزيل سورة كاملة للاستماع دون إنترنت (ملف لكل آية).
  Future<void> downloadSurah(int surahId, void Function(int done, int total) onProgress) async {
    final r = settings.reciterObj;
    final ayahs = Repo.i.ayahsOf(surahId);
    final d = await getApplicationSupportDirectory();
    final dir = Directory('${d.path}${Platform.pathSeparator}audio'
        '${Platform.pathSeparator}${r.folder}');
    await dir.create(recursive: true);
    var done = 0;
    for (final a in ayahs) {
      final f = File('${dir.path}${Platform.pathSeparator}${_sss(a.surah)}${_aaa(a.ayah)}.mp3');
      if (!f.existsSync()) {
        try {
          final res = await http
              .get(Uri.parse(everyAyahUrl(r, a.surah, a.ayah)))
              .timeout(const Duration(seconds: 30));
          if (res.statusCode == 200) await f.writeAsBytes(res.bodyBytes);
        } catch (_) {}
      }
      done++;
      onProgress(done, ayahs.length);
    }
  }
}

final audio = AudioService();

// ───────── رواية ورش (حزمة اختيارية) ─────────
class WarshVerse {
  final int id;
  final String text;
  final List<int> hafs;
  const WarshVerse(this.id, this.text, this.hafs);
}

class WarshSurah {
  final int id;
  final List<WarshVerse> verses;
  const WarshSurah(this.id, this.verses);
}

class WarshService {
  static const url = 'https://quran-json.risanb.com/text/warsh/quran.json';
  static const attribution =
      'المصدر: Qur\'anpedia.net عبر quran-json.risanb.com — نص رواية ورش كما هو، مع ذكر المصدر. '
      'أرقام الآيات هنا برواية ورش (6,214 آية) وقد تختلف عن ترقيم حفص؛ يُعرض مقابل كل آية رقمها في حفص.';

  static Future<File> _file() async {
    final d = await getApplicationSupportDirectory();
    return File('${d.path}${Platform.pathSeparator}warsh.json');
  }

  static Future<bool> isDownloaded() async => (await _file()).existsSync();

  static Future<void> download(void Function(double) onProgress) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) throw Exception('تعذّر تنزيل حزمة ورش (رمز ${res.statusCode})');
    final f = await _file();
    await f.writeAsBytes(res.bodyBytes);
    onProgress(1);
    // تحقق سريع: 114 سورة و6,214 آية
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    final total = data.fold<int>(0, (n, s) => n + ((s as Map)['verses'] as List).length);
    if (data.length != 114 || total != 6214) {
      await f.delete();
      throw Exception('ملف ورش غير مكتمل — أعد المحاولة.');
    }
    user.setWarshReady(true);
  }

  static Future<List<WarshSurah>> load() async {
    final f = await _file();
    final data = jsonDecode(await f.readAsString()) as List<dynamic>;
    return [
      for (final s in data)
        WarshSurah(
          (s as Map)['id'] as int,
          [
            for (final v in (s['verses'] as List))
              WarshVerse(
                v['id'] as int,
                v['text'] as String,
                (v['number_in_hafs'] as List).map((e) => e as int).toList(),
              ),
          ],
        ),
    ];
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await settings.load();
  await user.load();
  await hifz.load();
  // Pro: التسميع الذكي — التهيئة محمية: أي فشل هنا (مثلاً لا مجلد دعم)
  // يجعل التسميع غير متاح فقط، ولا يمنع التطبيق من العمل إطلاقاً.
  try {
    recitationModelManager = await ModelManager.create();
    recitationEngine = WebViewEngine(modelManager: recitationModelManager);
    recitationProgress = await ProgressStore.create();
    await recitationProgress.load();
    recitationReady = true;
  } catch (_) {
    recitationReady = false;
  }
  await NotificationService.init();
  runApp(const TilawaApp());
}


/// تنسيق مدة بالشكل 0:45
String fmtDur(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

class TilawaApp extends StatelessWidget {
  const TilawaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (_, __) => MaterialApp(
        title: 'تلاوة',
        debugShowCheckedModeBanner: false,
        themeMode: settings.mode,
        theme: buildTheme(false),
        darkTheme: buildTheme(true),
        navigatorKey: navKey,
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const BootPage(),
      ),
    );
  }
}

// ───────── عناصر مشتركة ─────────
Widget softCard(BuildContext c,
    {required Widget child,
    VoidCallback? onTap,
    EdgeInsets padding = const EdgeInsets.all(16),
    Gradient? gradient}) {
  final dark = Theme.of(c).brightness == Brightness.dark;
  final r = BorderRadius.circular(24);
  return Container(
    decoration: BoxDecoration(
      color: dark ? const Color(0xFF1C2B33) : Colors.white,
      gradient: gradient,
      borderRadius: r,
      boxShadow: [
        BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06), blurRadius: 14, offset: const Offset(0, 4))
      ],
    ),
    child: Material(
      color: Colors.transparent,
      borderRadius: r,
      child: InkWell(borderRadius: r, onTap: onTap, child: Padding(padding: padding, child: child)),
    ),
  );
}

TextStyle quranStyle(double size, {double h = 2.0, FontWeight w = FontWeight.w600}) =>
    TextStyle(fontSize: size, height: h, fontWeight: w, fontFamily: settings.amiri ? 'Amiri' : null);

Future<String?> askText(BuildContext c, String title, String initial,
    {int lines = 1, List<String> chips = const []}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctl, maxLines: lines, autofocus: true),
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(spacing: 6, children: [
              for (final t in chips) ActionChip(label: Text(t), onPressed: () => ctl.text = t),
            ]),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('حفظ')),
      ],
    ),
  );
}

Widget ayahCard(BuildContext c, Ayah a) => softCard(
      c,
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => AyahDetailPage(a.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(a.text, maxLines: 3, overflow: TextOverflow.ellipsis, style: quranStyle(17, h: 1.9)),
        const SizedBox(height: 6),
        Text('سورة ${a.surahName} • آية ${a.ayah}', style: const TextStyle(fontSize: 12, color: gold)),
      ]),
    );

/// تحويل رقم إلى أرقام عربية مشرقية (١٢٣) لعرض رقم الآية داخل النص.
/// هذه زخرفة واجهة فقط وليست جزءًا من نص الآية.
String _arDigits(int n) =>
    n.toString().split('').map((d) => '٠١٢٣٤٥٦٧٨٩'[int.parse(d)]).join();

/// ورقة إجراءات الآية المحددة (ضغطة مطوّلة في القارئ أو المصحف):
/// نسخ، مشاركة، عرض التفسير من قاعدة البيانات، مفضلة، استماع.
/// نص الآية يُنسخ/يُشارك حرفيًا كما هو في قاعدة البيانات دون تعديل.
Future<void> showAyahActions(BuildContext c, Ayah a) async {
  final isFav = user.has(a.id);
  final choice = await showModalBottomSheet<String>(
    context: c,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.menu_book_rounded, color: teal),
          title: Text('سورة ${a.surahName} • آية ${a.ayah}'),
          subtitle: Text(a.text,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: quranStyle(15, h: 1.8)),
        ),
        const Divider(height: 1),
        ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('نسخ الآية'),
            onTap: () => Navigator.pop(ctx, 'copy')),
        ListTile(
            leading: const Icon(Icons.share_rounded),
            title: const Text('مشاركة الآية'),
            onTap: () => Navigator.pop(ctx, 'share')),
        ListTile(
            leading: const Icon(Icons.auto_stories_rounded),
            title: const Text('عرض التفسير'),
            subtitle: const Text('الميسر، الجلالين، السعدي — من قاعدة البيانات دون إنترنت'),
            onTap: () => Navigator.pop(ctx, 'tafsir')),
        ListTile(
            leading: Icon(isFav ? Icons.star_rounded : Icons.star_border_rounded, color: gold),
            title: Text(isFav ? 'إزالة من المفضلة' : 'حفظ في المفضلة'),
            onTap: () => Navigator.pop(ctx, 'fav')),
        ListTile(
            leading: const Icon(Icons.play_arrow_rounded),
            title: const Text('استماع للآية'),
            onTap: () => Navigator.pop(ctx, 'play')),
      ]),
    ),
  );
  if (choice == null) return;
  switch (choice) {
    case 'copy':
      await Clipboard.setData(ClipboardData(text: a.text));
      if (c.mounted) {
        ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('تم نسخ الآية')));
      }
    case 'share':
      await Share.share('﴿${a.text}﴾\nسورة ${a.surahName} — آية ${a.ayah}');
    case 'tafsir':
      if (c.mounted) {
        Navigator.push(c, MaterialPageRoute(builder: (_) => AyahDetailPage(a.id)));
      }
    case 'fav':
      user.toggle(a.id);
    case 'play':
      await audio.playAyah(a);
      if (audio.error != null && c.mounted) {
        ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(audio.error!)));
      }
  }
}

Widget emptyState(IconData icon, String text, {String? button, VoidCallback? onTap}) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(radius: 48, backgroundColor: tealLight, child: Icon(icon, size: 48, color: teal)),
          const SizedBox(height: 20),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, height: 1.7)),
          if (button != null) ...[
            const SizedBox(height: 20),
            FilledButton.tonal(onPressed: onTap, child: Text(button)),
          ],
        ]),
      ),
    );


// ───────── فضل السور — قائمة منقولة موثقة المصدر ─────────
/// فضائل سور من أحاديث مشهورة موثقة المصدر.
/// القاعدة: إن لم يكن الفضل ثابتًا في مصدر صحيح/حسن مشهور، لا يُدرج.
/// (لهذا لا تظهر هنا سور مثل يس والواقعة والرحمن — أحاديث فضائلها ضعيفة.)
const surahVirtues = <int, (String, String)>{
  1: ('أعظم سورة في القرآن، وهي السبع المثاني.', 'صحيح البخاري'),
  2: ('أخذها بركة وتركها حسرة، وفيها آية الكرسي أعظم آية في كتاب الله.', 'صحيح مسلم'),
  3: ('مع سورة البقرة تُدعيان «الزهراوين»، وتأتيان يوم القيامة كأنهما غمامتان تحاجّان عن صاحبهما.', 'صحيح مسلم'),
  18: ('قراءتها في يوم الجمعة نورٌ بين الجمعتين.', 'رواه الحاكم والبيهقي'),
  32: ('كان النبي ﷺ لا ينام حتى يقرأها مع سورة الملك.', 'رواه الترمذي'),
  67: ('ثلاثون آية شفعت لرجل حتى غُفر له.', 'رواه الترمذي وأبو داود'),
  109: ('تعدل ربع القرآن.', 'رواه الترمذي'),
  112: ('تعدل ثلث القرآن.', 'صحيح البخاري'),
  113: ('من أذكار الصباح والمساء، وما استعاذ مستعيذ بمثلها.', 'صحيح مسلم'),
  114: ('من أذكار الصباح والمساء، وما استعاذ مستعيذ بمثلها.', 'صحيح مسلم'),
};

// ───────── تدبّر اليوم ─────────
/// أسئلة تأمل عامة — لا تفسر الآية ولا تضيف معنى، بل تدعو القارئ للتفكر فيها.
const tadabburQuestions = [
  'ما الذي تخبرك به هذه الآية عن الله سبحانه؟',
  'كيف تعيش معنى هذه الآية في يومك؟',
  'ما العمل الذي تدعوك إليه هذه الآية؟',
  'ما أثر هذه الآية في قلبك لو تأملتها دقيقة؟',
  'أي اسم من أسماء الله يظهر في هذه الآية؟',
  'ما الرسالة التي تحملها لك هذه الآية اليوم؟',
];

String tadabburQuestion(DateTime d) =>
    tadabburQuestions[d.difference(DateTime(d.year, 1, 1)).inDays % tadabburQuestions.length];

/// خطة ورد ذكية حسب الوقت المتاح (تقديرات تقريبية لقراءة متأنية:
/// ربع الحزب ≈ صفحتان ونصف ≈ 5 دقائق).
(int, String) wirdPlanFor(int minutes) {
  if (minutes <= 5) return (1, 'ربع حزب');
  if (minutes <= 10) return (2, 'ربعا حزب');
  return (3, 'ثلاثة أرباع حزب');
}

// ───────── شاشة البداية وتجهيز المكتبة ─────────
class BootPage extends StatefulWidget {
  const BootPage({super.key});
  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> {
  double? progress;
  bool installing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => error = null);
    try {
      final repo = Repo.i;
      if (!await repo.isInstalled() || await repo.needsUpdate()) {
        setState(() => installing = true);
        await repo.install((p) {
          if (mounted) setState(() => progress = p);
        });
      }
      await repo.open();
      if (settings.reminderOn) await NotificationService.scheduleDaily();
      // إظهار شاشة البداية لحظة قصيرة حتى تُرى
      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, __, ___) => const Shell(),
        transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
      ));
    } catch (e) {
      if (mounted) setState(() => error = 'تعذّر تجهيز المكتبة:\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final onBg = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [const Color(0xFF101D24), const Color(0xFF1C2B33)]
                : [skyLight, pinkLight, mintLight],
          ),
        ),
        child: SafeArea(
          child: Stack(children: [
            const Positioned(top: 0, right: 0, child: FloralCorner(size: 120)),
            const Positioned(top: 0, left: 0, child: FloralCorner(size: 120, flip: true)),
            const Positioned(bottom: 0, left: 0, child: FloralCorner(size: 100, flip: true)),
            Center(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    // قوس على طراز التصميم
                    Container(
                      padding: const EdgeInsets.fromLTRB(24, 36, 24, 28),
                      decoration: BoxDecoration(
                        color: (dark ? const Color(0xFF1C2B33) : Colors.white)
                            .withValues(alpha: 0.75),
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(170), bottom: Radius.circular(28)),
                        border: Border.all(color: gold.withValues(alpha: 0.5), width: 1.5),
                      ),
                      child: Column(children: [
                        const LogoMark(150),
                        const SizedBox(height: 8),
                        Text('تلاوة',
                            style: TextStyle(
                                fontSize: 54,
                                fontWeight: FontWeight.w800,
                                color: dark ? sky : skyDeep,
                                fontFamily: 'Amiri')),
                        const SizedBox(height: 4),
                        Text('استمع .. اقرأ .. تدبر',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700, color: onBg)),
                        const SizedBox(height: 14),
                        Row(children: [
                          Expanded(child: Divider(color: gold.withValues(alpha: 0.6))),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text('✦', style: TextStyle(color: gold)),
                          ),
                          Expanded(child: Divider(color: gold.withValues(alpha: 0.6))),
                        ]),
                        const SizedBox(height: 10),
                        Text('نسخة متميزة من القرآن الكريم',
                            style: TextStyle(
                                fontSize: 14, color: onBg.withValues(alpha: 0.8))),
                      ]),
                    ),
                    const SizedBox(height: 36),
                    if (error != null) ...[
                      Text(error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: _start, child: const Text('إعادة المحاولة')),
                    ] else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                            value: installing ? progress : null, minHeight: 6),
                      ),
                      const SizedBox(height: 12),
                      Text(installing
                          ? 'جارٍ تجهيز المصحف… ${((progress ?? 0) * 100).round()}٪ (مرة واحدة فقط)'
                          : 'جارٍ التحميل…'),
                    ],
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────── الهيكل والتنقل ─────────
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  void go(int i) => setState(() => tab = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: tab, children: [
        HomePage(onTab: go),
        const SurahsPage(),
        const MorePage(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: go,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'الرئيسية'),
          NavigationDestination(icon: Icon(Icons.menu_book_rounded), label: 'المكتبة'),
          NavigationDestination(icon: Icon(Icons.more_horiz_rounded), label: 'المزيد'),
        ],
      ),
    );
  }
}

// ───────── المزيد: مركز أقسام التطبيق ─────────
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  Widget _row(BuildContext c, IconData icon, String label, String? sub, Color bg, Color fg,
      VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: softCard(c,
            onTap: onTap,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(children: [
              CircleAvatar(backgroundColor: bg, child: Icon(icon, color: fg)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub, style: const TextStyle(fontSize: 12)),
                  ],
                ]),
              ),
              const Icon(Icons.chevron_left, color: Colors.grey),
            ])),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('المزيد')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        _row(context, Icons.star_rounded, 'المفضلة', 'آياتك المحفوظة وأوسامك', pinkLight, pink,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => FavsPage(
                onTab: (_) => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const SurahsPage())))))),
        _row(context, Icons.search_rounded, 'البحث', 'في الآيات والتفاسير والسور', skyLight, sky,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchPage()))),
        _row(context, Icons.headphones_rounded, 'التلاوات', 'اختر قارئك واستمع', mintLight, teal,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecitationsPage()))),
        _row(context, Icons.auto_stories_rounded, 'التفسير', 'تصفح تفسير السور', goldLight, gold,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TafsirBrowserPage()))),
        _row(context, Icons.palette_rounded, 'أحكام التجويد', 'مفتاح الألوان — التلوين قيد التحقق',
            tealLight, teal,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TajweedPage()))),
        _row(context, Icons.lightbulb_rounded, 'الإعجاز القرآني', '10 مقالات موثقة', goldLight, gold,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const IjazPage()))),
        _row(context, Icons.library_books_rounded, 'القراءات', 'حفص وورش', mintLight, teal,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QiraatPage()))),
        _row(context, Icons.notifications_active_rounded, 'الورد والتذكير', 'ختمتك ووردك اليومي',
            skyLight, sky,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WirdPage()))),
        _row(context, Icons.school_rounded, 'خطط الحفظ', 'حفظك ومراجعتك المتباعدة',
            mintLight, teal,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => HifzPage(store: hifz)))),
        _row(context, Icons.mic_rounded, 'التسميع الذكي', 'سمّع واحفظ مع تصحيح الكلمات — دون إنترنت',
            mintLight, teal, () {
          if (recitationReady) {
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => RecitationScreen(
                        engine: recitationEngine, progressStore: recitationProgress)));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'التسميع غير متاح على هذا الجهاز حالياً — أعد تشغيل التطبيق وحاول مجدداً')));
          }
        }),
        _row(context, Icons.history_rounded, 'السجل', 'آيات قرأتها مؤخرًا', pinkLight, pink,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage()))),
        _row(context, Icons.library_add_check_rounded, 'المكتبة والمصادر', 'المحتوى والسلامة والتراخيص',
            mintLight, teal,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LibraryPage()))),
        _row(context, Icons.settings_rounded, 'الإعدادات', 'المظهر والخط والتذكير', skyLight, sky,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
        _row(context, Icons.apps_rounded, 'تعرف على أعمالنا', 'تطبيقاتنا الأخرى', goldLight, gold,
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OurWorksPage()))),
        const SizedBox(height: 8),
        Stack(children: [
          softCard(context,
              child: const Row(children: [
                LogoMark(64),
                SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('تلاوة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: skyDeep)),
                    SizedBox(height: 4),
                    Text('رفيقك في رحلتك مع القرآن', style: TextStyle(fontSize: 13, height: 1.7)),
                    SizedBox(height: 2),
                    Text('الإصدار 1.1.0', style: TextStyle(fontSize: 12, color: gold)),
                  ]),
                ),
              ])),
          const Positioned(top: 0, left: 0, child: FloralCorner(size: 56)),
        ]),
      ]),
    );
  }
}

// ───────── تعرف على أعمالنا ─────────
class OurWorksPage extends StatelessWidget {
  const OurWorksPage({super.key});

  static const _releaseUrl =
      'https://github.com/ezzaldeenmansour123/Ezz-alsonah/releases/tag/build-1';
  static const _repoUrl = 'https://github.com/ezzaldeenmansour123/Ezz-alsonah';

  Future<void> _open(BuildContext c, String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(
          const SnackBar(content: Text('تعذّر فتح الرابط — تحقق من الاتصال.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تعرف على أعمالنا')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Stack(children: [
          softCard(context,
              child: const Row(children: [
                LogoMark(64),
                SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('أعمالنا',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: skyDeep)),
                    SizedBox(height: 4),
                    Text('تطبيقات من تطوير عزالدين منصور',
                        style: TextStyle(fontSize: 13, height: 1.7)),
                    SizedBox(height: 2),
                    Text('علمٌ نافع يصلك حيثما كنت — دون إنترنت حيث أمكن',
                        style: TextStyle(fontSize: 12, height: 1.7)),
                  ]),
                ),
              ])),
          const Positioned(top: 0, left: 0, child: FloralCorner(size: 56)),
        ]),
        const SizedBox(height: 16),
        softCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const CircleAvatar(
                backgroundColor: goldLight,
                radius: 26,
                child: Text('عز',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800, color: gold))),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('عز السنة',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('موسوعة أحاديث نبوية للأندرويد',
                    style: TextStyle(fontSize: 13, height: 1.6)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                  color: mintLight, borderRadius: BorderRadius.circular(20)),
              child: const Text('الإصدار 1.1.1',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: teal)),
            ),
          ]),
          const SizedBox(height: 12),
          const Text(
              '9 كتب، 39,598 حديثًا — تعمل دون إنترنت بالكامل، ببحث عربي ذكي، '
              'وعرض درجة كل حديث مع اسم المقيِّم، وشروح موثقة المصدر، ومساعد يبحث بالموضوع.',
              style: TextStyle(fontSize: 13, height: 1.9)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _open(context, _releaseUrl),
              icon: const Icon(Icons.download_rounded),
              label: const Text('تحميل التطبيق'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _open(context, _repoUrl),
              icon: const Icon(Icons.code_rounded),
              label: const Text('صفحة المشروع على GitHub'),
            ),
          ),
        ])),
        const SizedBox(height: 16),
        const Center(
          child: Text('تطبيقات أخرى قادمة قريبًا إن شاء الله',
              style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.7)),
        ),
      ]),
    );
  }
}

// ───────── الرئيسية ─────────
class HomePage extends StatefulWidget {
  final void Function(int) onTab;
  const HomePage({super.key, required this.onTab});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Ayah? _daily;

  @override
  void initState() {
    super.initState();
    _daily = Repo.i.daily();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // متابعة القراءة: آخر موضع محفوظ (سورة/آية/صفحة) أولاً، ثم السجل إن لم يوجد.
    final resumeAyah = user.hasReadingPosition
        ? Repo.i.ayahById(user.lastReadAyahId!)
        : (user.history.isEmpty ? null : Repo.i.ayahById(user.history.first));
    final resumeIsMushaf = user.hasReadingPosition && resumeAyah != null;
    final q = user.khatmahQuarter;
    final done = q > 240;
    final progress = ((q - 1).clamp(0, 240)) / 240;
    const quickSurahs = [1, 2, 18, 36, 67, 112];
    final isDark = settings.mode == ThemeMode.dark ||
        (settings.mode == ThemeMode.system && dark);
    return Scaffold(
      appBar: AppBar(
        title: const Text('تلاوة'),
        actions: [
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
            tooltip: 'الوضع الليلي',
            onPressed: () =>
                settings.setMode(isDark ? ThemeMode.light : ThemeMode.dark),
          ),
          IconButton(
            icon: const Icon(Icons.smart_toy_rounded),
            tooltip: 'المساعد الذكي',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const AssistantPage())),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
        // شريط البحث — يفتح صفحة البحث
        GestureDetector(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const SearchPage())),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1C2B33) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)
              ],
            ),
            child: Row(children: [
              const Icon(Icons.search_rounded, color: sky),
              const SizedBox(width: 10),
              Text('ابحث في القرآن الكريم...',
                  style: TextStyle(fontSize: 15, color: Theme.of(context).hintColor)),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Stack(children: [
          softCard(context,
              gradient: LinearGradient(
                colors: dark
                    ? [const Color(0xFF1C2B33), const Color(0xFF123B33)]
                    : [skyLight, pinkLight],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [
                  LogoMark(64),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('تلاوة',
                          style: TextStyle(
                              fontSize: 26, fontWeight: FontWeight.w800, color: skyDeep)),
                      SizedBox(height: 2),
                      Text('رفيقك في رحلتك مع القرآن',
                          style: TextStyle(fontSize: 14, height: 1.6)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 10),
                Text('114 سورة • 6,236 آية • المصحف العثماني برواية حفص، وثلاثة تفاسير، وتلاوة صوتية.',
                    style: TextStyle(fontSize: 14, height: 1.7, color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 14),
                FilledButton.tonalIcon(
                  onPressed: () => widget.onTab(1),
                  icon: const Icon(Icons.menu_book_rounded),
                  label: const Text('تصفح السور'),
                ),
              ])),
          const Positioned(top: 0, left: 0, child: FloralCorner(size: 72)),
        ]),
        if (_daily != null) ...[
          const SizedBox(height: 14),
          Stack(children: [
            softCard(context,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.wb_sunny_rounded, color: gold),
                      const SizedBox(width: 8),
                      const Text('تدبّر اليوم', style: TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('سورة ${_daily!.surahName} • آية ${_daily!.ayah}',
                          style: const TextStyle(fontSize: 12, color: gold)),
                    ]),
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => AyahDetailPage(_daily!.id))),
                      child: Text(_daily!.text, style: quranStyle(19, h: 1.9)),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: dark ? const Color(0xFF24455A) : mintLight,
                          borderRadius: BorderRadius.circular(16)),
                      child: Row(children: [
                        const Icon(Icons.psychology_rounded, color: teal, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(tadabburQuestion(DateTime.now()),
                              style: const TextStyle(fontSize: 14, height: 1.7)),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => AssistantPage(ayah: _daily))),
                        icon: const Icon(Icons.smart_toy_rounded),
                        label: const Text('اسأل عن هذه الآية'),
                      ),
                    ),
                  ],
                )),
            const Positioned(bottom: 0, left: 0, child: FloralCorner(size: 56, flip: true)),
          ]),
        ],
        if (resumeAyah != null) ...[
          const SizedBox(height: 14),
          softCard(context,
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => resumeIsMushaf
                          ? MushafPage(initialPage: user.lastReadPage!)
                          : AyahDetailPage(resumeAyah.id))),
              child: Row(children: [
                const Icon(Icons.history_rounded, color: teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('متابعة القراءة', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                        'سورة ${resumeAyah.surahName} • آية ${resumeAyah.ayah}'
                        '${resumeIsMushaf ? ' • صفحة ${user.lastReadPage}' : ''}',
                        style: const TextStyle(fontSize: 13)),
                  ]),
                ),
                const Icon(Icons.chevron_left),
              ])),
        ],
        const SizedBox(height: 14),
        softCard(context,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WirdPage())),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.track_changes_rounded, color: teal),
                const SizedBox(width: 8),
                const Text('ختمة القرآن', style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                    done ? 'ختمة مكتملة' : 'الربع $q من 240',
                    style: const TextStyle(fontSize: 12, color: gold, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                    value: progress, minHeight: 8, backgroundColor: tealLight, color: teal),
              ),
              const SizedBox(height: 8),
              Text(done
                  ? 'تقبّل الله منك — اضغط لبدء ختمة جديدة.'
                  : 'وردك اليوم: ${settings.wirdQuarters == 1 ? 'ربع حزب' : settings.wirdQuarters == 4 ? 'حزب كامل' : 'جزء كامل'} — اضغط لعرض الورد وإتمامه.',
                  style: const TextStyle(fontSize: 13)),
            ])),
        const SizedBox(height: 18),
        const Text('أقسام التطبيق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.7,
          children: [
            _tile(context, Icons.headphones_rounded, 'التلاوات', skyLight, sky,
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const RecitationsPage()))),
            _tile(context, Icons.menu_book_rounded, 'القرآن الكريم', mintLight, teal,
                () => widget.onTab(1)),
            _tile(context, Icons.auto_stories_rounded, 'المصحف', goldLight, gold,
                () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            MushafPage(initialPage: user.lastReadPage ?? 1)))),
            _tile(context, Icons.auto_stories_rounded, 'التفسير', goldLight, gold,
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const TafsirBrowserPage()))),
            _tile(context, Icons.favorite_rounded, 'المفضلة', pinkLight, pink,
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => FavsPage(onTab: (_) => widget.onTab(1))))),
            _tile(context, Icons.smart_toy_rounded, 'المساعد الذكي', skyLight, sky,
                () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AssistantPage()))),
            _tile(context, Icons.grid_view_rounded, 'المزيد', mintLight, teal,
                () => widget.onTab(2)),
          ],
        ),
        const SizedBox(height: 18),
        const Text('سور مختارة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: [
            for (final id in quickSurahs)
              Builder(builder: (c) {
                final s = Repo.i.surah(id)!;
                return softCard(c, onTap: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => SurahReaderPage(id))), child: Center(
                  child: Text(s.nameShort,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
                          color: Theme.of(c).colorScheme.onSurface)),
                ));
              }),
          ],
        ),
      ]),
    );
  }

  Widget _tile(BuildContext c, IconData icon, String label, Color bg, Color fg,
          VoidCallback onTap) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    final bgColor = dark ? const Color(0xFF1C2B33) : bg;
    return Container(
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(24)),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Icon(icon, color: fg, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────── قائمة السور ─────────
class SurahsPage extends StatefulWidget {
  const SurahsPage({super.key});
  @override
  State<SurahsPage> createState() => _SurahsPageState();
}

class _SurahsPageState extends State<SurahsPage> {
  final _ctl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = Repo.i.surahs();
    final n = normalizeAr(_q);
    final list = n.isEmpty
        ? all
        : all.where((s) {
            final name = normalizeAr('${s.nameAr} ${s.nameShort} ${s.nameEn}');
            final digits = s.id.toString();
            return name.contains(n) || digits == _q.trim();
          }).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('سور القرآن الكريم'),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_stories_rounded),
            tooltip: 'المصحف (604 صفحات)',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => MushafPage(initialPage: user.lastReadPage ?? 1))),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _ctl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'ابحث باسم السورة أو رقمها…',
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? emptyState(Icons.search_off_rounded, 'لا توجد سورة بهذا الاسم أو الرقم.')
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (c, i) {
                    final s = list[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: softCard(c,
                          onTap: () => Navigator.push(
                              c, MaterialPageRoute(builder: (_) => SurahReaderPage(s.id))),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: tealLight,
                              child: Text('${s.id}',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: teal)),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(s.nameAr,
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(
                                    '${s.revelation} • ${s.ayahCount} آية • الجزء ${s.juzStart}',
                                    style: const TextStyle(fontSize: 12)),
                              ]),
                            ),
                            const Icon(Icons.chevron_left, color: Colors.grey),
                          ])),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ───────── قارئ السورة ─────────
class SurahReaderPage extends StatefulWidget {
  final int surahId;
  const SurahReaderPage(this.surahId, {super.key});
  @override
  State<SurahReaderPage> createState() => _SurahReaderPageState();
}

class _SurahReaderPageState extends State<SurahReaderPage> {
  late List<Ayah> _ayahs;
  late Surah _surah;
  bool _downloading = false;
  double _dlProgress = 0;
  bool _downloaded = false;

  @override
  void initState() {
    super.initState();
    _surah = Repo.i.surah(widget.surahId)!;
    _ayahs = Repo.i.ayahsOf(widget.surahId);
    audio.isSurahDownloaded(widget.surahId).then((v) {
      if (mounted) setState(() => _downloaded = v);
    });
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _dlProgress = 0;
    });
    await audio.downloadSurah(widget.surahId, (done, total) {
      if (mounted) setState(() => _dlProgress = done / total);
    });
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _downloaded = true;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تم تنزيل السورة للاستماع دون إنترنت')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('سورة ${_surah.nameAr}'),
        actions: [
          if (_downloading)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(value: _dlProgress, strokeWidth: 3)),
            )
          else
            IconButton(
              icon: Icon(_downloaded ? Icons.download_done_rounded : Icons.download_rounded),
              tooltip: _downloaded ? 'تم تنزيل الصوت' : 'تنزيل الصوت للاستماع دون إنترنت',
              onPressed: _downloaded ? null : _download,
            ),
          IconButton(
            icon: const Icon(Icons.play_circle_filled_rounded),
            tooltip: 'تلاوة السورة كاملة',
            onPressed: () => audio.playSurah(widget.surahId),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'خيارات القراءة',
            onSelected: (v) {
              switch (v) {
                case 'font_up':
                  settings.setFont((settings.fontSize + 2).clamp(18, 36).toDouble());
                case 'font_down':
                  settings.setFont((settings.fontSize - 2).clamp(18, 36).toDouble());
                case 'night':
                  settings.setMode(
                      Theme.of(context).brightness == Brightness.dark
                          ? ThemeMode.light
                          : ThemeMode.dark);
                case 'mushaf':
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => MushafPage(
                              initialPage: Repo.i.surahStartPage(widget.surahId))));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'font_up',
                  child: Text('تكبير الخط (الآن ${settings.fontSize.round()})')),
              PopupMenuItem(
                  value: 'font_down',
                  child: Text('تصغير الخط (الآن ${settings.fontSize.round()})')),
              const PopupMenuItem(value: 'night', child: Text('الوضع الليلي / الفاتح')),
              const PopupMenuItem(value: 'mushaf', child: Text('عرض في المصحف')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            Chip(label: Text(_surah.revelation)),
            const SizedBox(width: 8),
            Chip(label: Text('${_surah.ayahCount} آية')),
            const SizedBox(width: 8),
            Chip(label: Text('يبدأ في الجزء ${_surah.juzStart}')),
          ]),
        ),
        if (surahVirtues.containsKey(widget.surahId))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: softCard(context,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.emoji_events_rounded, color: gold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('فضل السورة',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(surahVirtues[widget.surahId]!.$1,
                          style: const TextStyle(fontSize: 13, height: 1.8)),
                      const SizedBox(height: 2),
                      Text('المصدر: ${surahVirtues[widget.surahId]!.$2}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ]),
                  ),
                ])),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: OrnateFrame(
              child: AnimatedBuilder(
                animation: audio,
                builder: (c, _) => ListView.builder(
                  padding: EdgeInsets.zero,
              itemCount: _ayahs.length,
              itemBuilder: (c, i) {
                final a = _ayahs[i];
                final isPlaying = audio.currentAyahId == a.id;
                final dark = Theme.of(c).brightness == Brightness.dark;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Material(
                    color: isPlaying
                        ? (dark ? const Color(0xFF2C463F) : tealLight)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        user.touch(a.id);
                        user.saveReadingPosition(surah: a.surah, ayahId: a.id, page: a.page);
                        Navigator.push(c,
                            MaterialPageRoute(builder: (_) => AyahDetailPage(a.id)));
                      },
                      onLongPress: () => showAyahActions(c, a),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: isPlaying ? teal : tealLight,
                            child: isPlaying
                                ? const Icon(Icons.volume_up_rounded, size: 16, color: Colors.white)
                                : Text('${a.ayah}',
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: teal)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              a.text,
                              style: quranStyle(settings.fontSize, h: 2.0,
                                  w: isPlaying ? FontWeight.w800 : FontWeight.w600),
                            ),
                          ),
                          if (a.sajda)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Text('۩', style: TextStyle(fontSize: 18, color: gold)),
                            ),
                        ]),
                      ),
                    ),
                  ),
                );
              },
            ),
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: audio,
          builder: (c, _) {
            if (audio.currentAyahId == null || audio.playlist.isEmpty) return const SizedBox.shrink();
            final cur = Repo.i.ayahById(audio.currentAyahId!);
            if (cur == null) return const SizedBox.shrink();
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(c).colorScheme.surface,
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10)],
              ),
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                StreamBuilder<Duration>(
                  stream: audio.player.positionStream,
                  builder: (_, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = audio.player.duration ?? Duration.zero;
                    final max =
                        dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
                    return Column(children: [
                      Slider(
                        value: pos.inMilliseconds.toDouble().clamp(0, max),
                        max: max,
                        onChanged: (v) =>
                            audio.player.seek(Duration(milliseconds: v.round())),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(fmtDur(pos), style: const TextStyle(fontSize: 12)),
                              Text(fmtDur(dur), style: const TextStyle(fontSize: 12)),
                            ]),
                      ),
                    ]);
                  },
                ),
                Row(children: [
                  IconButton(icon: const Icon(Icons.skip_next_rounded), onPressed: audio.next),
                  IconButton(
                    icon: Icon(audio.playing
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_filled_rounded),
                    iconSize: 40,
                    color: teal,
                    onPressed: audio.togglePlayPause,
                  ),
                  IconButton(icon: const Icon(Icons.skip_previous_rounded), onPressed: audio.previous),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                          c, MaterialPageRoute(builder: (_) => AyahDetailPage(cur.id))),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('سورة ${cur.surahName} • آية ${cur.ayah}',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                        Text(cur.text, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close_rounded), onPressed: audio.stop),
                ]),
                // سرعة التشغيل والتكرار ومؤقت النوم (Pro).
                Row(children: [
                  TextButton.icon(
                    onPressed: audio.cycleSpeed,
                    icon: const Icon(Icons.speed_rounded, size: 18),
                    label: Text('السرعة ${audio.speedLabel}'),
                  ),
                  TextButton.icon(
                    onPressed: audio.cycleRepeat,
                    icon: Icon(
                      audio.repeatMode == LoopMode.one
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      size: 18,
                      color: audio.repeatMode == LoopMode.off ? Colors.grey : teal,
                    ),
                    label: Text(audio.repeatLabel),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final choice = await showModalBottomSheet<Duration?>(
                        context: c,
                        builder: (ctx) => SafeArea(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const ListTile(
                                title: Text('مؤقت النوم — إيقاف التلاوة تلقائياً')),
                            for (final m in [15, 30, 60])
                              ListTile(
                                title: Text('بعد $m دقيقة'),
                                onTap: () =>
                                    Navigator.pop(ctx, Duration(minutes: m)),
                              ),
                            ListTile(
                              title: const Text('إلغاء المؤقت'),
                              onTap: () => Navigator.pop(ctx, Duration.zero),
                            ),
                          ]),
                        ),
                      );
                      if (choice == null) return;
                      audio.setSleepTimer(
                          choice == Duration.zero ? null : choice);
                    },
                    icon: Icon(Icons.bedtime_rounded,
                        size: 18,
                        color: audio.sleepEndsAt == null ? Colors.grey : teal),
                    label: Text(audio.sleepEndsAt == null
                        ? 'مؤقت النوم'
                        : 'ينتهي خلال ~${audio.sleepMinutesLeft} د'),
                  ),
                ]),
              ]),
            );
          },
        ),
      ]),
    );
  }
}

// ───────── المصحف: 604 صفحات بتخطيط نصي من قاعدة البيانات ─────────
// وضع الصفحات نصي بالكامل: لا صور مصحف في APK إطلاقًا. كل صفحة تُبنى
// من ayahs.page (1..604) في قاعدة البيانات، والنص يُعرض حرفيًا من
// Ayah.text دون أي تعديل. عنوان السورة والبسملة: البسملة مأخوذة حرفيًا
// من نص آية 1:1 في القاعدة (Repo.i.ayahById(1)) وليست مكتوبة يدويًا،
// وتُعرض فقط عند بداية سورة (عدا الفاتحة — فآيتها الأولى هي البسملة
// نفسها — وعدا التوبة التي لا بسملة لها).
class MushafPage extends StatefulWidget {
  final int initialPage;
  const MushafPage({this.initialPage = 1, super.key});
  @override
  State<MushafPage> createState() => _MushafPageState();
}

class _MushafPageState extends State<MushafPage> {
  late final PageController _ctl;
  late int _page;
  late List<Ayah> _ayahs;
  String? _basmala;

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage.clamp(1, 604).toInt();
    _ctl = PageController(initialPage: _page - 1);
    _ayahs = Repo.i.ayahsOfPage(_page);
    _basmala = Repo.i.ayahById(1)?.text;
    _savePosition();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _savePosition() {
    if (_ayahs.isEmpty) return;
    final first = _ayahs.first;
    user.saveReadingPosition(surah: first.surah, ayahId: first.id, page: _page);
  }

  void _goTo(int page) {
    final p = page.clamp(1, 604).toInt();
    _ctl.animateToPage(p - 1,
        duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Future<void> _jumpDialog() async {
    final pageCtl = TextEditingController(text: '$_page');
    int? surahId;
    int? juz;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, setD) => AlertDialog(
          title: const Text('الانتقال في المصحف'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: pageCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'رقم الصفحة (1–604)'),
            ),
            const SizedBox(height: 12),
            DropdownButton<int>(
              value: surahId,
              hint: const Text('أو اختر سورة'),
              isExpanded: true,
              items: [
                for (final s in Repo.i.surahs())
                  DropdownMenuItem(value: s.id, child: Text('سورة ${s.nameAr}')),
              ],
              onChanged: (v) => setD(() => surahId = v),
            ),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: juz,
              hint: const Text('أو اختر جزءًا'),
              isExpanded: true,
              items: [
                for (var j = 1; j <= 30; j++)
                  DropdownMenuItem(value: j, child: Text('الجزء $j')),
              ],
              onChanged: (v) => setD(() => juz = v),
            ),
            const SizedBox(height: 8),
            const Text('إن اخترت سورة أو جزءًا فهو يقدَّم على رقم الصفحة.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('انتقال')),
          ],
        ),
      ),
    );
    final pageText = pageCtl.text.trim();
    pageCtl.dispose();
    if (go != true || !mounted) return;
    if (surahId != null) {
      _goTo(Repo.i.surahStartPage(surahId!));
      return;
    }
    if (juz != null) {
      _goTo(Repo.i.juzStartPage(juz!));
      return;
    }
    final n = int.tryParse(pageText);
    if (n == null || n < 1 || n > 604) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('رقم الصفحة بين 1 و 604')));
      return;
    }
    _goTo(n);
  }

  @override
  Widget build(BuildContext context) {
    final first = _ayahs.isEmpty ? null : _ayahs.first;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surahNames = _ayahs.map((a) => a.surahName).toSet().toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('المصحف • صفحة $_page'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            tooltip: 'خيارات المصحف',
            onSelected: (v) {
              switch (v) {
                case 'font_up':
                  settings.setFont((settings.fontSize + 2).clamp(18, 36).toDouble());
                case 'font_down':
                  settings.setFont((settings.fontSize - 2).clamp(18, 36).toDouble());
                case 'night':
                  settings.setMode(dark ? ThemeMode.light : ThemeMode.dark);
                case 'jump':
                  _jumpDialog();
                case 'tajweed':
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const TajweedPage()));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'font_up',
                  child: Text('تكبير الخط (الآن ${settings.fontSize.round()})')),
              PopupMenuItem(
                  value: 'font_down',
                  child: Text('تصغير الخط (الآن ${settings.fontSize.round()})')),
              const PopupMenuItem(value: 'night', child: Text('الوضع الليلي / الفاتح')),
              const PopupMenuItem(value: 'jump', child: Text('الانتقال إلى صفحة / سورة / جزء…')),
              const PopupMenuItem(value: 'tajweed', child: Text('أحكام التجويد')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            if (first != null) ...[
              Chip(label: Text('الجزء ${first.juz}')),
              const SizedBox(width: 8),
              Chip(label: Text('${_ayahs.length} آية')),
              const SizedBox(width: 8),
              Expanded(
                child: Text(surahNames.join('، '),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ]),
        ),
        Expanded(
          child: PageView.builder(
            controller: _ctl,
            itemCount: 604,
            onPageChanged: (i) {
              setState(() {
                _page = i + 1;
                _ayahs = Repo.i.ayahsOfPage(_page);
              });
              _savePosition();
            },
            itemBuilder: (c, i) => _buildPage(c, i + 1),
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.chevron_right_rounded),
              tooltip: 'الصفحة السابقة',
              onPressed: _page > 1 ? () => _goTo(_page - 1) : null,
            ),
            Expanded(
              child: Text('صفحة $_page من 604',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded),
              tooltip: 'الصفحة التالية',
              onPressed: _page < 604 ? () => _goTo(_page + 1) : null,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext c, int page) {
    final ayahs = Repo.i.ayahsOfPage(page);
    if (ayahs.isEmpty) {
      return emptyState(Icons.menu_book_rounded, 'لا توجد آيات في الصفحة $page.');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: OrnateFrame(
        child: ListView.builder(
          itemCount: ayahs.length,
          itemBuilder: (c, i) {
            final a = ayahs[i];
            final children = <Widget>[];
            if (a.ayah == 1) {
              final s = Repo.i.surah(a.surah);
              if (s != null) children.add(_surahHeader(c, s));
              // البسملة من نص آية 1:1 في القاعدة حرفيًا — لا تُكتب يدويًا.
              if (a.surah != 1 && a.surah != 9 && _basmala != null) {
                children.add(Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(_basmala!,
                        textAlign: TextAlign.center, style: quranStyle(settings.fontSize, h: 1.9)),
                  ),
                ));
              }
            }
            children.add(_ayahRow(c, a));
            return Column(children: children);
          },
        ),
      ),
    );
  }

  Widget _surahHeader(BuildContext c, Surah s) {
    final dark = Theme.of(c).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF24455A) : goldLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: gold.withValues(alpha: 0.5)),
      ),
      child: Center(
        child: Text('سورة ${s.nameAr}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800, fontFamily: 'Amiri', color: skyDeep)),
      ),
    );
  }

  Widget _ayahRow(BuildContext c, Ayah a) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          user.touch(a.id);
          user.saveReadingPosition(surah: a.surah, ayahId: a.id, page: a.page);
          Navigator.push(c, MaterialPageRoute(builder: (_) => AyahDetailPage(a.id)));
        },
        onLongPress: () => showAyahActions(c, a),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: a.text, style: quranStyle(settings.fontSize, h: 2.0)),
              TextSpan(
                  text: ' ﴿${_arDigits(a.ayah)}﴾',
                  style: quranStyle(settings.fontSize - 2, h: 2.0, w: FontWeight.w700)
                      .copyWith(color: gold)),
              if (a.sajda)
                TextSpan(
                    text: ' ۩',
                    style: quranStyle(settings.fontSize, h: 2.0).copyWith(color: gold)),
            ]),
            textAlign: TextAlign.justify,
          ),
        ),
      ),
    );
  }
}

// ───────── أحكام التجويد: مفتاح الألوان وحالة التلوين ─────────
// التلوين داخل النص غير مفعّل: بيانات cpfair/quran-tajweed مرخّصة
// CC BY 4.0 لكن إزاحاتها مبنية على نص تنزيل 2017 بينما نص التطبيق
// تنزيل Uthmani v1.1، ولم يُتحقق من المحاذاة آيةً بآية بعد.
// هذه الصفحة تعرض الأحكام ومفتاح الألوان والحالة بصراحة، ولا تلوّن
// أي حرف قبل اكتمال التحقق (tools/verify_tajweed.py).
class TajweedPage extends StatelessWidget {
  const TajweedPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('أحكام التجويد')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        softCard(context,
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.info_rounded, color: skyDeep),
                SizedBox(width: 8),
                Text('حالة التلوين',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ]),
              SizedBox(height: 8),
              Text(
                  'التلوين داخل نص المصحف غير مفعّل حالياً — لا يُلوَّن أي حرف قبل اكتمال التحقق من المحاذاة.',
                  style: TextStyle(fontSize: 14, height: 1.9, fontWeight: FontWeight.w700)),
              SizedBox(height: 6),
              Text(
                  'بيانات الأحكام من مشروع cpfair/quran-tajweed، مرخّصة Creative Commons Attribution 4.0 (CC BY 4.0) وتشمل 18 حكماً لرواية حفص عن عاصم. لكن إزاحاتها (مواضع الأحكام حرفًا بحرف) مبنية على نص تنزيل Uthmani من عام 2017، بينما نص هذا التطبيق هو تنزيل Uthmani v1.1 — وقد ثبت اختلاف بنيوي واحد على الأقل: نص 2017 يُلحق البسملة بأول آية في كل سورة، بينما قاعدة التطبيق لا تفعل. تطبيق الإزاحات دون محاذاة قد يلوّن الحرف الخطأ. لذلك لا تُدمج البيانات قبل أن يمرّ فحص المحاذاة (tools/verify_tajweed.py) على الآيات الـ 6,236 كلها.',
                  style: TextStyle(fontSize: 13, height: 1.9)),
            ])),
        const SizedBox(height: 14),
        const Text('الأحكام — رواية حفص عن عاصم',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('الألوان أدناه هي المفتاح المقترح للتلوين عند تفعيله بعد التحقق.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
        const SizedBox(height: 10),
        for (final r in tajweedRules)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: softCard(context,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 12, backgroundColor: Color(r.color)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(r.nameAr,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(r.definition, style: const TextStyle(fontSize: 13, height: 1.8)),
                    ]),
                  ),
                ])),
          ),
        const SizedBox(height: 6),
        const Text(tajweedAttribution,
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.8)),
      ]),
    );
  }
}

// ───────── تفاصيل الآية والتفسير ─────────
class AyahDetailPage extends StatefulWidget {
  final int ayahId;
  const AyahDetailPage(this.ayahId, {super.key});
  @override
  State<AyahDetailPage> createState() => _AyahDetailPageState();
}

class _AyahDetailPageState extends State<AyahDetailPage> {
  late Ayah _a;
  int _sourceIdx = 0;
  late Map<String, String> _offline;

  List<(String id, String name, bool online)> get _sources => [
        for (final (id, name) in offlineTafsirs) (id, name, false),
        for (final (id, name) in onlineTafsirs) ('$id', name, true),
      ];

  @override
  void initState() {
    super.initState();
    _a = Repo.i.ayahById(widget.ayahId)!;
    user.touch(_a.id);
    user.saveReadingPosition(surah: _a.surah, ayahId: _a.id, page: _a.page);
    _offline = Repo.i.tafsirOf(_a.surah, _a.ayah);
  }

  void _go(int delta) {
    final id = Repo.i.neighbor(_a, delta);
    if (id == null) return;
    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => AyahDetailPage(id)));
  }

  @override
  Widget build(BuildContext context) {
    final fav = user.has(_a.id);
    final note = user.notes[_a.id];
    final tag = user.tags[_a.id];
    final (sid, sname, online) = _sources[_sourceIdx];
    final ijazHere =
        Repo.i.ijazList().where((e) => e.surah == _a.surah && e.ayah == _a.ayah).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('سورة ${_a.surahName} • آية ${_a.ayah}'),
        actions: [
          IconButton(
            icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded, color: gold),
            tooltip: 'حفظ في المفضلة',
            onPressed: () => setState(() => user.toggle(_a.id)),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: user,
        builder: (c, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          softCard(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_a.text, style: quranStyle(settings.fontSize + 2, h: 2.0)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [
              Chip(label: Text('الجزء ${_a.juz}')),
              Chip(label: Text('الحزب ${_a.hizb}')),
              Chip(label: Text('صفحة المصحف ${_a.page}')),
              if (_a.sajda) const Chip(label: Text('۩ سجدة تلاوة')),
            ]),
            if (tag != null || note != null) ...[
              const SizedBox(height: 10),
              if (tag != null) Chip(label: Text('🏷 $tag'), backgroundColor: tealLight),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('ملاحظتي: $note', style: const TextStyle(fontSize: 14, height: 1.7)),
                ),
            ],
          ])),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
              onPressed: () async {
                await audio.playAyah(_a);
                if (!c.mounted) return;
                if (audio.error != null && mounted) {
                  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(audio.error!)));
                }
              },
              icon: AnimatedBuilder(
                animation: audio,
                builder: (_, __) => Icon(audio.currentAyahId == _a.id && audio.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
              ),
              label: const Text('استماع'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Navigator.push(
                  c, MaterialPageRoute(builder: (_) => AssistantPage(ayah: _a))),
              icon: const Icon(Icons.smart_toy_rounded),
              label: const Text('اسأل عن هذه الآية'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => Share.share('﴿${_a.text}﴾\nسورة ${_a.surahName} — آية ${_a.ayah}'),
              icon: const Icon(Icons.share_rounded),
              label: const Text('مشاركة'),
            ),
            FilledButton.tonalIcon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _a.text));
                if (!c.mounted) return;
                if (mounted) {
                  ScaffoldMessenger.of(c)
                      .showSnackBar(const SnackBar(content: Text('تم نسخ الآية')));
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('نسخ'),
            ),
            FilledButton.tonalIcon(
              onPressed: () async {
                final t = await askText(c, 'ملاحظة على الآية', note ?? '', lines: 3);
                if (t != null) setState(() => user.setNote(_a.id, t));
              },
              icon: const Icon(Icons.note_add_rounded),
              label: const Text('ملاحظة'),
            ),
            FilledButton.tonalIcon(
              onPressed: () async {
                final t = await askText(c, 'وسم للآية', tag ?? '',
                    chips: ['دعاء', 'أحكام', 'قصص', 'عقيدة', 'أخلاق']);
                if (!c.mounted) return;
                if (t != null) {
                  if (t.trim().isEmpty && !user.has(_a.id)) {
                    if (mounted) {
                      ScaffoldMessenger.of(c).showSnackBar(
                          const SnackBar(content: Text('أضف الآية إلى المفضلة أولاً')));
                    }
                    return;
                  }
                  setState(() {
                    if (!user.has(_a.id)) user.toggle(_a.id);
                    user.setTag(_a.id, t);
                  });
                }
              },
              icon: const Icon(Icons.label_rounded),
              label: const Text('وسم'),
            ),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            FilledButton.tonalIcon(
              onPressed: () => _go(-1),
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('الآية السابقة'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _go(1),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('الآية التالية'),
            ),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            const Text('التفسير', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            if (online)
              const Chip(
                label: Text('متصل بالإنترنت', style: TextStyle(fontSize: 11)),
                backgroundColor: Color(0xFFFFF3CD),
              ),
          ]),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _sources.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(_sources[i].$2),
                    selected: i == _sourceIdx,
                    onSelected: (_) => setState(() => _sourceIdx = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          softCard(c,
              child: online
                  ? FutureBuilder<String?>(
                      future: Repo.i.onlineTafsir(int.parse(sid), _a.surah, _a.ayah),
                      builder: (ctx, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final text = snap.data;
                        if (text == null) {
                          return const Text(
                              'تعذّر جلب التفسير الآن — تحقق من الإنترنت، أو جرّب مصدرًا آخر. '
                              'التفاسير الكبيرة تُجلب من Quran.com عند الاتصال وتُحفظ محليًا بعد أول مرة.',
                              style: TextStyle(height: 1.8));
                        }
                        return Text(text, style: const TextStyle(fontSize: 15, height: 1.9));
                      },
                    )
                  : Text(
                      _offline[sid] ?? 'لا يوجد تفسير من هذا المصدر لهذه الآية في المكتبة.',
                      style: const TextStyle(fontSize: 15, height: 1.9),
                    )),
          const SizedBox(height: 14),
          const Text('آيات مشابهة',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('آيات تشترك مع هذه الآية في ألفاظها وموضوعها — من نص القرآن الكريم.',
              style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
          const SizedBox(height: 8),
          FutureBuilder<List<Ayah>>(
            future: Repo.i.related(_a),
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Center(child: CircularProgressIndicator()));
              }
              final rel = snap.data ?? [];
              if (rel.isEmpty) {
                return const Text('لا توجد آيات مشابهة ظاهرة لهذه الآية.',
                    style: TextStyle(fontSize: 13, color: Colors.grey));
              }
              return Column(children: [
                for (final r in rel)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ayahCard(ctx, r),
                  ),
              ]);
            },
          ),
          if (ijazHere.isNotEmpty) ...[
            const SizedBox(height: 14),
            softCard(c,
                onTap: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => IjazDetailPage(ijazHere.first.id))),
                child: Row(children: [
                  const Icon(Icons.lightbulb_rounded, color: gold),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('من الإعجاز: ${ijazHere.first.title}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  const Icon(Icons.chevron_left),
                ])),
          ],
          const SizedBox(height: 14),
          Text('المصدر: $sname', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
    );
  }
}

// ───────── البحث ─────────
// تبويبات: الآيات / التفسير / السور.
// (لا يوجد تبويب أحاديث — هذا تطبيق قرآن كريم، والتصميم الأصلي خلط عناصر تطبيق أحاديث.)
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _ctl = TextEditingController();
  List<Ayah>? results;
  List<TafsirHit>? tafsirResults;
  bool searching = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _go(String q) async {
    if (q.trim().isEmpty) return;
    setState(() => searching = true);
    if (_tabs.index == 1) {
      final r = await Repo.i.searchTafsir(q);
      if (!mounted) return;
      setState(() {
        tafsirResults = r;
        results = null;
        searching = false;
      });
    } else {
      // Pro: البحث المعجمي أولاً (41 استعلاماً موثقاً، missing=0)؛
      // وإن غابت جداول المعجم من المكتبة المثبتة يُعاد إلى البحث القديم.
      List<Ayah> r;
      try {
        if (await Repo.i.lexiconAvailable()) {
          r = await Repo.i.searchLexicon(q);
        } else {
          r = await Repo.i.search(q);
        }
      } on StateError {
        r = await Repo.i.search(q);
      }
      if (!mounted) return;
      setState(() {
        results = r;
        tafsirResults = null;
        searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('البحث'),
        bottom: TabBar(
          controller: _tabs,
          onTap: (_) => setState(() {
            results = null;
            tafsirResults = null;
          }),
          tabs: const [
            Tab(text: 'الآيات'),
            Tab(text: 'التفسير'),
            Tab(text: 'السور'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _searchColumn(
              hint: 'ابحث في نص القرآن… مثال: الصلاة، الصبر',
              resultsWidget: _ayahResults()),
          _searchColumn(
              hint: 'ابحث في نصوص التفاسير… مثال: الصبر، الرحمة',
              resultsWidget: _tafsirResults()),
          const _SurahSearchTab(),
        ],
      ),
    );
  }

  Widget _searchColumn({required String hint, required Widget resultsWidget}) =>
      Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _ctl,
            textInputAction: TextInputAction.search,
            onSubmitted: _go,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: hint,
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () => setState(() {
                        _ctl.clear();
                        results = null;
                        tafsirResults = null;
                      }),
                    ),
              filled: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 6, children: [
            for (final hint in ['الصلاة', 'الصبر', 'الرحمن', '2:255'])
              ActionChip(
                label: Text(hint),
                onPressed: () {
                  _ctl.text = hint;
                  _go(hint);
                },
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(child: resultsWidget),
      ]);

  Widget _ayahResults() {
    if (results == null) {
      return emptyState(Icons.search_rounded,
          'ابحث في نص القرآن الكريم كاملاً.\nيمكنك أيضاً كتابة مرجع مباشر مثل «2:255» للانتقال إلى آية الكرسي.');
    }
    if (results!.isEmpty) {
      return emptyState(Icons.search_off_rounded, 'لا توجد نتائج مطابقة — جرّب كلمة أخرى.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: results!.length,
      itemBuilder: (c, i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ayahCard(c, results![i]),
      ),
    );
  }

  Widget _tafsirResults() {
    if (tafsirResults == null) {
      return emptyState(Icons.auto_stories_rounded,
          'ابحث في نصوص التفاسير المدمجة (الميسر، الجلالين، السعدي).\nالنتائج تعرض الآية مع مقتطف من التفسير ومصدره.');
    }
    if (tafsirResults!.isEmpty) {
      return emptyState(Icons.search_off_rounded, 'لا توجد نتائج في التفاسير — جرّب كلمة أخرى.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: tafsirResults!.length,
      itemBuilder: (c, i) {
        final h = tafsirResults![i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: softCard(c,
              onTap: () => Navigator.push(
                  c, MaterialPageRoute(builder: (_) => AyahDetailPage(h.ayah.id))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(h.ayah.text,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: quranStyle(16, h: 1.9)),
                const SizedBox(height: 6),
                Text(h.snippet, style: const TextStyle(fontSize: 13, height: 1.8)),
                const SizedBox(height: 6),
                Text('سورة ${h.ayah.surahName} • آية ${h.ayah.ayah} — ${h.sourceName}',
                    style: const TextStyle(fontSize: 12, color: gold)),
              ])),
        );
      },
    );
  }
}

/// تبويب بحث السور بالاسم أو الرقم.
class _SurahSearchTab extends StatefulWidget {
  const _SurahSearchTab();
  @override
  State<_SurahSearchTab> createState() => _SurahSearchTabState();
}

class _SurahSearchTabState extends State<_SurahSearchTab> {
  final _ctl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = Repo.i.surahs();
    final n = normalizeAr(_q);
    final list = n.isEmpty
        ? all
        : all.where((s) {
            final name = normalizeAr('${s.nameAr} ${s.nameShort} ${s.nameEn}');
            return name.contains(n) || s.id.toString() == _q.trim();
          }).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(
          controller: _ctl,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search_rounded),
            hintText: 'ابحث باسم السورة أو رقمها…',
            filled: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      Expanded(
        child: list.isEmpty
            ? emptyState(Icons.search_off_rounded, 'لا توجد سورة بهذا الاسم أو الرقم.')
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (c, i) {
                  final s = list[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: softCard(c,
                        onTap: () => Navigator.push(
                            c, MaterialPageRoute(builder: (_) => SurahReaderPage(s.id))),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          CircleAvatar(
                              radius: 22,
                              backgroundColor: skyLight,
                              child: Text('${s.id}',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: skyDeep))),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(s.nameAr,
                                  style: const TextStyle(
                                      fontSize: 18, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text('${s.revelation} • ${s.ayahCount} آية • الجزء ${s.juzStart}',
                                  style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                          const Icon(Icons.chevron_left, color: Colors.grey),
                        ])),
                  );
                },
              ),
      ),
    ]);
  }
}

// ───────── المفضلة ─────────
class FavsPage extends StatefulWidget {
  final void Function(int) onTab;
  const FavsPage({super.key, required this.onTab});
  @override
  State<FavsPage> createState() => _FavsPageState();
}

class _FavsPageState extends State<FavsPage> {
  String? filter;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          Text('المفضلة'),
          SizedBox(width: 8),
          Icon(Icons.favorite_rounded, color: pink),
        ]),
      ),
      body: AnimatedBuilder(
        animation: user,
        builder: (c, _) {
          final ids = filter == null
              ? user.ids
              : user.ids.where((id) => user.tags[id] == filter).toList();
          final tags = user.allTags;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Stack(children: [
                softCard(c,
                    child: Row(children: [
                      const Icon(Icons.bookmark_rounded, color: pink, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('آياتك المحفوظة',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 16)),
                              Text(
                                  user.ids.isEmpty
                                      ? 'احفظ الآيات التي تحبها لتعود إليها بسرعة.'
                                      : '${user.ids.length} آية محفوظة — اضغط أي آية لفتحها.',
                                  style: const TextStyle(fontSize: 13, height: 1.7)),
                            ]),
                      ),
                    ])),
                const Positioned(top: 0, left: 0, child: FloralCorner(size: 52)),
              ]),
            ),
            if (tags.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                          label: const Text('الكل'),
                          selected: filter == null,
                          onSelected: (_) => setState(() => filter = null)),
                    ),
                    for (final t in tags)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                            label: Text(t),
                            selected: filter == t,
                            onSelected: (_) => setState(() => filter = t)),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: user.ids.isEmpty
                  ? emptyState(Icons.bookmark_border_rounded,
                      'لا توجد آيات محفوظة بعد.\nافتح أي آية واضغط على النجمة لحفظها هنا.',
                      button: 'تصفح السور', onTap: () => widget.onTab(1))
                  : ids.isEmpty
                      ? emptyState(Icons.label_off_rounded, 'لا توجد آيات بهذا الوسم.')
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          itemCount: ids.length,
                          itemBuilder: (c, i) {
                            final a = Repo.i.ayahById(ids[i]);
                            if (a == null) return const SizedBox.shrink();
                            final tag = user.tags[a.id];
                            final note = user.notes[a.id];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: softCard(c,
                                  onTap: () => Navigator.push(c,
                                      MaterialPageRoute(builder: (_) => AyahDetailPage(a.id))),
                                  child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(a.text,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: quranStyle(17, h: 1.9)),
                                        const SizedBox(height: 6),
                                        Row(children: [
                                          const Icon(Icons.bookmark_rounded,
                                              color: pink, size: 16),
                                          const SizedBox(width: 4),
                                          Text('سورة ${a.surahName} • آية ${a.ayah}',
                                              style: const TextStyle(fontSize: 12, color: gold)),
                                          const Spacer(),
                                          if (tag != null) Chip(label: Text(tag)),
                                        ]),
                                        if (note != null) ...[
                                          const SizedBox(height: 6),
                                          Text('ملاحظتي: $note',
                                              style: const TextStyle(fontSize: 13, height: 1.6)),
                                        ],
                                      ])),
                            );
                          },
                        ),
            ),
          ]);
        },
      ),
    );
  }
}

// ───────── السجل ─────────
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('السجل'),
        actions: [
          if (user.history.isNotEmpty)
            IconButton(icon: const Icon(Icons.delete_sweep_rounded), onPressed: user.clearHistory),
        ],
      ),
      body: AnimatedBuilder(
        animation: user,
        builder: (c, _) {
          if (user.history.isEmpty) {
            return emptyState(Icons.history_rounded, 'لا توجد قراءات بعد.\nالآيات التي تفتحها ستظهر هنا.');
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: user.history.length,
            itemBuilder: (c, i) {
              final a = Repo.i.ayahById(user.history[i]);
              if (a == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ayahCard(c, a),
              );
            },
          );
        },
      ),
    );
  }
}

// ───────── المساعد الذكي (استرجاعي فقط — بلا توليد وبلا فتاوى) ─────────
/// أنواع رسائل المساعد:
/// 0 سؤال المستخدم، 1 نتائج موضوع، 2 جواب عن آية (تفسير + آيات مشابهة)،
/// 3 معلومة، 4 فضل سورة، 5 مخطط الورد الذكي.
class _Msg {
  final int kind;
  final String text;
  final List<Ayah>? results;
  final List<Ayah>? related;
  final Ayah? ayah;
  final Map<String, String>? tafsir;
  final int? surahId;
  _Msg(this.kind, this.text,
      {this.results, this.related, this.ayah, this.tafsir, this.surahId});
}

class AssistantPage extends StatefulWidget {
  final Ayah? ayah; // سياق: آية سُئل عنها من القارئ («اسأل عن هذه الآية»)
  const AssistantPage({this.ayah, super.key});
  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  final _msgs = <_Msg>[];
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  bool _busy = false;
  Ayah? _contextAyah; // الآية الحالية التي يدور حولها الحوار
  List<String> _followUps = [];

  @override
  void initState() {
    super.initState();
    _msgs.add(_Msg(3,
        'أنا مساعد تلاوة. أبحث في نص القرآن الكريم وتفاسيره وأعرض لك الآيات مع مصادرها.\n'
        'لا أصدر فتاوى ولا أفسّر من عندي — أبحث فقط في نصوص المكتبة.\n'
        'يمكنك سؤالي عن موضوع («آيات عن الصبر»)، أو عن آية محددة من القارئ، '
        'أو أن أخطط لك وردًا حسب وقتك.'));
    if (widget.ayah != null) {
      _contextAyah = widget.ayah;
      _askAboutAyah(widget.ayah!);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _scrollDown() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_scroll.hasClients) {
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  /// جواب عن آية محددة: نصها + تفسيرها من التفاسير المدمجة + آيات مشابهة.
  Future<void> _askAboutAyah(Ayah a) async {
    setState(() {
      _msgs.add(_Msg(0, 'ما معنى هذه الآية؟ — سورة ${a.surahName}، آية ${a.ayah}'));
      _busy = true;
    });
    final tafsir = Repo.i.tafsirOf(a.surah, a.ayah);
    final rel = await Repo.i.related(a);
    if (!mounted) return;
    setState(() {
      _msgs.add(_Msg(2, 'هذه الآية من سورة ${a.surahName}:',
          ayah: a, tafsir: tafsir, related: rel));
      _followUps = ['ما معنى هذه الآية؟', 'آيات مشابهة', 'فضل السورة'];
      _busy = false;
    });
    _scrollDown();
  }

  Ayah? _lastResultAyah() {
    for (var i = _msgs.length - 1; i >= 0; i--) {
      final m = _msgs[i];
      if (m.ayah != null) return m.ayah;
      if (m.results != null && m.results!.isNotEmpty) return m.results!.first;
    }
    return null;
  }

  void _answerVirtue(String q) {
    Surah? hit;
    if (q.trim() == 'فضل السورة' && _contextAyah != null) {
      hit = Repo.i.surah(_contextAyah!.surah);
    } else {
      for (final s in Repo.i.surahs()) {
        if (q.contains(s.nameAr) || q.contains(s.nameShort)) {
          hit = s;
          break;
        }
      }
    }
    if (hit == null) {
      setState(() => _msgs.add(_Msg(3,
          'اكتب اسم السورة مع كلمة «فضل»، مثل: «فضل سورة الكهف».')));
    } else {
      final h = hit;
      final v = surahVirtues[h.id];
      if (v == null) {
        setState(() => _msgs.add(_Msg(3,
            'لا يوجد فضل موثّق لسورة ${h.nameAr} في القائمة المختصرة للتطبيق — '
            'والقائمة تقتصر على ما ثبت في مصادر صحيحة مشهورة، فلا أضيف ما لم يثبت.')));
      } else {
        setState(() => _msgs.add(_Msg(4, v.$1, surahId: h.id)));
      }
    }
    _scrollDown();
  }

  Future<void> _send(String q) async {
    q = q.trim();
    if (q.isEmpty || _busy) return;
    _ctl.clear();
    // مخطط الورد الذكي
    if (q.contains('خطط') && q.contains('ورد')) {
      setState(() {
        _msgs.add(_Msg(0, q));
        _msgs.add(_Msg(5, 'مخطط الورد الذكي:'));
        _followUps = [];
      });
      _scrollDown();
      return;
    }
    // فضل سورة
    if (q.startsWith('فضل')) {
      setState(() => _msgs.add(_Msg(0, q)));
      _answerVirtue(q);
      return;
    }
    // معنى الآية الحالية
    if (q.contains('ما معنى هذه الآية') || q.contains('ما معنى الآية')) {
      if (_contextAyah != null) {
        await _askAboutAyah(_contextAyah!);
      } else {
        setState(() {
          _msgs.add(_Msg(0, q));
          _msgs.add(_Msg(3,
              'افتح أي آية في القارئ واضغط «اسأل عن هذه الآية»، وسأعرض لك تفسيرها من التفاسير المدمجة مع آيات مشابهة.'));
        });
        _scrollDown();
      }
      return;
    }
    // آيات مشابهة لآخر نتيجة
    if (q == 'آيات مشابهة') {
      final target = _lastResultAyah();
      setState(() => _msgs.add(_Msg(0, q)));
      if (target == null) {
        setState(() => _msgs.add(
            _Msg(3, 'اسأل أولاً عن موضوع أو آية، ثم اطلب «آيات مشابهة».')));
      } else {
        final rel = await Repo.i.related(target);
        if (!mounted) return;
        setState(() => _msgs.add(_Msg(1,
            'آيات مشابهة لآية سورة ${target.surahName} (${target.ayah}):',
            results: rel)));
      }
      _scrollDown();
      return;
    }
    // السؤال العام: مرجع مباشر أو موضوع
    setState(() {
      _msgs.add(_Msg(0, q));
      _busy = true;
    });
    await Future.delayed(const Duration(milliseconds: 150));
    final ref = RegExp(r'^(\d{1,3})\s*:\s*(\d{1,3})$').firstMatch(q);
    if (ref != null) {
      final a = Repo.i.ayahByRef(int.parse(ref.group(1)!), int.parse(ref.group(2)!));
      if (a == null) {
        setState(() {
          _msgs.add(_Msg(3, 'لا توجد آية بهذا المرجع — تأكد من رقم السورة والآية.'));
          _busy = false;
        });
      } else {
        _contextAyah = a;
        final rel = await Repo.i.related(a);
        final tafsir = Repo.i.tafsirOf(a.surah, a.ayah);
        if (!mounted) return;
        setState(() {
          _msgs.add(_Msg(2, 'هذه الآية المطلوبة:',
              ayah: a, tafsir: tafsir, related: rel));
          _followUps = ['ما معنى هذه الآية؟', 'آيات مشابهة', 'فضل السورة'];
          _busy = false;
        });
      }
    } else {
      final topics = Repo.topic(q);
      final res = await Repo.i.ask(q);
      if (res.isEmpty) {
        setState(() {
          _msgs.add(_Msg(3,
              'لم أجد آيات عن هذا الموضوع في نص القرآن. جرّب كلمة أخرى — مثل: الصبر، الصلاة، الرحمة، العلم.'));
          _busy = false;
        });
      } else {
        final rel = await Repo.i.related(res.first);
        if (!mounted) return;
        _contextAyah = res.first;
        setState(() {
          _msgs.add(_Msg(
              1,
              topics.isEmpty
                  ? 'وجدت ${res.length} آيات:'
                  : 'وجدت ${res.length} آيات عن «${topics.join('، ')}»:',
              results: res,
              related: rel));
          _followUps = ['آيات مشابهة', 'فضل السورة', 'خطط وردي'];
          _busy = false;
        });
      }
    }
    _scrollDown();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const RobotAvatar(size: 36),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('المساعد الذكي', style: TextStyle(fontSize: 18)),
            Text('يبحث في القرآن وتفاسيره — لا يفتي',
                style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
          ]),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            itemCount: _msgs.length,
            itemBuilder: (c, i) => _bubble(c, _msgs[i]),
          ),
        ),
        if (_followUps.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final s in _followUps)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(label: Text(s), onPressed: () => _send(s)),
                  ),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final s in ['آيات عن الصبر', 'آيات عن الصلاة', 'فضل سورة الكهف', 'خطط وردي'])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(label: Text(s), onPressed: () => _send(s)),
                ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ctl,
                textInputAction: TextInputAction.send,
                onSubmitted: _send,
                decoration: InputDecoration(
                  hintText: 'اسأل عن موضوع في القرآن…',
                  filled: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _busy ? null : () => _send(_ctl.text),
              icon: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _bubble(BuildContext c, _Msg m) {
    if (m.kind == 0) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: sky, borderRadius: BorderRadius.circular(18)),
          child: Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12, right: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const RobotAvatar(size: 32),
          const SizedBox(width: 8),
          Expanded(child: Text(m.text, style: const TextStyle(fontSize: 15, height: 1.8))),
        ]),
        if (m.kind == 2 && m.ayah != null) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => AyahDetailPage(m.ayah!.id))),
            child: Text(m.ayah!.text, style: quranStyle(18, h: 1.9)),
          ),
          const SizedBox(height: 6),
          Text('سورة ${m.ayah!.surahName} • آية ${m.ayah!.ayah}',
              style: const TextStyle(fontSize: 12, color: gold)),
          const SizedBox(height: 10),
          _tafsirExcerpt(c, m.ayah!, m.tafsir ?? {}),
          _relatedSection(c, m.related),
        ],
        if (m.kind == 1 && m.results != null) ...[
          const SizedBox(height: 10),
          for (final a in m.results!)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ayahCard(c, a),
            ),
          const Text('المصدر: نص القرآن الكريم (المصحف العثماني، رواية حفص).',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          _relatedSection(c, m.related),
        ],
        if (m.kind == 4 && m.surahId != null) ...[
          const SizedBox(height: 8),
          Text('المصدر: ${surahVirtues[m.surahId]!.$2}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => SurahReaderPage(m.surahId!))),
            icon: const Icon(Icons.menu_book_rounded),
            label: Text('فتح سورة ${Repo.i.surah(m.surahId!)?.nameAr ?? ''}'),
          ),
        ],
        if (m.kind == 5) ...[
          const SizedBox(height: 8),
          const _WirdPlannerCard(),
        ],
      ]),
    );
  }

  /// مقتطف من تفسير الآية — الميسر أولاً، ثم الجلالين، ثم السعدي.
  Widget _tafsirExcerpt(BuildContext c, Ayah a, Map<String, String> tafsir) {
    const order = ['muyassar', 'jalalayn', 'saadi'];
    const names = {
      'muyassar': 'التفسير الميسر',
      'jalalayn': 'تفسير الجلالين',
      'saadi': 'تفسير السعدي'
    };
    String? text;
    String? name;
    for (final id in order) {
      if (tafsir[id] != null && tafsir[id]!.trim().isNotEmpty) {
        text = tafsir[id]!;
        name = names[id];
        break;
      }
    }
    if (text == null) {
      return const Text(
          'لا يوجد تفسير مدمج لهذه الآية في المكتبة — جرّب التفاسير الكبيرة من صفحة الآية (عند الاتصال).',
          style: TextStyle(fontSize: 14, height: 1.8));
    }
    final short = text.length > 500 ? '${text.substring(0, 500)}…' : text;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(short, style: const TextStyle(fontSize: 14, height: 1.9)),
      const SizedBox(height: 4),
      Text('المصدر: $name', style: const TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: () =>
            Navigator.push(c, MaterialPageRoute(builder: (_) => AyahDetailPage(a.id))),
        icon: const Icon(Icons.auto_stories_rounded, size: 18),
        label: const Text('عرض التفسير كاملًا'),
      ),
    ]);
  }

  Widget _relatedSection(BuildContext c, List<Ayah>? rel) {
    if (rel == null || rel.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      const Divider(),
      const SizedBox(height: 6),
      const Text('آيات مشابهة', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      const Text('تشترك معها في ألفاظها وموضوعها.',
          style: TextStyle(fontSize: 12, color: Colors.grey)),
      const SizedBox(height: 8),
      for (final a in rel)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ayahCard(c, a),
        ),
    ]);
  }
}

/// مخطط الورد الذكي: يقترح وردًا حسب الوقت المتاح ويعرض التقدم.
class _WirdPlannerCard extends StatefulWidget {
  const _WirdPlannerCard();
  @override
  State<_WirdPlannerCard> createState() => _WirdPlannerCardState();
}

class _WirdPlannerCardState extends State<_WirdPlannerCard> {
  int? _minutes;

  @override
  Widget build(BuildContext context) {
    final q = user.khatmahQuarter;
    final progress = ((q - 1).clamp(0, 240)) / 240;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('كم دقيقة لديك اليوم؟', style: TextStyle(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (final m in [5, 10, 15])
          ChoiceChip(
            label: Text('$m دقائق'),
            selected: _minutes == m,
            onSelected: (_) => setState(() => _minutes = m),
          ),
      ]),
      if (_minutes != null) ...[
        const SizedBox(height: 10),
        Builder(builder: (c) {
          final (quarters, label) = wirdPlanFor(_minutes!);
          final end = (q + quarters - 1).clamp(1, 240);
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('خطتك: $label — من الربع $q إلى الربع $end من الختمة.',
                style: const TextStyle(fontSize: 14, height: 1.8)),
            const SizedBox(height: 4),
            Text('تقدمك في الختمة: ${(progress * 100).round()}٪ (الربع $q من 240).',
                style: const TextStyle(fontSize: 13, color: gold)),
            const SizedBox(height: 4),
            const Text('التقديرات تقريبية لقراءة متأنية.',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.tonalIcon(
                onPressed: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => const WirdPage())),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('ابدأ الورد'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () async {
                  await settings.setReminder(true);
                  if (c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(
                        const SnackBar(content: Text('تم تفعيل التذكير اليومي بالورد')));
                  }
                },
                icon: const Icon(Icons.notifications_active_rounded),
                label: const Text('ذكّرني يوميًا'),
              ),
            ]),
          ]);
        }),
      ],
    ]);
  }
}

// ───────── التلاوات: اختيار القارئ ─────────
// تبويبات: الكل / المشايخ / المفضلة.
// الصور الرمزية حروف أولى فقط — لا صور لأشخاص حقيقيين.
class RecitationsPage extends StatefulWidget {
  const RecitationsPage({super.key});
  @override
  State<RecitationsPage> createState() => _RecitationsPageState();
}

class _RecitationsPageState extends State<RecitationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _playSample(Reciter r) async {
    settings.setReciter(r.id);
    await audio.playSurah(1);
    if (mounted && audio.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(audio.error!)));
    }
  }

  Widget _row(Reciter r) {
    final isDefault = settings.reciter == r.id;
    final fav = user.hasReciter(r.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: softCard(context,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            IconButton.filledTonal(
              onPressed: () => _playSample(r),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 12),
            MonogramAvatar(r.nameAr, radius: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(r.nameAr,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  if (isDefault)
                    const Chip(
                        label: Text('القارئ الافتراضي', style: TextStyle(fontSize: 10)),
                        backgroundColor: mintLight),
                ]),
                const SizedBox(height: 2),
                const Text('رواية حفص عن عاصم',
                    style: TextStyle(fontSize: 12, color: gold)),
              ]),
            ),
            IconButton(
              icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded,
                  color: fav ? gold : Colors.grey),
              tooltip: fav ? 'إزالة من المفضلة' : 'إضافة إلى المفضلة',
              onPressed: () => setState(() => user.toggleReciter(r.id)),
            ),
          ])),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([settings, user]),
      builder: (c, _) => Scaffold(
        appBar: AppBar(
          title: const Text('التلاوات'),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'الكل'),
              Tab(text: 'المشايخ'),
              Tab(text: 'المفضلة'),
            ],
          ),
        ),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: softCard(c,
                child: const Row(children: [
                  Icon(Icons.headphones_rounded, color: sky),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        'اضغط زر التشغيل للاستماع إلى سورة الفاتحة بصوت القارئ، '
                        'ويُحفظ اختيارك قارئًا افتراضيًا للتطبيق.',
                        style: TextStyle(fontSize: 13, height: 1.7)),
                  ),
                ])),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _list(reciters),
                _list(reciters,
                    header: 'جميع القرّاء في التطبيق برواية حفص عن عاصم.'),
                _list(reciters.where((r) => user.hasReciter(r.id)).toList(),
                    empty:
                        'لا توجد تلاوات مفضلة بعد.\nاضغط النجمة بجانب أي قارئ لحفظه هنا.'),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _list(List<Reciter> items, {String? header, String? empty}) {
    if (items.isEmpty) {
      return emptyState(Icons.star_border_rounded, empty ?? 'لا توجد عناصر.');
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        if (header != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(header,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ],
        for (final r in items) _row(r),
      ],
    );
  }
}

// ───────── متصفح التفسير ─────────
class TafsirBrowserPage extends StatelessWidget {
  const TafsirBrowserPage({super.key});
  @override
  Widget build(BuildContext context) {
    final all = Repo.i.surahs();
    return Scaffold(
      appBar: AppBar(title: const Text('التفسير')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: all.length,
        itemBuilder: (c, i) {
          final s = all[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: softCard(c,
                onTap: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => TafsirSurahPage(s.id))),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  CircleAvatar(
                      radius: 22,
                      backgroundColor: goldLight,
                      child: Text('${s.id}',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800, color: gold))),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(s.nameAr,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  Text('${s.ayahCount} آية', style: const TextStyle(fontSize: 12)),
                  const Icon(Icons.chevron_left, color: Colors.grey),
                ])),
          );
        },
      ),
    );
  }
}

class TafsirSurahPage extends StatefulWidget {
  final int surahId;
  const TafsirSurahPage(this.surahId, {super.key});
  @override
  State<TafsirSurahPage> createState() => _TafsirSurahPageState();
}

class _TafsirSurahPageState extends State<TafsirSurahPage> {
  int _sourceIdx = 0;

  @override
  Widget build(BuildContext context) {
    final surah = Repo.i.surah(widget.surahId)!;
    final ayahs = Repo.i.ayahsOf(widget.surahId);
    final (sid, sname) = offlineTafsirs[_sourceIdx];
    return Scaffold(
      appBar: AppBar(title: Text('تفسير سورة ${surah.nameAr}')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < offlineTafsirs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(offlineTafsirs[i].$2),
                    selected: i == _sourceIdx,
                    onSelected: (_) => setState(() => _sourceIdx = i),
                  ),
                ),
            ]),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            itemCount: ayahs.length,
            itemBuilder: (c, i) {
              final a = ayahs[i];
              final tafsir = Repo.i.tafsirOf(a.surah, a.ayah);
              final text = tafsir[sid];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: softCard(c,
                    onTap: () => Navigator.push(
                        c, MaterialPageRoute(builder: (_) => AyahDetailPage(a.id))),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.text, style: quranStyle(17, h: 1.9)),
                      const SizedBox(height: 4),
                      Text('آية ${a.ayah}',
                          style: const TextStyle(fontSize: 12, color: gold)),
                      const Divider(),
                      Text(
                          text ?? 'لا يوجد تفسير من هذا المصدر لهذه الآية في المكتبة.',
                          style: const TextStyle(fontSize: 14, height: 1.9)),
                      const SizedBox(height: 4),
                      Text('المصدر: $sname',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ])),
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ───────── الإعجاز القرآني ─────────
class IjazPage extends StatelessWidget {
  const IjazPage({super.key});
  @override
  Widget build(BuildContext context) {
    final items = Repo.i.ijazList();
    return Scaffold(
      appBar: AppBar(title: const Text('الإعجاز القرآني')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: items.length,
        itemBuilder: (c, i) {
          final e = items[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: softCard(c,
                onTap: () => Navigator.push(
                    c, MaterialPageRoute(builder: (_) => IjazDetailPage(e.id))),
                child: Row(children: [
                  const CircleAvatar(
                      backgroundColor: Color(0xFFFFF3CD),
                      child: Icon(Icons.lightbulb_rounded, color: gold)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(e.ayahRef, style: const TextStyle(fontSize: 13, color: gold)),
                    ]),
                  ),
                  const Icon(Icons.chevron_left),
                ])),
          );
        },
      ),
    );
  }
}

class IjazDetailPage extends StatelessWidget {
  final int id;
  const IjazDetailPage(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final e = Repo.i.ijazById(id)!;
    final ayah = Repo.i.ayahByRef(e.surah, e.ayah);
    return Scaffold(
      appBar: AppBar(title: Text(e.title)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        softCard(context,
            onTap: ayah == null
                ? null
                : () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => AyahDetailPage(ayah.id))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (ayah != null) Text(ayah.text, style: quranStyle(19, h: 1.9)),
              const SizedBox(height: 8),
              Text(e.ayahRef, style: const TextStyle(fontSize: 13, color: gold)),
            ])),
        const SizedBox(height: 14),
        softCard(context, child: Text(e.text, style: const TextStyle(fontSize: 15, height: 2.0))),
        const SizedBox(height: 14),
        Text('المصدر: ${e.source}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        const Text(
            'هذه المقالات مختصرة من مصادر معروفة في الإعجاز العلمي، وتعرض الآية كما هي دون زيادة. '
            'ليست فتوى ولا تفسيرًا ملزمًا.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.8)),
      ]),
    );
  }
}

// ───────── القراءات (حفص / ورش) ─────────
class QiraatPage extends StatefulWidget {
  const QiraatPage({super.key});
  @override
  State<QiraatPage> createState() => _QiraatPageState();
}

class _QiraatPageState extends State<QiraatPage> {
  bool _downloading = false;
  double _progress = 0;
  bool _downloaded = false;

  @override
  void initState() {
    super.initState();
    WarshService.isDownloaded().then((v) {
      if (mounted) setState(() => _downloaded = v);
    });
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      await WarshService.download((p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تنزيل نص رواية ورش — يمكنك الآن فتح القارئ')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('القراءات')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        softCard(context,
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SurahsPage())),
            child: const Row(children: [
              CircleAvatar(backgroundColor: tealLight, child: Icon(Icons.menu_book_rounded, color: teal)),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('حفص عن عاصم', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text('الرواية الافتراضية في التطبيق — المصحف العثماني كاملاً مع التفاسير والتلاوة.',
                      style: TextStyle(fontSize: 13, height: 1.7)),
                ]),
              ),
              Icon(Icons.chevron_left),
            ])),
        const SizedBox(height: 12),
        softCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const CircleAvatar(backgroundColor: Color(0xFFFFF3CD), child: Icon(Icons.auto_stories_rounded, color: gold)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('ورش عن نافع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            Chip(label: Text(_downloaded ? 'مثبتة' : 'حزمة اختيارية')),
          ]),
          const SizedBox(height: 10),
          const Text('نص رواية ورش كاملاً (6,214 آية) مع عرض رقم كل آية في حفص بجانبها. '
              'يُنزَّل مرة واحدة ويبقى دون إنترنت.',
              style: TextStyle(fontSize: 13, height: 1.8)),
          const SizedBox(height: 6),
          const Text(WarshService.attribution, style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
          const SizedBox(height: 12),
          if (_downloading)
            Column(children: [
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('جارٍ تنزيل حزمة ورش… ${(_progress * 100).round()}٪'),
            ])
          else if (_downloaded)
            Row(children: [
              FilledButton.tonalIcon(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const WarshReaderPage())),
                icon: const Icon(Icons.menu_book_rounded),
                label: const Text('فتح قارئ ورش'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () async {
                  final f = await WarshService._file();
                  if (await f.exists()) await f.delete();
                  user.setWarshReady(false);
                  setState(() => _downloaded = false);
                },
                icon: const Icon(Icons.delete_rounded),
                label: const Text('حذف الحزمة'),
              ),
            ])
          else
            FilledButton.icon(
              onPressed: _download,
              icon: const Icon(Icons.download_rounded),
              label: const Text('تنزيل نص ورش (~1.6 MB)'),
            ),
        ])),
        const SizedBox(height: 12),
        const Text(
            'ملاحظة: ترقيم آيات ورش يختلف عن ترقيم حفص في بعض السور (مثلاً: الفاتحة 7 آيات في حفص و6 في ورش، '
            'لأن البسملة لا تُعدّ آية عند ورش). يُعرض مقابل كل آية ورش رقمها في حفص.',
            style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.8)),
      ]),
    );
  }
}

// ───────── قارئ ورش ─────────
class WarshReaderPage extends StatelessWidget {
  const WarshReaderPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('قارئ ورش عن نافع')),
      body: FutureBuilder<List<WarshSurah>>(
        future: WarshService.load(),
        builder: (c, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData) {
            return emptyState(Icons.error_outline_rounded, 'تعذّر فتح حزمة ورش — أعد تنزيلها من صفحة القراءات.');
          }
          final data = snap.data!;
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: data.length,
            itemBuilder: (c, i) {
              final w = data[i];
              final s = Repo.i.surah(w.id);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: softCard(c,
                    onTap: () => Navigator.push(c,
                        MaterialPageRoute(builder: (_) => WarshSurahPage(w))),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      CircleAvatar(
                          radius: 22,
                          backgroundColor: tealLight,
                          child: Text('${w.id}',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: teal))),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(s?.nameAr ?? 'سورة ${w.id}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      ),
                      Text('${w.verses.length} آية', style: const TextStyle(fontSize: 12)),
                      const Icon(Icons.chevron_left, color: Colors.grey),
                    ])),
              );
            },
          );
        },
      ),
    );
  }
}

class WarshSurahPage extends StatelessWidget {
  final WarshSurah surah;
  const WarshSurahPage(this.surah, {super.key});
  @override
  Widget build(BuildContext context) {
    final s = Repo.i.surah(surah.id);
    return Scaffold(
      appBar: AppBar(title: Text('سورة ${s?.nameAr ?? surah.id} — ورش')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: surah.verses.length,
        itemBuilder: (c, i) {
          final v = surah.verses[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: tealLight,
                child: Text('${v.id}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: teal)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(v.text, style: quranStyle(settings.fontSize, h: 2.0)),
                  Text('في حفص: آية ${v.hafs.join('، ')}',
                      style: const TextStyle(fontSize: 11, color: gold)),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

// ───────── الورد والختمة ─────────
class WirdPage extends StatelessWidget {
  const WirdPage({super.key});

  String get _wirdLabel => settings.wirdQuarters == 1
      ? 'ربع حزب'
      : settings.wirdQuarters == 4
          ? 'حزب كامل'
          : 'جزء كامل';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('وردي وختمتي')),
      body: AnimatedBuilder(
        animation: user,
        builder: (c, _) {
          final q = user.khatmahQuarter;
          final done = q > 240;
          final progress = ((q - 1).clamp(0, 240)) / 240;
          final end = (q + settings.wirdQuarters - 1).clamp(1, 240);
          final ayahs = <Ayah>[];
          if (!done) {
            for (var i = q; i <= end; i++) {
              ayahs.addAll(Repo.i.ayahsInQuarter(i));
            }
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            softCard(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.track_changes_rounded, color: teal),
                const SizedBox(width: 8),
                const Text('تقدم الختمة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(done ? 'مكتملة' : '${((progress) * 100).round()}٪',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: gold)),
              ]),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                    value: progress, minHeight: 8, backgroundColor: tealLight, color: teal),
              ),
              const SizedBox(height: 8),
              Text(done
                  ? 'أتممت ختمة كاملة — تقبّل الله منك.'
                  : 'وصلت إلى الربع $q من 240 ربعًا (الحزب ${(q - 1) ~/ 4 + 1}، الجزء ${(q - 1) ~/ 8 + 1}).',
                  style: const TextStyle(fontSize: 13, height: 1.7)),
            ])),
            const SizedBox(height: 14),
            if (done)
              FilledButton.icon(
                onPressed: () {
                  user.resetKhatmah();
                  ScaffoldMessenger.of(c).showSnackBar(
                      const SnackBar(content: Text('بدأت ختمة جديدة — بالتوفيق')));
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('بدء ختمة جديدة'),
              )
            else ...[
              Row(children: [
                const Text('ورد اليوم', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Chip(label: Text(_wirdLabel)),
                const Spacer(),
                Text('${ayahs.length} آية', style: const TextStyle(fontSize: 12, color: gold)),
              ]),
              const SizedBox(height: 6),
              Text('من الربع $q إلى الربع $end — اضغط أي آية لقراءتها، وعند الانتهاء اضغط «أتممت الورد».',
                  style: const TextStyle(fontSize: 13, height: 1.7)),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  await user.completeWird();
                  if (c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(
                        const SnackBar(content: Text('تقبّل الله — تم تسجيل ورد اليوم')));
                  }
                },
                icon: const Icon(Icons.check_circle_rounded),
                label: const Text('أتممت الورد'),
              ),
              const SizedBox(height: 14),
              for (final a in ayahs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ayahCard(c, a),
                ),
            ],
          ]);
        },
      ),
    );
  }
}

// ───────── المكتبة ─────────
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _check;

  Future<void> _runCheck() async {
    setState(() => _check = 'جارٍ الفحص…');
    try {
      final ok = await Repo.i.quickCheck();
      final hashOk = await Repo.i.verifyHash();
      if (!mounted) return;
      setState(() => _check = ok == 'ok' && hashOk
          ? 'سلامة المكتبة: سليمة ✓ (quick_check: ok، وبصمة SHA-256 مطابقة)'
          : 'تنبيه: فحص السلامة أظهر مشكلة (quick_check: $ok، SHA-256: ${hashOk ? 'مطابق' : 'غير مطابق'}) — أعد تثبيت التطبيق.');
    } catch (e) {
      if (mounted) setState(() => _check = 'تعذّر الفحص: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = Repo.i.meta();
    final tafsirCounts = {
      for (final r in Repo.i.db.select('SELECT source, COUNT(*) AS c FROM tafsir GROUP BY source'))
        r['source'] as String: r['c'] as int
    };
    return Scaffold(
      appBar: AppBar(title: const Text('المكتبة والمصادر')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        softCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('محتوى المكتبة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _row('السور', '114 سورة'),
          _row('الآيات', '6,236 آية'),
          _row('التفسير الميسر', '${tafsirCounts['muyassar'] ?? 0} آية'),
          _row('تفسير الجلالين', '${tafsirCounts['jalalayn'] ?? 0} آية (226 آية بلا نص في المصدر)'),
          _row('تفسير السعدي', '${tafsirCounts['saadi'] ?? 0} آية'),
          _row('مقالات الإعجاز', '10 مقالات'),
          _row('حجم قاعدة البيانات', '${(meta['size_bytes'] ?? '?')} بايت'),
          _row('تاريخ البناء', meta['built'] ?? '?'),
        ])),
        const SizedBox(height: 12),
        softCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('المصادر والتراخيص', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          _row('نص المصحف العثماني', 'tanzil.net — المصحف العثماني (Uthmani text v1.1)'),
          _row('التفاسير', 'HuggingFace quranlab/quran-tafsir — الميسر، الجلالين، السعدي (أعمال كلاسيكية في الملك العام)'),
          _row('التفاسير الكبيرة (عند الاتصال)', 'Quran.com API v4 — ابن كثير، الطبري، القرطبي'),
          _row('التلاوة الصوتية', 'EveryAyah.com — تسجيلات مجانية؛ احتياطي: cdn.islamic.network'),
          _row('بيانات التجويد (غير مضمّنة بعد)',
              'cpfair/quran-tajweed — CC BY 4.0 — التلوين متوقف حتى اكتمال التحقق من المحاذاة'),
          _row('نص ورش (اختياري)', 'Qur\'anpedia.net عبر quran-json.risanb.com'),
        ])),
        const SizedBox(height: 12),
        softCard(context, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('سلامة المكتبة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _runCheck,
            icon: const Icon(Icons.verified_rounded),
            label: const Text('فحص السلامة (quick_check + SHA-256)'),
          ),
          if (_check != null) ...[
            const SizedBox(height: 10),
            Text(_check!, style: const TextStyle(fontSize: 13, height: 1.7)),
          ],
        ])),
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13, height: 1.6))),
        ]),
      );
}

// ───────── الإعدادات ─────────
class SettingsPage extends StatefulWidget {
  final bool showBack;
  const SettingsPage({this.showBack = true, super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _dataBusy = false;
  String? _dataMsg;

  /// تصدير بيانات المستخدم إلى ملف JSON ومشاركته (للحفظ/الإرسال).
  /// الكتابة ذرية مع تحقق من البصمة قبل الحفظ (UserExportService).
  Future<void> _exportData() async {
    if (_dataBusy) return;
    setState(() {
      _dataBusy = true;
      _dataMsg = null;
    });
    try {
      final svc = await UserExportService.create();
      final file = await svc.exportToFile(appVersion: '1.1.0+1');
      await Share.shareXFiles([XFile(file.path)],
          subject: 'نسخة بيانات تلاوة برو');
      if (!mounted) return;
      setState(() => _dataMsg =
          'تم التصدير: ${file.path.split('/').last} — شاركه أو احفظه في مكان آمن.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _dataMsg = 'فشل التصدير: $e');
    } finally {
      if (mounted) setState(() => _dataBusy = false);
    }
  }

  /// استيراد بيانات من ملف تصدير JSON: تحقق مسبق (dry-run) ثم حوار
  /// يعرض الأعداد ويطلب اختيار الدمج (آمن، لا يحذف شيئاً) أو الاستبدال
  /// (يتطلب تأكيداً ثانياً، وتُكتب نسخة احتياطية تلقائية أولاً).
  /// ملاحظة: خطط الحفظ (hifz_*) ليست ضمن التصدير بعد — تُصدَّر لاحقاً.
  Future<void> _importData() async {
    if (_dataBusy) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null || picked.files.single.path == null) return;
    final file = File(picked.files.single.path!);
    setState(() {
      _dataBusy = true;
      _dataMsg = null;
    });
    try {
      final svc = await UserExportService.create();
      final preview = await svc.previewImport(file);
      if (!mounted) return;
      if (!preview.isValid || preview.data == null) {
        setState(() {
          _dataMsg =
              'رُفض الملف: ${preview.rejectionReason ?? 'غير صالح'} — لم يُكتب شيء.';
          _dataBusy = false;
        });
        return;
      }
      final counts = preview.counts;
      final mode = await showDialog<ImportMode>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('استيراد بيانات'),
          content: Text(
              'الملف صالح ويحوي: ${counts['favorites'] ?? 0} مفضلة، '
              '${counts['history'] ?? 0} في السجل، '
              '${counts['tags'] ?? 0} وسوم، '
              '${counts['notes'] ?? 0} ملاحظات، '
              '${counts['fav_reciters'] ?? 0} قرّاء مفضلين.'
              '${preview.quarantined.isNotEmpty ? '\nسيُعزل ${preview.quarantined.length} سجلاً فاسداً دون استيراده.' : ''}'
              '${preview.warnings.isNotEmpty ? '\nتحذير: ${preview.warnings.join(' ')}' : ''}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ImportMode.merge),
                child: const Text('دمج (آمن)')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ImportMode.replace),
                child: const Text('استبدال الكل')),
          ],
        ),
      );
      if (mode == null) {
        if (mounted) setState(() => _dataBusy = false);
        return;
      }
      if (!mounted) return;
      var confirmReplace = false;
      if (mode == ImportMode.replace) {
        confirmReplace = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('استبدال كل بياناتك؟'),
                content: const Text(
                    'سيُحذف كل ما لديك الآن (مفضلة، سجل، وسوم، ملاحظات، ختمة) '
                    'ويُستبدل بمحتوى الملف. تُكتب نسخة احتياطية تلقائية من حالتك '
                    'الحالية أولاً.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('نعم، استبدل')),
                ],
              ),
            ) ??
            false;
        if (!confirmReplace) {
          if (mounted) setState(() => _dataBusy = false);
          return;
        }
      }
      final report = await svc.importFile(file,
          mode: mode, confirmReplace: confirmReplace);
      await user.load();
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        _dataMsg = 'تم الاستيراد (${mode == ImportMode.merge ? 'دمج' : 'استبدال'}): '
            '${report.imported.favorites.length} مفضلة، '
            '${report.imported.history.length} في السجل، '
            '${report.imported.tags.length} وسوم، '
            '${report.imported.notes.length} ملاحظات.'
            '${report.quarantined.isNotEmpty ? ' عُزل ${report.quarantined.length} سجلاً فاسداً.' : ''}'
            '${report.backupPath != null ? ' النسخة الاحتياطية: ${report.backupPath!.split('/').last}.' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dataMsg = 'فشل الاستيراد: $e';
        _dataBusy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: AnimatedBuilder(
        animation: settings,
        builder: (c, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          const Text('المظهر', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, child: Column(children: [
            SwitchListTile(
              title: const Text('الوضع الليلي'),
              subtitle: const Text('مظهر داكن مريح للعين ليلاً'),
              secondary: const Icon(Icons.dark_mode_rounded, color: skyDeep),
              value: settings.mode == ThemeMode.dark,
              onChanged: (v) =>
                  settings.setMode(v ? ThemeMode.dark : ThemeMode.light),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              title: const Text('اتباع النظام'),
              subtitle: const Text('يتغير المظهر مع إعدادات جهازك'),
              trailing: settings.mode == ThemeMode.system
                  ? const Icon(Icons.check_rounded, color: teal)
                  : null,
              contentPadding: EdgeInsets.zero,
              onTap: () => settings.setMode(ThemeMode.system),
            ),
          ])),
          const SizedBox(height: 18),
          const Text('القراءة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('حجم خط المصحف'),
              const Spacer(),
              IconButton(
                icon: const Text('A−',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                tooltip: 'تصغير الخط',
                onPressed: () =>
                    settings.setFont((settings.fontSize - 2).clamp(18, 36).toDouble()),
              ),
              Text('${settings.fontSize.round()}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              IconButton(
                icon: const Text('A+',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                tooltip: 'تكبير الخط',
                onPressed: () =>
                    settings.setFont((settings.fontSize + 2).clamp(18, 36).toDouble()),
              ),
            ]),
            Slider(
              value: settings.fontSize,
              min: 18,
              max: 36,
              divisions: 18,
              label: '${settings.fontSize.round()}',
              onChanged: settings.setFont,
            ),
            Text('بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ',
                style: quranStyle(settings.fontSize, h: 1.9)),
            SwitchListTile(
              title: const Text('خط أميري (للمصحف العثماني)'),
              value: settings.amiri,
              onChanged: settings.setAmiri,
              contentPadding: EdgeInsets.zero,
            ),
          ])),
          const SizedBox(height: 18),
          const Text('التلاوة الصوتية', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, child: ListTile(
            leading: const CircleAvatar(
                backgroundColor: skyLight,
                child: Icon(Icons.headphones_rounded, color: sky)),
            title: const Text('القارئ الافتراضي'),
            subtitle: Text(settings.reciterObj.nameAr),
            trailing: const Icon(Icons.chevron_left),
            contentPadding: EdgeInsets.zero,
            onTap: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => const RecitationsPage())),
          )),
          const SizedBox(height: 18),
          const Text('اللغة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, child: const ListTile(
            leading: CircleAvatar(
                backgroundColor: skyLight, child: Icon(Icons.language_rounded, color: sky)),
            title: Text('لغة التطبيق'),
            subtitle: Text('العربية — التطبيق بالعربية حاليًا'),
            contentPadding: EdgeInsets.zero,
          )),
          const SizedBox(height: 18),
          const Text('تذكير الورد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              title: const Text('تذكير يومي بالورد'),
              subtitle: const Text('إشعار محلي على الجهاز — يعمل دون إنترنت'),
              value: settings.reminderOn,
              onChanged: (v) => settings.setReminder(v),
              contentPadding: EdgeInsets.zero,
            ),
            if (settings.reminderOn) ...[
              ListTile(
                title: const Text('وقت التذكير'),
                trailing: Text(
                    '${settings.reminderHour.toString().padLeft(2, '0')}:${settings.reminderMinute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                contentPadding: EdgeInsets.zero,
                onTap: () async {
                  final t = await showTimePicker(
                    context: c,
                    initialTime: TimeOfDay(hour: settings.reminderHour, minute: settings.reminderMinute),
                  );
                  if (t != null) settings.setReminder(true, hour: t.hour, minute: t.minute);
                },
              ),
              const Text('حجم الورد اليومي', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final (n, label) in [(1, 'ربع حزب'), (4, 'حزب كامل'), (8, 'جزء كامل')])
                  ChoiceChip(
                    label: Text(label),
                    selected: settings.wirdQuarters == n,
                    onSelected: (_) => settings.setWirdQuarters(n),
                  ),
              ]),
              const SizedBox(height: 8),
              const Text('عند الضغط على الإشعار يفتح التطبيق على أول آية في وردك مع زر استماع.',
                  style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.7)),
            ],
          ])),
          const SizedBox(height: 18),
          const Text('المكتبة والقراءات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), child: Column(children: [
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('التحميلات والبيانات'),
              subtitle: const Text('حزمة ورش، وتنزيل السور من القارئ'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const QiraatPage())),
            ),
            ListTile(
              leading: const Icon(Icons.library_books_rounded),
              title: const Text('القراءات (حفص / ورش)'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const QiraatPage())),
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('الحزم والتنزيلات'),
              subtitle: const Text('حزم اختيارية تُنزَّل عند الطلب مع إظهار الحجم'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const PackagesPage())),
            ),
            ListTile(
              leading: const Icon(Icons.library_add_check_rounded),
              title: const Text('المكتبة والمصادر'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const LibraryPage())),
            ),
            ListTile(
              leading: const Icon(Icons.lightbulb_rounded),
              title: const Text('الإعجاز القرآني'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const IjazPage())),
            ),
          ])),
          const SizedBox(height: 18),
          const Text('بياناتك', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          softCard(c, padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), child: Column(children: [
            ListTile(
              leading: const Icon(Icons.upload_rounded),
              title: const Text('تصدير بياناتي'),
              subtitle: const Text('مفضلة وسجل ووسوم وملاحظات وختمة — ملف JSON تشاركه أو تحفظه'),
              trailing: _dataBusy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_left),
              onTap: _dataBusy ? null : _exportData,
            ),
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('استيراد بيانات'),
              subtitle: const Text('من ملف تصدير JSON — دمج آمن أو استبدال مع نسخة احتياطية'),
              trailing: const Icon(Icons.chevron_left),
              onTap: _dataBusy ? null : _importData,
            ),
            ListTile(
              leading: const Icon(Icons.backup_rounded),
              title: const Text('نسخ احتياطي واستعادة'),
              subtitle: const Text('صفحة كاملة: ملفات محفوظة وآخر نسخة احتياطية'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () async {
                final page = await ExportPage.create(appVersion: '1.1.0+1');
                if (!c.mounted) return;
                await Navigator.push(c, MaterialPageRoute(builder: (_) => page));
                await user.load(); // تحديث بيانات الذاكرة بعد أي استيراد من الصفحة
              },
            ),
            if (_dataMsg != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Text(_dataMsg!, style: const TextStyle(fontSize: 12, height: 1.8)),
              ),
          ])),
          const SizedBox(height: 18),
          Stack(children: [
            softCard(c, child: const Row(children: [
              LogoMark(64),
              SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('تلاوة برو — الإصدار 1.1.0',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  SizedBox(height: 4),
                  Text('رفيقك في رحلتك مع القرآن',
                      style: TextStyle(fontSize: 13, height: 1.7)),
                  SizedBox(height: 4),
                  Text(
                      'المصحف العثماني كاملاً دون إنترنت، ثلاثة تفاسير، تلاوة صوتية، '
                      'تذكير بالورد، ومساعد بحث استرجاعي لا يفتي ولا يولّد نصوصًا.\n'
                      'التفاسير الكبيرة (ابن كثير، الطبري، القرطبي) تُجلب عند الاتصال فقط.\n'
                      'الصوت يحتاج إنترنت ما لم تُنزَّل السورة مسبقًا.',
                      style: TextStyle(fontSize: 12, height: 1.8)),
                ]),
              ),
            ])),
            const Positioned(top: 0, left: 0, child: FloralCorner(size: 56)),
          ]),
          // Pro: إسناد البحث المعجمي — يظهر فقط إن كانت جداول المعجم
          // مثبتة فعلاً في المكتبة (وهي كذلك في هذا الإصدار).
          if (Repo.i.lexiconMeta().isNotEmpty) ...[
            const SizedBox(height: 18),
            softCard(
                c,
                child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('المصادر والنِّسَب',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      SizedBox(height: 8),
                      Text(
                          'البحث المعجمي مبني على تحليلات صرفية من Quranic Arabic Corpus v0.4 '
                          '(corpus.quran.com) — برخصة GPL. التأكيد القانوني لشحن الجداول المشتقة ما زال معلّقاً.',
                          style: TextStyle(fontSize: 12, height: 1.8)),
                    ])),
          ],
        ]),
      ),
    );
  }
}
