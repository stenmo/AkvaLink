#!/usr/bin/env python3
"""AkvaLink publish helper — ship a GitHub release from the dist/ artifacts.

Takes the merged images that scripts/release.py produced in dist/ (one per
variant: thread, wifi, ble, ap, station), pushes the tag, then creates (or
updates) the GitHub release and uploads those images + their .sha256 sidecars
as assets.

Division of labour:
    scripts/release.py  --bump patch   # prepare: test, bump, build all, tag, dist/
    scripts/publish.py                 # ship: push tag + GitHub release from dist/

So release.py *prepares* locally; publish.py *ships* remotely. publish.py does
NOT build — run release.py first (it fills dist/).

Auth: reuses the GitHub token Git Credential Manager already stores for
github.com (the same one `git push` uses) — no `gh` CLI required. Override with
the GITHUB_TOKEN environment variable (handy for CI).

Examples
--------
    py -3 scripts/publish.py --dry-run   # show the plan, change nothing
    py -3 scripts/publish.py             # publish v<version.txt> from dist/
    py -3 scripts/publish.py --draft     # create the release as a draft

Requires: git and network access.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "version.txt"
DIST_DIR = REPO_ROOT / "dist"
REPO_SLUG = os.environ.get("AKVALINK_REPO", "stenmo/AkvaLink")
API = "https://api.github.com"

# The variants shipped as release assets (slug → human label).
VARIANTS = {
    "thread":  "Matter over Thread — battery-powered, longest life (Sleepy End Device)",
    "wifi":    "Matter over Wi-Fi — battery-powered, shorter life than Thread",
    "ble":     "Standalone BLE GATT — battery-powered, no hub, no Matter",
    "espnow":  "ESP-NOW broadcast — deep-sleep sensor for friends' ESP32 networks; no hub, no provisioning",
    "ap":      "Wi-Fi AP — open hotspot + captive page, any phone; needs mains/USB power",
    "station": "Wi-Fi station — BLE-provisioned, joins your Wi-Fi, page at akvalink.local; needs mains/USB",
    "esphome": "ESPHome / Home Assistant — native HA API, adopt-and-customize YAML, OTA from HA dashboard",
}


# ---- pure helpers (unit-tested) --------------------------------------------

def asset_name(variant: str, version: str) -> str:
    return f"akvalink-{variant}-v{version}.bin"


def app_image_name(variant: str, version: str) -> str:
    # Bare app-partition image — the OTA payload (BLE / Matter OTA + web 'flash latest').
    return f"akvalink-{variant}-app-v{version}.bin"


def clean_upload_url(upload_url: str, filename: str) -> str:
    """Turn GitHub's templated upload_url into a concrete asset-upload URL.

    The API hands back e.g.
        https://uploads.github.com/repos/O/R/releases/42/assets{?name,label}
    which we specialise with the asset filename.
    """
    base = upload_url.split("{", 1)[0]
    return f"{base}?name={urllib.parse.quote(filename)}"


def read_digest(path: Path) -> str:
    """Read the sha256 hex from a `<hex>  <name>` sidecar written by release.py."""
    if not path.is_file():
        return "<unknown>"
    return path.read_text(encoding="utf-8").split()[0]


def format_notes(version: str, digests: dict) -> str:
    """Release body: what each asset is + how to flash it, with SHA256s."""
    battery_variants = {k: v for k, v in VARIANTS.items() if k in ("thread", "wifi", "ble", "espnow", "esphome")}
    mains_variants   = {k: v for k, v in VARIANTS.items() if k in ("ap", "station")}
    lines = [
        f"# AkvaLink v{version}",
        "",
        "Prebuilt, single-image firmware for the u-blox NORA-W40 (ESP32-C6).",
        "Each `.bin` is a complete image (bootloader + partition table + app),",
        "flashable to offset `0x0` — no build toolchain required:",
        "",
        "```",
        "pip install esptool",
        f"esptool --chip esp32c6 write-flash 0x0 {asset_name('thread', version)}",
        "```",
        "",
        "## Battery-powered variants",
        "",
        "Thread lasts longest, Wi-Fi the shortest — pick by how you reach the sensor.",
        "",
        "| Asset | What it is |",
        "|-------|------------|",
    ]
    for variant, label in battery_variants.items():
        lines.append(f"| `{asset_name(variant, version)}` | {label} |")
    lines += [
        "",
        "## Mains/USB-powered variants",
        "",
        "These keep Wi-Fi active and need external power.",
        "",
        "| Asset | What it is |",
        "|-------|------------|",
    ]
    for variant, label in mains_variants.items():
        lines.append(f"| `{asset_name(variant, version)}` | {label} |")
    lines += ["", "## SHA256", "", "```"]
    for variant in VARIANTS:
        name = asset_name(variant, version)
        digest = digests.get(variant, "<pending>")
        lines.append(f"{digest}  {name}")
    lines.append("```")
    return "\n".join(lines) + "\n"


# ---- process / IO helpers --------------------------------------------------

def _run(cmd: list[str], dry_run: bool) -> None:
    print(f"    $ {' '.join(cmd)}")
    if dry_run:
        return
    result = subprocess.run(cmd, cwd=REPO_ROOT, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed ({result.returncode}): {' '.join(cmd)}")


def _query(cmd: list[str]) -> str:
    return subprocess.run(
        cmd, cwd=REPO_ROOT, text=True, capture_output=True, check=False
    ).stdout.strip()


def github_token() -> str | None:
    """Prefer $GITHUB_TOKEN; else ask Git Credential Manager for github.com."""
    tok = os.environ.get("GITHUB_TOKEN")
    if tok:
        return tok.strip()
    try:
        proc = subprocess.run(
            ["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            text=True, capture_output=True, check=False,
        )
    except FileNotFoundError:
        return None
    for line in proc.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    return None


def _api(method: str, url: str, token: str, data=None,
         content_type: str = "application/json"):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "akvalink-publish",
    }
    body = None
    if data is not None:
        if content_type == "application/json":
            body = json.dumps(data).encode("utf-8")
        else:
            body = data
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def get_release(token: str, tag: str):
    try:
        return _api("GET", f"{API}/repos/{REPO_SLUG}/releases/tags/{tag}", token)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def create_release(token: str, tag: str, name: str, body: str,
                   commitish: str, draft: bool):
    payload = {
        "tag_name": tag,
        "target_commitish": commitish,
        "name": name,
        "body": body,
        "draft": draft,
        "prerelease": False,
    }
    return _api("POST", f"{API}/repos/{REPO_SLUG}/releases", token, payload)


def update_release(token: str, release_id: int, body: str, draft: bool):
    return _api(
        "PATCH", f"{API}/repos/{REPO_SLUG}/releases/{release_id}", token,
        {"body": body, "draft": draft},
    )


def delete_asset(token: str, asset_id: int) -> None:
    _api("DELETE", f"{API}/repos/{REPO_SLUG}/releases/assets/{asset_id}", token)


def upload_asset(token: str, release: dict, path: Path) -> None:
    # Replace an existing same-named asset (releases can't hold duplicates).
    for asset in release.get("assets", []):
        if asset.get("name") == path.name:
            delete_asset(token, asset["id"])
    url = clean_upload_url(release["upload_url"], path.name)
    _api("POST", url, token, data=path.read_bytes(),
         content_type="application/octet-stream")


# ---- pipeline --------------------------------------------------------------

def collect_assets(version: str) -> list[Path]:
    """Return the dist/ files to upload (merged image + bare app image + sidecars
    per variant). Raises if a variant's merged image is missing (release.py
    hasn't produced it)."""
    assets: list[Path] = []
    for variant in VARIANTS:
        image = DIST_DIR / asset_name(variant, version)
        if not image.is_file():
            raise SystemExit(
                f"missing {image} — run `py -3 scripts/release.py` first to "
                f"build + package the variants into dist/."
            )
        for candidate in (image, DIST_DIR / app_image_name(variant, version)):
            if candidate.is_file():
                assets.append(candidate)
            sidecar = DIST_DIR / (candidate.name + ".sha256")
            if sidecar.is_file():
                assets.append(sidecar)
    return assets


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Ship a GitHub release from the dist/ artifacts.")
    p.add_argument("--version", help="version to publish (default: version.txt)")
    p.add_argument("--tag", help="git tag (default: v<version>)")
    p.add_argument("--no-push", action="store_true", help="do not push the tag before releasing")
    p.add_argument("--draft", action="store_true", help="create the release as a draft")
    p.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    p.add_argument("--yes", action="store_true", help="do not prompt before publishing")
    args = p.parse_args(argv)

    version = (args.version or VERSION_FILE.read_text(encoding="utf-8")).strip()
    tag = args.tag or f"v{version}"
    commitish = _query(["git", "rev-parse", "HEAD"]) or "main"

    print(f"AkvaLink publish: {tag}  (repo {REPO_SLUG})")
    print(f"Variants: {', '.join(VARIANTS)}")
    if args.dry_run:
        print("[dry-run] no changes will be made.\n")

    # 1. Gather the artifacts release.py built into dist/ (fails if missing).
    assets = collect_assets(version)
    digests = {v: read_digest(DIST_DIR / (asset_name(v, version) + ".sha256")) for v in VARIANTS}
    for path in assets:
        print(f"• asset: dist/{path.name}")

    notes = format_notes(version, digests)
    print("• release notes:\n" + "\n".join("    " + ln for ln in notes.splitlines()))

    # 2. Confirm before the irreversible publish.
    if not args.dry_run and not args.yes:
        try:
            if input(f"Publish {tag} to GitHub ({REPO_SLUG})? [y/N] ").strip().lower() not in ("y", "yes"):
                print("Aborted before publish. dist/ artifacts are ready.")
                return 1
        except EOFError:
            print("Non-interactive and no --yes; aborting before publish.")
            return 1

    # 3. Auth.
    token = github_token()
    if not token and not args.dry_run:
        raise SystemExit(
            "no GitHub token — set GITHUB_TOKEN or run `git push` once so Git "
            "Credential Manager caches a github.com credential."
        )

    # 4. Push the tag so the release points at the right commit.
    if not args.no_push:
        _run(["git", "push", "origin", "HEAD"], args.dry_run)
        if _query(["git", "tag", "--list", tag]):
            _run(["git", "push", "origin", tag], args.dry_run)
        else:
            print(f"• note: local tag {tag} not found — the release will create it at {commitish[:8]}")

    if args.dry_run:
        print(f"\n[dry-run] would create release {tag} with {len(VARIANTS)} assets.")
        return 0

    # 5. Create or update the release, then upload assets.
    release = get_release(token, tag)
    if release:
        print(f"• release {tag} exists (id {release['id']}) — updating notes + assets")
        update_release(token, release["id"], notes, args.draft)
        release = get_release(token, tag)  # refresh asset list
    else:
        print(f"• creating release {tag}")
        release = create_release(token, tag, f"AkvaLink {tag}", notes, commitish, args.draft)

    for path in assets:
        print(f"• uploading {path.name}")
        upload_asset(token, release, path)

    url = release.get("html_url", f"https://github.com/{REPO_SLUG}/releases/tag/{tag}")
    print(f"\nPublished {tag} ✔  {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
