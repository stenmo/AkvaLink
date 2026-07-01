# Detect the COM port of an attached NORA-W40 EVK.
# Matches USB VID_303A & PID_1001 (Espressif ESP32-C6 native USB-Serial/JTAG).
# Prints just the port name (e.g. "COM62") to stdout, or nothing if not found.
# Exit 0 if found, 1 if not.

$dev = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DeviceID -match 'USB\\VID_303A&PID_1001' -and $_.Name -match 'COM(\d+)'
    } |
    Select-Object -First 1

if ($dev) {
    $m = [regex]::Match($dev.Name, 'COM(\d+)')
    if ($m.Success) {
        Write-Output ('COM' + $m.Groups[1].Value)
        exit 0
    }
}

exit 1
