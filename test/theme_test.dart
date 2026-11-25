// اختبارات الهوية البصرية المنقولة إلى lib/core/theme.dart (Phase 1، الخطوة 2 من التقسيم).
//
// الغرض: تثبيت قيم الألوان وسلوك buildTheme والودجتات المنقولة حرفياً من
// lib/main.dart (الألوان 19-33، buildTheme 509-541، الرسامون/الأفاتارات 649-843،
// التزام 07204f14) قبل أي دمج. هذه اختبارات قيم/عرض فقط — لا تقارن لقطات (screenshots)
// قبل/بعد على جهاز؛ تلك المقارنة البصرية ما زالت خطوة لاحقة.
// التشغيل (في بيئة فيها Flutter SDK): `flutter test test/theme_test.dart`
// ملاحظة: لا Flutter/Dart SDK في بيئة كتابة هذه الاختبارات — لم تُشغَّل بعد.
//
// تحذير موثّق: theme.dart يفترض أن كل رموز Flutter تصل عبر
// package:material_ui/material_ui.dart كما في main.dart الأصلي. إن كان
// material_ui لا يُصدّر رمزاً ما (مثلاً CustomPainter أو ColorScheme)،
// فسيفشل `flutter analyze`/`flutter test` عند أول تشغيل — وهذا أول ما
// يجب التحقق منه، ويُصلَّح حينها بالاستيراد المباشر من package:flutter/material.dart.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tilawa_pro/core/theme.dart';
import 'package:tilawa_pro/core/widgets.dart';

