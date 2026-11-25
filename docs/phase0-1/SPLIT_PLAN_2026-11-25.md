# خطة تقسيم `lib/main.dart` — Tilawa — Phase 0، المهمة ج

- **التاريخ:** 2026-11-25
- **المستودع:** https://github.com/ezzaldeenmansour123/Tilawa — التزام `07204f14` (v1.0.0+1)
- **نسخة العمل:** `~/workspace/tilawa/` (استنساخ محلي، لم يُدفَع منه شيء)
- **المرجع:** `AUDIT_2026-11-25.md` §7.1 و `PLAN_2026-11-25.md` §3.1
- **الحالة:** **خطة فقط — لم يُنفَّذ أي تقسيم كود في هذه الجولة** (السبب في §5).

> قاعدة القياس: كل أرقام الأسطر أدناه مقيسة فعلياً من الملفات بـ `grep` ومطابقة أقواس (brace-matching)، لا تقديرات من الذاكرة. نطاقات الأصناف هي امتداد الصنف نفسه فقط (بدون الكود العام الذي يليه).

---

## 1. ما فُحص فعلياً

| الملف | الأسطر | المحتوى المقيس |
|---|---|---|
| `lib/main.dart` | **3959 سطراً / 163 KB** | **57 إعلان `class`** (31 صنف Widget + 16 صنف State + 10 أصناف خدمات/نماذج/مساعِدة)، + كود عام (ثوابت، دوال مساعِدة، `main()`) |
| `lib/db.dart` | **549 سطراً / 20 KB** | 4 نماذج + 3 ثوابت قوائم + دوال بحث FTS + صنف `Repo` (singleton) |
| `test/` | غير موجود | لا يوجد مجلد اختبارات إطلاقاً؛ والـ CI يحذفه بـ `rm -rf test` |

### 1.1 جرد `main.dart` — الأصناف بامتدادها الدقيق (سطر البداية–النهاية)

**الخدمات والحالة (38–499):**

| الأسطر | الصنف | الأسطر | الدور |
|---|---|---|---|
| 38–108 | `AppSettings` | 71 | إعدادات + `ChangeNotifier`؛ يقرأ `reciters` من `db.dart` |
| 110–203 | `UserData` | 94 | مفضلة/وسوم/ملاحظات/سجل/ختمة + `ChangeNotifier` |
| 209–275 | `NotificationService` | 67 | تذكير الورد اليومي (static) |
| 278–434 | `AudioService` | 157 | مشغل `just_audio` + تنزيل سورة |
| 439–444 | `WarshVerse` | 6 | نموذج آية ورش |
| 446–450 | `WarshSurah` | 5 | نموذج سورة ورش |
| 452–499 | `WarshService` | 48 | تنزيل/تحقق/تحميل حزمة ورش (static) |

**الكود العام بين الأصناف:**

| الأسطر | البند |
|---|---|
| 20–33 | 14 ثابت لون باستيل (`teal…ink`) |
| 35 | `final navKey = GlobalKey<NavigatorState>()` |
| 205–206 | `final settings = AppSettings(); final user = UserData();` |
| 436 | `final audio = AudioService();` |
| 501–507 | `main()` — تهيئة + `runApp` |
| 509–543 | `buildTheme(bool dark)` |
| 544–548 | `fmtDur(Duration)` |
| 571–596 | `softCard(...)` |
| 596–598 | `quranStyle(double size, …)` — **يقرأ `settings.amiri`** |
| 599–623 | `askText(...)` — حوار إدخال نص |
| 624–633 | `ayahCard(...)` — **يتنقل إلى `AyahDetailPage`** |
| 634–648 | `emptyState(...)` |
| 849–862 | `const surahVirtues` (10 سور فقط، موثقة المصدر) |
| 864–883 | `tadabburQuestions` + `tadabburQuestion(DateTime)` + `wirdPlanFor(int)` |

**الواجهات (550–3959):**

