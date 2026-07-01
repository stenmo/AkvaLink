"""Tests for scripts/monitor_com.py — timestamp/tee helpers + CLI wiring."""

import re

import pytest

import monitor_com


def test_now_hms_format():
    assert re.match(r"^\d{2}:\d{2}:\d{2}\.\d{3}$", monitor_com._now_hms())


def test_tee_writes_and_prints(tmp_path, capsys):
    log = tmp_path / "m.log"
    monitor_com._tee("hello world", str(log))
    assert log.read_text(encoding="utf-8") == "hello world\n"
    assert "hello world" in capsys.readouterr().out


def test_tee_appends(tmp_path):
    log = tmp_path / "m.log"
    monitor_com._tee("line 1", str(log))
    monitor_com._tee("line 2", str(log))
    assert log.read_text(encoding="utf-8") == "line 1\nline 2\n"


def test_tee_survives_unwritable_path(capsys):
    # A bad log path must never crash the monitor — it still prints.
    monitor_com._tee("still printed", "/no/such/dir/really/nope.log")
    assert "still printed" in capsys.readouterr().out


def test_main_zero_seconds_writes_markers(monkeypatch, tmp_path):
    # --seconds 0 exits the loop immediately without opening any port.
    log = tmp_path / "run.log"
    argv = [
        "monitor_com.py",
        "--port", "COM_TEST",
        "--seconds", "0",
        "--log-file", str(log),
    ]
    monkeypatch.setattr("sys.argv", argv)
    rc = monitor_com.main()
    assert rc == 0
    text = log.read_text(encoding="utf-8")
    assert "monitor start" in text
    assert "monitor end" in text
    assert "COM_TEST" in text


def test_main_requires_port(monkeypatch, tmp_path):
    argv = ["monitor_com.py", "--log-file", str(tmp_path / "x.log")]
    monkeypatch.setattr("sys.argv", argv)
    with pytest.raises(SystemExit):
        monitor_com.main()


def test_main_requires_log_file(monkeypatch):
    argv = ["monitor_com.py", "--port", "COM_TEST"]
    monkeypatch.setattr("sys.argv", argv)
    with pytest.raises(SystemExit):
        monitor_com.main()
