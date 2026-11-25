// ودجتات مشتركة لإعادة تصميم تلاوة — تقرير إعادة التصميم §d.3 (2026-11-26).
// مصدر الحقيقة الوحيد لأنماط البطاقات والأزرار والشارات في Phase B.
// ملاحظة الاستيراد (كما في theme.dart): كل رموز Flutter تصل عبر
// package:material_ui/material_ui.dart — لم يُتحقق من قائمة صادرات
// material_ui محلياً (لا Flutter/Dart SDK هنا)؛ CI هو الحكم.
//
// قواعد ملزمة في هذا الملف:
// - لا أرقام/إحصاءات مُخترعة؛ لا عناصر زخرفية تحل محل وظيفة حقيقية.
// - الزر المعطَّل يبقى بالشكل الافتراضي للإطار (لا يُعاد تلوينه ليبدو مفعَّلاً).
// - ألوان StatusChip تأتي فقط من الرموز الدلالية؛ لا ألوان حرة عند الاستدعاء.
// - AyahText يمرّر نص الآية حرفياً دون أي تعديل.
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// لون يُطبَّق فقط عند التفعيل؛ عند التعطيل يُرجع null فيترك الإطار
/// لونه الافتراضي — حتى لا يبدو الزر المعطَّل مفعَّلاً أبداً.
WidgetStateProperty<Color?> _enabledColor(Color color) =>
    WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled) ? null : color);

/// بطاقة تلاوة الموحّدة — تحل محل softCard() في main.dart (نحو 50 موضعاً)
/// و_hifzCard() المكررة في hifz_page.dart.
/// نصف القطر 24، ظل blur 14 وإزاحة (0,4) وألفا 0.06 (فاتح) / 0.25 (ليلي)،
/// كما في softCard الحالية حرفياً — بلا تغيير بصري عند الترحيل الميكانيكي.
class TilawaCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final Gradient? gradient;
  const TilawaCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(spaceCard),
    this.gradient,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final r = BorderRadius.circular(radiusCard);
    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C2B33) : surfaceCard,
        gradient: gradient,
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// زر أساسي معبأ — brandPrimary، ارتفاع 52، نصف قطر 14 (من سمة Theme).
/// ‏onPressed يقبل null صراحةً: الزر المعطَّل يستخدم الشكل الافتراضي للإطار.
/// المتغير النغمي (tonal: true) خلفيته tealLight ونصه brandPrimaryDark.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool tonal;
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.tonal = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final style = tonal
        ? ButtonStyle(
            backgroundColor: _enabledColor(tealLight),
            foregroundColor: _enabledColor(brandPrimaryDark),
          )
        : null;
    if (icon != null) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: style,
      );
    }
    return FilledButton(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}

/// زر ثانوي محاط — حدود brandPrimary، ارتفاع 52، نصف قطر 14 (من سمة Theme).
/// ‏onPressed يقبل null صراحةً: الزر المعطَّل يستخدم الشكل الافتراضي للإطار.
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  const SecondaryButton({
    required this.label,
    required this.onPressed,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// عنوان قسم — 18 w800 مع إجراء اختياري في الطرف.
/// يحل محل عناوين Text(..., fontSize: 18, FontWeight.w800) المكررة.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  const SectionHeader({
    required this.title,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const Spacer(),
        if (actionLabel != null)
          TextButton(onPressed: onAction, child: Text(actionLabel!)),
      ],
    );
  }
}

/// بلاطة إحصائية — قيمة 22 w700 وتسمية متمركزة، داخل بطاقة.
/// ‏color يقبل فقط رمزاً دلالياً (success / warning / error / sky / brandPrimary…)؛
/// الافتراضي brandPrimary. لا أرقام مُخترعة: القيمة تأتي دائماً من بيانات حقيقية.
class StatTile extends StatelessWidget {
  final String value;
  final String label;
  final Color? color;
  final IconData? icon;
  const StatTile({
    required this.value,
    required this.label,
    this.color,
    this.icon,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? brandPrimary;
    return TilawaCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: c, size: 22),
            const SizedBox(height: 4),
          ],
          Text(value,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700, color: c)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: muted)),
        ],
      ),
    );
  }
}

/// شريط تقدم موحّد — يحل محل LinearProgressIndicator المتناثرة.
/// المسار tealLight، الشريط success للتقدم وbrandPrimary للتنزيل (يمرَّر عبر color).
/// الارتفاع الأدنى 8 ونصف القطر 4. ‏value تقبل null (غير محدد) كما في الإطار.
class TilawaProgressBar extends StatelessWidget {
  final double? value;
  final Color? trackColor;
  final Color? color;
  const TilawaProgressBar({
    this.value,
    this.trackColor,
    this.color,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: value,
        backgroundColor: trackColor ?? tealLight,
        valueColor: AlwaysStoppedAnimation<Color>(color ?? success),
        minHeight: 8,
      ),
    );
  }
}