| الأسطر | الصنف | الأسطر | ملاحظة |
|---|---|---|---|
| 550–568 | `TilawaApp` | 19 | `AnimatedBuilder` على `settings` + `Directionality` RTL |
| 649–655 | `LogoMark` | 7 | |
| 657–705 | `_LogoPainter` | 49 | رسم مخصص |
| 708–754 | `_FloralPainter` | 47 | رسم مخصص |
| 757–766 | `FloralCorner` | 10 | |
| 769–806 | `OrnateFrame` | 38 | |
| 809–824 | `MonogramAvatar` | 16 | |
| 827–843 | `RobotAvatar` | 17 | نقي (أيقونة روبوت بتدرج) |
| 885–889 / 891–1014 | `BootPage` / `_BootPageState` | 5 / 124 | تجهيز المكتبة + تنقّل بديل |
| 1017–1021 / 1023–1046 | `Shell` / `_ShellState` | 5 / 24 | 3 تبويبات + `IndexedStack` |
| 1049–1127 | `MorePage` | 79 | مركز الأقسام |
| 1130–1230 | `OurWorksPage` | 101 | **الاستخدام المباشر الوحيد لـ `url_launcher`** (سطر 1139) |
| 1233–1238 / 1240–1513 | `HomePage` / `_HomePageState` | 6 / 274 | الصفحة الرئيسية |
| 1516–1520 / 1522–1599 | `SurahsPage` / `_SurahsPageState` | 5 / 78 | فهرس السور |
| 1602–1607 / 1609–1835 | `SurahReaderPage` / `_SurahReaderPageState` | 6 / 227 | قارئ السورة |
| 1838–1843 / 1845–2097 | `AyahDetailPage` / `_AyahDetailPageState` | 6 / 253 | تفاصيل الآية؛ **الاستخدام المباشر الوحيد لـ `share_plus`** (سطر 1936) |
| 2102–2106 / 2108–2282 | `SearchPage` / `_SearchPageState` | 5 / 175 | بحث FTS + تبويبات |
| 2285–2289 / 2291–2367 | `_SurahSearchTab` / `_SurahSearchTabState` | 5 / 77 | تبويب بحث السور |
| 2370–2375 / 2377–2500 | `FavsPage` / `_FavsPageState` | 6 / 124 | المفضلة |
| 2503–2537 | `HistoryPage` | 35 | السجل |
| 2543–2553 | `_Msg` | 11 | نموذج رسالة مساعد |
| 2555–2560 / 2562–2966 | `AssistantPage` / `_AssistantPageState` | 6 / **405** | **أكبر كتلة منفردة — تتجاوز سقف 400 سطر وحدها** |
| 2969–2973 / 2975–3033 | `_WirdPlannerCard` / `_WirdPlannerCardState` | 5 / 59 | مخطط الورد الذكي |
| 3038–3042 / 3044–3177 | `RecitationsPage` / `_RecitationsPageState` | 5 / 134 | التلاوات |
| 3180–3218 | `TafsirBrowserPage` | 39 | متصفح التفسير |
| 3220–3225 / 3227–3288 | `TafsirSurahPage` / `_TafsirSurahPageState` | 6 / 62 | تفسير السورة |
| 3291–3327 | `IjazPage` | 37 | مقالات الإعجاز |
| 3329–3361 | `IjazDetailPage` | 33 | تفاصيل مقال |
| 3364–3368 / 3370–3485 | `QiraatPage` / `_QiraatPageState` | 5 / 116 | القراءات (ورش) |
| 3488–3537 | `WarshReaderPage` | 50 | قارئ ورش |
| 3539–3575 | `WarshSurahPage` | 37 | سورة ورش |
| 3578–3672 | `WirdPage` | 95 | الورد والختمة |
| 3675–3679 / 3681–3755 | `LibraryPage` / `_LibraryPageState` | 5 / 75 | المكتبة + فحص السلامة |
| 3758–3763 / 3765–3959 | `SettingsPage` / `_SettingsPageState` | 6 / 195 | الإعدادات |

### 1.2 جرد `db.dart` (549 سطراً)

| الأسطر | المحتوى |
|---|---|
| 19–45 | `normalizeAr` + `_searchExpr` (تطبيع عربي + بناء استعلام FTS) |
| 46–120 | النماذج: `Surah` (46–52)، `Ayah` (53–60)، `Ijaz` (61–70)، `Reciter` (71–76) + الثوابت: `reciters` (7 قرّاء، 77–85)، `offlineTafsirs` (3، 88–92)، `onlineTafsirs` (14/15/90، 96–100) |
| 121–315 | دوال بحث عامة (top-level): `_searchSync`، `_askSync`، `_relatedSync`، `_searchTafsirSync`، `_topicWords`، `_stripHtml`، `_sha`، `_quick` — **تعمل داخل `Isolate.run`، فيجب أن تبقى top-level/static** |
| 316–549 | `class Repo` (singleton `Repo.i`) — تثبيت DB ذري + SHA + `open/surahs/ayahsOf/ayahsInQuarter/tafsirOf/onlineTafsir/ijazList/search/ask/related/topic` |

---

## 2. خريطة الاعتماديات

### 2.1 الواردات الحالية

