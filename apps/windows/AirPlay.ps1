$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

. (Join-Path $PSScriptRoot "Discovery.ps1")

$script:EnginePath = Join-Path $PSScriptRoot "AirPlay.Engine.exe"
$script:EngineProcess = $null
$script:OutputRead = $null
$script:ErrorRead = $null
$script:PromptTail = ""
$script:DiscoveryProcess = $null
$script:DiscoveryTask = $null
$script:DiscoveryErrorTask = $null
$script:DiscoveryRepairOffered = $false
$script:SelectedDevices = @()
# The Go engine writes UTF-8. Without this, receiver names containing non-ASCII
# characters (such as typographic apostrophes) are decoded with the OEM code page.
$script:EngineEncoding = New-Object System.Text.UTF8Encoding($false)
$script:DisplayModeChanged = $false

Add-Type -Namespace AirPlayMirror -Name Display -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int ChangeDisplaySettingsEx(string deviceName, IntPtr devMode, IntPtr hwnd, uint flags, IntPtr param);
'@

# The engine switches the display with a temporary mode change and restores it
# when mirroring ends. This resets it as well in case the engine was killed.
function Restore-DisplayMode {
    if (-not $script:DisplayModeChanged) { return }
    $script:DisplayModeChanged = $false
    [void][AirPlayMirror.Display]::ChangeDisplaySettingsEx($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
}

$ColorBackground = [System.Drawing.Color]::FromArgb(18, 20, 28)
$ColorCard = [System.Drawing.Color]::FromArgb(31, 35, 47)
$ColorCardSoft = [System.Drawing.Color]::FromArgb(40, 45, 59)
$ColorText = [System.Drawing.Color]::FromArgb(246, 247, 251)
$ColorMuted = [System.Drawing.Color]::FromArgb(174, 181, 199)
$ColorAccent = [System.Drawing.Color]::FromArgb(114, 92, 255)
$ColorGreen = [System.Drawing.Color]::FromArgb(44, 204, 151)
$ColorAmber = [System.Drawing.Color]::FromArgb(247, 195, 95)

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [float]$Size = 10,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.Color]$Color = $ColorText
    )
    $control = New-Object System.Windows.Forms.Label
    $control.Text = $Text
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, $Height)
    $control.Font = New-Object System.Drawing.Font("Segoe UI", $Size, $Style)
    $control.ForeColor = $Color
    $control.BackColor = [System.Drawing.Color]::Transparent
    return $control
}

function New-Card {
    param([int]$X, [int]$Y, [int]$Width, [int]$Height)
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($X, $Y)
    $card.Size = New-Object System.Drawing.Size($Width, $Height)
    $card.BackColor = $ColorCard
    return $card
}

function Find-GStreamerBin {
    $onPath = Get-Command "gst-launch-1.0.exe" -ErrorAction SilentlyContinue
    if ($onPath) {
        return (Split-Path $onPath.Source -Parent)
    }

    $candidates = @(@(
        $(if ($env:GSTREAMER_1_0_ROOT_MSVC_X86_64) { Join-Path $env:GSTREAMER_1_0_ROOT_MSVC_X86_64 "bin" }),
        $(if ($env:GSTREAMER_ROOT_X86_64) { Join-Path $env:GSTREAMER_ROOT_X86_64 "bin" }),
        "C:\gstreamer\1.0\msvc_x86_64\bin",
        "C:\Program Files\gstreamer\1.0\msvc_x86_64\bin"
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ "gst-launch-1.0.exe")) })

    if ($candidates.Count -gt 0) {
        $env:Path = "$($candidates[0]);$env:Path"
        return $candidates[0]
    }
    return $null
}

