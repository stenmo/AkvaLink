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
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
FIRMWARE_BIN = REPO_ROOT / "build" / "aqualink.bin"

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


def _build_cmd() -> list[str]:
    if os.name == "nt":
        return ["cmd", "/c", str(REPO_ROOT / "launch-aqualink-wsl.cmd"), "--rebuild"]
    return ["bash", str(REPO_ROOT / "build.sh")]


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
    if args.skip_build:
        print("• build: skipped")
    else:
        print("• build: firmware")
        try:
            _run(_build_cmd(), args.dry_run)
        except SystemExit:
            if not args.dry_run:  # roll back the version bump on build failure
                _run(["git", "checkout", "--", str(VERSION_FILE)], dry_run=False)
            raise

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
    if FIRMWARE_BIN.is_file():
        gh_cmd.append(str(FIRMWARE_BIN))
        print(f"• attaching {FIRMWARE_BIN.name}")
    try:
        _run(gh_cmd, args.dry_run)
    finally:
        if not args.dry_run:
            os.unlink(notes_path)

    print(f"\nReleased {tag} ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
