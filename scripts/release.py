#!/usr/bin/env python3
"""AkvaLink release helper — *prepare* a release (local only).

Pipeline: preflight -> test (pytest) -> bump version -> build ALL variants
(thread, wifi, ble, ap, station) into their own dirs -> merge each into a single
0x0-flashable image in dist/ -> commit + tag.

This script stops at the tag: it does not touch GitHub. Shipping (push, GitHub
release, asset upload) is the job of scripts/publish.py. So:

    release.py  =>  prepare locally  (bump + build + tag + dist/)
    publish.py  =>  ship remotely    (push tag + GitHub release from dist/)

`version.txt` at the repo root is the single source of truth for the version.
ESP-IDF automatically embeds it as the firmware `PROJECT_VER`, so a bump here
flows into every built image and what the device reports over Matter.

Examples
--------
    py -3 scripts/release.py --bump patch --dry-run     # show the plan
    py -3 scripts/release.py --bump minor               # 0.1.0 -> 0.2.0
    py -3 scripts/release.py --set 1.0.0 --skip-build   # explicit version

Safety
------
- Refuses to run on a dirty tree or off the main branch (override with flags).
- `--dry-run` prints every command without changing anything.
- Rolls back the version bump if a build fails.

Requires: git and esptool. The build step uses the WSL launcher on Windows and
scripts/build.sh elsewhere.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
BUILD_DIR = REPO_ROOT / "build"
FIRMWARE_BIN = BUILD_DIR / "akvalink.bin"
FLASHER_ARGS = BUILD_DIR / "flasher_args.json"
DIST_DIR = REPO_ROOT / "dist"

# The variants built + packaged for every release.
# thread/wifi/ble/espnow are battery-powered.
# ap and station need mains/USB (captive web page / LAN page).
# esphome uses its own build system (ESPHome YAML, not ESP-IDF directly).
VARIANTS = ("thread", "wifi", "ble", "ap", "station", "espnow", "esphome")

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


# ---- pure helpers (unit-tested) --------------------------------------------

def parse_version(value: str) -> tuple[int, int, int]:
    m = SEMVER_RE.match(value.strip())
    if not m:
        raise ValueError(f"not a MAJOR.MINOR.PATCH version: {value!r}")
    return tuple(int(x) for x in m.groups())  # type: ignore[return-value]


def bump_version(current: str, part: str) -> str:
    major, minor, patch = parse_version(current)
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ValueError(f"unknown bump part: {part!r}")


def format_release_notes(version: str, subjects: list[str], prev_tag: str | None) -> str:
    lines = [f"# AkvaLink v{version}", ""]
    lines.append(f"Changes since {prev_tag}:" if prev_tag else "Initial release.")
    lines.append("")
    if subjects:
        lines.extend(f"- {s}" for s in subjects)
    else:
        lines.append("- (no changes recorded)")
    return "\n".join(lines) + "\n"


def esptool_merge_cmd(python: str, chip: str, settings: dict, flash_files: dict, out_path) -> list[str]:
    """Build the `esptool merge-bin` argv from flasher_args.json data.

    Offsets are emitted in ascending numeric order so the merged image is laid
    out correctly regardless of dict ordering.
    """
    cmd = [
        python, "-m", "esptool", "--chip", chip, "merge-bin",
        "-o", str(out_path),
        "--flash-mode", settings["flash_mode"],
        "--flash-freq", settings["flash_freq"],
        "--flash-size", settings["flash_size"],
    ]
    for offset, rel in sorted(flash_files.items(), key=lambda kv: int(kv[0], 16)):
        cmd += [offset, str(BUILD_DIR / rel)]
    return cmd


def flash_instructions(version: str, variant: str, sha256: str) -> str:
    name = f"akvalink-{variant}-v{version}.bin"
    return (
        "## Flash it (no build needed)\n\n"
        f"Prebuilt **{variant}** firmware for the u-blox NORA-W40 (ESP32-C6) — a\n"
        "single merged image. Flash to offset `0x0` with esptool "
        "(`pip install esptool`):\n\n"
        f"```\nesptool --chip esp32c6 write-flash 0x0 {name}\n```\n\n"
        f"**SHA256** (`{name}`):\n`{sha256}`\n"
    )


# ---- process helpers -------------------------------------------------------

def _query(cmd: list[str]) -> str:
    """Run a read-only command and return stdout (always runs, even in dry-run)."""
    return subprocess.run(
        cmd, cwd=REPO_ROOT, text=True, capture_output=True, check=False
    ).stdout.strip()


def _run(cmd: list[str], dry_run: bool) -> None:
    """Run a mutating command, honouring dry-run."""
    print(f"    $ {' '.join(cmd)}")
    if dry_run:
        return
    result = subprocess.run(cmd, cwd=REPO_ROOT, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed ({result.returncode}): {' '.join(cmd)}")


def _build_cmd(variant: str) -> list[str]:
    if variant == "esphome":
        # ESPHome uses its own build system (not ESP-IDF / akvalink.cmd)
        if os.name == "nt":
            drive = REPO_ROOT.drive[0].lower()
            rest = REPO_ROOT.as_posix()[3:]  # strip "E:/"
            wsl_root = f"/mnt/{drive}/{rest}"
            return ["cmd", "/c", "wsl", "bash", "-lc",
                    f"cd {wsl_root} && ~/.local/bin/esphome compile esphome/akvalink.yaml"]
        return ["bash", "-c",
                f"cd '{REPO_ROOT}' && esphome compile esphome/akvalink.yaml"]
    FLAG = {"wifi": "--wifi", "ble": "--ble", "ap": "--ap", "station": "--station", "espnow": "--espnow"}
    if os.name == "nt":
        cmd = ["cmd", "/c", str(REPO_ROOT / "akvalink.cmd")]
        flag = FLAG.get(variant)
        if flag:
            cmd.append(flag)
        cmd.append("--rebuild")
        return cmd
    cmd = ["bash", str(REPO_ROOT / "scripts" / "build.sh"), "build"]
    flag = FLAG.get(variant)
    if flag:
        cmd.append(flag)
    return cmd


def _update_esphome_version(version: str) -> None:
    """Patch the project.version string in esphome/akvalink.yaml."""
    yaml_path = REPO_ROOT / "esphome" / "akvalink.yaml"
    txt = yaml_path.read_text(encoding="utf-8")
    txt = re.sub(
        r"(name: stenmo\.akvalink\n\s+version:\s*\")[^\"]*\"",
        rf'\g<1>{version}"',
        txt,
    )
    yaml_path.write_text(txt, encoding="utf-8")


def _stage_esphome(version: str, dry_run: bool) -> None:
    """Copy ESPHome factory.bin (merged, 0x0-flashable) and ota.bin to dist/."""
    pio = (REPO_ROOT / "esphome" / ".esphome" / "build" / "akvalink"
           / ".pioenvs" / "akvalink")
    for src, dst_name in [
        (pio / "firmware.factory.bin", f"akvalink-esphome-v{version}.bin"),
        (pio / "firmware.ota.bin",     f"akvalink-esphome-app-v{version}.bin"),
    ]:
        dst = DIST_DIR / dst_name
        print(f"\u2022 package: dist/{dst_name}")
        if dry_run:
            continue
        if not src.is_file():
            print(f"    (no {src} \u2014 skipping)")
            continue
        shutil.copyfile(src, dst)
        digest = sha256_file(dst)
        Path(str(dst) + ".sha256").write_text(f"{digest}  {dst.name}\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def merge_firmware(version: str, variant: str, dry_run: bool, out_dir=None):
    """Merge bootloader + partition table + otadata + app into one image
    flashable at 0x0. Inputs come from BUILD_DIR (the variant's build dir); the
    merged image + sidecar are written to out_dir (defaults to BUILD_DIR).
    Returns (image, sha256_sidecar, sha256_hex) or None."""
    if not FLASHER_ARGS.is_file():
        print(f"    (no {FLASHER_ARGS} — skipping merged image)")
        return None
    data = json.loads(FLASHER_ARGS.read_text(encoding="utf-8"))
    chip = data.get("extra_esptool_args", {}).get("chip", "esp32c6")
    out = (out_dir or BUILD_DIR) / f"akvalink-{variant}-v{version}.bin"
    _run(esptool_merge_cmd(sys.executable, chip, data["flash_settings"],
                           data["flash_files"], out), dry_run)
    sha_path = Path(str(out) + ".sha256")
    if dry_run:
        return (out, sha_path, "<sha256>")
    digest = sha256_file(out)
    sha_path.write_text(f"{digest}  {out.name}\n", encoding="utf-8")
    return (out, sha_path, digest)


def app_image_name(variant: str, version: str) -> str:
    """The bare app-partition image name (the OTA payload — flashed to the app
    slot only, NOT the merged 0x0 image)."""
    return f"akvalink-{variant}-app-v{version}.bin"


def stage_app_image(variant: str, version: str, dry_run: bool):
    """Copy build/<variant>/akvalink.bin -> dist/akvalink-<variant>-app-v<ver>.bin
    (+ sha256). This bare app image is what BLE / Matter OTA flash (app slot),
    and what the web page's 'flash latest' streams over BLE."""
    dst = DIST_DIR / app_image_name(variant, version)
    print(f"• package: dist/{dst.name}")
    if dry_run:
        return None
    src = BUILD_DIR / "akvalink.bin"
    if not src.is_file():
        print(f"    (no {src} — skipping app image)")
        return None
    shutil.copyfile(src, dst)
    digest = sha256_file(dst)
    (DIST_DIR / (dst.name + ".sha256")).write_text(
        f"{digest}  {dst.name}\n", encoding="utf-8")
    return dst


# ---- pipeline --------------------------------------------------------------
def preflight(args) -> None:
    if not args.allow_dirty and _query(["git", "status", "--porcelain"]):
        raise SystemExit("working tree is dirty — commit/stash first (or --allow-dirty).")
    branch = _query(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    if not args.allow_branch and branch != "main":
        raise SystemExit(f"on branch {branch!r}, expected 'main' (or --allow-branch).")


def main(argv: list[str] | None = None) -> int:
    # Windows consoles default to cp1252 when stdout is piped, which cannot
    # encode status glyphs (•, ✔). Force UTF-8 so a redirected run never crashes.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Cut an AkvaLink release.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--bump", choices=["major", "minor", "patch"], help="bump part of the semver")
    g.add_argument("--set", dest="set_version", metavar="X.Y.Z", help="set an explicit version")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    p.add_argument("--skip-tests", action="store_true", help="skip the pytest run")
    p.add_argument("--skip-build", action="store_true", help="skip the firmware build")
    p.add_argument("--allow-dirty", action="store_true", help="allow a dirty working tree")
    p.add_argument("--allow-branch", action="store_true", help="allow running off main")
    args = p.parse_args(argv)

    current = VERSION_FILE.read_text(encoding="utf-8").strip()
    parse_version(current)  # validate
    new_version = args.set_version.strip() if args.set_version else bump_version(current, args.bump)
    parse_version(new_version)  # validate
    tag = f"v{new_version}"

    print(f"AkvaLink release: {current} -> {new_version}  (tag {tag})")
    print(f"Variants: {', '.join(VARIANTS)}")
    if args.dry_run:
        print("[dry-run] no changes will be made.\n")

    preflight(args)

    # 1. Tests
    if args.skip_tests:
        print("• tests: skipped")
    else:
        print("• tests: pytest")
        _run([sys.executable, "-m", "pytest", "-q"], args.dry_run)

    # 2. Bump version.txt (ESP-IDF embeds it as PROJECT_VER in every variant)
    print(f"• version: write {new_version} to version.txt")
    if not args.dry_run:
        VERSION_FILE.write_text(new_version + "\n", encoding="utf-8")

    # 3. Build every variant into its own dir, merge each into dist/.
    # (BUILD_DIR/FLASHER_ARGS are module globals so merge_firmware + the tests
    # can point at the current variant's build directory.)
    global BUILD_DIR, FIRMWARE_BIN, FLASHER_ARGS
    if args.skip_build:
        print("• build: skipped")
    else:
        DIST_DIR.mkdir(exist_ok=True)
        for variant in VARIANTS:
            BUILD_DIR = REPO_ROOT / "build" / variant
            FIRMWARE_BIN = BUILD_DIR / "akvalink.bin"
            FLASHER_ARGS = BUILD_DIR / "flasher_args.json"
            print(f"• build: {variant}")
            if variant == "esphome" and not args.dry_run:
                _update_esphome_version(new_version)
            try:
                _run(_build_cmd(variant), args.dry_run)
            except SystemExit:
                if not args.dry_run:  # roll back the version bump on build failure
                    _run(["git", "checkout", "--", str(VERSION_FILE)], dry_run=False)
                raise
            if variant == "esphome":
                _stage_esphome(new_version, args.dry_run)
            else:
                print(f"\u2022 package: dist/akvalink-{variant}-v{new_version}.bin")
                merge_firmware(new_version, variant, args.dry_run, out_dir=DIST_DIR)
                stage_app_image(variant, new_version, args.dry_run)

    # 4. Commit + tag
    print(f"• commit + tag {tag}")
    _run(["git", "add", str(VERSION_FILE),
          str(REPO_ROOT / "esphome" / "akvalink.yaml")], args.dry_run)
    _run(["git", "commit", "-m", f"release: {tag}"], args.dry_run)
    _run(["git", "tag", "-a", tag, "-m", f"AkvaLink {tag}"], args.dry_run)

    print(f"\nPrepared {tag} ✔  (artifacts in dist/)")
    print("Ship it to GitHub with:")
    print("    py -3 scripts/publish.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