function Test-GStreamer {
    # Windows PowerShell 5.1 turns redirected native stderr into error records,
    # and the script-wide Stop preference would make GStreamer's plugin-loading
    # warnings abort this check. Exit codes are inspected explicitly below.
    $ErrorActionPreference = "Continue"
    if (-not (Find-GStreamerBin)) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "AirPlay needs the 64-bit GStreamer MSVC runtime (Complete install). Open the official download page now?",
            "GStreamer is required",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process "https://gstreamer.freedesktop.org/download/#windows"
        }
        return $false
    }

    foreach ($element in @("d3d11screencapturesrc", "wasapi2src", "x264enc", "rtponviftimestamp")) {
        & "gst-inspect-1.0.exe" $element *> $null
        if ($LASTEXITCODE -ne 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "The GStreamer element '$element' is missing. Re-run the 64-bit MSVC installer and choose Complete.",
                "Incomplete GStreamer installation",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return $false
        }
    }
    return $true
}

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $logBox.AppendText($Text)
    if ($logBox.TextLength -gt 24000) {
        $logBox.Select(0, $logBox.TextLength - 18000)
        $logBox.SelectedText = ""
    }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Set-Status {
    param([string]$Text, [string]$Kind = "ready")
    $statusPill.Text = "  $Text  "
    switch ($Kind) {
        "connected" { $statusPill.BackColor = $ColorGreen; $statusPill.ForeColor = [System.Drawing.Color]::FromArgb(12, 48, 38) }
        "working"   { $statusPill.BackColor = $ColorAmber; $statusPill.ForeColor = [System.Drawing.Color]::FromArgb(57, 39, 8) }
        default     { $statusPill.BackColor = [System.Drawing.Color]::FromArgb(77, 82, 101); $statusPill.ForeColor = $ColorText }
    }
}

function Repair-DiscoveryAccess {
    $repairScript = Join-Path $PSScriptRoot "Repair discovery.ps1"
    if (-not (Test-Path $repairScript)) {
        Append-Log "Discovery repair tool is missing. Extract the complete release ZIP.`r`n"
        return $false
    }

    $arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$repairScript`" -EnginePath `"$script:EnginePath`""
    try {
        $repair = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($repair.ExitCode -eq 0) {
            Append-Log "Windows Firewall access repaired. Retrying discovery...`r`n"
            return $true
        }
        Append-Log "Windows Firewall repair exited with status $($repair.ExitCode).`r`n"
    } catch {
        Append-Log "Windows Firewall repair was not completed: $($_.Exception.Message)`r`n"
    }
    return $false
}

function Write-DiscoveryDiagnostics {
    param([string]$EngineLog)
    if (-not [string]::IsNullOrWhiteSpace($EngineLog)) {
        Append-Log "$($EngineLog.Trim())`r`n"
    }
    try {
        foreach ($connection in @(Get-NetConnectionProfile -ErrorAction Stop)) {
            Append-Log "Network '$($connection.InterfaceAlias)' is $($connection.NetworkCategory).`r`n"
        }
    } catch { }
}

function New-ReadState {
    param([System.IO.StreamReader]$Reader)
    $buffer = New-Object char[] 1024
    return @{
        Reader = $Reader
        Buffer = $buffer
        Task = $Reader.ReadAsync($buffer, 0, $buffer.Length)
    }
}

function Handle-EngineText {
    param([string]$Text)
    Append-Log $Text
    $lower = $Text.ToLowerInvariant()
    if ($lower.Contains("connected to:")) { Set-Status "Preparing" "working" }
    if ($lower.Contains("screen capture started") -or $lower.Contains("mirror session ready")) {
        Set-Status "Mirroring" "connected"
    }
    if ($lower.Contains("streaming error:") -or $lower.Contains("fatal")) {
        Set-Status "Connection error" "ready"
    }

    $script:PromptTail = ($script:PromptTail + $lower)
    if ($script:PromptTail.Length -gt 600) {
        $script:PromptTail = $script:PromptTail.Substring($script:PromptTail.Length - 600)
    }
    if ($script:PromptTail -match "enter the (pin|code|receiver's configured password)") {
        $credentialPanel.Visible = $true
        $credentialBox.Focus()
        Set-Status "Code needed" "working"
        $script:PromptTail = ""
    }
}

function Poll-ReadState {
    param([hashtable]$State)
    if (-not $State -or -not $State.Task.IsCompleted) { return }
    try {
        $count = $State.Task.Result
    } catch {
        return
    }
    if ($count -le 0) { return }
    $text = [string]::new($State.Buffer, 0, $count)
    Handle-EngineText $text
    $State.Buffer = New-Object char[] 1024
    $State.Task = $State.Reader.ReadAsync($State.Buffer, 0, $State.Buffer.Length)
}

function Set-RunningUI {
    param([bool]$Running)
    $startButton.Text = $(if ($Running) { "Stop mirroring" } else { "Start mirroring" })
    $startButton.BackColor = $(if ($Running) { [System.Drawing.Color]::FromArgb(213, 79, 93) } else { $ColorAccent })
    $deviceCombo.Enabled = -not $Running
    $displayCombo.Enabled = -not $Running
    $audioCheck.Enabled = -not $Running
    $cursorCheck.Enabled = -not $Running
    $fillCheck.Enabled = -not $Running
    $fpsCombo.Enabled = -not $Running
    $refreshButton.Enabled = -not $Running
}

