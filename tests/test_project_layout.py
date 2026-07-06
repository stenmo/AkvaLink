"""Project/environment sanity checks — cheap guards, no hardware or ESP-IDF."""

import pathlib

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

KEY_FILES = [
    "CMakeLists.txt",
    "config/partitions.csv",
    "config/sdkconfig.defaults",
    "akvalink.cmd",
    "main/app_main.cpp",
    "main/ds18b20_task.cpp",
    "main/ds2482_onewire.cpp",
    "scripts/detect_nora_w40_port.py",
    "scripts/monitor_com.py",
]


@pytest.mark.parametrize("rel", KEY_FILES)
def test_key_file_exists(rel):
    assert (REPO_ROOT / rel).is_file(), f"missing expected file: {rel}"


def test_pyserial_available():
    # The host helpers depend on pyserial; the environment must provide it.
    import serial  # noqa: F401
    from serial.tools import list_ports  # noqa: F401


def _partition_rows():
    rows = []
    for line in (REPO_ROOT / "config" / "partitions.csv").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in line.split(",")]
        rows.append(fields)
    return rows


def test_partition_table_is_wellformed():
    rows = _partition_rows()
    assert rows, "partitions.csv has no data rows"
    # Name, Type, SubType, Offset, Size (Flags optional/trailing).
    for fields in rows:
        assert len(fields) >= 5, f"malformed partition row: {fields}"


def test_partition_table_has_expected_entries():
    rows = _partition_rows()
    names = {r[0] for r in rows}
    types = {r[1] for r in rows}
    # Dual-OTA Matter layout: no single 'factory' app, but ota_0/ota_1 apps.
    assert {"nvs", "ota_0", "ota_1", "fctry"} <= names
    assert "app" in types, "expected at least one 'app' partition"
