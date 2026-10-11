$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$shell = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath("Desktop")
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$target = Join-Path $PSScriptRoot "Start AirPlay.cmd"
$icon = Join-Path $PSScriptRoot "AirPlay.ico"

foreach ($folder in @($desktop, $startMenu)) {
    $shortcut = $shell.CreateShortcut((Join-Path $folder "AirPlay.lnk"))
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $PSScriptRoot
    if (Test-Path $icon) { $shortcut.IconLocation = $icon }
    $shortcut.Description = "Mirror this PC to an AirPlay TV"
    $shortcut.Save()
}

[System.Windows.Forms.MessageBox]::Show("AirPlay was added to your Desktop and Start menu.", "AirPlay") | Out-Null
