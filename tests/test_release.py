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
