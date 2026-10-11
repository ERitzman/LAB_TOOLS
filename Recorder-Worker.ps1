<#
PURPOSE:
    Owns the hidden FFmpeg recording process so it can be stopped gracefully.

WHY A WORKER EXISTS:
    FFmpeg must receive the letter q through its standard input before it exits.
    That allows FFmpeg to finish the MP4 container instead of being force-killed.

USER INTERACTION:
    None. This script runs hidden. Use the Start Recording and Stop Recording
    desktop shortcuts instead.
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$FfmpegExe    = 'C:\EXTRAS\ffmpeg\bin\ffmpeg.exe'
$FfprobeExe   = 'C:\EXTRAS\ffmpeg\bin\ffprobe.exe'
$StateFile    = 'C:\AZBUILD\Recorder.state'
$StopFile     = 'C:\AZBUILD\Recorder.stop'
$SessionLog   = 'C:\AZBUILD\Logs\Session.log'
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

function Write-RecorderState {
    param(
        [string]$Status,
        [int]$FfmpegPid = 0,
        [string]$Detail = '',
        [string]$Duration = ''
    )

    $safeDetail = ($Detail -replace "`r|`n", ' ')
    $lines = @(
        "STATUS=$Status"
        "WORKER_PID=$PID"
        "FFMPEG_PID=$FfmpegPid"
        "OUTPUT=$OutputPath"
        "DURATION=$Duration"
        "DETAIL=$safeDetail"
        "UPDATED=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )

    $temp = "$StateFile.tmp"
    Set-Content -LiteralPath $temp -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $StateFile -Force
}

try {
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Write-RecorderState -Status 'STARTING'

    if (-not (Test-Path -LiteralPath $FfmpegExe -PathType Leaf)) {
        throw "FFmpeg not found: $FfmpegExe"
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FfmpegExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = '-y -f gdigrab -framerate 15 -i desktop -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p "' + $OutputPath + '"'

    $ffmpeg = New-Object System.Diagnostics.Process
    $ffmpeg.StartInfo = $psi

    if (-not $ffmpeg.Start()) {
        throw 'FFmpeg did not start.'
    }

    Write-RecorderState -Status 'RECORDING' -FfmpegPid $ffmpeg.Id
    Write-SessionLog "Recording started. WorkerPID=$PID FfmpegPID=$($ffmpeg.Id) File=$OutputPath"

    while (-not $ffmpeg.HasExited) {
        if (Test-Path -LiteralPath $StopFile) {
            Write-RecorderState -Status 'FINALIZING' -FfmpegPid $ffmpeg.Id -Detail 'Graceful stop requested.'
            Write-SessionLog "Graceful stop requested. Sending q to FFmpeg PID=$($ffmpeg.Id)."

            try {
                $ffmpeg.StandardInput.WriteLine('q')
                $ffmpeg.StandardInput.Flush()
            }
            catch {
                Write-SessionLog "WARN - Could not send q to FFmpeg: $($_.Exception.Message)"
            }

            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $ffmpeg.HasExited) {
        $ffmpeg.WaitForExit()
    }

    $exitCode = $ffmpeg.ExitCode
    Write-SessionLog "FFmpeg exited. ExitCode=$exitCode File=$OutputPath"

    if ($exitCode -ne 0) {
        throw "FFmpeg exited with code $exitCode."
    }

    Write-RecorderState -Status 'VERIFYING' -Detail 'FFmpeg exited cleanly. Verifying the MP4.'

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw 'The recording file was not created.'
    }

    $recordingFile = Get-Item -LiteralPath $OutputPath
    if ($recordingFile.Length -le 0) {
        throw 'The recording file is empty.'
    }

    if (-not (Test-Path -LiteralPath $FfprobeExe -PathType Leaf)) {
        throw "ffprobe was not found: $FfprobeExe"
    }

    $probePsi = New-Object System.Diagnostics.ProcessStartInfo
    $probePsi.FileName = $FfprobeExe
    $probePsi.UseShellExecute = $false
    $probePsi.CreateNoWindow = $true
    $probePsi.RedirectStandardOutput = $true
    $probePsi.RedirectStandardError = $true
    $probePsi.Arguments = '-v error -select_streams v:0 -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "' + $OutputPath + '"'

    $probe = New-Object System.Diagnostics.Process
    $probe.StartInfo = $probePsi
    [void]$probe.Start()
    $probeOutput = $probe.StandardOutput.ReadToEnd().Trim()
    $probeError = $probe.StandardError.ReadToEnd().Trim()
    $probe.WaitForExit()

    if ($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probeOutput)) {
        if ([string]::IsNullOrWhiteSpace($probeError)) { $probeError = 'ffprobe could not read a video duration.' }
        throw "Recording verification failed: $probeError"
    }

    $durationSeconds = 0.0
    if (-not [double]::TryParse($probeOutput, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$durationSeconds)) {
        throw "Recording verification returned an unreadable duration: $probeOutput"
    }
    if ($durationSeconds -le 0) {
        throw 'Recording verification returned a zero duration.'
    }

    $durationText = [TimeSpan]::FromSeconds($durationSeconds).ToString('hh\:mm\:ss')
    Write-RecorderState -Status 'COMPLETE' -Detail "Verified MP4. Size=$($recordingFile.Length) bytes." -Duration $durationText
    Write-SessionLog "Recording finalized and verified. Duration=$durationText Size=$($recordingFile.Length) File=$OutputPath"
}
catch {
    Write-RecorderState -Status 'FAILED' -Detail $_.Exception.Message
    Write-SessionLog "FAIL - Recorder worker: $($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
}
