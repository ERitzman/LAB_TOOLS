<#
.SYNOPSIS
    Lightweight Windows system monitor.

.PURPOSE
    Displays a compact, always-on-top view of CPU, logical processor, memory,
    disk, and network activity.

    This file is intentionally self-contained. PowerShell starts the utility
    and performs integration/logging tasks. An embedded C# WinForms class
    implements the persistent graphical interface.

.WHEN THIS RUNS
    Run this script with Windows PowerShell 5.1. No separate C# project,
    compiler installation, Java runtime, or supporting executable is required.

.SAFETY
    This utility is observational. It does not change CPU, memory, disk,
    network, power, or Windows performance settings.

.LOGGING
    Runtime warnings/errors are written to:
        C:\AZBUILD\Logs\SystemMonitor.log

    If removable media named WIN11_BUILD is attached and writable, log entries
    are also mirrored to:
        WIN11_BUILD:\AZBUILD\Logs\SystemMonitor.log

.TROUBLESHOOTING
    If the monitor does not appear, first check SystemMonitor.log.
    Closing the monitor does not affect other programs or build processes.

============================================================================
EASTER-NUT: WHY IS THERE C# INSIDE THIS POWERSHELL SCRIPT?
============================================================================
PowerShell is excellent at automation and orchestration. A persistent Windows
GUI has different needs: repainting, timers, mouse interaction, window
movement, minimize/close behavior, and responsive controls.

The embedded C# section handles those GUI jobs using Windows Forms while
PowerShell remains the launcher and integration layer.

You do NOT need to understand C# to use this utility. The C# section uses
descriptive names and comments so a curious reader can identify what each
major part does.
============================================================================
#>

param(
    [switch]$HiddenChild
)

# ============================================================================
# PART 0 - POWERSHELL: DETACH FROM A VISIBLE HOST
# ============================================================================
#
# A borderless monitor should not leave a PowerShell console window behind.
# When this file is started normally, it launches a second copy of itself in a
# hidden Windows PowerShell process and then returns control to the caller.
#
# The -HiddenChild switch prevents an infinite relaunch loop. It is an internal
# implementation detail; users do not need to supply it themselves.
#
# This also means Setup.ps1 does not have to rely on its own -WindowStyle Hidden
# behavior to keep the monitor cleanly detached.

if (-not $HiddenChild) {
    try {
        $PowerShellExe = Join-Path $PSHOME 'powershell.exe'

        $ChildArguments = @(
            '-NoProfile'
            '-ExecutionPolicy', 'Bypass'
            '-WindowStyle', 'Hidden'
            '-File', ('"{0}"' -f $PSCommandPath)
            '-HiddenChild'
        )

        Start-Process `
            -FilePath $PowerShellExe `
            -ArgumentList $ChildArguments `
            -WindowStyle Hidden `
            -ErrorAction Stop

        return
    }
    catch {
        # If detaching fails, continue in the current process so the user gets
        # a usable monitor and a visible error path instead of silent failure.
        Write-Warning "Could not detach System Monitor from the current PowerShell host: $($_.Exception.Message)"
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# PART 1 - POWERSHELL: PATHS AND LOGGING
# ============================================================================

$LogDirectory = 'C:\AZBUILD\Logs'
$LogPath = Join-Path $LogDirectory 'SystemMonitor.log'
$UsbLogPath = $null

try {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }
}
catch {
    # Logging failure must not prevent an observational utility from starting.
}

try {
    $UsbVolume = Get-Volume |
        Where-Object { $_.FileSystemLabel -eq 'WIN11_BUILD' -and $_.DriveLetter } |
        Select-Object -First 1

    if ($UsbVolume) {
        $UsbDirectory = "$($UsbVolume.DriveLetter):\AZBUILD\Logs"
        New-Item -Path $UsbDirectory -ItemType Directory -Force | Out-Null
        $UsbLogPath = Join-Path $UsbDirectory 'SystemMonitor.log'
    }
}
catch {
    # USB mirroring is optional.
}

function Write-MonitorLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"

    try {
        Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
    }
    catch {}

    if ($script:UsbLogPath) {
        try {
            Add-Content -LiteralPath $script:UsbLogPath -Value $Line -Encoding UTF8
        }
        catch {}
    }
}

