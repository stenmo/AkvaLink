#!/usr/bin/env python3
"""AquaLink release helper.

One command to cut a release: preflight -> test (pytest) -> bump version ->
build firmware -> commit + tag -> generate notes -> publish (GitHub release,
with the firmware image attached if present).

`version.txt` at the repo root is the single source of truth for the version.
ESP-IDF automatically embeds it as the firmware `PROJECT_VER`, so a bump here
flows into the built image and what the device reports over Matter.

Examples
--------
    py -3 scripts/release.py --bump patch --dry-run     # show the plan
    py -3 scripts/release.py --bump minor               # 0.1.0 -> 0.2.0
    py -3 scripts/release.py --set 1.0.0 --skip-build   # explicit version

Safety
------
- Refuses to run on a dirty tree or off the main branch (override with flags).
- `--dry-run` prints every command without changing anything.
- Prompts before the irreversible publish step unless `--yes` is given.

Requires: git, and (for publishing) the GitHub CLI `gh` authenticated to the
repo. The build step uses the WSL launcher on Windows and build.sh elsewhere.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
BUILD_DIR = REPO_ROOT / "build"
FIRMWARE_BIN = BUILD_DIR / "aqualink.bin"
FLASHER_ARGS = BUILD_DIR / "flasher_args.json"

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
    lines = [f"# AquaLink v{version}", ""]
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
    name = f"aqualink-{variant}-v{version}.bin"
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
    if os.name == "nt":
        cmd = ["cmd", "/c", str(REPO_ROOT / "launch-aqualink-wsl.cmd")]
        flag = {"wifi": "--wifi", "ble": "--ble-only"}.get(variant)
        if flag:
            cmd.append(flag)
        cmd.append("--rebuild")
        return cmd
    # build.sh builds the default (Thread) variant; extend when it grows a flag.
    return ["bash", str(REPO_ROOT / "build.sh")]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def merge_firmware(version: str, variant: str, dry_run: bool):
    """Merge bootloader + partition table + otadata + app into one image
    flashable at 0x0. Returns (image, sha256_sidecar, sha256_hex) or None."""
    if not FLASHER_ARGS.is_file():
        print("    (no build/flasher_args.json — skipping merged image)")
        return None
    data = json.loads(FLASHER_ARGS.read_text(encoding="utf-8"))
    chip = data.get("extra_esptool_args", {}).get("chip", "esp32c6")
    out = BUILD_DIR / f"aqualink-{variant}-v{version}.bin"
    _run(esptool_merge_cmd(sys.executable, chip, data["flash_settings"],
                           data["flash_files"], out), dry_run)
    sha_path = Path(str(out) + ".sha256")
    if dry_run:
        return (out, sha_path, "<sha256>")
    digest = sha256_file(out)
    sha_path.write_text(f"{digest}  {out.name}\n", encoding="utf-8")
    return (out, sha_path, digest)


def _confirm(prompt: str) -> bool:
    try:
        return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
    except EOFError:
        return False


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

    p = argparse.ArgumentParser(description="Cut an AquaLink release.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--bump", choices=["major", "minor", "patch"], help="bump part of the semver")
    g.add_argument("--set", dest="set_version", metavar="X.Y.Z", help="set an explicit version")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    p.add_argument("--skip-tests", action="store_true", help="skip the pytest run")
    p.add_argument("--skip-build", action="store_true", help="skip the firmware build")
    p.add_argument("--no-publish", action="store_true", help="commit + tag but do not push/publish")
    p.add_argument("--yes", action="store_true", help="do not prompt before publishing")
    p.add_argument("--allow-dirty", action="store_true", help="allow a dirty working tree")
    p.add_argument("--allow-branch", action="store_true", help="allow running off main")
    p.add_argument("--variant", choices=["thread", "wifi", "ble"], default="thread",
                   help="firmware variant to build + name the image (default: thread)")
    args = p.parse_args(argv)

    current = VERSION_FILE.read_text(encoding="utf-8").strip()
    parse_version(current)  # validate
    new_version = args.set_version.strip() if args.set_version else bump_version(current, args.bump)
    parse_version(new_version)  # validate
    tag = f"v{new_version}"
    prev_tag = _query(["git", "describe", "--tags", "--abbrev=0"]) or None

    print(f"AquaLink release: {current} -> {new_version}  (tag {tag})")
    if prev_tag:
        print(f"Previous tag: {prev_tag}")
    if args.dry_run:
        print("[dry-run] no changes will be made.\n")

    preflight(args)

    # 1. Tests
    if args.skip_tests:
        print("• tests: skipped")
    else:
        print("• tests: pytest")
        _run([sys.executable, "-m", "pytest", "-q"], args.dry_run)

    # 2. Bump version.txt
    print(f"• version: write {new_version} to version.txt")
    if not args.dry_run:
        VERSION_FILE.write_text(new_version + "\n", encoding="utf-8")

    # 3. Build
    merged = None
    if args.skip_build:
        print("• build: skipped")
    else:
        print(f"• build: firmware ({args.variant})")
        try:
            _run(_build_cmd(args.variant), args.dry_run)
        except SystemExit:
            if not args.dry_run:  # roll back the version bump on build failure
                _run(["git", "checkout", "--", str(VERSION_FILE)], dry_run=False)
            raise
        print("• package: merged flashable image")
        merged = merge_firmware(new_version, args.variant, args.dry_run)

    # 4. Commit + tag
    print(f"• commit + tag {tag}")
    _run(["git", "add", str(VERSION_FILE)], args.dry_run)
    _run(["git", "commit", "-m", f"release: {tag}"], args.dry_run)
    _run(["git", "tag", "-a", tag, "-m", f"AquaLink {tag}"], args.dry_run)

    # 5. Notes
    log_range = f"{prev_tag}..HEAD" if prev_tag else "HEAD"
    raw = _query(["git", "log", log_range, "--no-merges", "--pretty=format:%s"])
    subjects = [s for s in raw.splitlines() if s and not s.startswith("release:")]
    notes = format_release_notes(new_version, subjects, prev_tag)
    if merged:
        notes += "\n" + flash_instructions(new_version, args.variant, merged[2])
    print("• release notes:\n" + "\n".join("    " + line for line in notes.splitlines()))

    # 6. Publish
    if args.no_publish:
        print("• publish: skipped (--no-publish). Push + create the release manually when ready.")
        return 0
    if not args.dry_run and not args.yes and not _confirm(f"Publish {tag} to origin + GitHub?"):
        print("Aborted before publish. Commit + tag are local; undo with:")
        print(f"    git tag -d {tag} && git reset --hard HEAD~1")
        return 1

    _run(["git", "push", "origin", "HEAD"], args.dry_run)
    _run(["git", "push", "origin", tag], args.dry_run)

    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fh:
        fh.write(notes)
        notes_path = fh.name
    gh_cmd = ["gh", "release", "create", tag, "--title", f"AquaLink {tag}", "--notes-file", notes_path]
    assets = []
    if merged:
        assets += [str(merged[0]), str(merged[1])]
    if FIRMWARE_BIN.is_file():
        assets.append(str(FIRMWARE_BIN))
    for asset in assets:
        gh_cmd.append(asset)
        print(f"• attaching {Path(asset).name}")
    try:
        _run(gh_cmd, args.dry_run)
    finally:
        if not args.dry_run:
            os.unlink(notes_path)

    print(f"\nReleased {tag} ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
