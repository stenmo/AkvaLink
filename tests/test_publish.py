"""Tests for scripts/publish.py — pure helpers (no network, no build)."""

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


def test_read_digest_parses_sidecar(tmp_path):
    sidecar = tmp_path / "akvalink-thread-v0.1.0.bin.sha256"
    sidecar.write_text("deadbeef  akvalink-thread-v0.1.0.bin\n", encoding="utf-8")
    assert publish.read_digest(sidecar) == "deadbeef"


def test_read_digest_missing_file(tmp_path):
    assert publish.read_digest(tmp_path / "nope.sha256") == "<unknown>"


def test_collect_assets_ok(tmp_path, monkeypatch):
    monkeypatch.setattr(publish, "DIST_DIR", tmp_path)
    for variant in publish.VARIANTS:
        name = publish.asset_name(variant, "0.2.0")
        (tmp_path / name).write_bytes(b"IMG")
        (tmp_path / (name + ".sha256")).write_text(f"abc  {name}\n", encoding="utf-8")
    assets = publish.collect_assets("0.2.0")
    assert len(assets) == 6   # image + sidecar for each of the three variants
    names = [p.name for p in assets]
    assert "akvalink-thread-v0.2.0.bin" in names
    assert "akvalink-ble-v0.2.0.bin.sha256" in names


def test_collect_assets_missing_raises(tmp_path, monkeypatch):
    monkeypatch.setattr(publish, "DIST_DIR", tmp_path)
    with pytest.raises(SystemExit):
        publish.collect_assets("0.2.0")


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
