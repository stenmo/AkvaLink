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


class _FakeSerial:
    """Minimal serial.Serial stand-in driven by a scripted list of readline
    results (bytes to return, or an Exception class to raise once)."""

    def __init__(self, script):
        self._script = script
        self.is_open = True
        self.dtr = False
        self.rts = False

    def readline(self):
        if not self._script:
            return b""
        item = self._script.pop(0)
        if isinstance(item, type) and issubclass(item, Exception):
            raise item("simulated I/O error")
        return item

    def close(self):
        self.is_open = False


def _clock(monkeypatch, seconds_budget):
    """Make monitor_com.time advance 0.5 s per call and never sleep."""
    state = {"t": 0.0}

    def mono():
        state["t"] += 0.5
        return state["t"]

    monkeypatch.setattr(monitor_com.time, "monotonic", mono)
    monkeypatch.setattr(monitor_com.time, "sleep", lambda *_: None)


def test_main_reads_and_logs_lines(monkeypatch, tmp_path):
    import serial

    monkeypatch.setattr(
        serial, "Serial",
        lambda *a, **k: _FakeSerial([b"boot ok\r\n", b"", b"temp 28.5\r\n"]),
    )
    _clock(monkeypatch, 3)
    log = tmp_path / "run.log"
    monkeypatch.setattr(
        "sys.argv",
        ["monitor_com.py", "--port", "COMX", "--seconds", "3", "--log-file", str(log)],
    )
    assert monitor_com.main() == 0
    text = log.read_text(encoding="utf-8")
    assert "opened @ 115200" in text
    assert "boot ok" in text
    assert "temp 28.5" in text


def test_main_reconnects_after_io_error(monkeypatch, tmp_path):
    import serial

    # First connection drops mid-read; the reopened connection recovers.
    connections = [[OSError], [b"recovered\r\n"]]

    def factory(*a, **k):
        return _FakeSerial(connections.pop(0) if connections else [])

    monkeypatch.setattr(serial, "Serial", factory)
    _clock(monkeypatch, 3)
    log = tmp_path / "run.log"
    monkeypatch.setattr(
        "sys.argv",
        ["monitor_com.py", "--port", "COMX", "--seconds", "3", "--log-file", str(log)],
    )
    assert monitor_com.main() == 0
    text = log.read_text(encoding="utf-8")
    assert "port lost" in text
    assert "recovered" in text


def test_main_retries_when_open_fails(monkeypatch, tmp_path):
    import serial

    # First open attempt fails (port busy); the retry succeeds.
    attempts = {"n": 0}

    def factory(*a, **k):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise serial.SerialException("port busy")
        return _FakeSerial([b"up\r\n"])

    monkeypatch.setattr(serial, "Serial", factory)
    _clock(monkeypatch, 3)
    log = tmp_path / "run.log"
    monkeypatch.setattr(
        "sys.argv",
        ["monitor_com.py", "--port", "COMX", "--seconds", "3", "--log-file", str(log)],
    )
    assert monitor_com.main() == 0
    text = log.read_text(encoding="utf-8")
    assert "open failed" in text
    assert "up" in text
