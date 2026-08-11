"""Tests for scripts/release_app.py — pure helpers + the local build pipeline."""

import hashlib
import zipfile
from pathlib import Path

import pytest

import release_app


@pytest.mark.parametrize(
    "version,expected",
    [("0.1.0", 100), ("0.3.4", 304), ("1.2.3", 10203), ("2.0.0", 20000)],
)
def test_build_number_ok(version, expected):
    assert release_app.build_number(version) == expected


@pytest.mark.parametrize("bad", ["1.0", "v1.0.0", "1.0.0-rc1", "x", "1.0.0.0", ""])
def test_build_number_rejects_bad(bad):
    with pytest.raises(ValueError):
        release_app.build_number(bad)


def _fake_app_dir(tmp_path, pubspec_version, dart_version):
    app = tmp_path / "app_flutter"
    (app / "lib").mkdir(parents=True)
    (app / "pubspec.yaml").write_text(
        f"name: akvalink\nversion: {pubspec_version}+1\n", encoding="utf-8"
    )
    (app / "lib" / "app_version.dart").write_text(
        f"const String kAppVersion = '{dart_version}';\n", encoding="utf-8"
    )
    return app


def test_check_version_mirrors_ok(tmp_path, monkeypatch):
    monkeypatch.setattr(release_app, "APP_DIR", _fake_app_dir(tmp_path, "0.5.0", "0.5.0"))
    assert release_app.check_version_mirrors("0.5.0") == []


def test_check_version_mirrors_reports_both_stale(tmp_path, monkeypatch):
    monkeypatch.setattr(release_app, "APP_DIR", _fake_app_dir(tmp_path, "0.4.0", "0.3.5"))
    problems = release_app.check_version_mirrors("0.5.0")
    assert len(problems) == 2
    assert any("pubspec" in p for p in problems)
    assert any("kAppVersion" in p for p in problems)


def test_sha256_file(tmp_path):
    f = tmp_path / "x.apk"
    f.write_bytes(b"hello world")
    assert release_app.sha256_file(f) == hashlib.sha256(b"hello world").hexdigest()


def test_apk_asset_name():
    assert release_app.apk_asset_name("0.3.4") == "akvalink-app-android-v0.3.4.apk"


def test_windows_asset_name():
    # "-unsigned" must stay in the filename — no code-signing cert.
    assert release_app.windows_asset_name("0.3.4") == "akvalink-app-windows-v0.3.4-unsigned.zip"


def test_flutter_cmd_windows(monkeypatch):
    monkeypatch.setattr(release_app.os, "name", "nt")
    assert release_app._flutter_cmd(["test"]) == ["cmd", "/c", "flutter", "test"]


def test_flutter_cmd_posix(monkeypatch):
    monkeypatch.setattr(release_app.os, "name", "posix")
    assert release_app._flutter_cmd(["test"]) == ["flutter", "test"]


def test_stage_copies_and_hashes(tmp_path):
    src = tmp_path / "app-release.apk"
    src.write_bytes(b"APKDATA")
    dst = tmp_path / "dist_app" / "akvalink-app-android-v0.1.0.apk"
    dst.parent.mkdir()
    release_app._stage(src, dst, dry_run=False)
    assert dst.read_bytes() == b"APKDATA"
    sidecar = Path(str(dst) + ".sha256")
    assert sidecar.is_file()
    assert hashlib.sha256(b"APKDATA").hexdigest() in sidecar.read_text()


def test_stage_missing_src_is_skipped(tmp_path):
    dst = tmp_path / "out.apk"
    release_app._stage(tmp_path / "nope.apk", dst, dry_run=False)
    assert not dst.exists()


def test_stage_dry_run_is_no_op(tmp_path):
    src = tmp_path / "app-release.apk"
    src.write_bytes(b"APKDATA")
    dst = tmp_path / "out.apk"
    release_app._stage(src, dst, dry_run=True)
    assert not dst.exists()


def test_zip_dir_creates_zip_and_hash(tmp_path):
    src_dir = tmp_path / "Release"
    src_dir.mkdir()
    (src_dir / "akvalink.exe").write_bytes(b"EXEDATA")
    dst_zip = tmp_path / "dist_app" / "akvalink-app-windows-v0.1.0-unsigned.zip"
    dst_zip.parent.mkdir()
    release_app._zip_dir(src_dir, dst_zip, dry_run=False)
    assert dst_zip.is_file()
    with zipfile.ZipFile(dst_zip) as zf:
        assert "akvalink.exe" in zf.namelist()
    sidecar = Path(str(dst_zip) + ".sha256")
    assert sidecar.is_file()


def test_zip_dir_missing_src_dir_is_skipped(tmp_path):
    dst_zip = tmp_path / "out.zip"
    release_app._zip_dir(tmp_path / "nope", dst_zip, dry_run=False)
    assert not dst_zip.exists()


def test_build_apk_stages_output(monkeypatch, tmp_path):
    fake_apk = tmp_path / "app-release.apk"
    fake_apk.write_bytes(b"APKDATA")
    dist_app = tmp_path / "dist_app"
    dist_app.mkdir()
    monkeypatch.setattr(release_app, "APK_SRC", fake_apk)
    monkeypatch.setattr(release_app, "DIST_APP_DIR", dist_app)
    monkeypatch.setattr(release_app, "_run", lambda cmd, dry_run: None)

    release_app.build_apk("0.1.0", 100, dry_run=False)

    out = dist_app / "akvalink-app-android-v0.1.0.apk"
    assert out.read_bytes() == b"APKDATA"


def test_build_windows_skips_on_non_windows(monkeypatch):
    monkeypatch.setattr(release_app.os, "name", "posix")

    def fail(*a, **kw):
        raise AssertionError("must not run flutter build on a non-Windows host")

    monkeypatch.setattr(release_app, "_run", fail)
    release_app.build_windows("0.1.0", 100, dry_run=False)  # must not raise


def test_main_rejects_unknown_target():
    with pytest.raises(SystemExit):
        release_app.main(["--targets", "bogus", "--dry-run"])


def test_main_dry_run_plan(monkeypatch, tmp_path, capsys):
    version_file = tmp_path / "version.txt"
    version_file.write_text("0.1.0\n")
    monkeypatch.setattr(release_app, "VERSION_FILE", version_file)
    monkeypatch.setattr(release_app, "DIST_APP_DIR", tmp_path / "dist_app")
    # The mirror preflight refuses to build when the app files disagree with
    # version.txt, so give it a matching fake app tree.
    monkeypatch.setattr(release_app, "APP_DIR", _fake_app_dir(tmp_path, "0.1.0", "0.1.0"))

    rc = release_app.main(["--dry-run"])

    assert rc == 0
    out = capsys.readouterr().out
    assert "v0.1.0" in out
    assert "dry-run" in out