function Stop-Mirroring {
    if (-not $script:EngineProcess) { return }
    Set-Status "Stopping" "working"
    try {
        if (-not $script:EngineProcess.HasExited) {
            & taskkill.exe /PID $script:EngineProcess.Id /T /F 2>$null | Out-Null
        }
    } catch { }
    $script:EngineProcess = $null
    $script:OutputRead = $null
    $script:ErrorRead = $null
    Restore-DisplayMode
    $credentialPanel.Visible = $false
    Set-RunningUI $false
    Set-Status "Ready"
    Append-Log "`r`nMirroring stopped.`r`n"
}

function Start-Mirroring {
    if ($script:EngineProcess -and -not $script:EngineProcess.HasExited) {
        Stop-Mirroring
        return
    }
    if ($deviceCombo.SelectedIndex -lt 0 -or $script:SelectedDevices.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Choose an AirPlay TV first.", "AirPlay") | Out-Null
        return
    }
    if (-not (Test-GStreamer)) { return }

    $device = $script:SelectedDevices[$deviceCombo.SelectedIndex]
    $monitorIndex = -1
    if ($displayCombo.SelectedIndex -gt 0) {
        $monitorIndex = $displayCombo.SelectedIndex - 1
    }
    $fps = [int]($fpsCombo.SelectedItem.ToString().Split(' ')[0])
    $arguments = @(
        "-target", $device.ip,
        "-port", $device.port,
        "-capture-source", "monitor",
        "-monitor-index", $monitorIndex,
        "-fps", $fps,
        "-hwaccel", "none",
        "-preserve-receiver-volume=true"
    )
    if (-not $audioCheck.Checked) { $arguments += "-no-audio" }
    if (-not $cursorCheck.Checked) { $arguments += "-no-cursor" }
    if ($fillCheck.Checked -and $monitorIndex -lt 0) {
        $arguments += "-match-receiver-aspect"
        $script:DisplayModeChanged = $true
    }

    $logBox.Clear()
    Append-Log "Connecting to $($device.name) at $($device.ip):$($device.port)...`r`n"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:EnginePath
    $psi.Arguments = ($arguments -join " ")
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:EngineEncoding
    $psi.StandardErrorEncoding = $script:EngineEncoding

    try {
        $script:EngineProcess = New-Object System.Diagnostics.Process
        $script:EngineProcess.StartInfo = $psi
        [void]$script:EngineProcess.Start()
        $script:OutputRead = New-ReadState $script:EngineProcess.StandardOutput
        $script:ErrorRead = New-ReadState $script:EngineProcess.StandardError
        $script:PromptTail = ""
        Set-RunningUI $true
        Set-Status "Connecting" "working"
    } catch {
        $script:EngineProcess = $null
        Set-RunningUI $false
        Set-Status "Could not start"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Could not start AirPlay") | Out-Null
    }
}

function Start-Discovery {
    if ($script:DiscoveryProcess -and -not $script:DiscoveryProcess.HasExited) { return }
    $refreshButton.Enabled = $false
    $deviceCombo.Items.Clear()
    $deviceCombo.Items.Add("Searching for AirPlay TVs...") | Out-Null
    $deviceCombo.SelectedIndex = 0
    $deviceCombo.Enabled = $false
    Set-Status "Searching" "working"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:EnginePath
    $psi.Arguments = "-discover-json"
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:EngineEncoding
    $psi.StandardErrorEncoding = $script:EngineEncoding
    try {
        $script:DiscoveryProcess = New-Object System.Diagnostics.Process
        $script:DiscoveryProcess.StartInfo = $psi
        [void]$script:DiscoveryProcess.Start()
        $script:DiscoveryTask = $script:DiscoveryProcess.StandardOutput.ReadToEndAsync()
        $script:DiscoveryErrorTask = $script:DiscoveryProcess.StandardError.ReadToEndAsync()
    } catch {
        $script:DiscoveryProcess = $null
        $deviceCombo.Items.Clear()
        $deviceCombo.Items.Add("Discovery could not start") | Out-Null
        $deviceCombo.SelectedIndex = 0
        $refreshButton.Enabled = $true
        Set-Status "Ready"
    }
}

