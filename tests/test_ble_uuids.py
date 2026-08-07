"""BLE GATT UUID cross-file consistency checks.

`main/ble_gatt.cpp` is the source of truth for AkvaLink's standalone BLE GATT
contract. This test extracts the UUIDs it defines and checks that every
consumer of that contract — the web page (Web Bluetooth), the Flutter app,
and the debug script — advertises the *same* values. A firmware UUID change
that isn't propagated everywhere should fail here instead of silently
breaking temperature reads / OTA in the field.

Pure stdlib (re), no browser, no BLE hardware — mirrors the style of
tests/test_web.py.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "main" / "ble_gatt.cpp"
WEB_EN = ROOT / "web" / "index.html"
WEB_SV = ROOT / "web" / "index.sv.html"
APP_DART = ROOT / "app_flutter" / "lib" / "ble" / "akvalink_uuids.dart"
PY_SCRIPT = ROOT / "scripts" / "ble_gatt_client.py"


def _fw_16bit() -> dict:
    """UUID_<NAME> = BLE_UUID16_INIT(0xNNNN) -> {"<NAME>": 0xNNNN}."""
    text = FW.read_text(encoding="utf-8")
    return {
        name: int(val, 16)
        for name, val in re.findall(
            r"static const ble_uuid16_t UUID_(\w+)\s*=\s*BLE_UUID16_INIT\((0x[0-9A-Fa-f]+)\)",
            text,
        )
    }


def _fw_custom_suffixes() -> dict:
    """UUID_<NAME> = BLE_UUID128_INIT(0xSS, ...) -> {"<NAME>": "ss"} (first byte, lowercase hex)."""
    text = FW.read_text(encoding="utf-8")
    return {
        name: val.lower()
        for name, val in re.findall(
            r"static const ble_uuid128_t UUID_(\w+)\s*=\s*BLE_UUID128_INIT\(\s*0x([0-9A-Fa-f]{2})",
            text,
        )
    }


FW_16 = _fw_16bit()
FW_CUSTOM = _fw_custom_suffixes()


def test_firmware_defines_expected_16bit_uuids():
    # Regression guard: catches typos/accidental edits to well-known BT SIG UUIDs.
    expected = {
        "DIS": 0x180A, "ESS": 0x181A, "BAS": 0x180F,
        "MANUFACTURER": 0x2A29, "MODEL": 0x2A24, "FW_REVISION": 0x2A26,
        "TEMPERATURE": 0x2A6E, "BATTERY_LVL": 0x2A19,
    }
    for name, val in expected.items():
        assert name in FW_16, f"main/ble_gatt.cpp: UUID_{name} not found"
        assert FW_16[name] == val, (
            f"main/ble_gatt.cpp: UUID_{name} is {FW_16[name]:#06x}, expected {val:#06x}"
        )


def test_firmware_defines_expected_custom_suffixes():
    expected = {
        "AKVALINK_SVC": "01", "UPTIME": "02", "DEV_NAME": "03",
        "ALERT_HIGH": "04", "ALERT_LOW": "05",
        "OTA_SVC": "10", "OTA_CTRL": "11", "OTA_DATA": "12",
    }
    for name, suffix in expected.items():
        assert name in FW_CUSTOM, f"main/ble_gatt.cpp: UUID_{name} not found"
        assert FW_CUSTOM[name] == suffix, (
            f"main/ble_gatt.cpp: UUID_{name} suffix is {FW_CUSTOM[name]}, expected {suffix}"
        )


def _web_vars(path: Path):
    text = path.read_text(encoding="utf-8")
    hex_vars = {
        name: int(val, 16)
        for name, val in re.findall(r"var (\w+)\s*=\s*(0x[0-9A-Fa-f]+);", text)
    }
    str_vars = dict(re.findall(r"var (\w+)\s*=\s*'(f0a00001-[0-9a-f-]+)';", text))
    return hex_vars, str_vars


@pytest.mark.parametrize("path", [WEB_EN, WEB_SV], ids=["en", "sv"])
def test_web_page_uuids_match_firmware(path):
    hex_vars, str_vars = _web_vars(path)
    assert hex_vars.get("ESS_SERVICE") == FW_16["ESS"]
    assert hex_vars.get("TEMP_CHAR") == FW_16["TEMPERATURE"]
    assert hex_vars.get("DIS_SERVICE") == FW_16["DIS"]
    assert hex_vars.get("FW_CHAR") == FW_16["FW_REVISION"]
    assert str_vars.get("OTA_SERVICE", "").endswith(FW_CUSTOM["OTA_SVC"])
    assert str_vars.get("OTA_CTRL", "").endswith(FW_CUSTOM["OTA_CTRL"])
    assert str_vars.get("OTA_DATA", "").endswith(FW_CUSTOM["OTA_DATA"])


def _short16(uuid128: str) -> int:
    """'0000181a-0000-1000-8000-00805f9b34fb' -> 0x181a"""
    return int(uuid128[4:8], 16)


def _dart_vars() -> dict:
    text = APP_DART.read_text(encoding="utf-8")
    return dict(re.findall(r"static const (\w+)\s*=\s*'([0-9a-f-]{36})'", text))


def test_flutter_app_uuids_match_firmware():
    v = _dart_vars()
    assert _short16(v["essService"]) == FW_16["ESS"]
    assert _short16(v["tempChar"]) == FW_16["TEMPERATURE"]
    assert _short16(v["disService"]) == FW_16["DIS"]
    assert _short16(v["fwChar"]) == FW_16["FW_REVISION"]
    assert _short16(v["modelChar"]) == FW_16["MODEL"]
    assert _short16(v["mfrChar"]) == FW_16["MANUFACTURER"]
    assert _short16(v["basService"]) == FW_16["BAS"]
    assert _short16(v["batteryChar"]) == FW_16["BATTERY_LVL"]
    assert v["otaService"][-2:] == FW_CUSTOM["OTA_SVC"]
    assert v["otaCtrl"][-2:] == FW_CUSTOM["OTA_CTRL"]
    assert v["otaData"][-2:] == FW_CUSTOM["OTA_DATA"]


def _py_script_vars() -> dict:
    text = PY_SCRIPT.read_text(encoding="utf-8")
    return dict(re.findall(r'(\w+)\s*=\s*"([0-9a-f-]{36})"', text))


def test_debug_script_uuids_match_firmware():
    v = _py_script_vars()
    assert _short16(v["ESS_SVC"]) == FW_16["ESS"]
    assert _short16(v["TEMP_CHR"]) == FW_16["TEMPERATURE"]
    assert _short16(v["DIS_SVC"]) == FW_16["DIS"]
    assert _short16(v["FW_CHR"]) == FW_16["FW_REVISION"]
    assert _short16(v["MODEL_CHR"]) == FW_16["MODEL"]
    assert _short16(v["MFR_CHR"]) == FW_16["MANUFACTURER"]
    assert _short16(v["BAS_SVC"]) == FW_16["BAS"]
    assert _short16(v["BAT_CHR"]) == FW_16["BATTERY_LVL"]
    assert v["AKVA_SVC"][-2:] == FW_CUSTOM["AKVALINK_SVC"]
    assert v["UPTIME_CHR"][-2:] == FW_CUSTOM["UPTIME"]
    assert v["NAME_CHR"][-2:] == FW_CUSTOM["DEV_NAME"]
    assert v["ALERT_HI_CHR"][-2:] == FW_CUSTOM["ALERT_HIGH"]
    assert v["ALERT_LO_CHR"][-2:] == FW_CUSTOM["ALERT_LOW"]
    assert v["OTA_SVC"][-2:] == FW_CUSTOM["OTA_SVC"]
    assert v["OTA_CTRL"][-2:] == FW_CUSTOM["OTA_CTRL"]
    assert v["OTA_DATA"][-2:] == FW_CUSTOM["OTA_DATA"]


@pytest.mark.parametrize("path", [WEB_EN, WEB_SV], ids=["en", "sv"])
def test_web_gatt_reference_table_matches_firmware(path):
    # The human-readable GATT table (id="live", 4-5 col reference table) must
    # quote the same UUIDs as main/ble_gatt.cpp — this is what a developer
    # implementing their own BLE client would copy-paste.
    text = path.read_text(encoding="utf-8")
    for name in ("ESS", "DIS", "BAS", "TEMPERATURE", "MANUFACTURER", "MODEL", "FW_REVISION", "BATTERY_LVL"):
        expected = f"0x{FW_16[name]:04X}"
        assert expected in text, f"{path.name}: UUID {expected} ({name}) not found in GATT reference table"
    for name in ("UPTIME", "DEV_NAME", "ALERT_HIGH", "ALERT_LOW", "OTA_CTRL", "OTA_DATA"):
        assert f"6c00{FW_CUSTOM[name]}" in text, (
            f"{path.name}: custom UUID suffix for {name} not found in GATT reference table"
        )