/// نغمات شارة الحالة — التعيين الوحيد المسموح بين النغمة واللون.
/// لا ألوان حرة عند مواضع الاستدعاء.
enum StatusTone { ok, warn, error, info, neutral }

/// شارة حالة — تحل محل Chip(label: ...) النصية في كل مكان
/// (حالة النموذج، حالة الحزمة، «قيد الإعداد»، حالة المراجعة).
class StatusChip extends StatelessWidget {
  final String label;
  final StatusTone tone;
  const StatusChip({required this.label, required this.tone, super.key});

  (Color, Color) get _colors => switch (tone) {
        StatusTone.ok => (success, successLight),
        StatusTone.warn => (warning, goldLight),
        StatusTone.error => (error, errorBg),
        StatusTone.info => (skyDeep, skyLight),
        StatusTone.neutral => (muted, tealLight),
      };

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = _colors;
    return Chip(
      label: Text(label),
      backgroundColor: bg,
      labelStyle:
          TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusChip)),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// بطاقة خطأ — خلفية errorBg ونص/أيقونة error.
/// تحل محل Card(color: Colors.red.shade50) في مواضع الخطأ (5+ مواضع).
/// ‏message أو child واحد منهما على الأقل مطلوب.
class ErrorCard extends StatelessWidget {
  final String? message;
  final Widget? child;
  const ErrorCard({this.message, this.child, super.key})
      : assert(message != null || child != null,
            'ErrorCard requires a message or a child');

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(spaceCard),
      decoration: BoxDecoration(
        color: errorBg,
        borderRadius: BorderRadius.circular(radiusCardSmall),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline_rounded, color: error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(message!,
                      style: const TextStyle(
                          fontSize: 14, height: 1.7, color: error)),
                ),
              ],
            ),
          if (message != null && child != null) const SizedBox(height: 8),
          if (child != null) child!,
        ],
      ),
    );
  }
}

/// ملاحظة معلوماتية — خلفية goldLight وأيقونة gold.
/// تحل محل Card(color: Colors.green.shade50) وبطاقات الملاحظات الذهبية
/// (منها _SelfAssessmentNote في صفحة الحفظ).
class InfoNote extends StatelessWidget {
  final String message;
  final IconData? icon;
  const InfoNote({required this.message, this.icon, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(spaceCard),
      decoration: BoxDecoration(
        color: goldLight,
        borderRadius: BorderRadius.circular(radiusCardSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? Icons.info_outline_rounded, color: gold),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(fontSize: 14, height: 1.7, color: ink)),
          ),
        ],
      ),
    );
  }
}

/// نص آية — يغلّف منطق settings.amiri (خط أميري أو الخط الافتراضي).
/// النص يُمرَّر حرفياً كما هو في قاعدة البيانات؛ لا يُعدَّل ولا يُختصر أبداً.
/// ‏amiri معامل اختياري (افتراضي true = افتراضي AppSettings): مواضع الاستدعاء
/// تمرّر settings.amiri. لا يستورد هذا الملف main.dart لأن settings كائن
/// عام هناك، واستيراده سيخلق دورة استيراد (main.dart ← core/widgets.dart).
class AyahText extends StatelessWidget {
  final String text;
  final double fontSize;
  final bool amiri;
  final double height;
  final FontWeight fontWeight;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  const AyahText({
    required this.text,
    this.fontSize = 18,
    this.amiri = true,
    this.height = 2.0,
    this.fontWeight = FontWeight.w600,
    this.textAlign,
    this.maxLines,
    this.overflow,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      style: TextStyle(
        fontSize: fontSize,
        height: height,
        fontWeight: fontWeight,
        fontFamily: amiri ? 'Amiri' : null,
      ),
    );
  }
}

/// حالة فارغة — تحل محل emptyState() في main.dart (تُبقي W1 عليه اسماً مستعاراً).
/// نفس مظهر emptyState الحالية حرفياً: دائرة tealLight بأيقونة teal،
/// نص 18 بارتفاع 1.7، وزر نغمي اختياري.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? buttonLabel;
  final VoidCallback? onTap;
  const EmptyState({
    required this.icon,
    required this.text,
    this.buttonLabel,
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: tealLight,
              child: Icon(icon, size: 48, color: teal),
            ),
            const SizedBox(height: 20),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, height: 1.7),
            ),
            if (buttonLabel != null) ...[
              const SizedBox(height: 20),
              PrimaryButton(
                label: buttonLabel!,
                onPressed: onTap,
                tonal: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
