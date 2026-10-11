<#
PURPOSE:
    Starts the reference-session screen recorder.

PRIVACY:
    Everything visible on screen may be recorded. Stop recording before
    entering passwords, tokens, personal data, or other sensitive information.

NOTE:
    System Monitor is intentionally independent of recording. Setup starts the
    monitor once; this script starts only the recorder.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$FfmpegExe   = 'C:\EXTRAS\ffmpeg\bin\ffmpeg.exe'
$Worker      = 'C:\EXTRAS\Recorder-Worker.ps1'
$Recordings  = 'C:\Recordings'
$StateFile   = 'C:\AZBUILD\Recorder.state'
$StopFile    = 'C:\AZBUILD\Recorder.stop'
$SessionLog  = 'C:\AZBUILD\Logs\Session.log'
$UsbSessionLog = $null

try {
    $v = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'WIN11_BUILD' -and $_.DriveLetter } | Select-Object -First 1
    if ($v) { $UsbSessionLog = "$($v.DriveLetter):\AZBUILD\Logs\Session.log" }
} catch {}

function Write-SessionLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -LiteralPath $SessionLog -Encoding UTF8 -Value $line
    if ($script:UsbSessionLog) { try { Add-Content -LiteralPath $script:UsbSessionLog -Encoding UTF8 -Value $line } catch {} }
}

function Read-StateValue {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    $line = Get-Content -LiteralPath $StateFile -ErrorAction SilentlyContinue | Where-Object { $_ -like "$Name=*" } | Select-Object -First 1
    if ($line) { return $line.Substring($Name.Length + 1) }
    return $null
}

if (-not (Test-Path -LiteralPath $Recordings)) {
    New-Item -Path $Recordings -ItemType Directory -Force | Out-Null
}

# Prevent accidental double-start. A stale state file is harmless if its worker
# process is no longer running.
$existingWorkerPid = Read-StateValue -Name 'WORKER_PID'
$existingStatus = Read-StateValue -Name 'STATUS'
if ($existingWorkerPid -and $existingStatus -in @('STARTING','RECORDING','FINALIZING','VERIFYING')) {
    $existingWorker = Get-Process -Id ([int]$existingWorkerPid) -ErrorAction SilentlyContinue
    if ($existingWorker) {
        [System.Windows.Forms.MessageBox]::Show(
            "A recording session is already active or being finalized.`n`nStatus: $existingStatus",
            'Screen Recording',
            'OK',
            'Information'
        ) | Out-Null
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $FfmpegExe -PathType Leaf)) {
    Write-SessionLog "FFmpeg not found: $FfmpegExe"
    [System.Windows.Forms.MessageBox]::Show(
        "FFmpeg was not found.`n`nRecording cannot start, but the LAB build may continue.",
        'Screen Recording',
        'OK',
        'Warning'
    ) | Out-Null
    exit 1
}

if (-not (Test-Path -LiteralPath $Worker -PathType Leaf)) {
    Write-SessionLog "Recorder worker not found: $Worker"
    [System.Windows.Forms.MessageBox]::Show(
        "The recorder worker was not found.`n`nRecording cannot start.",
        'Screen Recording',
        'OK',
        'Warning'
    ) | Out-Null
    exit 1
}

Remove-Item -LiteralPath $StateFile,$StopFile -Force -ErrorAction SilentlyContinue
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$output = Join-Path $Recordings "ReferenceSession_$timestamp.mp4"

$workerArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Worker`" -OutputPath `"$output`""
$workerProcess = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                               -ArgumentList $workerArgs `
                               -WindowStyle Hidden `
                               -PassThru

# Give the worker a moment to start FFmpeg and publish its state.
$deadline = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 200
    $status = Read-StateValue -Name 'STATUS'
} while (-not $status -and (Get-Date) -lt $deadline)

if ($status -eq 'FAILED' -or -not $status) {
    $detail = Read-StateValue -Name 'DETAIL'
    if (-not $detail) { $detail = 'The recorder worker did not report a successful start.' }
    Write-SessionLog "Recording start failed. $detail"
    [System.Windows.Forms.MessageBox]::Show(
        "Recording could not start.`n`n$detail",
        'Screen Recording',
        'OK',
        'Warning'
    ) | Out-Null
    exit 1
}

Write-SessionLog "Recording start confirmed. WorkerPID=$($workerProcess.Id) File=$output"
[System.Windows.Forms.MessageBox]::Show(
    "Reference-build recording has started.`n`nFile:`n$output`n`nIMPORTANT: Stop recording before entering passwords, tokens, or other sensitive information.",
    'Recording Started',
    'OK',
    'Information'
) | Out-Null
