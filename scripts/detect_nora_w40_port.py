#!/usr/bin/env python3
"""Detect the serial port of an attached NORA-W40 EVK.

Matches USB VID 0x303A & PID 0x1001 (Espressif ESP32-C6 native USB-Serial/JTAG,
the bridge exposed by the EVK-NORA-W40). Prints just the port name to stdout
(e.g. "COM62" on Windows, "/dev/ttyACM0" on Linux, "/dev/cu.usbmodem*" on macOS).

Exit 0 if a port was found and printed, 1 otherwise. Cross-platform replacement
for detect-nora-w40-port.ps1 (Windows-only). Requires pyserial.
"""

import sys

NORA_W40_VID = 0x303A
NORA_W40_PID = 0x1001


def main() -> int:
    try:
        from serial.tools import list_ports
    except ImportError:
        # pyserial not installed — let the caller fall back to its native path.
        return 1

    for port in list_ports.comports():
        if port.vid == NORA_W40_VID and port.pid == NORA_W40_PID:
            print(port.device)
            return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
