#!/usr/bin/env python3
"""AkvaLink publish helper — build every firmware variant and ship a GitHub release.

Builds the three shipping variants (Thread, Wi-Fi, BLE) into their own isolated
build directories, merges each into a single 0x0-flashable image under dist/,
then creates (or updates) a GitHub release and uploads the images as assets.

Division of labour (see also scripts/release.py):
    scripts/release.py  --bump patch --no-publish   # test, bump version.txt, commit + tag
    scripts/publish.py                              # build all variants + publish

So release.py *prepares* (version + tag); publish.py *ships* (build + upload).

Auth: reuses the GitHub token Git Credential Manager already stores for
github.com (the same one `git push` uses) — no `gh` CLI required. Override with
the GITHUB_TOKEN environment variable (handy for CI).

Examples
--------
    py -3 scripts/publish.py --dry-run          # show the plan, change nothing
    py -3 scripts/publish.py                     # build all 3, publish v<version.txt>
    py -3 scripts/publish.py --no-build          # publish already-built variants
    py -3 scripts/publish.py --draft             # create the release as a draft

Requires: git, esptool (`pip install esptool`), and network access. The build
step uses the WSL launcher on Windows and build.sh elsewhere.
"""

from __future__ import annotations

import argparse
import hashlib
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
    "thread": "Matter over Thread (Sleepy End Device — battery target)",
    "wifi": "Matter over Wi-Fi",
    "ble": "Standalone BLE GATT (no hub, no Matter)",
}


# ---- pure helpers (unit-tested) --------------------------------------------

def asset_name(variant: str, version: str) -> str:
    return f"akvalink-{variant}-v{version}.bin"


def variant_build_dir(variant: str) -> Path:
    return REPO_ROOT / "build" / variant


def clean_upload_url(upload_url: str, filename: str) -> str:
    """Turn GitHub's templated upload_url into a concrete asset-upload URL.

    The API hands back e.g.
        https://uploads.github.com/repos/O/R/releases/42/assets{?name,label}
    which we specialise with the asset filename.
    """
    base = upload_url.split("{", 1)[0]
    return f"{base}?name={urllib.parse.quote(filename)}"


def esptool_merge_cmd(python: str, chip: str, settings: dict,
                      flash_files: dict, build_dir, out_path) -> list[str]:
    """Build the `esptool merge-bin` argv, offsets ascending so the merged
    image is laid out correctly regardless of dict ordering."""
    cmd = [
        python, "-m", "esptool", "--chip", chip, "merge-bin",
        "-o", str(out_path),
        "--flash-mode", settings["flash_mode"],
        "--flash-freq", settings["flash_freq"],
        "--flash-size", settings["flash_size"],
    ]
    for offset, rel in sorted(flash_files.items(), key=lambda kv: int(kv[0], 16)):
        cmd += [offset, str(Path(build_dir) / rel)]
    return cmd


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def build_variant_cmd(variant: str) -> list[str]:
    """Command that builds one variant into its own build/<variant> dir.

    Uses --build (not --rebuild): the per-variant directories are already
    isolated, so there is nothing to clean between variants.
    """
    flag = {"wifi": "--wifi", "ble": "--ble", "sensor": "--sensor"}.get(variant)
    if os.name == "nt":
        cmd = ["cmd", "/c", str(REPO_ROOT / "launch-akvalink-wsl.cmd")]
        if flag:
            cmd.append(flag)
        cmd.append("--build")
        return cmd
    cmd = ["bash", str(REPO_ROOT / "build.sh"), "build"]
    if flag:
        cmd.append(flag)
    return cmd


def format_notes(version: str, digests: dict) -> str:
    """Release body: what each asset is + how to flash it, with SHA256s."""
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
        "## Variants",
        "",
        "| Asset | What it is |",
        "|-------|------------|",
    ]
    for variant, label in VARIANTS.items():
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

def merge_variant(variant: str, version: str, dry_run: bool):
    """Merge one variant's build into dist/akvalink-<variant>-v<ver>.bin.
    Returns the sha256 hex (or '<dry-run>')."""
    build_dir = variant_build_dir(variant)
    flasher_args = build_dir / "flasher_args.json"
    if not flasher_args.is_file():
        raise SystemExit(
            f"missing {flasher_args} — build the '{variant}' variant first "
            f"(or drop --no-build)."
        )
    data = json.loads(flasher_args.read_text(encoding="utf-8"))
    chip = data.get("extra_esptool_args", {}).get("chip", "esp32c6")
    out = DIST_DIR / asset_name(variant, version)
    _run(
        esptool_merge_cmd(sys.executable, chip, data["flash_settings"],
                          data["flash_files"], build_dir, out),
        dry_run,
    )
    if dry_run:
        return "<dry-run>"
    digest = sha256_file(out)
    (DIST_DIR / (out.name + ".sha256")).write_text(
        f"{digest}  {out.name}\n", encoding="utf-8")
    return digest


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    p = argparse.ArgumentParser(description="Build all variants and publish a GitHub release.")
    p.add_argument("--version", help="version to publish (default: version.txt)")
    p.add_argument("--tag", help="git tag (default: v<version>)")
    p.add_argument("--no-build", action="store_true", help="use existing build/<variant> dirs")
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

    DIST_DIR.mkdir(exist_ok=True)

    # 1. Build + merge each variant.
    digests: dict[str, str] = {}
    for variant in VARIANTS:
        if args.no_build:
            print(f"• build: skipped ({variant})")
        else:
            print(f"• build: {variant}")
            _run(build_variant_cmd(variant), args.dry_run)
        print(f"• package: dist/{asset_name(variant, version)}")
        digests[variant] = merge_variant(variant, version, args.dry_run)

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

    for variant in VARIANTS:
        for suffix in ("", ".sha256"):
            path = DIST_DIR / (asset_name(variant, version) + suffix)
            if path.is_file():
                print(f"• uploading {path.name}")
                upload_asset(token, release, path)

    url = release.get("html_url", f"https://github.com/{REPO_SLUG}/releases/tag/{tag}")
    print(f"\nPublished {tag} ✔  {url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
