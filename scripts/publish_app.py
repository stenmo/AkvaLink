#!/usr/bin/env python3
"""AkvaLink companion-app publish helper — attach app builds to an existing
GitHub release.

Uploads the dist_app/ artifacts (built by scripts/release_app.py) as extra
assets on the GitHub release scripts/publish.py already created for the
current firmware version. It never creates or edits the release itself —
only adds assets to it — so the app can never block or complicate shipping
firmware: ship the firmware first, attach the app whenever it's ready.

Reuses the GitHub API/auth plumbing from scripts/publish.py as a library
(no changes made to that file — it stays firmware-only).

    release_app.py  =>  build locally   (flutter build -> dist_app/)
    publish_app.py  =>  ship remotely   (attach to the existing GitHub release)

Examples
--------
    py -3 scripts/publish_app.py --dry-run
    py -3 scripts/publish_app.py
    py -3 scripts/publish_app.py --version 0.3.4

Requires: git and network access.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import publish  # scripts/publish.py — reused for GitHub auth/API helpers only

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
DIST_APP_DIR = REPO_ROOT / "dist_app"


def collect_assets(version: str) -> list[Path]:
    from release_app import apk_asset_name, windows_asset_name  # local import: avoid a hard Flutter dep at module load

    assets: list[Path] = []
    for name in (apk_asset_name(version), windows_asset_name(version)):
        image = DIST_APP_DIR / name
        if image.is_file():
            assets.append(image)
            sidecar = DIST_APP_DIR / (name + ".sha256")
            if sidecar.is_file():
                assets.append(sidecar)
    if not assets:
        raise SystemExit(
            f"no app artifacts in {DIST_APP_DIR} — run `py -3 scripts/release_app.py` first."
        )
    return assets


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Attach the AkvaLink app build to its GitHub release.")
    p.add_argument("--version", help="version to publish (default: version.txt)")
    p.add_argument("--tag", help="git tag of the existing release (default: v<version>)")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    p.add_argument("--yes", action="store_true", help="do not prompt before uploading")
    args = p.parse_args(argv)

    version = (args.version or VERSION_FILE.read_text(encoding="utf-8")).strip()
    tag = args.tag or f"v{version}"

    print(f"AkvaLink app publish: {tag}  (repo {publish.REPO_SLUG})")
    if args.dry_run:
        print("[dry-run] no changes will be made.\n")

    assets = collect_assets(version)
    for path in assets:
        print(f"\u2022 asset: dist_app/{path.name}")

    if not args.dry_run and not args.yes:
        try:
            if input(f"Attach these to release {tag} ({publish.REPO_SLUG})? [y/N] ").strip().lower() not in ("y", "yes"):
                print("Aborted. dist_app/ artifacts are ready.")
                return 1
        except EOFError:
            print("Non-interactive and no --yes; aborting.")
            return 1

    token = publish.github_token()
    if not token and not args.dry_run:
        raise SystemExit(
            "no GitHub token — set GITHUB_TOKEN or run `git push` once so Git "
            "Credential Manager caches a github.com credential."
        )

    if args.dry_run:
        print(f"\n[dry-run] would attach {len(assets)} asset(s) to release {tag}.")
        return 0

    release = publish.get_release(token, tag)
    if not release:
        raise SystemExit(
            f"release {tag} not found on {publish.REPO_SLUG} — publish the "
            f"firmware first with `py -3 scripts/publish.py`, or pass --tag."
        )

    for path in assets:
        print(f"\u2022 uploading {path.name}")
        publish.upload_asset(token, release, path)

    url = release.get("html_url", f"https://github.com/{publish.REPO_SLUG}/releases/tag/{tag}")
    print(f"\nAttached app build to {tag} \u2714  {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