function Finish-Discovery {
    $json = $script:DiscoveryTask.Result
    $errorText = $script:DiscoveryErrorTask.Result
    $exitCode = $script:DiscoveryProcess.ExitCode
    $script:DiscoveryProcess = $null
    $script:DiscoveryTask = $null
    $script:DiscoveryErrorTask = $null
    $refreshButton.Enabled = $true
    $deviceCombo.Items.Clear()
    $script:SelectedDevices = @()
    $retryDiscovery = $false

    if ($exitCode -ne 0) {
        $deviceCombo.Items.Add("No receivers found") | Out-Null
        $deviceCombo.SelectedIndex = 0
        Append-Log "Discovery failed: $errorText`r`n"
        Set-Status "Ready"
        return
    }
    $parseError = $null
    try {
        $devices = @(ConvertFrom-AirPlayDiscoveryJson -Json $json)
    } catch {
        $devices = @()
        $parseError = $_.Exception.Message
    }
    foreach ($device in $devices) {
        if (-not $device.ip) { continue }
        $script:SelectedDevices += $device
        $model = $(if ($device.model) { $device.model } else { "AirPlay receiver" })
        $deviceCombo.Items.Add("$($device.name)  |  $model  |  $($device.ip):$($device.port)") | Out-Null
    }
    if ($script:SelectedDevices.Count -gt 0) {
        $deviceCombo.SelectedIndex = 0
        $deviceCombo.Enabled = $true
        Append-Log "Found $($script:SelectedDevices.Count) AirPlay receiver(s).`r`n"
    } else {
        $deviceCombo.Items.Add("No AirPlay TVs found") | Out-Null
        $deviceCombo.SelectedIndex = 0
        $deviceCombo.Enabled = $false
        if ($parseError) {
            Append-Log "Could not parse discovery results: $parseError`r`n"
        } elseif (-not [string]::IsNullOrWhiteSpace($json) -and $json.Trim() -ne "[]") {
            Append-Log "Discovery returned data, but it contained no usable receiver addresses.`r`n"
            Append-Log "Raw discovery output: $($json.Trim())`r`n"
        } else {
            Append-Log "Discovery completed without finding a receiver.`r`n"
            Write-DiscoveryDiagnostics $errorText
            if (-not $script:DiscoveryRepairOffered) {
                $script:DiscoveryRepairOffered = $true
                $choice = [System.Windows.Forms.MessageBox]::Show(
                    "Windows Firewall may be blocking AirPlay discovery. Allow AirPlay Mirror through the firewall and search again? Windows will ask for administrator approval.",
                    "Repair AirPlay discovery",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
                if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $retryDiscovery = Repair-DiscoveryAccess
                }
            }
        }
    }
    Set-Status "Ready"
    if ($retryDiscovery) {
        Start-Discovery
    }
}

