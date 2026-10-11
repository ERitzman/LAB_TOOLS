<#
PURPOSE:
    Gracefully stops, finalizes, and verifies the active reference recording.

IMPORTANT:
    This script does not declare success merely because FFmpeg disappears.
    Recording Complete means FFmpeg exited cleanly and ffprobe verified that
    the resulting MP4 contains a readable video duration.
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Read-RecorderState {
    $state = @{}
    if (Test-Path -LiteralPath $StateFile) {
        foreach ($line in (Get-Content -LiteralPath $StateFile -ErrorAction SilentlyContinue)) {
            $parts = $line -split '=',2
            if ($parts.Count -eq 2) { $state[$parts[0]] = $parts[1] }
        }
    }
    return $state
}

$initialState = Read-RecorderState
if (-not $initialState.ContainsKey('STATUS') -or $initialState['STATUS'] -notin @('STARTING','RECORDING','FINALIZING','VERIFYING')) {
    [System.Windows.Forms.MessageBox]::Show(
        'No active recording was identified.',
        'Screen Recording',
        'OK',
        'Information'
    ) | Out-Null
    exit 0
}

# Request a graceful stop. The hidden worker owns FFmpeg standard input and
# will send q, allowing FFmpeg to finalize the MP4 container.
Set-Content -LiteralPath $StopFile -Value "STOP $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding ASCII
Write-SessionLog 'Graceful recording stop requested.'

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Finalizing Recording'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(620,310)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.ControlBox = $true
$form.TopMost = $true

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(20,18)
$title.Size = New-Object System.Drawing.Size(565,30)
$title.Font = New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
$title.Text = 'Finalizing Recording...'
$form.Controls.Add($title)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(22,60)
$statusLabel.Size = New-Object System.Drawing.Size(560,48)
$statusLabel.Text = 'Please wait while the recording is finalized and verified.'
$form.Controls.Add($statusLabel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(24,115)
$progress.Size = New-Object System.Drawing.Size(555,22)
$progress.Style = 'Marquee'
$progress.MarqueeAnimationSpeed = 30
$form.Controls.Add($progress)

$elapsedLabel = New-Object System.Windows.Forms.Label
$elapsedLabel.Location = New-Object System.Drawing.Point(22,150)
$elapsedLabel.Size = New-Object System.Drawing.Size(560,24)
$elapsedLabel.Text = 'Elapsed: 00:00:00'
$form.Controls.Add($elapsedLabel)

$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Location = New-Object System.Drawing.Point(22,178)
$warningLabel.Size = New-Object System.Drawing.Size(560,42)
$warningLabel.Text = 'Do not stop the recording process or close this window while finalization is in progress.'
$form.Controls.Add($warningLabel)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = New-Object System.Drawing.Point(485,228)
$okButton.Size = New-Object System.Drawing.Size(95,30)
$okButton.Text = 'OK'
$okButton.Enabled = $false
$okButton.Add_Click({ $form.Close() })
$form.Controls.Add($okButton)

$forceButton = New-Object System.Windows.Forms.Button
$forceButton.Location = New-Object System.Drawing.Point(365,228)
$forceButton.Size = New-Object System.Drawing.Size(110,30)
$forceButton.Text = 'Force Stop...'
$forceButton.Visible = $false
$form.Controls.Add($forceButton)

$script:Finished = $false
$script:ForceRequested = $false
$started = Get-Date

$form.Add_FormClosing({
    param($sender,$e)
    if (-not $script:Finished) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            'Finalization is still in progress. Wait for Recording Complete before closing this window.',
            'Finalizing Recording',
            'OK',
            'Information'
        ) | Out-Null
    }
})

$forceButton.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Force-stopping FFmpeg may leave the recording unusable.`n`nUse this only if the recorder has stopped responding.`n`nForce stop now?",
        'WARNING - Force Stop Recording',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        $state = Read-RecorderState
        $ffmpegPid = 0
        if ($state.ContainsKey('FFMPEG_PID')) { [void][int]::TryParse($state['FFMPEG_PID'], [ref]$ffmpegPid) }
        if ($ffmpegPid -gt 0) {
            Stop-Process -Id $ffmpegPid -Force -ErrorAction SilentlyContinue
            Write-SessionLog "WARNING - User force-stopped FFmpeg PID=$ffmpegPid. Recording may be unusable."
        }
        $script:ForceRequested = $true
        $forceButton.Enabled = $false
        $statusLabel.Text = 'Force stop requested. Waiting for the recorder worker to report final status...'
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    $elapsed = (Get-Date) - $started
    $elapsedLabel.Text = 'Elapsed: ' + $elapsed.ToString('hh\:mm\:ss')

    if ($elapsed.TotalSeconds -ge 120 -and -not $script:Finished) {
        $forceButton.Visible = $true
    }

    $state = Read-RecorderState
    if (-not $state.ContainsKey('STATUS')) { return }

    switch ($state['STATUS']) {
        'FINALIZING' {
            $statusLabel.Text = 'Status: Finalizing video... FFmpeg is closing the recording cleanly.'
        }
        'VERIFYING' {
            $statusLabel.Text = 'Status: Verifying video... Checking that the MP4 is readable.'
        }
        'COMPLETE' {
            $script:Finished = $true
            $timer.Stop()
            $progress.Style = 'Continuous'
            $progress.Value = 100
            $title.Text = 'Recording Complete'
            $duration = $state['DURATION']
            $output = $state['OUTPUT']
            $sizeText = ''
            if ($output -and (Test-Path -LiteralPath $output)) {
                $sizeMB = [math]::Round((Get-Item -LiteralPath $output).Length / 1MB, 1)
                $sizeText = " | Size: $sizeMB MB"
            }
            $statusLabel.Text = "The recording was finalized and verified successfully.`nDuration: $duration$sizeText"
            $warningLabel.Text = "File: $output`nRecording Encoded - OK to Close."
            $okButton.Enabled = $true
            $okButton.Focus()
            $forceButton.Visible = $false
        }
        'FAILED' {
            $script:Finished = $true
            $timer.Stop()
            $progress.Style = 'Continuous'
            $progress.Value = 0
            $title.Text = 'Recording Finalization Failed'
            $detail = $state['DETAIL']
            if ($script:ForceRequested) {
                $detail = "The recording process was force-stopped. The MP4 may be unusable. $detail"
            }
            $statusLabel.Text = "The recording could not be verified.`n$detail"
            $warningLabel.Text = 'Do not delete the recording. Preserve it for diagnostics.'
            $okButton.Enabled = $true
            $forceButton.Visible = $false
        }
    }
})

$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
$timer.Dispose()
$form.Dispose()