void main() {
  group('palette constants (exact hex values as moved)', () {
    test('all 14 colors equal their moved values', () {
      expect(teal, const Color(0xFF0E7C6B));
      expect(tealLight, const Color(0xFFDFF0EC));
      expect(sky, const Color(0xFF4E9BC4));
      expect(skyLight, const Color(0xFFE4F1F9));
      expect(skyDeep, const Color(0xFF2E6E96));
      expect(pink, const Color(0xFFE88AA5));
      expect(pinkLight, const Color(0xFFFDE9EE));
      expect(mint, const Color(0xFF6FBF9B));
      expect(mintLight, const Color(0xFFE2F4EB));
      expect(gold, const Color(0xFFC9A227));
      expect(goldSoft, const Color(0xFFE8C468));
      expect(goldLight, const Color(0xFFFFF3CD));
      expect(cream, const Color(0xFFF6FAFC));
      expect(ink, const Color(0xFF1F2E2A));
    });
  });

  group('new design tokens (inspection report §d.1/§d.2 — deliberate additions)', () {
    test('new palette tokens equal their sampled hex values', () {
      expect(bgCream, const Color(0xFFFBF7F1));
      expect(surfaceCard, const Color(0xFFFFFFFF));
      expect(brandPrimary, const Color(0xFF276D87));
      expect(brandPrimaryDark, const Color(0xFF1B5566));
      expect(pinkSoft, const Color(0xFFFFE9E4));
      expect(success, const Color(0xFF4C9D62));
      expect(successLight, mintLight);
      expect(error, const Color(0xFFC62828));
      expect(errorBg, const Color(0xFFFDECEA));
      expect(warning, const Color(0xFFB7791F));
      expect(muted, const Color(0xFF6B7A76));
      expect(wordMatchedBg, const Color(0xFFC8E6C9));
      expect(wordErrorBg, const Color(0xFFFFCDD2));
      expect(wordReviewBg, const Color(0xFFFFF9C4));
    });

    test('radii and spacing tokens', () {
      expect(radiusCard, 24.0);
      expect(radiusCardSmall, 16.0);
      expect(radiusChip, 20.0);
      expect(radiusButton, 14.0);
      expect(spacePage, 16.0);
      expect(spaceCard, 16.0);
      expect(spaceSection, 12.0);
    });

    test('light theme uses bgCream scaffold; dark theme values unchanged', () {
      final light = buildTheme(false);
      expect(light.scaffoldBackgroundColor, bgCream);
      expect(light.cardTheme.color, surfaceCard);
      final dark = buildTheme(true);
      expect(dark.scaffoldBackgroundColor, const Color(0xFF101D24));
      expect(dark.cardTheme.color, const Color(0xFF1C2B33));
    });

    test('ThemeData additions (§d.2) exist in both brightnesses', () {
      for (final dark in [false, true]) {
        final t = buildTheme(dark);
        expect(t.filledButtonTheme.style, isNotNull);
        expect(t.outlinedButtonTheme.style, isNotNull);
        expect(t.textButtonTheme.style, isNotNull);
        expect(t.segmentedButtonTheme.style, isNotNull);
        expect(t.switchTheme.trackColor, isNotNull);
        expect(t.checkboxTheme.fillColor, isNotNull);
        expect(t.progressIndicatorTheme.color, brandPrimary);
        expect(t.inputDecorationTheme.fillColor, isNotNull);
        expect(t.dividerTheme.color, isNotNull);
        expect(t.textTheme.titleLarge?.fontSize, 20);
        expect(t.textTheme.titleMedium?.fontSize, 18);
        expect(t.textTheme.labelSmall?.fontSize, 12);
      }
    });
  });

  group('buildTheme', () {
    test('light theme: Material 3, sky primary, bgCream scaffold', () {
      final t = buildTheme(false);
      expect(t.useMaterial3, isTrue);
      expect(t.brightness, Brightness.light);
      expect(t.colorScheme.primary, sky);
      expect(t.colorScheme.secondary, gold);
      expect(t.colorScheme.surface, Colors.white);
      expect(t.colorScheme.onSurface, ink);
      // تقرير إعادة التصميم §d.1/§d.2 (تغيير مقصود): خلفية الوضع الفاتح
      // من cream الباردة 0xFFF6FAFC إلى bgCream السكرية الدافئة 0xFFFBF7F1.
      expect(t.scaffoldBackgroundColor, bgCream);
      expect(t.appBarTheme.centerTitle, isTrue);
      expect(t.appBarTheme.elevation, 0);
      expect(t.navigationBarTheme.indicatorColor, skyLight);
    });

    test('dark theme: dark scheme, dark scaffold and surfaces', () {
      final t = buildTheme(true);
      expect(t.useMaterial3, isTrue);
      expect(t.brightness, Brightness.dark);
      expect(t.colorScheme.primary, sky);
      expect(t.colorScheme.secondary, goldSoft);
      expect(t.colorScheme.surface, const Color(0xFF1C2B33));
      expect(t.colorScheme.onSurface, const Color(0xFFEAF3F0));
      expect(t.scaffoldBackgroundColor, const Color(0xFF101D24));
      expect(t.navigationBarTheme.backgroundColor, const Color(0xFF16242B));
      expect(t.navigationBarTheme.indicatorColor, const Color(0xFF24455A));
    });

    test('light and dark themes differ only where the moved code says so', () {
      final light = buildTheme(false);
      final dark = buildTheme(true);
      expect(light.colorScheme.primary, dark.colorScheme.primary);
      expect(light.colorScheme.secondary, isNot(dark.colorScheme.secondary));
      expect(light.scaffoldBackgroundColor,
          isNot(dark.scaffoldBackgroundColor));
    });
  });

  group('widgets (pump smoke tests — render without throwing)', () {
    testWidgets('LogoMark renders a CustomPaint at the given size',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: LogoMark(48))));
      // النطاق داخل LogoMark نفسها: MaterialApp/Scaffold يضيفان CustomPaint
      // خاصة بالإطار في Flutter 3.50، فلا يُحصى على مستوى الشجرة كلها.
      final markPaint = find.descendant(
          of: find.byType(LogoMark), matching: find.byType(CustomPaint));
      expect(markPaint, findsOneWidget);
      final paint = tester.widget<CustomPaint>(markPaint);
      expect(paint.size, const Size(48, 48));
    });

    testWidgets('FloralCorner renders in both orientations',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: Row(children: [FloralCorner(), FloralCorner(flip: true)]))));
      expect(
          find.descendant(
              of: find.byType(FloralCorner),
              matching: find.byType(CustomPaint)),
          findsNWidgets(2));
    });

    testWidgets('OrnateFrame renders its child', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrnateFrame(child: Text('اختبار الإطار')))));
      expect(find.text('اختبار الإطار'), findsOneWidget);
    });

    testWidgets('MonogramAvatar shows the first letter of the name',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: MonogramAvatar('أحمد'))));
      expect(find.text('أ'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
    });

    testWidgets('MonogramAvatar shows ؟ for an empty or blank name',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: Column(children: [MonogramAvatar(''), MonogramAvatar('   ')]))));
      expect(find.text('؟'), findsNWidgets(2));
    });

    testWidgets('RobotAvatar renders the smart-toy icon', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: RobotAvatar())));
      expect(find.byIcon(Icons.smart_toy_rounded), findsOneWidget);
    });

    testWidgets('OrnateFrame follows dark brightness (no throw)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: buildTheme(true),
          home: const Scaffold(body: OrnateFrame(child: Text('ليلي')))));
      expect(find.text('ليلي'), findsOneWidget);
    });
  });

  group('shared widgets (core/widgets.dart — inspection report §d.3, pump smoke tests)', () {
    testWidgets('TilawaCard renders its child and taps', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: TilawaCard(
                  onTap: () => tapped = true,
                  child: const Text('بطاقة')))));
      expect(find.text('بطاقة'), findsOneWidget);
      expect(find.byType(InkWell), findsOneWidget);
      await tester.tap(find.byType(TilawaCard));
      expect(tapped, isTrue);
    });

    testWidgets('PrimaryButton renders label, icon variant, and disabled state',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Column(children: [
                PrimaryButton(label: 'ابدأ', onPressed: () {}),
                const PrimaryButton(
                    label: 'معطل', onPressed: null, icon: Icons.mic),
                const PrimaryButton(
                    label: 'نغمي', onPressed: null, tonal: true),
              ]))));
      expect(find.text('ابدأ'), findsOneWidget);
      expect(find.text('معطل'), findsOneWidget);
      expect(find.text('نغمي'), findsOneWidget);
      expect(find.byType(FilledButton), findsNWidgets(3));
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('SecondaryButton renders an outlined button', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: SecondaryButton(
                  label: 'ثانوي', onPressed: null, icon: Icons.settings))));
      expect(find.text('ثانوي'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('SectionHeader renders title and optional action',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Column(children: [
                const SectionHeader(title: 'قسم'),
                SectionHeader(
                    title: 'قسم بإجراء',
                    actionLabel: 'عرض الكل',
                    onAction: () {}),
              ]))));
      expect(find.text('قسم'), findsOneWidget);
      expect(find.text('قسم بإجراء'), findsOneWidget);
      expect(find.text('عرض الكل'), findsOneWidget);
    });

    testWidgets('StatTile renders value, label, and icon', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: StatTile(
                  value: '28', label: 'جلسة', icon: Icons.check_circle))));
      expect(find.text('28'), findsOneWidget);
      expect(find.text('جلسة'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('TilawaProgressBar renders a linear indicator',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: TilawaProgressBar(value: 0.75))));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('StatusChip renders every tone', (tester) async {
      for (final tone in StatusTone.values) {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(body: StatusChip(label: 'حالة', tone: tone))));
        expect(find.text('حالة'), findsOneWidget);
        expect(find.byType(Chip), findsOneWidget);
      }
    });

    testWidgets('ErrorCard and InfoNote render their messages',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: Column(children: [
                ErrorCard(message: 'حدث خطأ'),
                InfoNote(message: 'ملاحظة'),
              ]))));
      expect(find.text('حدث خطأ'), findsOneWidget);
      expect(find.text('ملاحظة'), findsOneWidget);
    });

    testWidgets('AyahText renders the ayah text verbatim', (tester) async {
      const text = 'بسم الله الرحمن الرحيم';
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: AyahText(text: text, fontSize: 20))));
      expect(find.text(text), findsOneWidget);
    });

    testWidgets('EmptyState renders text and optional button',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Column(children: [
                const EmptyState(icon: Icons.inbox, text: 'لا عناصر بعد'),
                EmptyState(
                    icon: Icons.inbox,
                    text: 'فارغ',
                    buttonLabel: 'تصفح',
                    onTap: () {}),
              ]))));
      expect(find.text('لا عناصر بعد'), findsOneWidget);
      expect(find.text('فارغ'), findsOneWidget);
      expect(find.text('تصفح'), findsOneWidget);
    });
  });
}
