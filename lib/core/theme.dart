// هوية تلاوة البصرية — نُقلت حرفياً من lib/main.dart في التزام 07204f14:
//   الألوان 19-33، buildTheme 509-541، الرسامون/الأفاتارات 649-843.
// مسودة Phase 1 (2026-11-25): لم يُتحقق من التجميع — لا Flutter/Dart SDK في هذه البيئة.
// افتراض غير موثَّق: كل رموز Flutter (Color/ThemeData/Widget...) تصل عبر package:material_ui
// كما في main.dart الأصلي — لم يُتحقق من قائمة صادرات material_ui (لا pubspec.lock ولا cache حزم).
// القيم والأسماء حرفية كما هي؛ صفر تغيير سلوك أو واجهة.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

// ───────── الألوان الرسمية — لوحة باستيل من التصميم ─────────
const teal = Color(0xFF0E7C6B); // أخضر عميق (لمسات)
const tealLight = Color(0xFFDFF0EC);
const sky = Color(0xFF4E9BC4); // أزرق سماوي
const skyLight = Color(0xFFE4F1F9);
const skyDeep = Color(0xFF2E6E96);
const pink = Color(0xFFE88AA5); // وردي ناعم
const pinkLight = Color(0xFFFDE9EE);
const mint = Color(0xFF6FBF9B); // نعناعي
const mintLight = Color(0xFFE2F4EB);
const gold = Color(0xFFC9A227);
const goldSoft = Color(0xFFE8C468);
const goldLight = Color(0xFFFFF3CD);
const cream = Color(0xFFF6FAFC); // خلفية فاتحة بلون سماوي شاحب
const ink = Color(0xFF1F2E2A);

ThemeData buildTheme(bool dark) {
  final scheme = dark
      ? const ColorScheme.dark(
          primary: sky,
          secondary: goldSoft,
          surface: Color(0xFF1C2B33),
          onSurface: Color(0xFFEAF3F0))
      : const ColorScheme.light(
          primary: sky, secondary: gold, surface: Colors.white, onSurface: ink);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF101D24) : cream,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF16242B) : Colors.white,
      indicatorColor: dark ? const Color(0xFF24455A) : skyLight,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: dark ? const Color(0xFF24455A) : skyLight,
      selectedColor: sky,
      labelStyle: TextStyle(color: dark ? Colors.white : skyDeep),
      secondaryLabelStyle: const TextStyle(color: Colors.white),
    ),
  );
}

class LogoMark extends StatelessWidget {
  final double size;
  const LogoMark(this.size, {super.key});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size, size), painter: _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  Path _poly(List<List<double>> pts) {
    final p = Path();
    for (var i = 0; i < pts.length; i++) {
      i == 0 ? p.moveTo(pts[i][0], pts[i][1]) : p.lineTo(pts[i][0], pts[i][1]);
    }
    return p..close();
  }

  @override
  void paint(Canvas c, Size s) {
    c.scale(s.width / 100);
    // هلال ذهبي أعلى اليسار
    final crescent = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(const Rect.fromLTWH(8, 6, 17, 17))
      ..addOval(const Rect.fromLTWH(12, 4, 17, 17));
    c.drawPath(crescent, Paint()..color = gold);
    // فانوس معلّق أعلى الوسط
    c.drawLine(const Offset(50, 2), const Offset(50, 10),
        Paint()..color = gold..strokeWidth = 1.5);
    c.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(43, 10, 14, 16), const Radius.circular(4)),
        Paint()..color = goldSoft);
    c.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(46.5, 14, 7, 8), const Radius.circular(2)),
        Paint()..color = const Color(0xFFFFF3CD));
    c.drawLine(const Offset(50, 26), const Offset(50, 30),
        Paint()..color = gold..strokeWidth = 1.5);
    c.drawCircle(const Offset(50, 32), 1.6, Paint()..color = gold);
    // مصحف مفتوح
    const left = [[50.0, 70.0], [12.0, 60.0], [10.0, 40.0], [50.0, 50.0]];
    const right = [[50.0, 70.0], [88.0, 60.0], [90.0, 40.0], [50.0, 50.0]];
    c.drawPath(_poly(left), Paint()..color = teal);
    c.drawPath(_poly(right), Paint()..color = const Color(0xFF4DB3A2));
    c.drawLine(const Offset(50, 50), const Offset(50, 70),
        Paint()..color = Colors.white.withValues(alpha: 0.7)..strokeWidth = 1.5);
    // كرسي المصحف (رحل): عارضتان خشبيتان متقاطعتان
    final wood = Paint()
      ..color = const Color(0xFF8B5E34)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    c.drawLine(const Offset(30, 74), const Offset(70, 94), wood);
    c.drawLine(const Offset(70, 74), const Offset(30, 94), wood);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

