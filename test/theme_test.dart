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

  group('buildTheme', () {
    test('light theme: Material 3, sky primary, cream scaffold', () {
      final t = buildTheme(false);
      expect(t.useMaterial3, isTrue);
      expect(t.brightness, Brightness.light);
      expect(t.colorScheme.primary, sky);
      expect(t.colorScheme.secondary, gold);
      expect(t.colorScheme.surface, Colors.white);
      expect(t.colorScheme.onSurface, ink);
      expect(t.scaffoldBackgroundColor, cream);
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
}
