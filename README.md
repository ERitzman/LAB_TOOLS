# LAB TOOLS #
This repository contains the customized tools for monitoring System Status and provides recording capability for use with LD&P-A Custom Lab Computer(s).
FFMPEG is an open-source recording tool and its inclussion here does not indicate nor suggest that any additional customization or modification has been done to the original source, nor imply any ownership of its code or usage. For Licensing and most current version please see details via [https://ffmpeg.org/].

## ::: DESKTOP SHORTCUTS ::: ##
### START-RECORD: ###
	Target: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\EXTRAS\Start-Session.ps1"
	Start In: C:\EXTRAS
	Run: Normal Window
	Comment: Start reference-session screen recording
	Icon: %SystemRoot%\System32\imageres.dll (Green Checkmark icon)
### STOP-RECORD: ###
	Target: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\EXTRAS\Stop-Session.ps1"
	Start In: C:\EXTRAS
	Run: Normal Window
	Comment: Gracefully finalize and verify the active recording
	Icon: %SystemRoot%\System32\imageres.dll (Red X icon)
### CSTM_SYSMON: ###
	Target: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\EXTRAS\SystemMonitor.ps1"
	Start In: C:\EXTRAS
	Run: Normal Window
	Comment: Launch the custom LAB System Monitor
	Icon: %SystemRoot%\System32\resmon.exe (System Guage icon)