// ───────── زخارف التصميم: أزهار وأطر مزخرفة ─────────
class _FloralPainter extends CustomPainter {
  final bool flip;
  const _FloralPainter({this.flip = false});

  void _leaf(Canvas c, double x, double y, double angle, Paint p) {
    c.save();
    c.translate(x, y);
    c.rotate(angle);
    c.drawOval(const Rect.fromLTWH(-14, -5, 28, 10), p);
    c.restore();
  }

  void _flower(Canvas c, double cx, double cy, double r, Paint petal, Paint center) {
    for (var i = 0; i < 5; i++) {
      final a = i * 1.2566;
      c.drawCircle(
          Offset(cx + math.cos(a) * r * 0.75, cy + math.sin(a) * r * 0.75), r * 0.62, petal);
    }
    c.drawCircle(Offset(cx, cy), r * 0.45, center);
  }

  @override
  void paint(Canvas c, Size s) {
    if (flip) {
      c.translate(s.width, 0);
      c.scale(-1, 1);
    }
    final petal = Paint()..color = pink.withValues(alpha: 0.85);
    final petalDeep = Paint()..color = const Color(0xFFD96A8B).withValues(alpha: 0.85);
    final leaf = Paint()..color = mint.withValues(alpha: 0.8);
    final center = Paint()..color = goldSoft;
    final stem = Path()
      ..moveTo(s.width * 0.08, s.height)
      ..quadraticBezierTo(
          s.width * 0.4, s.height * 0.5, s.width * 0.85, s.height * 0.12);
    c.drawPath(
        stem, Paint()..color = mint..style = PaintingStyle.stroke..strokeWidth = 2.5);
    _leaf(c, s.width * 0.35, s.height * 0.62, -0.6, leaf);
    _leaf(c, s.width * 0.55, s.height * 0.38, 0.7, leaf);
    _flower(c, s.width * 0.86, s.height * 0.12, 13, petal, center);
    _flower(c, s.width * 0.56, s.height * 0.28, 10, petal, center);
    _flower(c, s.width * 0.3, s.height * 0.55, 8, petalDeep, center);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// زخرفة زهرية توضع في زاوية بطاقة (داخل Stack).
class FloralCorner extends StatelessWidget {
  final double size;
  final bool flip;
  const FloralCorner({this.size = 90, this.flip = false, super.key});
  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
            size: Size(size, size), painter: _FloralPainter(flip: flip)),
      );
}

/// إطار مزخرف ذهبي/أخضر على طراز صفحات المصحف.
class OrnateFrame extends StatelessWidget {
  final Widget child;
  const OrnateFrame({required this.child, super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: gold, width: 2),
        borderRadius: BorderRadius.circular(18),
        color: dark ? const Color(0xFF1C2B33) : Colors.white,
      ),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(color: dark ? mint : teal, width: 1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Stack(children: [
          Padding(padding: const EdgeInsets.all(12), child: child),
          for (final a in [
            Alignment.topRight,
            Alignment.topLeft,
            Alignment.bottomRight,
            Alignment.bottomLeft,
          ])
            Align(
              alignment: a,
              child: const Padding(
                padding: EdgeInsets.all(1),
                child: Text('✦', style: TextStyle(color: gold, fontSize: 11)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// صورة رمزية بحرف أول الاسم — تُستخدم للقرّاء بدل صور الأشخاص.
class MonogramAvatar extends StatelessWidget {
  final String name;
  final double radius;
  const MonogramAvatar(this.name, {this.radius = 24, super.key});
  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '؟' : name.trim()[0];
    return CircleAvatar(
      radius: radius,
      backgroundColor: skyLight,
      child: Text(letter,
          style: TextStyle(
              fontSize: radius * 0.85, fontWeight: FontWeight.w800, color: skyDeep)),
    );
  }
}

/// روبوت المساعد الذكي — مرسوم بالأيقونة والتدرج، بلا صور خارجية.
class RobotAvatar extends StatelessWidget {
  final double size;
  const RobotAvatar({this.size = 48, super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              colors: [sky, Color(0xFF7FB8D9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Icon(Icons.smart_toy_rounded, color: Colors.white, size: size * 0.55),
      );
}