**`main.dart` يستورد:** `dart:async, convert, io, math` + `material_ui` + `flutter/services` + `flutter_local_notifications` + `flutter_timezone` + `http` + `just_audio` + `path_provider` + `share_plus` + `shared_preferences` + `url_launcher` + `timezone` + `db.dart`.

**`db.dart` يستورد:** `dart:convert, io, isolate, math` + `crypto` + `flutter/services` (لـ `rootBundle`) + `http` + `path_provider` + `shared_preferences` (لمفتاح `lib_sha` فقط) + `sqlite3`.

**نقطة حرجة موثقة:** `main.dart` يستورد `package:material_ui/material_ui.dart` ولا يستورد `package:flutter/material.dart` مباشرة إطلاقاً. كل رموز واجهة Flutter (`Color`، `Colors`، `ThemeData`، `ChangeNotifier`، `Widget`…) تصل عبر ما يُصدّره `material_ui`. **قبل أي تقسيم يجب التحقق من قائمة صادرات `material_ui`؛ وكل ملف جديد يستورد `material_ui` بالطريقة نفسها إلى أن يُتحقق من ذلك — لا يُستبدل بـ `flutter/material.dart` في خطوة التقسيم نفسها.**

### 2.2 الحالة المشتركة (العموميات — Globals)

| العام | النوع | أين يُقرأ / يُكتب |
|---|---|---|
| `settings` | `AppSettings` | كل الصفحات تقريباً؛ `TilawaApp` يستمع إليه بـ `AnimatedBuilder`؛ `quranStyle` يقرأ `settings.amiri`؛ `AppSettings.reciterObj` يقرأ `reciters` من `db.dart` |
| `user` | `UserData` | Home، القارئ، تفاصيل الآية، المفضلة، السجل، الورد، التلاوات، القراءات؛ `WarshService.download` يستدعي `user.setWarshReady(true)` |
| `audio` | `AudioService` | قارئ السورة، تفاصيل الآية، التلاوات، الإشعارات (ضمنياً عبر `currentAyahId`) |
| `navKey` | `GlobalKey<NavigatorState>` | `TilawaApp` + `NotificationService` (يفتح `AyahDetailPage` من الإشعار) |
| `Repo.i` | `Repo` (في `db.dart`) | كل الصفحات والخدمات تقريباً |
| ثوابت الألوان (14) | `const Color` | كل الواجهات + `buildTheme` + الرسامون |

**مفاتيح `SharedPreferences` (يجب ألا تتغير أسماؤها أبداً أثناء التقسيم — تغييرها يمسح بيانات المستخدم):**
`mode, font, amiri, reciter, reminder, rem_hour, rem_min, wird_q, favs, history, tags, notes, khatmah_q, warsh_ready, fav_reciters, lib_sha`.

### 2.3 حلقات الاعتماد (Cycles) — أخطر ما في الملف

| الحلقة | السلسلة | الكسر المطلوب |
|---|---|---|
| أ | `AppSettings.setReminder` → `NotificationService` → (`settings` + `user` + `Repo.i`) → `AyahDetailPage` (عبر `navKey`) | `NotificationService.init({onNotificationTap})` — يُمرَّر رد النداء من `main.dart`؛ ولا يستورد `AyahDetailPage` مباشرة. و `AppSettings` لا يستورد الإشعارات: حقل رد نداء `onReminderChanged` يُعيَّن في `main.dart` |
| ب | `UserData.completeWird` → `settings` (العام) + `NotificationService` | `UserData` يستورد `settings.dart` فقط (اتجاه واحد)؛ وإعادة الجدولة عبر رد النداء نفسه من (أ)، لا باستيراد مباشر |
| ج | `AudioService` → `settings.reciterObj` → `reciters` (في `db.dart`) | بعد نقل `reciters` إلى `data/models.dart` يستورد `settings.dart` و `audio_service.dart` النماذجَ من هناك؛ ولا يستورد `settings.dart` من `data/` |
| د | `ayahCard` (دالة عامة) → `AyahDetailPage`، وكل الصفحات تستورد `ayahCard` | `ayahCard` **لا** تذهب إلى `core/widgets.dart`؛ تنتقل إلى `features/reader/ayah_detail_page.dart` (أو تبقى دالة محلية فيه)، والصفحات الأخرى تستوردها من القارئ |
| هـ | `quranStyle` → `settings.amiri` | إما أن تبقى في ملف يستورد `settings.dart`، أو يُغيَّر توقيعها إلى `quranStyle(size, {required bool amiri})` وتُحدَّث مواقع الاستدعاء — الخيار الثاني أنظف ويُبقي `widgets.dart` ورقة (leaf) |

