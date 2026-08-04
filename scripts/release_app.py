#!/usr/bin/env python3
"""AkvaLink companion-app build helper — *build* the Flutter app for testing.

Builds an unsigned Windows app + a sideloadable Android APK from
app_flutter/, stamped with the *current* firmware version (version.txt) —
the firmware release decides the version, this script never bumps or
commits anything.

Kept fully separate from scripts/release.py: the app is lower priority and
must never block or complicate a firmware release.

    release_app.py  =>  build locally   (flutter build -> dist_app/)
    publish_app.py  =>  ship remotely   (attach to the existing GitHub release)

Examples
--------
    py -3 scripts/release_app.py --dry-run
    py -3 scripts/release_app.py                  # APK + Windows zip
    py -3 scripts/release_app.py --targets apk     # just the APK
    py -3 scripts/release_app.py --skip-tests

Requires: a working Flutter SDK on PATH (`flutter doctor`). The Windows
target only builds on Windows; the APK needs the Android toolchain.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
APP_DIR = REPO_ROOT / "app_flutter"
DIST_APP_DIR = REPO_ROOT / "dist_app"

APK_SRC = APP_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
WINDOWS_RELEASE_DIR = APP_DIR / "build" / "windows" / "x64" / "runner" / "Release"

ALL_TARGETS = ("apk", "windows")


# ---- pure helpers -----------------------------------------------------------

def build_number(version: str) -> int:
    """MAJOR.MINOR.PATCH -> a monotonically increasing Android versionCode."""
    parts = version.strip().split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise ValueError(f"not a MAJOR.MINOR.PATCH version: {version!r}")
    major, minor, patch = (int(p) for p in parts)
    return major * 10_000 + minor * 100 + patch


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def apk_asset_name(version: str) -> str:
    return f"akvalink-app-android-v{version}.apk"


def windows_asset_name(version: str) -> str:
    # "-unsigned" stays in the filename: no code-signing cert, Windows
    # SmartScreen will warn on first run. Don't hide that.
    return f"akvalink-app-windows-v{version}-unsigned.zip"


# ---- process helpers --------------------------------------------------------

def _flutter_cmd(args: list[str]) -> list[str]:
    # flutter is a .bat on Windows; run it through cmd so subprocess finds it.
    if os.name == "nt":
        return ["cmd", "/c", "flutter", *args]
    return ["flutter", *args]


def _run(cmd: list[str], dry_run: bool, cwd: Path = APP_DIR) -> None:
    print(f"    $ {' '.join(cmd)}")
    if dry_run:
        return
    result = subprocess.run(cmd, cwd=cwd, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed ({result.returncode}): {' '.join(cmd)}")


def _stage(src: Path, dst: Path, dry_run: bool) -> None:
    print(f"\u2022 package: dist_app/{dst.name}")
    if dry_run:
        return
    if not src.is_file():
        print(f"    (no {src} \u2014 skipping)")
        return
    shutil.copyfile(src, dst)
    digest = sha256_file(dst)
    Path(str(dst) + ".sha256").write_text(f"{digest}  {dst.name}\n", encoding="utf-8")


def _zip_dir(src_dir: Path, dst_zip: Path, dry_run: bool) -> None:
    print(f"\u2022 package: dist_app/{dst_zip.name}")
    if dry_run:
        return
    if not src_dir.is_dir():
        print(f"    (no {src_dir} \u2014 skipping)")
        return
    base_name = str(dst_zip)[: -len(".zip")]
    shutil.make_archive(base_name, "zip", root_dir=str(src_dir))
    digest = sha256_file(dst_zip)
    Path(str(dst_zip) + ".sha256").write_text(f"{digest}  {dst_zip.name}\n", encoding="utf-8")


# ---- pipeline ----------------------------------------------------------------

def build_apk(version: str, code: int, dry_run: bool) -> None:
    print("\u2022 build: Android APK")
    _run(_flutter_cmd(["build", "apk", "--release",
                       f"--build-name={version}", f"--build-number={code}"]), dry_run)
    _stage(APK_SRC, DIST_APP_DIR / apk_asset_name(version), dry_run)


def build_windows(version: str, code: int, dry_run: bool) -> None:
    if os.name != "nt":
        print("\u2022 build: Windows \u2014 skipped (only builds on a Windows host)")
        return
    print("\u2022 build: Windows (unsigned)")
    _run(_flutter_cmd(["build", "windows", "--release",
                       f"--build-name={version}", f"--build-number={code}"]), dry_run)
    _zip_dir(WINDOWS_RELEASE_DIR, DIST_APP_DIR / windows_asset_name(version), dry_run)


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Build the AkvaLink companion app for testing.")
    p.add_argument("--targets", default=",".join(ALL_TARGETS),
                   help="comma-separated: apk,windows (default: both)")
    p.add_argument("--skip-tests", action="store_true", help="skip `flutter test`")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = p.parse_args(argv)

    targets = [t.strip() for t in args.targets.split(",") if t.strip()]
    unknown = [t for t in targets if t not in ALL_TARGETS]
    if unknown:
        raise SystemExit(f"unknown target(s): {', '.join(unknown)} (choose from {', '.join(ALL_TARGETS)})")

    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    code = build_number(version)

    print(f"AkvaLink app build: v{version} (Android versionCode {code})")
    print(f"Targets: {', '.join(targets)}")
    if args.dry_run:
        print("[dry-run] no changes will be made.\n")

    if args.skip_tests:
        print("\u2022 tests: skipped")
    else:
        print("\u2022 tests: flutter test")
        _run(_flutter_cmd(["test"]), args.dry_run)

    DIST_APP_DIR.mkdir(exist_ok=True)
    if "apk" in targets:
        build_apk(version, code, args.dry_run)
    if "windows" in targets:
        build_windows(version, code, args.dry_run)

    print(f"\nBuilt v{version} \u2714  (artifacts in dist_app/)")
    print("Attach it to the firmware's GitHub release with:")
    print("    py -3 scripts/publish_app.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
