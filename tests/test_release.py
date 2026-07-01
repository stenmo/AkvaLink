"""Tests for scripts/release.py — version bump + release-note formatting."""

import pytest

import release


@pytest.mark.parametrize(
    "text,expected",
    [("0.1.0", (0, 1, 0)), ("1.2.3", (1, 2, 3)), (" 10.20.30 ", (10, 20, 30))],
)
def test_parse_version_ok(text, expected):
    assert release.parse_version(text) == expected


@pytest.mark.parametrize("bad", ["1.0", "v1.0.0", "1.0.0-rc1", "x", "1.0.0.0", ""])
def test_parse_version_rejects_bad(bad):
    with pytest.raises(ValueError):
        release.parse_version(bad)


@pytest.mark.parametrize(
    "current,part,expected",
    [
        ("0.1.0", "patch", "0.1.1"),
        ("0.1.9", "patch", "0.1.10"),
        ("0.1.5", "minor", "0.2.0"),
        ("1.4.7", "major", "2.0.0"),
        ("0.9.9", "major", "1.0.0"),
    ],
)
def test_bump_version(current, part, expected):
    assert release.bump_version(current, part) == expected


def test_bump_version_rejects_unknown_part():
    with pytest.raises(ValueError):
        release.bump_version("1.0.0", "build")


def test_format_release_notes_with_prev_tag():
    notes = release.format_release_notes(
        "0.1.1", ["fix: a thing", "docs: another"], "v0.1.0"
    )
    assert notes.startswith("# AquaLink v0.1.1")
    assert "Changes since v0.1.0:" in notes
    assert "- fix: a thing" in notes
    assert "- docs: another" in notes
    assert notes.endswith("\n")


def test_format_release_notes_initial():
    notes = release.format_release_notes("0.1.0", ["initial import"], None)
    assert "Initial release." in notes
    assert "Changes since" not in notes


def test_format_release_notes_no_changes():
    notes = release.format_release_notes("0.1.1", [], "v0.1.0")
    assert "- (no changes recorded)" in notes


def test_version_file_is_valid_semver():
    # The committed source of truth must always parse.
    from pathlib import Path

    text = (Path(release.__file__).resolve().parents[1] / "version.txt").read_text().strip()
    assert release.parse_version(text)


def test_esptool_merge_cmd_orders_offsets_ascending():
    settings = {"flash_mode": "dio", "flash_freq": "80m", "flash_size": "4MB"}
    files = {"0x20000": "app.bin", "0x0": "bootloader/boot.bin", "0x8000": "pt.bin"}
    cmd = release.esptool_merge_cmd("py", "esp32c6", settings, files, "out.bin")
    assert "merge-bin" in cmd
    assert cmd[cmd.index("--chip") + 1] == "esp32c6"
    assert cmd[cmd.index("--flash-size") + 1] == "4MB"
    # offsets must appear low -> high regardless of dict order
    assert cmd.index("0x0") < cmd.index("0x8000") < cmd.index("0x20000")


def test_flash_instructions_has_command_name_and_hash():
    txt = release.flash_instructions("0.1.1", "thread", "deadbeef")
    assert "aqualink-thread-v0.1.1.bin" in txt
    assert "write-flash 0x0" in txt
    assert "deadbeef" in txt
    assert "**thread**" in txt


def test_flash_instructions_variant_wifi():
    txt = release.flash_instructions("1.2.3", "wifi", "abc")
    assert "aqualink-wifi-v1.2.3.bin" in txt