**القاعدة العامة:** `features/*` لا تستورد بعضها بعضاً إلا عبر `core/` أو `data/`؛ والاتجاه الوحيد المسموح: `features → core/data`، و `core → data`، ولا عكس. `main.dart` وحده يستورد الكل ويربط الردود (wiring).

### 2.4 خريطة من-يستخدم-ماذا (مختصرة، من فحص فعلي)

| المستخدِم | يعتمد على |
|---|---|
| `TilawaApp` | `settings`، `buildTheme`، `navKey`، `BootPage` |
| `_BootPageState` (124) | `Repo.i`، `settings.reminderOn`، `NotificationService`، `Shell`، `FloralCorner`، `LogoMark` |
| `_HomePageState` (274) | `settings`، `user`، `Repo.i`، `quranStyle`، `softCard`، `tadabburQuestion`، `wirdPlanFor`، `FloralCorner`، `LogoMark` |
| `_SurahReaderPageState` (227) | `settings`، `user`، `audio`، `Repo.i`، `OrnateFrame` |
| `_AyahDetailPageState` (253) | `settings`، `user`، `audio`، `Repo.i`، `Share.share`، `Repo.i.onlineTafsir`، `ijazList` |
| `_SearchPageState` (175) | `Repo.i` (بحث + تفسير)، `ayahCard` |
| `_AssistantPageState` (405) | `Repo.i.ask/related/tafsirOf/topic`، `surahVirtues`، `RobotAvatar` |
| `_RecitationsPageState` (134) | `settings`، `user`، `audio`، `reciters`، `MonogramAvatar` |
| `_QiraatPageState` (116) | `user`، `WarshService` |
| `WarshReaderPage` / `WarshSurahPage` | `Repo.i`، `WarshService` |
| `_SettingsPageState` (195) | `settings`، `FloralCorner`، `LogoMark` |
| `OurWorksPage` (101) | `launchUrl` فقط خارجياً |
| `LibraryPage` (75) | `Repo.i` (`quickCheck/verifyHash/sizeBytes/needsUpdate`) |
| `AudioService` | `settings.reciterObj`، `Repo.i.ayahsOf`، `just_audio`، `http` (تنزيل السورة)، `path_provider` |
| `WarshService` | `http`، `path_provider`، `user.setWarshReady` |
| `Repo` | `rootBundle`، `SharedPreferences` (`lib_sha`)، `Isolate` |

---

## 3. جدول التقسيم — الملف → المحتوى → الأسطر التقديرية → الترتيب

سقف كل ملف **~400 سطر**. `main.dart` النهائي: bootstrap فقط (~60–120 سطراً: `main()` + `TilawaApp` + ربط الردود).

### الخطوة 0 — أولاً وقبل أي نقل (شرط مسبق)

| الملف | المحتوى | الأسطر | الترتيب |
|---|---|---|---|
| `test/` (جديد) | `models_test.dart` + `theme_test.dart` + `search_test.dart` (انظر §4) | ~150 | **0** |
| `.github/workflows/build.yml` | حذف `rm -rf test` واستبداله ببوابة `flutter test` تمنع الدمج عند الفشل | تعديل سطرين | **0** |

بدون هذه الخطوة لا توجد طريقة للتحقق من أي نقل — ولهذا هي أولاً.

### المرحلة أ — أوراق بلا اعتماديات (Leaves) — أقل خطر

| # | الملف الجديد | المحتوى (المصدر الحالي) | الأسطر تقديراً | الترتيب |
|---|---|---|---|---|
| 1 | `lib/data/models.dart` | من `db.dart:46–120`: `Surah`، `Ayah`، `Ijaz`، `Reciter` + `reciters` (7) + `offlineTafsirs` + `onlineTafsirs`؛ ويُعاد تصديرها من `db.dart` مؤقتاً (`export 'models.dart';`) حتى تُحدَّث كل الاستيرادات | ~75 | **1** |
| 2 | `lib/core/theme.dart` | من `main.dart:20–33` (14 لوناً) + `509–543` (`buildTheme`) + `649–843` (الرسامون والأفاتارات: `LogoMark`، `_LogoPainter`، `_FloralPainter`، `FloralCorner`، `OrnateFrame`، `MonogramAvatar`، `RobotAvatar`) | ~290 | **2** |
| 3 | `lib/core/widgets.dart` | من `main.dart:544–548` (`fmtDur`) + `571–596` (`softCard`) + `599–623` (`askText`) + `634–648` (`emptyState`) + `quranStyle` بعد تغيير توقيعها (انظر حلقة هـ)؛ **بدون `ayahCard`** (تذهب للقارئ، حلقة د) | ~110 | **3** |

### المرحلة ب — الحالة والخدمات (بعد الأوراق)

