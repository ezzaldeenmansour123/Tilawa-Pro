#!/usr/bin/env python3
"""Download تلاوة برو assets with SHA-256 verification.

Downloads, into --out (default assets/models):
  - model-lite.onnx (24,650,054 bytes) or model-full.onnx (67,759,744 bytes)
  - manifest-lite.json / manifest-full.json (the per-model manifest;
    loadNodeModel(dir) reads dir/manifest.json, so the Node smoke test
    needs it next to the .onnx file)
  - ref-v2.json (reference; pinned SHA-256 since Phase 2 — downloaded
    2026-11-25 from https://tilawa.dev/v1/reference/ref-v2.json, 6236
    ayahs; verified by size + SHA + ayah count)
  - onnxruntime-web <version> WASM files (from the jsDelivr CDN mirror of
    the npm package; the app must not depend on tilawa.dev at runtime)
    — pinned size + SHA-256 since Phase 2, verified in --check-only and
    on every download (a cached file is never trusted blindly any more)

Hashes/sizes are from docs/model-card.md in yazinsai/tilawa, re-verified
2026-11-25 against the live registry and the downloaded files:
  lite sha256 4974de78d3c35d2542e7a24d99b747e1160d6e31e366fb68492b74a789890f1b
  full sha256 714e98addee73b1b8781ad7d99b6d3c745acd9116638baf4e12891f53a15af1b
  ref-v2.json: 4,749,281 bytes,
    sha256 f236384ea91e81ad554ba2777bc4073c3ff41e34120343a8a474571c577b7727
  ort-wasm-simd-threaded.jsep.mjs: 46,851 bytes,
    sha256 709853412fd1ffc34247af1e73569227b5b79629c5ca3f59cc39cf7e500e4947
  ort-wasm-simd-threaded.jsep.wasm: 28,312,028 bytes,
    sha256 3ad23231b5bd6d9dda55a7f84606315e0bf35b6750c28ee993c987c54cacab0f
  (JSEP pins verified 2026-11-26 against the jsDelivr source itself:
  downloaded from cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/
  and SHA-256-compared with the vendored node_modules copy —
  byte-identical. The pre-2026-11-26 non-JSEP pins are RETIRED: the
  1.30.0 "all" build NEVER requests those files, so they were replaced,
  not kept alongside.)

Usage:
  python3 tools/download_assets.py --tier lite --out assets/models
  python3 tools/download_assets.py --tier full --out assets/models
  python3 tools/download_assets.py --check-only --tier lite --out assets/models

Exit code 0 = all present and verified. Any mismatch aborts loudly.
"""

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

