"""Tests for scripts/publish.py — pure helpers (no network, no build)."""

import hashlib
from pathlib import Path

import pytest

import publish


@pytest.mark.parametrize(
    "variant,version,expected",
    [
        ("thread", "0.1.0", "akvalink-thread-v0.1.0.bin"),
        ("wifi", "1.2.3", "akvalink-wifi-v1.2.3.bin"),
        ("ble", "10.0.0", "akvalink-ble-v10.0.0.bin"),
    ],
)
def test_asset_name(variant, version, expected):
    assert publish.asset_name(variant, version) == expected


def test_variants_are_the_three_shipping_ones():
    assert list(publish.VARIANTS) == ["thread", "wifi", "ble"]


def test_clean_upload_url_strips_template_and_adds_name():
    tmpl = "https://uploads.github.com/repos/o/r/releases/42/assets{?name,label}"
    url = publish.clean_upload_url(tmpl, "akvalink-thread-v0.1.0.bin")
    assert url == (
        "https://uploads.github.com/repos/o/r/releases/42/assets"
        "?name=akvalink-thread-v0.1.0.bin"
    )
    assert "{" not in url


def test_clean_upload_url_quotes_special_chars():
    url = publish.clean_upload_url("https://x/assets{?name}", "a b+c.bin")
    assert "a%20b%2Bc.bin" in url


def test_esptool_merge_cmd_orders_offsets_ascending(tmp_path):
    settings = {"flash_mode": "dio", "flash_freq": "80m", "flash_size": "4MB"}
    files = {"0x20000": "app.bin", "0x0": "bootloader/boot.bin", "0x8000": "pt.bin"}
    cmd = publish.esptool_merge_cmd("py", "esp32c6", settings, files, tmp_path, "out.bin")
    assert "merge-bin" in cmd
    assert cmd[cmd.index("--chip") + 1] == "esp32c6"
    assert cmd[cmd.index("--flash-size") + 1] == "4MB"
    assert cmd.index("0x0") < cmd.index("0x8000") < cmd.index("0x20000")


def test_esptool_merge_cmd_prefixes_build_dir(tmp_path):
    files = {"0x0": "bootloader/boot.bin"}
    settings = {"flash_mode": "dio", "flash_freq": "80m", "flash_size": "4MB"}
    cmd = publish.esptool_merge_cmd("py", "esp32c6", settings, files, tmp_path, "o.bin")
    # the file path must be resolved under the given build dir
    assert str(Path(tmp_path) / "bootloader/boot.bin") in cmd


def test_variant_build_dir():
    assert publish.variant_build_dir("wifi").name == "wifi"
    assert publish.variant_build_dir("wifi").parent.name == "build"


def test_build_variant_cmd_windows(monkeypatch):
    monkeypatch.setattr(publish.os, "name", "nt")
    assert "--wifi" in publish.build_variant_cmd("wifi")
    assert "--build" in publish.build_variant_cmd("wifi")
    assert "--rebuild" not in publish.build_variant_cmd("wifi")
    # thread carries no network flag
    assert "--wifi" not in publish.build_variant_cmd("thread")
    assert "--ble" not in publish.build_variant_cmd("thread")


def test_build_variant_cmd_posix(monkeypatch):
    monkeypatch.setattr(publish.os, "name", "posix")
    cmd = publish.build_variant_cmd("ble")
    assert cmd[0] == "bash"
    assert cmd[1].endswith("build.sh")
    assert "build" in cmd and "--ble" in cmd


def test_sha256_file(tmp_path):
    f = tmp_path / "x.bin"
    f.write_bytes(b"hello world")
    assert publish.sha256_file(f) == hashlib.sha256(b"hello world").hexdigest()


def test_format_notes_lists_all_variants_and_hashes():
    digests = {"thread": "aaa", "wifi": "bbb", "ble": "ccc"}
    notes = publish.format_notes("0.2.0", digests)
    assert notes.startswith("# AkvaLink v0.2.0")
    assert "write-flash 0x0 akvalink-thread-v0.2.0.bin" in notes
    for variant in ("thread", "wifi", "ble"):
        assert publish.asset_name(variant, "0.2.0") in notes
    assert "aaa" in notes and "bbb" in notes and "ccc" in notes
    assert notes.endswith("\n")


def test_github_token_prefers_env(monkeypatch):
    monkeypatch.setenv("GITHUB_TOKEN", "  tok123  ")
    assert publish.github_token() == "tok123"