| # | الملف الجديد | المحتوى (المصدر الحالي) | الأسطر تقديراً | الترتيب |
|---|---|---|---|---|
| 4 | `lib/core/settings.dart` | `AppSettings` (`main.dart:38–108`) + `final settings`؛ يستورد `data/models.dart` (لـ `reciters`)؛ **بدون** استيراد الإشعارات — رد نداء `onReminderChanged` يُعيَّن من `main.dart` | ~80 | 4 |
| 5 | `lib/core/user_data.dart` | `UserData` (`main.dart:110–203`) + `final user`؛ يستورد `settings.dart` فقط (اتجاه واحد)؛ إعادة جدولة التذكير عبر رد النداء | ~100 | 5 |
| 6 | `lib/core/notifications.dart` | `NotificationService` (`main.dart:209–275`)؛ يستورد `settings.dart` + `user_data.dart` + `data/db.dart`؛ ويأخذ `onNotificationTap(int ayahId)` من `main.dart` بدل استيراد `AyahDetailPage` | ~75 | 6 |
| 7 | `lib/features/audio/audio_service.dart` | `AudioService` (`main.dart:278–434`) + `final audio`؛ يستورد `core/settings.dart` + `data/db.dart` + `just_audio` + `http` + `path_provider` | ~165 | 7 |
| 8 | `lib/features/qiraat/warsh_service.dart` | `WarshVerse` + `WarshSurah` + `WarshService` (`main.dart:439–499`)؛ يستورد `core/user_data.dart` + `http` + `path_provider` | ~65 | 8 |
| 9 | `lib/data/search.dart` | من `db.dart:19–45` + `121–315`: `normalizeAr`، `_searchExpr`، `_searchSync`، `_askSync`، `_relatedSync`، `_searchTafsirSync`، `_topicWords`، `_stripHtml`، `_sha`، `_quick` — **تبقى top-level** (تعمل في `Isolate.run`) | ~220 | 9 |
| 10 | `lib/data/repo.dart` | `Repo` (`db.dart:316–549`)؛ يستورد `models.dart` + `search.dart` + `rootBundle` + `SharedPreferences` | ~235 | 10 |
| 11 | `lib/data/db.dart` (يُبقي الاسم) | بعد النقل يصبح **barrel فقط**: `export 'models.dart'; export 'search.dart'; export 'repo.dart';` — ثم يُحذف الـ barrel في خطوة لاحقة بعد تحديث كل الاستيرادات إلى المسارات الجديدة | ~5 | 10 (مع 10) |

### المرحلة ج — الصفحات (من الأقل تشابكاً إلى الأكثر)

| # | الملف الجديد | المحتوى (المصدر الحالي) | الأسطر تقديراً | الترتيب |
|---|---|---|---|---|
| 12 | `lib/features/tafsir/tafsir_pages.dart` | `TafsirBrowserPage` (39) + `TafsirSurahPage` (62) + `IjazPage` (37) + `IjazDetailPage` (33) | ~175 | 11 |
| 13 | `lib/features/user/favs_page.dart` | `FavsPage` (124) | ~130 | 12 |
| 14 | `lib/features/user/history_page.dart` | `HistoryPage` (35) | ~40 | 12 |
| 15 | `lib/features/user/library_page.dart` | `LibraryPage` (75) | ~80 | 12 |
| 16 | `lib/features/user/wird_page.dart` | `WirdPage` (95) + `_WirdPlannerCard` (59) | ~160 | 13 |
| 17 | `lib/features/user/more_page.dart` | `MorePage` (79) + `OurWorksPage` (101) — `launchUrl` يبقى هنا فقط | ~185 | 13 |
| 18 | `lib/features/user/settings_page.dart` | `SettingsPage` (195) | ~200 | 13 |
| 19 | `lib/features/reader/surahs_page.dart` | `SurahsPage` (78) | ~85 | 14 |
| 20 | `lib/features/reader/surah_reader_page.dart` | `SurahReaderPage` (227) | ~235 | 15 |
| 21 | `lib/features/reader/ayah_detail_page.dart` | `AyahDetailPage` (253) + `ayahCard` (624–633) منقولة إلى هنا | ~265 | 16 |
| 22 | `lib/features/search/search_page.dart` | `SearchPage` (175) + `_SurahSearchTab` (77) | ~255 | 17 |
| 23 | `lib/features/audio/recitations_page.dart` | `RecitationsPage` (134) | ~140 | 17 |
| 24 | `lib/features/qiraat/qiraat_pages.dart` | `QiraatPage` (116) + `WarshReaderPage` (50) + `WarshSurahPage` (37) | ~210 | 18 |
| 25 | `lib/features/home/home_page.dart` | `HomePage` (274) | ~280 | 19 |
| 26 | `lib/features/assistant/assistant_data.dart` | `surahVirtues` + `tadabburQuestions` + `tadabburQuestion` + `wirdPlanFor` (`main.dart:849–883`) | ~40 | 20 |
| 27 | `lib/features/assistant/assistant_controller.dart` | منطق `_AssistantPageState` غير الواجهي: `_askAboutAyah`، `_answerVirtue`، `_send`، تحليل المرجع `2:255`، استدعاءات `Repo.ask/related/tafsirOf/topic` | ~200 | 20 |
| 28 | `lib/features/assistant/assistant_page.dart` | واجهة `AssistantPage` + `_Msg` + بناء الرسائل (الباقي من 405 سطور بعد فصل المنطق والبيانات) | ~200 | 20 |
| 29 | `lib/core/router.dart` | `Shell` + `_ShellState` (24) + `navKey` (منقول من سطر 35) | ~35 | 21 |
| 30 | `lib/features/boot/boot_page.dart` | `BootPage` + `_BootPageState` (124) | ~130 | 21 |
| 31 | `lib/main.dart` (نهائي) | `main()` + `TilawaApp` (19) + ربط الردود (`onReminderChanged`، `onNotificationTap`) + استيراد الوحدات | ~60–120 | 21 |