if (-not (Test-Path $script:EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show("AirPlay.Engine.exe is missing. Keep all files together after extracting the ZIP.", "AirPlay") | Out-Null
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "AirPlay"
$form.ClientSize = New-Object System.Drawing.Size(900, 820)
$form.MinimumSize = New-Object System.Drawing.Size(916, 859)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $ColorBackground
$form.ForeColor = $ColorText
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$iconPath = Join-Path $PSScriptRoot "AirPlay.ico"
if (Test-Path $iconPath) { $form.Icon = [System.Drawing.Icon]::new($iconPath) }

$hero = New-Object System.Windows.Forms.Panel
$hero.Location = New-Object System.Drawing.Point(28, 24)
$hero.Size = New-Object System.Drawing.Size(844, 132)
$hero.BackColor = $ColorAccent
$hero.Add_Paint({
    param($sender, $event)
    $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        $sender.ClientRectangle,
        [System.Drawing.Color]::FromArgb(83, 62, 226),
        [System.Drawing.Color]::FromArgb(26, 137, 229),
        0.0
    )
    $event.Graphics.FillRectangle($brush, $sender.ClientRectangle)
    $brush.Dispose()
})
$form.Controls.Add($hero)

$heroIcon = New-Label "TV" 26 22 70 70 25 ([System.Drawing.FontStyle]::Bold)
$heroIcon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$hero.Controls.Add($heroIcon)
$hero.Controls.Add((New-Label "Your screen, on the big screen." 112 25 540 42 21 ([System.Drawing.FontStyle]::Bold)))
$hero.Controls.Add((New-Label "Mirror this Windows PC with sound to any AirPlay TV." 114 72 570 28 10.5 ([System.Drawing.FontStyle]::Regular) ([System.Drawing.Color]::FromArgb(225, 230, 249))))
$statusPill = New-Label "  Ready  " 704 44 112 38 10 ([System.Drawing.FontStyle]::Bold)
$statusPill.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$statusPill.BackColor = [System.Drawing.Color]::FromArgb(77, 82, 101)
$hero.Controls.Add($statusPill)

$deviceCard = New-Card 28 176 844 146
$form.Controls.Add($deviceCard)
$deviceCard.Controls.Add((New-Label "Choose a TV" 20 14 250 30 15 ([System.Drawing.FontStyle]::Bold)))
$deviceCard.Controls.Add((New-Label "AirPlay receivers on this network" 21 44 350 24 9.5 ([System.Drawing.FontStyle]::Regular) $ColorMuted))
$deviceCombo = New-Object System.Windows.Forms.ComboBox
$deviceCombo.Location = New-Object System.Drawing.Point(20, 80)
$deviceCombo.Size = New-Object System.Drawing.Size(695, 34)
$deviceCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$deviceCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$deviceCombo.BackColor = $ColorCardSoft
$deviceCombo.ForeColor = $ColorText
$deviceCombo.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$deviceCard.Controls.Add($deviceCombo)
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "Refresh"
$refreshButton.Location = New-Object System.Drawing.Point(730, 79)
$refreshButton.Size = New-Object System.Drawing.Size(92, 35)
$refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$refreshButton.FlatAppearance.BorderSize = 0
$refreshButton.BackColor = $ColorCardSoft
$refreshButton.ForeColor = $ColorText
$refreshButton.Add_Click({ Start-Discovery })
$deviceCard.Controls.Add($refreshButton)

$optionsCard = New-Card 28 342 844 192
$form.Controls.Add($optionsCard)
$optionsCard.Controls.Add((New-Label "Mirroring options" 20 13 280 30 15 ([System.Drawing.FontStyle]::Bold)))
$optionsCard.Controls.Add((New-Label "Display" 22 59 100 24 10 ([System.Drawing.FontStyle]::Bold)))
$displayCombo = New-Object System.Windows.Forms.ComboBox
$displayCombo.Location = New-Object System.Drawing.Point(20, 87)
$displayCombo.Size = New-Object System.Drawing.Size(360, 34)
$displayCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$displayCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$displayCombo.BackColor = $ColorCardSoft
$displayCombo.ForeColor = $ColorText
$displayCombo.Items.Add("Primary display") | Out-Null
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $displayCombo.Items.Add("$($screen.DeviceName)  |  $($screen.Bounds.Width)x$($screen.Bounds.Height)") | Out-Null
}
$displayCombo.SelectedIndex = 0
$optionsCard.Controls.Add($displayCombo)

$optionsCard.Controls.Add((New-Label "Frame rate" 420 59 120 24 10 ([System.Drawing.FontStyle]::Bold)))
$fpsCombo = New-Object System.Windows.Forms.ComboBox
$fpsCombo.Location = New-Object System.Drawing.Point(420, 87)
$fpsCombo.Size = New-Object System.Drawing.Size(135, 34)
$fpsCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$fpsCombo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$fpsCombo.BackColor = $ColorCardSoft
$fpsCombo.ForeColor = $ColorText
$fpsCombo.Items.AddRange(@("24 FPS", "30 FPS", "60 FPS"))
$fpsCombo.SelectedIndex = 1
$optionsCard.Controls.Add($fpsCombo)

$audioCheck = New-Object System.Windows.Forms.CheckBox
$audioCheck.Text = "Desktop audio"
$audioCheck.Checked = $true
$audioCheck.Location = New-Object System.Drawing.Point(600, 65)
$audioCheck.Size = New-Object System.Drawing.Size(190, 28)
$audioCheck.ForeColor = $ColorText
$audioCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$optionsCard.Controls.Add($audioCheck)
$cursorCheck = New-Object System.Windows.Forms.CheckBox
$cursorCheck.Text = "Show pointer"
$cursorCheck.Checked = $true
$cursorCheck.Location = New-Object System.Drawing.Point(600, 101)
$cursorCheck.Size = New-Object System.Drawing.Size(190, 28)
$cursorCheck.ForeColor = $ColorText
$cursorCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$optionsCard.Controls.Add($cursorCheck)
$fillCheck = New-Object System.Windows.Forms.CheckBox
$fillCheck.Text = "Fill the TV (switch this PC to the TV's shape while mirroring)"
$fillCheck.Checked = $true
$fillCheck.Location = New-Object System.Drawing.Point(420, 140)
$fillCheck.Size = New-Object System.Drawing.Size(410, 28)
$fillCheck.ForeColor = $ColorText
$fillCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$optionsCard.Controls.Add($fillCheck)
$optionsCard.Controls.Add((New-Label "The TV's current volume is preserved automatically." 22 145 380 26 9.5 ([System.Drawing.FontStyle]::Regular) $ColorMuted))

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start mirroring"
$startButton.Location = New-Object System.Drawing.Point(28, 554)
$startButton.Size = New-Object System.Drawing.Size(844, 52)
$startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$startButton.FlatAppearance.BorderSize = 0
$startButton.BackColor = $ColorAccent
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.Font = New-Object System.Drawing.Font("Segoe UI", 11.5, [System.Drawing.FontStyle]::Bold)
$startButton.Add_Click({ Start-Mirroring })
$form.Controls.Add($startButton)

