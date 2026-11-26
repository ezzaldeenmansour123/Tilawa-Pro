// Unit tests for the WebView microphone permission rule (2026-11-26).
//
// The pro-build-34 phone test proved the app-level RECORD_AUDIO
// permission is NOT enough: the page's getUserMedia is denied inside
// the WebView unless Dart grants the WebChromeClient PermissionRequest.
// The rule: grant exactly the microphone and nothing else.

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tilawa_pro/features/recitation/webview_engine.dart';

void main() {
  group('shouldGrantMicPermission', () {
    test('grants exactly the microphone', () {
      expect(
        shouldGrantMicPermission({WebViewPermissionResourceType.microphone}),
        isTrue,
      );
    });

    test('denies an empty request', () {
      expect(shouldGrantMicPermission({}), isFalse);
    });

    test('denies the camera', () {
      expect(
        shouldGrantMicPermission({WebViewPermissionResourceType.camera}),
        isFalse,
      );
    });

    test('denies the microphone bundled with anything else', () {
      expect(
        shouldGrantMicPermission({
          WebViewPermissionResourceType.microphone,
          WebViewPermissionResourceType.camera,
        }),
        isFalse,
      );
    });
  });
}