### المرحلة د — وحدات جديدة بلا كود منقول (هيكلة فقط، تُبنى في مراحل لاحقة)

هذه الوحدات الست من مخطط PLAN §3.1 **لا يوجد لها أي كود في `main.dart` أصلاً** — فلا تُنشأ بنقل أسطر، بل كهيكل/واجهة (stub) أو تُؤجَّل لمرحلتها. إنشاؤها الآن كملفات فارغة يُضلِّل (يوحي بوجود ميزة غير موجودة — مخالفة للقاعدة 6 في PLAN §14):

| الوحدة (من PLAN §3.1) | الحالة الفعلية | القرار |
|---|---|---|
| `features/mushaf/` (صفحات المصحف 604) | غير موجود — رقم الصفحة مخزَّن في `ayahs.page` فقط | هيكل في Phase 1، لا نقل الآن |
| `features/tajweed/` (TajweedEngine) | غير موجود — صفر ظهور لكلمة «تجويد» في الكود | Phase 1، بعد مصدر `cpfair` + محاذاة |
| `features/memorization/` (حفظ + مراجعة متباعدة) | غير موجود — يوجد فقط تتبع ختمة بالأرباع | Phase 3 |
| `features/speech/` (تسميع yazinsai) | غير موجود — **مشروط بنجاح PoC** | Phase 3، بعد PoC |
| `features/academy/` (دروس + نورانية + أطفال) | غير موجود | Phase 4 |
| `features/translation/` (ترجمات + transliteration) | غير موجود — التطبيق عربي فقط | Phase 4 |
| `features/words/` (بطاقة الكلمة) | غير موجود — لا جدول `words` في DB | Phase 4 |
| `core/download_manager.dart` | جديد — تنزيل الصوت الحالي هشّ (بلا استئناف) | Phase 2 |
| `core/connectivity.dart` | جديد — لا مؤشر اتصال حالياً | Phase 0 متأخر / Phase 5 |
| `data/migrations.dart` + `data/packages.dart` | جديد — ترحيل SharedPreferences ← SQLite | Phase 0 (مهمة مستقلة عن التقسيم) |

**الخلاصة العددية:** بعد اكتمال النقل يصبح `main.dart` ≈ 60–120 سطراً، وأكبر ملف جديد ≈ 290 سطراً (`theme.dart`)، وكل الملفات الأخرى ≤ ~265 سطراً. الاستثناء الوحيد الذي يتطلب فصلاً إضافياً هو `_AssistantPageState` (405 أسطر) — يُفصل إلى 3 ملفات (26–28 أعلاه).

---

## 4. أول ملفين يُقسَّمان بأقل خطر

### الأول: `lib/data/models.dart` (من `db.dart:46–120`، ~75 سطراً)

**لماذا هو الأقل خطراً:**
- كود **نقي 100%**: أصناف بيانات (`Surah`، `Ayah`، `Ijaz`، `Reciter`) + ثوابت قوائم — بلا Flutter، بلا `async`، بلا IO، بلا حالة، بلا واجهة، بلا استيرادات خارجية إطلاقاً.
- لا يعتمد على شيء، ويعتمد عليه الجميع — اتجاه الاعتماد واحد (الجميع يستورد منه، هو لا يستورد أحداً)، فلا حلقة ممكنة.
- النقل ميكانيكي حرفي (قص/لصق) بلا تغيير توقيع أو سلوك؛ و `db.dart` يُبقي `export 'models.dart';` مؤقتاً فلا ينكسر أي مستورِد قبل تحديثه.

