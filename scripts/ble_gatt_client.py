#!/usr/bin/env python3
"""
ble_gatt_client.py — AkvaLink BLE GATT discovery and debug tool.

Scans for AkvaLink devices advertising the ESS service (0x181A) or
name prefix "AkvaLink", connects, discovers ALL GATT services and
characteristics, reads known values, subscribes to temperature
notifications, then disconnects cleanly.

Useful for verifying that the firmware's GATT table is registered
correctly and that the right service UUIDs are visible to clients.

Requirements:
    pip install bleak

Usage:
    python scripts/ble_gatt_client.py              # scan then connect to best
    python scripts/ble_gatt_client.py --scan       # scan only, no connect
    python scripts/ble_gatt_client.py --addr XX:XX:XX:XX:XX:XX
    python scripts/ble_gatt_client.py --time 30    # stay connected 30 s (default 10)
"""

import argparse
import asyncio
import struct
import sys

try:
    from bleak import BleakClient, BleakScanner
except ImportError:
    sys.exit("bleak not installed — run:  pip install bleak")

# ---------------------------------------------------------------------------
# Known AkvaLink UUIDs
# ---------------------------------------------------------------------------
SCAN_PREFIX = "AkvaLink"

ESS_SVC  = "0000181a-0000-1000-8000-00805f9b34fb"  # Environmental Sensing
TEMP_CHR = "00002a6e-0000-1000-8000-00805f9b34fb"  # Temperature (sint16, 0.01 °C)

DIS_SVC   = "0000180a-0000-1000-8000-00805f9b34fb"  # Device Information
FW_CHR    = "00002a26-0000-1000-8000-00805f9b34fb"  # Firmware Revision
MODEL_CHR = "00002a24-0000-1000-8000-00805f9b34fb"  # Model Number
MFR_CHR   = "00002a29-0000-1000-8000-00805f9b34fb"  # Manufacturer Name

BAS_SVC  = "0000180f-0000-1000-8000-00805f9b34fb"  # Battery Service
BAT_CHR  = "00002a19-0000-1000-8000-00805f9b34fb"  # Battery Level (uint8, %)

AKVA_SVC  = "f0a00001-6e40-4a71-9b2c-6b6e696c0001"  # AkvaLink Custom
OTA_SVC   = "f0a00001-6e40-4a71-9b2c-6b6e696c0010"  # AkvaLink OTA
OTA_CTRL  = "f0a00001-6e40-4a71-9b2c-6b6e696c0011"  # OTA Control
OTA_DATA  = "f0a00001-6e40-4a71-9b2c-6b6e696c0012"  # OTA Data

KNOWN_SERVICES = {
    "00001800-0000-1000-8000-00805f9b34fb": "Generic Access",
    "00001801-0000-1000-8000-00805f9b34fb": "Generic Attribute",
    ESS_SVC:  "⭐ Environmental Sensing (ESS 0x181A)",
    DIS_SVC:  "Device Information (DIS 0x180A)",
    BAS_SVC:  "Battery Service (BAS 0x180F)",
    AKVA_SVC: "AkvaLink Custom",
    OTA_SVC:  "AkvaLink OTA",
}
KNOWN_CHARS = {
    TEMP_CHR:  "Temperature (sint16, 0.01 °C)",
    FW_CHR:    "Firmware Revision",
    MODEL_CHR: "Model Number",
    MFR_CHR:   "Manufacturer Name",
    BAT_CHR:   "Battery Level (%)",
    OTA_CTRL:  "OTA Control",
    OTA_DATA:  "OTA Data",
    "00002a00-0000-1000-8000-00805f9b34fb": "Device Name",
    "00002a01-0000-1000-8000-00805f9b34fb": "Appearance",
}


def _label_svc(uuid: str) -> str:
    return KNOWN_SERVICES.get(uuid.lower(), "")


def _label_chr(uuid: str) -> str:
    return KNOWN_CHARS.get(uuid.lower(), "")


def _fmt_temp(data: bytes) -> str:
    if len(data) < 2:
        return f"?? (raw {data.hex()})"
    raw = struct.unpack_from("<h", data)[0]  # sint16 LE
    return f"{raw / 100:.2f} °C  (raw {data.hex()})"


def _fmt_utf8(data: bytes) -> str:
    return data.decode("utf-8", errors="replace").strip()


def _fmt_battery(data: bytes) -> str:
    return f"{data[0]} %" if data else "??"