$credentialPanel = New-Card 28 622 844 56
$credentialPanel.Visible = $false
$credentialPanel.Controls.Add((New-Label "TV code" 15 16 85 24 10 ([System.Drawing.FontStyle]::Bold)))
$credentialBox = New-Object System.Windows.Forms.TextBox
$credentialBox.Location = New-Object System.Drawing.Point(102, 13)
$credentialBox.Size = New-Object System.Drawing.Size(600, 30)
$credentialBox.UseSystemPasswordChar = $true
$credentialBox.BackColor = $ColorCardSoft
$credentialBox.ForeColor = $ColorText
$credentialBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$credentialPanel.Controls.Add($credentialBox)
$credentialSubmit = New-Object System.Windows.Forms.Button
$credentialSubmit.Text = "Submit"
$credentialSubmit.Location = New-Object System.Drawing.Point(714, 11)
$credentialSubmit.Size = New-Object System.Drawing.Size(112, 34)
$credentialSubmit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$credentialSubmit.FlatAppearance.BorderSize = 0
$credentialSubmit.BackColor = $ColorAccent
$credentialSubmit.ForeColor = $ColorText
$credentialSubmit.Add_Click({
    if ($script:EngineProcess -and -not $script:EngineProcess.HasExited -and $credentialBox.Text) {
        $script:EngineProcess.StandardInput.WriteLine($credentialBox.Text)
        $script:EngineProcess.StandardInput.Flush()
        $credentialBox.Clear()
        $credentialPanel.Visible = $false
        Set-Status "Pairing" "working"
        Append-Log "AirPlay code submitted.`r`n"
    }
})
$credentialPanel.Controls.Add($credentialSubmit)
$form.Controls.Add($credentialPanel)

$logLabel = New-Label "Connection details" 31 694 260 25 10 ([System.Drawing.FontStyle]::Bold) $ColorMuted
$form.Controls.Add($logLabel)
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(28, 723)
$logBox.Size = New-Object System.Drawing.Size(844, 72)
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(13, 15, 21)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(198, 205, 220)
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$logBox.Font = New-Object System.Drawing.Font("Cascadia Mono", 8.5)
$form.Controls.Add($logBox)

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 100
$pollTimer.Add_Tick({
    if ($script:DiscoveryProcess -and $script:DiscoveryProcess.HasExited -and $script:DiscoveryTask.IsCompleted -and $script:DiscoveryErrorTask.IsCompleted) {
        Finish-Discovery
    }
    if ($script:EngineProcess) {
        Poll-ReadState $script:OutputRead
        Poll-ReadState $script:ErrorRead
        if ($script:EngineProcess.HasExited) {
            $exitCode = $script:EngineProcess.ExitCode
            $script:EngineProcess = $null
            $script:OutputRead = $null
            $script:ErrorRead = $null
            Restore-DisplayMode
            $credentialPanel.Visible = $false
            Set-RunningUI $false
            if ($exitCode -eq 0) {
                Set-Status "Ready"
            } else {
                Set-Status "Connection ended"
                Append-Log "`r`nAirPlay exited with status $exitCode.`r`n"
            }
        }
    }
})
$pollTimer.Start()

$form.Add_FormClosing({
    if ($script:EngineProcess -and -not $script:EngineProcess.HasExited) {
        try { & taskkill.exe /PID $script:EngineProcess.Id /T /F 2>$null | Out-Null } catch { }
    }
    Restore-DisplayMode
})
$form.Add_Shown({ Start-Discovery })
[void]$form.ShowDialog()
