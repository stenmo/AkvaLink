param(
    [string]$Port = "COM62",
    [int]$Seconds = 180,
    [int]$Baud = 115200,
    [string]$LogFile = "$PSScriptRoot\..\logs\nora-w40-monitor.log"
)

$dir = Split-Path $LogFile -Parent
if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function Open-Port {
    param([string]$Name, [int]$Baud)
    $sp = New-Object System.IO.Ports.SerialPort $Name, $Baud, None, 8, one
    $sp.ReadTimeout  = 500
    $sp.WriteTimeout = 500
    $sp.DtrEnable    = $true
    $sp.RtsEnable    = $true
    $sp.Open()
    return $sp
}

"=== monitor start $(Get-Date -Format o) on $Port for ${Seconds}s ===" | Tee-Object -FilePath $LogFile

$end       = (Get-Date).AddSeconds($Seconds)
$sp        = $null
$backoffMs = 200

while ((Get-Date) -lt $end) {

    # (Re)open the port if not currently open
    if ($null -eq $sp -or -not $sp.IsOpen) {
        try {
            if ($sp) { try { $sp.Dispose() } catch {} ; $sp = $null }
            $sp = Open-Port -Name $Port -Baud $Baud
            $ts = (Get-Date -Format "HH:mm:ss.fff")
            "$ts [monitor] $Port opened @ ${Baud}" | Tee-Object -FilePath $LogFile -Append
            $backoffMs = 200
        } catch {
            $ts = (Get-Date -Format "HH:mm:ss.fff")
            "$ts [monitor] open failed: $($_.Exception.Message) (retry in ${backoffMs}ms)" |
                Tee-Object -FilePath $LogFile -Append
            Start-Sleep -Milliseconds $backoffMs
            if ($backoffMs -lt 3000) { $backoffMs = [math]::Min($backoffMs * 2, 3000) }
            continue
        }
    }

    try {
        $line = $sp.ReadLine()
        $ts = (Get-Date -Format "HH:mm:ss.fff")
        "$ts $line" | Tee-Object -FilePath $LogFile -Append
    }
    catch [System.TimeoutException] {
        # No data this window - normal, keep polling
    }
    catch {
        # Port closed (device reboot / USB drop) or any other I/O failure.
        # Drop the handle so the outer loop reopens with backoff.
        $ts = (Get-Date -Format "HH:mm:ss.fff")
        "$ts [monitor] port lost: $($_.Exception.Message)" |
            Tee-Object -FilePath $LogFile -Append
        try { $sp.Close() }   catch {}
        try { $sp.Dispose() } catch {}
        $sp = $null
        Start-Sleep -Milliseconds 200
    }
}

if ($sp) { try { $sp.Close() } catch {}; try { $sp.Dispose() } catch {} }
"=== monitor end $(Get-Date -Format o) ===" | Tee-Object -FilePath $LogFile -Append
