#!/usr/bin/env python3
"""Serial monitor for the NORA-W40 EVK with reconnect + timestamped logging.

Cross-platform replacement for monitor-com.ps1 (Windows-only). Opens the given
serial port, echoes every line to stdout and appends it to a log file with a
millisecond timestamp, and transparently reconnects (with backoff) if the port
drops out — e.g. when the device reboots or the USB link glitches. Requires
pyserial.

Works on Windows (COMx), Linux (/dev/ttyACM*, /dev/ttyUSB*) and macOS
(/dev/cu.usbmodem*). Stop with Ctrl+C.
"""

import argparse
import os
import sys
import time
from datetime import datetime, timezone


def _now_hms() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _tee(line: str, log_path: str) -> None:
    print(line, flush=True)
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        # Never let a logging hiccup kill the monitor.
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description="NORA-W40 serial monitor.")
    parser.add_argument("--port", required=True, help="Serial port (COM62, /dev/ttyACM0, ...)")
    parser.add_argument("--seconds", type=int, default=180, help="How long to run (s)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate")
    parser.add_argument("--log-file", required=True, help="Path to append the log to")
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        print("[monitor] pyserial not installed (pip install pyserial)", file=sys.stderr)
        return 2

    log_dir = os.path.dirname(os.path.abspath(args.log_file))
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)

    _tee(
        f"=== monitor start {datetime.now(timezone.utc).isoformat()} "
        f"on {args.port} for {args.seconds}s ===",
        args.log_file,
    )

    end = time.monotonic() + args.seconds
    sp = None
    backoff = 0.2

    try:
        while time.monotonic() < end:
            # (Re)open the port if it is not currently open.
            if sp is None or not sp.is_open:
                try:
                    if sp is not None:
                        try:
                            sp.close()
                        except Exception:
                            pass
                        sp = None
                    sp = serial.Serial(args.port, args.baud, timeout=0.5)
                    sp.dtr = True
                    sp.rts = True
                    _tee(f"{_now_hms()} [monitor] {args.port} opened @ {args.baud}", args.log_file)
                    backoff = 0.2
                except Exception as exc:
                    _tee(
                        f"{_now_hms()} [monitor] open failed: {exc} "
                        f"(retry in {int(backoff * 1000)}ms)",
                        args.log_file,
                    )
                    time.sleep(backoff)
                    backoff = min(backoff * 2, 3.0)
                    continue

            try:
                raw = sp.readline()
                if not raw:
                    # Timeout with no data — normal, keep polling.
                    continue
                line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                _tee(f"{_now_hms()} {line}", args.log_file)
            except Exception as exc:
                # Port closed (device reboot / USB drop) or any other I/O error.
                _tee(f"{_now_hms()} [monitor] port lost: {exc}", args.log_file)
                try:
                    sp.close()
                except Exception:
                    pass
                sp = None
                time.sleep(0.2)
    except KeyboardInterrupt:
        pass
    finally:
        if sp is not None:
            try:
                sp.close()
            except Exception:
                pass

    _tee(f"=== monitor end {datetime.now(timezone.utc).isoformat()} ===", args.log_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
