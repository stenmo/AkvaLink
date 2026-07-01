"""Tests for scripts/detect_nora_w40_port.py — NORA-W40 EVK port detection."""

import types

import serial.tools.list_ports as list_ports

import detect_nora_w40_port as detect


def _port(vid, pid, device):
    return types.SimpleNamespace(vid=vid, pid=pid, device=device)


def test_vid_pid_constants():
    # ESP32-C6 native USB Serial/JTAG exposed by the EVK-NORA-W40.
    assert detect.NORA_W40_VID == 0x303A
    assert detect.NORA_W40_PID == 0x1001


def test_finds_evk(monkeypatch, capsys):
    monkeypatch.setattr(
        list_ports, "comports", lambda: [_port(0x303A, 0x1001, "COM63")]
    )
    rc = detect.main()
    assert rc == 0
    assert capsys.readouterr().out.strip() == "COM63"


def test_ignores_non_evk(monkeypatch, capsys):
    monkeypatch.setattr(
        list_ports,
        "comports",
        lambda: [_port(0x1234, 0x5678, "COM9"), _port(0x0403, 0x6001, "COM4")],
    )
    rc = detect.main()
    assert rc == 1
    assert capsys.readouterr().out.strip() == ""


def test_picks_evk_among_others(monkeypatch, capsys):
    monkeypatch.setattr(
        list_ports,
        "comports",
        lambda: [
            _port(0x1546, 0x0508, "COM122"),
            _port(0x303A, 0x1001, "/dev/ttyACM0"),
            _port(0x0403, 0x6015, "COM5"),
        ],
    )
    rc = detect.main()
    assert rc == 0
    assert capsys.readouterr().out.strip() == "/dev/ttyACM0"


def test_no_ports(monkeypatch, capsys):
    monkeypatch.setattr(list_ports, "comports", lambda: [])
    rc = detect.main()
    assert rc == 1
    assert capsys.readouterr().out.strip() == ""


def test_none_vid_pid_is_safe(monkeypatch, capsys):
    # Some virtual ports report vid/pid as None — must not crash or match.
    monkeypatch.setattr(
        list_ports, "comports", lambda: [_port(None, None, "COM3")]
    )
    rc = detect.main()
    assert rc == 1