Write-MonitorLog 'System Monitor starting.'

# ============================================================================
# PART 2 - EASTER-NUT: EMBEDDED C# WINDOWS FORMS MONITOR
# ============================================================================

$MonitorSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.VisualBasic.Devices;

public sealed class SystemMonitorForm : Form
{
    // Public metadata also gives Add-Type a discoverable public member.
    // This avoids the Windows PowerShell 5.1 warning that a generated type
    // defines no public methods or properties.
    public static string UtilityName
    {
        get { return "System Monitor"; }
    }

    // Windows messages let the operating system perform dragging smoothly.
    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(
        IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    private const int WM_NCLBUTTONDOWN = 0x00A1;
    private const int HTCAPTION = 2;

    private readonly Timer refreshTimer = new Timer();

    private readonly Label cpuLabel;
    private readonly Label memoryLabel;
    private readonly Label diskLabel;
    private readonly Label networkLabel;
    private readonly Label interfaceLabel;
    private readonly Label statusLabel;

    private readonly FlatMeter cpuMeter;
    private readonly FlatMeter memoryMeter;
    private readonly FlatMeter diskMeter;

    private readonly List<Label> coreLabels = new List<Label>();
    private readonly List<FlatMeter> coreMeters = new List<FlatMeter>();
    private readonly List<PerformanceCounter> coreCounters =
        new List<PerformanceCounter>();

    private readonly PerformanceCounter totalCpuCounter;

    private long previousRx;
    private long previousTx;
    private DateTime previousNetworkTime;
    private int refreshNumber;

    private readonly string logPath;
    private readonly string usbLogPath;

    // Small custom meter avoids the heavy/default ProgressBar appearance.
    private sealed class FlatMeter
    {
        public Panel Background { get; private set; }
        public Panel Fill { get; private set; }
        public int MaximumWidth { get; private set; }

        public FlatMeter(Control parent, int x, int y, int width, int height)
        {
            MaximumWidth = Math.Max(1, width);

            Background = new Panel();
            Background.Location = new Point(x, y);
            Background.Size = new Size(MaximumWidth, height);
            Background.BackColor = Color.FromArgb(45, 45, 45);

            Fill = new Panel();
            Fill.Location = new Point(0, 0);
            Fill.Size = new Size(0, height);
            Fill.BackColor = Color.Gainsboro;

            Background.Controls.Add(Fill);
            parent.Controls.Add(Background);
        }

        public void SetPercent(float percent)
        {
            percent = Math.Max(0f, Math.Min(100f, percent));
            Fill.Width = (int)Math.Round(MaximumWidth * (percent / 100f));
        }
    }

    public SystemMonitorForm(string localLogPath, string removableLogPath)
    {
        logPath = localLogPath;
        usbLogPath = removableLogPath;

        Text = "System Monitor";
        Name = "SystemMonitor";
        FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.Black;
        ForeColor = Color.White;
        TopMost = true;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        Font = new Font("Consolas", 8f, FontStyle.Regular);

        int logicalProcessors = Math.Max(1, Environment.ProcessorCount);
        int columns = logicalProcessors > 8 ? 2 : 1;
        int rows = (int)Math.Ceiling(logicalProcessors / (double)columns);

        Width = columns == 2 ? 500 : 440;
        Height = 270 + (rows * 22);

        Rectangle workingArea = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(
            workingArea.Right - Width - 12,
            workingArea.Top + 12);

        // Header.
        AddLabel("LIVE SYSTEM MONITOR", 12, 10, Width - 50, 20, true, Color.White);

        Button closeButton = CreateHeaderButton("X", Width - 34, 5);
        closeButton.Click += delegate { Close(); };
        Controls.Add(closeButton);

        int physicalCores = 0;
        int sockets = 0;
        string cpuName = "CPU information unavailable";

        try
        {
            using (var searcher = new System.Management.ManagementObjectSearcher(
                "SELECT Name,NumberOfCores,NumberOfLogicalProcessors FROM Win32_Processor"))
            {
                foreach (System.Management.ManagementObject cpu in searcher.Get())
                {
                    sockets++;
                    physicalCores += Convert.ToInt32(cpu["NumberOfCores"]);
                    if (cpuName == "CPU information unavailable" && cpu["Name"] != null)
                        cpuName = Convert.ToString(cpu["Name"]).Trim();
                }
            }
        }
        catch (Exception ex)
        {
            WriteLog("WARN", "CPU topology query failed: " + ex.Message);
        }

        string topology = physicalCores > 0
            ? String.Format("{0} physical / {1} logical / {2} socket(s)",
                physicalCores, logicalProcessors, Math.Max(1, sockets))
            : String.Format("{0} logical processor(s)", logicalProcessors);

        AddLabel(topology, 12, 34, Width - 24, 18, false, Color.LightGray);
        AddLabel(cpuName, 12, 53, Width - 24, 18, false, Color.LightGray);

        // Summary rows. Values have enough width to stay on one line.
        cpuLabel = AddLabel("CPU TOTAL   -- %", 12, 82, 225, 18, true, Color.White);
        cpuMeter = new FlatMeter(this, 250, 87, Width - 262, 8);

        memoryLabel = AddLabel("MEMORY      -- %", 12, 108, 225, 18, true, Color.White);
        memoryMeter = new FlatMeter(this, 250, 113, Width - 262, 8);

        diskLabel = AddLabel("DISK C:     -- %", 12, 134, 225, 18, true, Color.White);
        diskMeter = new FlatMeter(this, 250, 139, Width - 262, 8);

        networkLabel = AddLabel(
            "NETWORK     RX -- / TX --", 12, 160, Width - 24, 18, true, Color.White);
        interfaceLabel = AddLabel(
            "Active interfaces: --", 12, 181, Width - 24, 18, false, Color.LightGray);

        AddLabel("LOGICAL PROCESSORS", 12, 208, Width - 24, 18, true, Color.White);

        int columnWidth = (Width - 30) / columns;
        int coreBaseY = 232;

        for (int i = 0; i < logicalProcessors; i++)
        {
            int column = i / rows;
            int row = i % rows;
            int x = 12 + (column * columnWidth);
            int y = coreBaseY + (row * 22);

            Label coreLabel = AddLabel(
                String.Format("LCore {0,2}: -- %", i),
                x, y, 112, 18, false, Color.White);

            FlatMeter meter = new FlatMeter(
                this, x + 116, y + 5, columnWidth - 126, 7);

            coreLabels.Add(coreLabel);
            coreMeters.Add(meter);

            try
            {
                PerformanceCounter counter = new PerformanceCounter(
                    "Processor", "% Processor Time", i.ToString(), true);
                counter.NextValue(); // Prime the counter; first sample is normally zero.
                coreCounters.Add(counter);
            }
            catch
            {
                coreCounters.Add(null);
            }
        }

        int statusY = coreBaseY + (rows * 22) + 8;
        statusLabel = AddLabel(
            "Starting... | Click here to minimize",
            12, statusY, Width - 24, 22, false, Color.LightGray);

        // The whole bottom status line is the minimize control.
        statusLabel.Cursor = Cursors.Hand;
        statusLabel.Click += delegate
        {
            WindowState = FormWindowState.Minimized;
        };

        // Native dragging: clicking unused black background or the header/title
        // asks Windows to move the borderless form as if its title bar was used.
        MouseDown += BeginNativeDrag;
        foreach (Control control in Controls)
        {
            if (control != closeButton && control != statusLabel &&
                !(control is Button))
            {
                control.MouseDown += BeginNativeDrag;
            }
        }

        totalCpuCounter = new PerformanceCounter(
            "Processor", "% Processor Time", "_Total", true);
        totalCpuCounter.NextValue();

        int initialActiveInterfaces;
        ReadNetworkTotals(out previousRx, out previousTx, out initialActiveInterfaces);
        previousNetworkTime = DateTime.UtcNow;

        refreshTimer.Interval = 3000;
        refreshTimer.Tick += delegate { RefreshMetrics(); };

        Shown += delegate
        {
            RefreshMetrics();
            refreshTimer.Start();
        };

        FormClosed += delegate
        {
            refreshTimer.Stop();
            refreshTimer.Dispose();

            totalCpuCounter.Dispose();
            foreach (PerformanceCounter counter in coreCounters)
            {
                if (counter != null)
                    counter.Dispose();
            }

            WriteLog("INFO", "System Monitor closed.");
        };
    }

    private Button CreateHeaderButton(string text, int x, int y)
    {
        Button button = new Button();
        button.Text = text;
        button.Location = new Point(x, y);
        button.Size = new Size(28, 24);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = Color.Black;
        button.ForeColor = Color.White;
        button.TabStop = false;
        return button;
    }

    private Label AddLabel(
        string text, int x, int y, int width, int height,
        bool bold, Color color)
    {
        Label label = new Label();
        label.Text = text;
        label.Location = new Point(x, y);
        label.Size = new Size(width, height);
        label.ForeColor = color;
        label.BackColor = Color.Black;
        label.Font = new Font(
            "Consolas", 8f, bold ? FontStyle.Bold : FontStyle.Regular);
        label.AutoEllipsis = true;
        Controls.Add(label);
        return label;
    }

    private void BeginNativeDrag(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left)
            return;

        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN,
            new IntPtr(HTCAPTION), IntPtr.Zero);
    }

    private void RefreshMetrics()
    {
        refreshNumber++;

        UpdateCpuMetrics();
        UpdateMemoryMetrics();
        UpdateNetworkMetrics();

        // Disk capacity changes slowly; polling every second refresh is enough.
        if (refreshNumber == 1 || refreshNumber % 2 == 0)
            UpdateDiskMetrics();

        statusLabel.Text =
            DateTime.Now.ToString("HH:mm:ss") + " | Click here to minimize";
    }

    private void UpdateCpuMetrics()
    {
        try
        {
            float total = ClampPercent(totalCpuCounter.NextValue());
            cpuLabel.Text = String.Format("CPU TOTAL   {0,3:0} %", total);
            cpuMeter.SetPercent(total);

            for (int i = 0; i < coreCounters.Count; i++)
            {
                PerformanceCounter counter = coreCounters[i];
                if (counter == null)
                    continue;

                float value = ClampPercent(counter.NextValue());
                coreLabels[i].Text =
                    String.Format("LCore {0,2}: {1,3:0} %", i, value);
                coreMeters[i].SetPercent(value);
            }
        }
        catch (Exception ex)
        {
            WriteLog("WARN", "CPU update failed: " + ex.Message);
        }
    }

    private void UpdateMemoryMetrics()
    {
        try
        {
            ComputerInfo info = new ComputerInfo();
            double total = info.TotalPhysicalMemory;
            double available = info.AvailablePhysicalMemory;
            double used = total - available;

            double percent = total > 0 ? (used / total) * 100.0 : 0.0;

            memoryLabel.Text = String.Format(
                "MEMORY      {0,3:0} %   {1:0.0} / {2:0.0} GB",
                percent, used / 1073741824.0, total / 1073741824.0);

            memoryMeter.SetPercent((float)percent);
        }
        catch (Exception ex)
        {
            memoryLabel.Text = "MEMORY      unavailable";
            WriteLog("WARN", "Memory update failed: " + ex.Message);
        }
    }

    private void UpdateDiskMetrics()
    {
        try
        {
            DriveInfo drive = new DriveInfo("C");
            double total = drive.TotalSize;
            double free = drive.TotalFreeSpace;
            double used = total - free;
            double percent = total > 0 ? (used / total) * 100.0 : 0.0;

            diskLabel.Text = String.Format(
                "DISK C:     {0,3:0} %   {1:0.0} / {2:0.0} GB",
                percent, used / 1073741824.0, total / 1073741824.0);

            diskMeter.SetPercent((float)percent);
        }
        catch (Exception ex)
        {
            diskLabel.Text = "DISK C:     unavailable";
            WriteLog("WARN", "Disk update failed: " + ex.Message);
        }
    }

    private void UpdateNetworkMetrics()
    {
        try
        {
            long rx;
            long tx;
            int active;
            ReadNetworkTotals(out rx, out tx, out active);

            DateTime now = DateTime.UtcNow;
            double elapsed = Math.Max(
                0.001, (now - previousNetworkTime).TotalSeconds);

            double rxRate = Math.Max(0, rx - previousRx) / elapsed;
            double txRate = Math.Max(0, tx - previousTx) / elapsed;

            networkLabel.Text = String.Format(
                "NETWORK     RX {0} / TX {1}",
                FormatRate(rxRate), FormatRate(txRate));

            interfaceLabel.Text =
                "Active interfaces: " + active.ToString();

            previousRx = rx;
            previousTx = tx;
            previousNetworkTime = now;
        }
        catch (Exception ex)
        {
            networkLabel.Text = "NETWORK     unavailable";
            WriteLog("WARN", "Network update failed: " + ex.Message);
        }
    }

    private static void ReadNetworkTotals(
        out long rx, out long tx, out int active)
    {
        rx = 0;
        tx = 0;
        active = 0;

        foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                nic.OperationalStatus != OperationalStatus.Up)
                continue;

            try
            {
                IPv4InterfaceStatistics stats = nic.GetIPv4Statistics();
                rx += stats.BytesReceived;
                tx += stats.BytesSent;
                active++;
            }
            catch
            {
                // One unusual adapter should not break the entire monitor.
            }
        }
    }

    private static string FormatRate(double bytesPerSecond)
    {
        if (bytesPerSecond >= 1073741824.0)
            return String.Format("{0:0.00} GB/s", bytesPerSecond / 1073741824.0);

        if (bytesPerSecond >= 1048576.0)
            return String.Format("{0:0.00} MB/s", bytesPerSecond / 1048576.0);

        if (bytesPerSecond >= 1024.0)
            return String.Format("{0:0.0} KB/s", bytesPerSecond / 1024.0);

        return String.Format("{0:0} B/s", bytesPerSecond);
    }

    private static float ClampPercent(float value)
    {
        if (value < 0f) return 0f;
        if (value > 100f) return 100f;
        return value;
    }

    private void WriteLog(string level, string message)
    {
        string line = String.Format(
            "[{0}] [{1}] {2}",
            DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
            level,
            message);

        try
        {
            File.AppendAllText(logPath, line + Environment.NewLine);
        }
        catch {}

        if (!String.IsNullOrWhiteSpace(usbLogPath))
        {
            try
            {
                File.AppendAllText(usbLogPath, line + Environment.NewLine);
            }
            catch {}
        }
    }
}
'@

# ============================================================================
# PART 3 - POWERSHELL: COMPILE AND LAUNCH THE EMBEDDED MONITOR
# ============================================================================

try {
    # The hidden child process reaches this section and compiles the small C#
    # class in memory. No separate executable or C# project is written to disk.
    Add-Type `
        -TypeDefinition $MonitorSource `
        -Language CSharp `
        -ReferencedAssemblies @(
            'System.dll',
            'System.Core.dll',
            'System.Drawing.dll',
            'System.Windows.Forms.dll',
            'System.Management.dll',
            'Microsoft.VisualBasic.dll'
        ) `
        -ErrorAction Stop

    Write-MonitorLog 'Embedded C# monitor compiled successfully.'

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $Monitor = New-Object SystemMonitorForm(
        $LogPath,
        $UsbLogPath
    )

    [System.Windows.Forms.Application]::Run($Monitor)
}
catch {
    Write-MonitorLog "System Monitor failed: $($_.Exception.Message)" 'ERROR'
    throw
}