async def scan(timeout: float) -> list:
    print(f"Scanning {timeout:.0f} s for AkvaLink devices…")
    devices = []
    async with BleakScanner() as _:
        await asyncio.sleep(timeout)
        for dev, adv in BleakScanner.discovered_devices_and_advertisement_data.values():
            name = dev.name or ""
            svc_uuids = [str(u).lower() for u in adv.service_uuids]
            if name.startswith(SCAN_PREFIX) or ESS_SVC in svc_uuids:
                devices.append((dev, adv))
    return devices


async def explore(address: str, stay: int) -> None:
    print(f"\nConnecting to {address} …")
    async with BleakClient(address, timeout=20.0) as c:
        print(f"Connected ✓  MTU={c.mtu_size} bytes")
        svcs = list(c.services)
        print(f"\n{'═'*65}")
        print(f"  {len(svcs)} service(s) discovered")
        print(f"{'═'*65}")

        for svc in svcs:
            slabel = _label_svc(svc.uuid)
            tag = f"  [{slabel}]" if slabel else ""
            print(f"\n  SERVICE  {svc.uuid}{tag}")
            for ch in svc.characteristics:
                clabel = _label_chr(ch.uuid)
                ctag = f"  [{clabel}]" if clabel else ""
                props = ", ".join(ch.properties)
                print(f"    CHAR   {ch.uuid}{ctag}")
                print(f"           props={props}  handle={ch.handle}")
                for dsc in ch.descriptors:
                    print(f"      DSC  {dsc.uuid}  handle={dsc.handle}")

        print(f"\n{'═'*65}")
        print("  Reading known characteristics…")
        print(f"{'═'*65}")

        reads = [
            (FW_CHR,    "Firmware revision", _fmt_utf8),
            (MODEL_CHR, "Model number",      _fmt_utf8),
            (MFR_CHR,   "Manufacturer",      _fmt_utf8),
            (BAT_CHR,   "Battery",           _fmt_battery),
            (TEMP_CHR,  "Temperature",       _fmt_temp),
        ]
        for uuid, name, fmt in reads:
            try:
                val = await c.read_gatt_char(uuid)
                print(f"  {name:<22} {fmt(val)}")
            except Exception as e:
                print(f"  {name:<22} ✗  {e}")

        print(f"\n{'─'*65}")
        print(f"  Subscribing to temperature notifications for {stay} s…")
        count = [0]

        def _on_temp(_, data: bytes) -> None:
            count[0] += 1
            print(f"  NOTIFY #{count[0]:>3}  {_fmt_temp(data)}", flush=True)

        try:
            await c.start_notify(TEMP_CHR, _on_temp)
            await asyncio.sleep(stay)
            await c.stop_notify(TEMP_CHR)
        except Exception as e:
            print(f"  Notify failed: {e}")

        print(f"\n  Received {count[0]} temperature notification(s).")

    print("Disconnected cleanly.\n")


async def main() -> None:
    ap = argparse.ArgumentParser(description="AkvaLink BLE GATT debug client")
    ap.add_argument("--addr", "-a", metavar="ADDRESS",
                    help="connect directly to this address (skip scan)")
    ap.add_argument("--scan", "-s", action="store_true",
                    help="scan only, do not connect")
    ap.add_argument("--scan-time", type=float, default=5.0, metavar="S",
                    help="scan duration in seconds (default 5)")
    ap.add_argument("--time", "-t", type=int, default=10, metavar="S",
                    help="seconds to stay connected (default 10)")
    args = ap.parse_args()

    if args.addr:
        await explore(args.addr, args.time)
        return

    devices = await scan(args.scan_time)
    if not devices:
        print("No AkvaLink devices found.")
        sys.exit(1)

    print(f"\nFound {len(devices)} device(s):")
    for i, (d, adv) in enumerate(devices):
        svc_list = ", ".join(str(u) for u in adv.service_uuids) or "none"
        print(f"  [{i}] {d.name}  {d.address}  RSSI={adv.rssi} dBm")
        print(f"       services in adv: {svc_list}")

    if args.scan:
        return

    # Pick the strongest RSSI.
    best_dev, best_adv = max(devices, key=lambda x: x[1].rssi or -999)
    print(f"\nSelecting: {best_dev.name}  {best_dev.address}")
    await explore(best_dev.address, args.time)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nAborted.")
