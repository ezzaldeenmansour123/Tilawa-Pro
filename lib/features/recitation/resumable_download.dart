// تنزيل ملف واحد قابل للاستئناف عبر HTTP Range، مع إلغاء وتحقق
// بالحجم + SHA-256 قبل التثبيت الذرّي.
//
// هذه هي آلية lib/features/packages/download_manager.dart نفسها
// (ملف ‎.part + ترويسة Range + معالجة 200/206/416 + تحقق SHA قبل
// إعادة التسمية)، منقولة هنا في وحدة صغيرة قابلة للاختبار دون جهاز،
// لأن DownloadManager نفسه منظَّم حول PackageManifest وسجل حزم
// (packages/<id>/)، بينما ملفات النموذج تعيش في مجلد tilawa-models
// الذي يقدّمه LocalServer — فإعادة استخدام المدير حرفياً كانت ستغيّر
// تخطيط ملفات التسميع. المنطق هنا مطابق لآليته، والمدير العام لم يُمسّ.
//
// الاستخدام: downloadChecked()‎ تنزّل إلى dest عبر dest.part، وتستأنف
// من ‎.part إن وُجد، وتتحقق من الحجم والبصمة قبل إعادة التسمية إلى
// dest. أي عدم تطابق يحذف الملف ويرمي SpeechEngineException.
// cancel()‎ يوقف تنزيلاً جارياً ويُبقي ‎.part للاستئناف لاحقاً.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'speech_engine.dart';

/// SHA-256 لملف كامل (يُستخدم للتحقق قبل التثبيت).
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

class ResumableDownload {
  HttpClient? _client;
  bool _cancelRequested = false;

  /// True بعد استدعاء [cancel] حتى يبدأ تنزيل جديد.
  bool get isCancelled => _cancelRequested;

  /// يوقف التنزيل الجاري (إن وُجد) ويُبقي ملف ‎.part للاستئناف.
  /// لا يحذف ما نُزّل. آمن إن لم يكن هناك تنزيل جارٍ.
  void cancel() {
    _cancelRequested = true;
    _client?.close(force: true);
  }

  /// ينزّل [url] إلى [dest] مع الاستئناف والإلغاء.
  ///
  /// - إن كان [dest] موجوداً أصلاً بحجم [expectedBytes] (عند تحديده)
  ///   وبصمة [expectedSha256] (عند تحديدها) يُعاد كما هو دون تنزيل.
  /// - وإلا يُنزَّل إلى `dest.part` (يُستأنف منه عبر Range إن وُجد)،
  ///   ويُتحقق من الحجم والبصمة قبل إعادة التسمية الذرّية إلى [dest].
  /// - [onProgress] تُستدعى بـ (المستلَم الكلي، الإجمالي المتوقع أو null).
  /// - الإلغاء عبر [cancel] يرمي SpeechEngineException بسبب 'cancelled'
  ///   ويُبقي ‎.part.
  Future<File> downloadChecked({
    required Uri url,
    required File dest,
    int? expectedBytes,
    String? expectedSha256,
    void Function(int received, int? total)? onProgress,
  }) async {
    _cancelRequested = false;
    if (await dest.exists()) {
      if (expectedBytes != null && await dest.length() != expectedBytes) {
        await dest.delete();
      } else if (expectedSha256 != null &&
          await sha256OfFile(dest) != expectedSha256) {
        await dest.delete();
      } else {
        onProgress?.call(await dest.length(), expectedBytes);
        return dest;
      }
    }

    final part = File('${dest.path}.part');
    var downloaded = await part.exists() ? await part.length() : 0;
    if (expectedBytes != null && downloaded > expectedBytes) {
      // ‎.part أطول من المتوقع = تالف.
      await part.delete();
      downloaded = 0;
    }

    final client = HttpClient();
    _client = client;
    try {
      // محاولتان كحد أقصى: الأولى بـ Range (للاستئناف)، والثانية من
      // الصفر إن تجاهل الخادم Range وأعاد 200 فوق ‎.part موجود.
      var attempts = 0;
      while (true) {
        attempts++;
        if (_cancelRequested) {
          throw const _Cancelled();
        }
        final req = await client.getUrl(url);
        if (downloaded > 0) {
          req.headers.set('Range', 'bytes=$downloaded-');
        }
        final res = await req.close();
        if (downloaded > 0 && res.statusCode == HttpStatus.ok) {
          // الخادم تجاهل Range: لا يُلحق فوق ‎.part، يُعاد من الصفر.
          await res.drain<void>();
          if (attempts >= 2) {
            throw SpeechEngineException(
                'الخادم تجاهل الاستئناف (Range) مرتين لـ $url');
          }
          await part.delete();
          downloaded = 0;
          continue;
        }
        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          // 416: ‎.part مكتمل فعلاً — يُتحقق منه أدناه.
          await res.drain<void>();
          break;
        }
        if (res.statusCode != HttpStatus.ok &&
            res.statusCode != HttpStatus.partialContent) {
          await res.drain<void>();
          throw SpeechEngineException(
              'فشل التنزيل: HTTP ${res.statusCode} لـ $url');
        }
        final total = expectedBytes ??
            (res.contentLength >= 0
                ? downloaded + res.contentLength
                : null);
        final sink = part.openWrite(mode: FileMode.append);
        try {
          await for (final chunk in res) {
            if (_cancelRequested) throw const _Cancelled();
            sink.add(chunk);
            downloaded += chunk.length;
            onProgress?.call(downloaded, total);
          }
        } finally {
          await sink.close();
        }
        break;
      }
    } on _Cancelled {
      // الإلغاء ليس فشلاً: يُبقي ‎.part للاستئناف، ولا يحذف شيئاً.
      throw SpeechEngineException('أُلغي التنزيل', reason: 'cancelled');
    } catch (_) {
      // إغلاق العميل قسراً عند الإلغاء يجعل التيار يرمي HttpException
      // قبل أن يصل فحص _cancelRequested — أي خطأ أثناء إلغاء مطلوب
      // هو إلغاء لا فشل.
      if (_cancelRequested) {
        throw SpeechEngineException('أُلغي التنزيل', reason: 'cancelled');
      }
      rethrow;
    } finally {
      if (identical(_client, client)) _client = null;
      client.close();
    }

    if (_cancelRequested) {
      throw SpeechEngineException('أُلغي التنزيل', reason: 'cancelled');
    }
    if (expectedBytes != null && downloaded != expectedBytes) {
      await part.delete();
      throw SpeechEngineException(
          'حجم التنزيل لا يطابق ($downloaded ≠ $expectedBytes)');
    }
    if (expectedSha256 != null && await sha256OfFile(part) != expectedSha256) {
      await part.delete();
      throw SpeechEngineException('بصمة SHA-256 لا تطابق بعد التنزيل');
    }
    await part.rename(dest.path);
    return dest;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