BASE = "https://tilawa.dev/v1"
MODELS = {
    "lite": {
        "id": "spliced-clean-lite",
        "version": "1-int8",
        "bytes": 24650054,
        "sha256": "4974de78d3c35d2542e7a24d99b747e1160d6e31e366fb68492b74a789890f1b",
        # Per-model manifest (models/<id>/<version>/manifest.json) — the
        # file loadNodeModel(dir) reads as dir/manifest.json, then loads
        # dir/<manifest.file>. Verified 2026-11-25 against the live
        # https://tilawa.dev/v1/manifest.json file list.
        "manifest_bytes": 8534,
        "manifest_sha256": "3f77f6368421a13ba8b0ca8e1610bd4a84ef3ac7407965d5c3cb9e322479cb30",
    },
    "full": {
        "id": "spliced-clean",
        "version": "1-int8",
        "bytes": 67759744,
        "sha256": "714e98addee73b1b8781ad7d99b6d3c745acd9116638baf4e12891f53a15af1b",
        "manifest_bytes": 11045,
        "manifest_sha256": "eb017b76cdca4261451ef5071acc637b57c5b62ed7ddb36f5daca1a2fc08d2b1",
    },
}
ORT_VERSION = "1.30.0"  # must match web/package.json + lib/model_manager.dart
# onnxruntime-web files needed by the bundle. CORRECTED 2026-11-26
# (pro-build-28 forensics): the 1.30.0 "all" build loads ONLY the JSEP
# pair — wasm-utils-import.ts:284 hardcodes
# 'ort-wasm-simd-threaded.jsep.mjs' — so the old non-JSEP list passed
# every check while the loader 404'd on the phone. The non-JSEP pair is
# REPLACED, not kept: this build never requests it (0 occurrences in
# assets/web/bundle.js). Pins verified 2026-11-26 against the jsDelivr
# source itself (byte-identical to the vendored node_modules copy).
# Keep in sync with lib/model_manager.dart (kOrtWasmAssets — same names,
# sizes and hashes, pinned 2026-11-26 from the jsDelivr URLs below).
ORT_WASM_FILES = [
    "ort-wasm-simd-threaded.jsep.mjs",
    "ort-wasm-simd-threaded.jsep.wasm",
]
ORT_WASM = {
    "ort-wasm-simd-threaded.jsep.mjs": {
        "bytes": 46851,
        "sha256": "709853412fd1ffc34247af1e73569227b5b79629c5ca3f59cc39cf7e500e4947",
    },
    "ort-wasm-simd-threaded.jsep.wasm": {
        "bytes": 28312028,
        "sha256": "3ad23231b5bd6d9dda55a7f84606315e0bf35b6750c28ee993c987c54cacab0f",
    },
}
# Reference identity, pinned 2026-11-25 (Phase 2, 2.5) from the same URL
# the app downloads from. Keep in sync with lib/model_manager.dart
# (kReferenceBytes / kReferenceSha256).
REF_BYTES = 4749281
REF_SHA256 = "f236384ea91e81ad554ba2777bc4073c3ff41e34120343a8a474571c577b7727"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: Path) -> None:
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    req = urllib.request.Request(url, headers={"User-Agent": "tilawa-pro/1.0"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as fh:
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            fh.write(chunk)
    tmp.replace(dest)


def check_model(out: Path, tier: str) -> bool:
    spec = MODELS[tier]
    dest = out / f"model-{tier}.onnx"
    if not dest.exists():
        print(f"MISSING {dest}")
        return False
    size = dest.stat().st_size
    if size != spec["bytes"]:
        print(f"SIZE MISMATCH {dest}: {size} != {spec['bytes']}")
        return False
    digest = sha256_of(dest)
    if digest != spec["sha256"]:
        print(f"SHA MISMATCH {dest}: {digest} != {spec['sha256']}")
        return False
    print(f"OK {dest} ({size} bytes, sha256 {digest[:12]}...)")
    return True


def check_manifest(out: Path, tier: str) -> bool:
    spec = MODELS[tier]
    dest = out / f"manifest-{tier}.json"
    if not dest.exists():
        print(f"MISSING {dest}")
        return False
    size = dest.stat().st_size
    if size != spec["manifest_bytes"]:
        print(f"SIZE MISMATCH {dest}: {size} != {spec['manifest_bytes']}")
        return False
    digest = sha256_of(dest)
    if digest != spec["manifest_sha256"]:
        print(f"SHA MISMATCH {dest}: {digest} != {spec['manifest_sha256']}")
        return False
    data = json.loads(dest.read_text(encoding="utf-8"))
    if data.get("file") != "model.onnx" or data.get("id") != spec["id"]:
        print(f"MANIFEST CONTENT MISMATCH {dest}: "
              f"id={data.get('id')} file={data.get('file')}")
        return False
    print(f"OK {dest} ({size} bytes, sha256 {digest[:12]}..., "
          f"id={data['id']}, file={data['file']})")
    return True


def check_reference(out: Path) -> bool:
    dest = out / "ref-v2.json"
    if not dest.exists():
        print(f"MISSING {dest}")
        return False
    size = dest.stat().st_size
    if size != REF_BYTES:
        print(f"SIZE MISMATCH {dest}: {size} != {REF_BYTES}")
        return False
    digest = sha256_of(dest)
    if digest != REF_SHA256:
        print(f"SHA MISMATCH {dest}: {digest} != {REF_SHA256}")
        return False
    data = json.loads(dest.read_text(encoding="utf-8"))
    ayahs = data.get("ayahs", [])
    if len(ayahs) != 6236:
        print(f"REF COUNT MISMATCH: {len(ayahs)} != 6236")
        return False
    print(f"OK {dest} ({size} bytes, sha256 {digest[:12]}..., 6236 ayahs)")
    return True


def check_wasm_file(out: Path, name: str) -> bool:
    """Verify one WASM file by pinned size + SHA-256."""
    spec = ORT_WASM[name]
    dest = out / "ort" / ORT_VERSION / name
    if not dest.exists():
        print(f"MISSING {dest}")
        return False
    size = dest.stat().st_size
    if size != spec["bytes"]:
        print(f"SIZE MISMATCH {dest}: {size} != {spec['bytes']}")
        return False
    digest = sha256_of(dest)
    if digest != spec["sha256"]:
        print(f"SHA MISMATCH {dest}: {digest} != {spec['sha256']}")
        return False
    print(f"OK {dest} ({size} bytes, sha256 {digest[:12]}...)")
    return True


def check_wasm(out: Path) -> bool:
    """Verify both WASM files by pinned size + SHA-256 (Phase 2, 2.5).

    --check-only used to skip WASM entirely, and the download path
    trusted any cached file with «OK (cached)» — a corrupt WASM then
    survived every check and failed only on the phone at load time.
    """
    return all(check_wasm_file(out, name) for name in ORT_WASM_FILES)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", choices=["lite", "full"], default="lite")
    ap.add_argument("--out", default="assets/models")
    ap.add_argument("--check-only", action="store_true")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    spec = MODELS[args.tier]

    if args.check_only:
        ok = (check_model(out, args.tier)
              and check_manifest(out, args.tier)
              and check_reference(out)
              and check_wasm(out))
        return 0 if ok else 1

    dest = out / f"model-{args.tier}.onnx"
    if not (dest.exists() and check_model(out, args.tier)):
        url = f"{BASE}/models/{spec['id']}/{spec['version']}/model.onnx"
        print(f"Downloading {url} ...")
        download(url, dest)
        if not check_model(out, args.tier):
            return 1

    manifest = out / f"manifest-{args.tier}.json"
    if not (manifest.exists() and check_manifest(out, args.tier)):
        url = f"{BASE}/models/{spec['id']}/{spec['version']}/manifest.json"
        print(f"Downloading {url} ...")
        download(url, manifest)
        if not check_manifest(out, args.tier):
            return 1

    ref = out / "ref-v2.json"
    if not (ref.exists() and check_reference(out)):
        print(f"Downloading {BASE}/reference/ref-v2.json ...")
        download(f"{BASE}/reference/ref-v2.json", ref)
    if not check_reference(out):
        return 1

    ort_dir = out / "ort" / ORT_VERSION
    ort_dir.mkdir(parents=True, exist_ok=True)
    for name in ORT_WASM_FILES:
        target = ort_dir / name
        if target.exists():
            if check_wasm_file(out, name):
                # Cached file trusted only when size + SHA match —
                # never blind «OK (cached)» (Phase 2, 2.5).
                continue
            # Present but corrupt: drop it and re-download below.
            print(f"RE-DOWNLOADING corrupt cached {target}")
            target.unlink()
        url = (
            f"https://cdn.jsdelivr.net/npm/onnxruntime-web@{ORT_VERSION}"
            f"/dist/{name}"
        )
        print(f"Downloading {url} ...")
        try:
            download(url, target)
            if not check_wasm_file(out, name):
                return 1
        except Exception as exc:  # noqa: BLE001 - fail the build loudly
            # A missing WASM file MUST fail CI: the old WARN-only behaviour
            # let the poc-9 404 (ort-wasm-simd.wasm does not exist in
            # onnxruntime-web 1.30.0) slip through to the user's phone.
            print(f"ERROR: could not download {name}: {exc}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
