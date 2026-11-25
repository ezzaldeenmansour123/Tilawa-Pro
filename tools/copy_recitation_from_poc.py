#!/usr/bin/env python3
"""Copy the Tilawa PoC (poc-13) smart-recitation engine into Tilawa Pro.

Source: ~/workspace/tilawa-poc/
Dest:   ~/workspace/tilawa-pro-full/lib/features/recitation/ (+ web/, assets/web/, tools/, test/)

Relative imports inside the PoC lib/ tree are preserved verbatim because the
whole subtree moves together (lib/*.dart -> features/recitation/*.dart,
lib/screens/*.dart -> features/recitation/screens/*.dart).

Adaptations (all mechanical string replacements, listed in REPLACEMENTS):
- storage dirs / ids: poc-progress -> recitation-progress, poc-logs ->
  recitation-logs, session id prefix poc- -> rec-
- JS bridge name: window.TilawaPoc -> window.TilawaPro (Dart + bridge.js +
  tilawa.html, kept in sync)
- user-visible "Tilawa PoC" -> "تلاوة برو"; "تبويب «النموذج»" -> "صفحة «النموذج»"
  (Pro has no tabs; ModelScreen/LogsScreen are pushed pages)
- test imports: package:tilawa_poc/... -> package:tilawa/features/recitation/...
- NO built bundle.js is copied (CI builds it from web/ — see report).
"""
import re
import shutil
from pathlib import Path

POC = Path.home() / "workspace" / "tilawa-poc"
PRO = Path.home() / "workspace" / "tilawa-pro-full"
FEAT = PRO / "lib" / "features" / "recitation"

ENGINE = [
    "model_manager.dart",
    "local_server.dart",
    "webview_engine.dart",
    "speech_engine.dart",
    "event_log.dart",
    "session_logic.dart",
    "progress_store.dart",
    "surah_names.dart",
    "models.dart",  # NOT in the task's file list, but speech_engine.dart and
    # session_logic.dart import it; Pro's lib/data/models.dart is a
    # different file (different path) so there is no clash.
]
SCREENS = [
    "recitation_screen.dart",
    "session_screen.dart",
    "results_screen.dart",
    "model_screen.dart",
    "logs_screen.dart",
]

# (old, new) replacements applied to every copied Dart/JS/HTML/Python file.
GLOBAL = [
    ("window.TilawaPoc", "window.TilawaPro"),
    ("[TilawaPoc]", "[TilawaPro]"),
    ("Tilawa PoC", "تلاوة برو"),
    ("poc-progress", "recitation-progress"),
    ("poc-logs", "recitation-logs"),
    ("'poc-", "'rec-"),
    ("tilawa-poc/0.1", "tilawa-pro/1.0"),
    ("tilawa-poc-web", "tilawa-pro-web"),
    ("Tilawa PoC assets", "Tilawa Pro recitation assets"),
    ("for the PoC recitation flow", "for the Pro recitation flow"),
    ("for the PoC speech engine", "for the Pro speech engine"),
    ("Shared value types for the PoC", "Shared value types for the Pro"),
    ("the PoC web directory", "the Pro web directory"),
    ("the PoC works fully offline", "the app works fully offline"),
    ("the PoC must not depend on tilawa.dev", "the app must not depend on tilawa.dev"),
    ("to the PoC's permission state", "to the app's permission state"),
    ("the PoC must record that", "the app must record that"),
    ("inside the PoC WebView", "inside the Pro app's WebView"),
    ("the PoC keeps the upstream default", "the app keeps the upstream default"),
    ("the PoC also needs the backend", "the app also needs the backend"),
    ("for the PoC web bridge", "for the Pro web bridge"),
    ("تبويب «النموذج»", "صفحة «النموذج»"),
    ("مساعد حفظ تجريبي", "مساعد حفظ"),
    ("Unit tests for the poc-13 session logic", "Unit tests for the Pro session logic (ported from Tilawa PoC poc-13)"),
    ("poc13-test-", "pro-recitation-test-"),
]

TEST_IMPORTS = [
    ("package:tilawa_poc/models.dart", "package:tilawa/features/recitation/models.dart"),
    ("package:tilawa_poc/progress_store.dart", "package:tilawa/features/recitation/progress_store.dart"),
    ("package:tilawa_poc/session_logic.dart", "package:tilawa/features/recitation/session_logic.dart"),
    ("package:tilawa_poc/speech_engine.dart", "package:tilawa/features/recitation/speech_engine.dart"),
]


def adapt(text: str, extra=()) -> str:
    for old, new in list(GLOBAL) + list(extra):
        text = text.replace(old, new)
    return text


def copy(src: Path, dst: Path, extra=()) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(adapt(src.read_text(encoding="utf-8"), extra), encoding="utf-8")
    print(f"copied {src.relative_to(POC)} -> {dst.relative_to(PRO)}")


def main() -> None:
    (FEAT / "screens").mkdir(parents=True, exist_ok=True)
    for name in ENGINE:
        copy(POC / "lib" / name, FEAT / name)
    for name in SCREENS:
        copy(POC / "lib" / "screens" / name, FEAT / "screens" / name)
    # Web bundle sources (NOT the built bundle.js — CI builds it).
    for rel in ["build.mjs", "package.json", "src/bridge.js"]:
        copy(POC / "web" / rel, PRO / "web" / rel)
    copy(POC / "assets" / "web" / "tilawa.html", PRO / "assets" / "web" / "tilawa.html")
    # CI smoke-test asset downloader, adapted to Pro paths (same layout).
    copy(POC / "tools" / "download_assets.py", PRO / "tools" / "download_assets.py")
    # Unit tests, with fixed imports.
    copy(POC / "test" / "session_logic_test.dart",
         PRO / "test" / "session_logic_test.dart", extra=TEST_IMPORTS)
    assert not (PRO / "assets" / "web" / "bundle.js").exists(), "bundle.js must not be committed"
    print("OK: no bundle.js present")


if __name__ == "__main__":
    main()