**الاختبارات التي تحميه** (`test/models_test.dart` — اختبار Dart نقي، يعمل بـ `flutter test`):
- `reciters` طولها 7، ومعرّفاتها فريدة، وكل `folder` غير فارغ وينتهي بـ `kbps`.
- `offlineTafsirs` طولها 3 (`muyassar`، `jalalayn`، `saadi`).
- `onlineTafsirs` معرّفاتها `{14، 15، 90}` كما هي في الكود (مع تعليق: 90 غير موثَّق — الاختبار يثبّت القيمة الحالية ولا يدّعي صحتها).
- منشئو `Surah`/`Ayah`/`Ijaz` يحفظون الحقول (اختبار بناء بسيط).
- بوابة CI: `flutter analyze` أخضر بعد النقل.

### الثاني: `lib/core/theme.dart` (من `main.dart:20–33` + `509–543` + `649–843`، ~290 سطراً)

**لماذا هو الثاني الأقل خطراً:**
- ورقة (leaf) أيضاً: الثوابت + `buildTheme` + الرسامون والأفاتارات لا يقرأون أي حالة ولا يستدعون أي خدمة ولا يتنقلون؛ اعتمادهم الوحيد `material_ui` + `dart:math` (ضمني في الرسامين — يُتحقق عند النقل).
- أسماء الثوابت (`teal`، `sky`، `pink`، `mint`، `gold`، `cream`، `ink`…) تبقى حرفياً كما هي، فلا يتغير أي موقع استدعاء إلا بإضافة سطر استيراد واحد.
- `RobotAvatar` نقي (تدرج + أيقونة فقط) — تأكّد بالفحص أنه لا يعتمد على `tadabburQuestion` (ذلك الثابت يقع في الكود العام بعده، لا داخله).

**الاختبارات التي تحميه** (`test/theme_test.dart` — `testWidgets`):
- `buildTheme(false).scaffoldBackgroundColor == cream (0xFFF6FAFC)`، و `buildTheme(true)` داكن (`0xFF101D24`)، و `primary == sky` في الحالتين.
- ضخّ (pump) `LogoMark` و `OrnateFrame` و `FloralCorner` و `RobotAvatar` و `MonogramAvatar` — تُبنى دون استثناء.
- مقارنة لقطات (screenshots) على الجهاز قبل/بعد النقل للصفحة الرئيسية وصفحة الإعدادات — التحقق البصري الوحيد الذي لا يغني عنه `analyze`.

**ثم الثالث مباشرة:** `lib/core/widgets.dart` (§3، #3) — بالمنطق نفسه (ورقة)، بعد حسم توقيع `quranStyle` (حلقة هـ).

---

## 5. ما نُفذ محلياً فعلياً وما لم يُنفَّذ ولماذا

### نُفذ في هذه الجولة (محلي فقط)
- قراءة `AUDIT_2026-11-25.md` و `PLAN_2026-11-25.md` §3.1 كاملين.
- فحص `lib/main.dart` (3959 سطراً) و `lib/db.dart` (549 سطراً) سطراً بسطر عبر `grep` ومطابقة أقواس: كل الأصناف بامتدادها الدقيق، والكود العام، والواردات، والعموميات، ومواقع الاستخدام المباشر الوحيدة لـ `share_plus` (سطر 1936) و `url_launcher` (سطر 1139) و `http.get` في `main.dart` (سطر 466، داخل `WarshService`).
- كتابة هذه الخطة في `SPLIT_PLAN_2026-11-25.md` (ملف جديد في نسخة العمل فقط).

### لم يُنفَّذ — ولا ملف كود واحد نُقل أو عُدِّل أو حُذف
- **لا Flutter SDK ولا Dart SDK في هذه البيئة** (`which flutter dart` → غير موجود، exit 1) — فلا `flutter analyze` ولا `flutter test` للتحقق من أي نقل.
- **لا `pubspec.lock` ولا cache للحزم محلياً** — ولا يمكن التحقق من قائمة صادرات `material_ui` التي يعتمد عليها كل الملف.
- التحقق الوحيد الممكن لنقل ميكانيكي هو GitHub Actions، وذلك يتطلب **دفعاً (push)** — وهو محظور في هذه المهمة (عمل محلي فقط).
- أي نقل دون تحقق قد يُدخل خطأ استيراد مكسوراً لا يظهر إلا عند البناء — فالخطة وحدها هي التسليم الصحيح لهذه الجولة، والتنفيذ يكون في بيئة فيها Flutter SDK مع `flutter analyze` + `flutter test` أخضر بعد كل خطوة على حدة.
- **لا نسخة احتياطية لزم إنشاؤها** لأنه لم يتغير أي ملف كود؛ و `git status` في نسخة العمل لم يتغير إلا بملفي الخطة/التدقيق غير المتعقَّبين أصلاً (`AUDIT_2026-11-25.md`، `PLAN_2026-11-25.md`، وهذا الملف).

---

## 6. الحفاظ على بساطة التصميم وسرعة التطبيق — ما الذي يجب ألا يتغير أثناء التقسيم

التقسيم **إعادة تنظيم كود فقط، صفر تغيير واجهة أو سلوك**. ما يجب ألا يتغير:

### الهوية البصرية (يُحافَظ عليها وتُهذَّب، لا تُستبدل — PLAN §10)
- قيم الألوان الـ14 حرفياً (`teal 0xFF0E7C6B`، `sky 0xFF4E9BC4`، `pink 0xFFE88AA5`، `mint 0xFF6FBF9B`، `gold 0xFFC9A227`، `cream 0xFFF6FAFC`، `ink 0xFF1F2E2A`…) — لا إعادة تسمية ولا تعديل درجة.
- `buildTheme` كما هو: مخططا الفاتح/الداكن، `surface 0xFF1C2B33` لليلي، `scaffoldBackgroundColor`، ثيما `NavigationBar` و `Chip`.
- `softCard`: نصف قطر 24، الظل نفسه (`blurRadius 14`)، اللون الداكن `0xFF1C2B33`.
- الخط الأميري + حجم الخط الافتراضي 26 + `height 2.0` في `quranStyle`؛ و `Directionality` RTL في `TilawaApp`.
- الرسامون المخصصون (`_LogoPainter`، `_FloralPainter`، `OrnateFrame`) يُنقلون كما هم — بلا «تحسين».

### التنقل والبنية
- التبويبات الثلاثة نفسها (الرئيسية/المكتبة/المزيد) + `IndexedStack` — **لا** تُستبدل بتحميل كسول (lazy) يُفقد حالة التبويبات ويُبطئ التنقل المتكرر.
- ترتيب أقسام الصفحة الرئيسية نفسه، ونصوص الواجهة العربية نفسها حرفياً، ومسارات `MaterialPageRoute` نفسها إلى الصفحات نفسها.
- قناة الإشعارات نفسها (`tilawa_wird`) والحمولة نفسها (`ayah:<id>`) والوقت الافتراضي 07:00.

### الأداء (لا تضحية بالأداء من أجل التنظيم)
- **لا حزم جديدة** في `pubspec.yaml` أثناء التقسيم؛ ولا تحويل العموميات (`settings`/`user`/`audio`) إلى حقن تبعيات (DI) في الخطوة نفسها — ذلك إعادة هيكلة مستقلة بمخاطرها، تُقرَّر وحدها لاحقاً.
- مستمع واحد على `settings` (`AnimatedBuilder` في `TilawaApp`) — لا مستمعين جدد ولا إعادة بناء إضافية.
- استعلامات البحث/المساعد تبقى في `Isolate.run` (`ask`، `related`، `searchTafsir`) — لا تُنقل إلى الخيط الرئيسي.
- `ListView.builder` يبقى builder — لا يُحوَّل إلى `Column` أو قوائم كاملة.
- **صفر تغيير في الأصول**: قاعدة البيانات نفسها (40.2 MB) والخطوط نفسها — التقسيم كودٌ فقط، وحجم APK لا يتغير به وحده.
- مفاتيح `SharedPreferences` نفسها (§2.2) — أي إعادة تسمية تمسح بيانات المستخدم؛ وآلية `needsUpdate()`/التثبيت الذري بـ SHA تبقى كما هي.

### قواعد التنفيذ (عندما يحين في بيئة فيها Flutter)
1. خطوة واحدة في كل مرة (ملف واحد من الجدول)، ثم `flutter analyze` + `flutter test` أخضر قبل الخطوة التالية.
2. لا تغيير سلوك في خطوة نقل: النقل حرفي، وأي تحسين (مثل توقيع `quranStyle`) خطوة منفصلة موثقة.
3. لا حذف لـ `main.dart` القديم إلا بعد أن يصبح `main.dart` الجديد هو الـ bootstrap وحده ويمر البناء.
4. التحقق البصري على جهاز (لقطات قبل/بعد) للرئيسية والقارئ وتفاصيل الآية والإعدادات.
