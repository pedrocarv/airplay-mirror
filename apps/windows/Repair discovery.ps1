param(
    [Parameter(Mandatory = $true)]
    [string]$EnginePath
)

$ErrorActionPreference = "Stop"
$ruleName = "AirPlay Mirror Discovery"
$engine = (Resolve-Path -LiteralPath $EnginePath).Path

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator approval is required to update Windows Firewall."
}

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# Dismissing the first-run Windows Firewall prompt creates inbound Block rules
# for the engine. Block rules take precedence over Allow rules, so they must be
# removed for the rule below to have any effect.
Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
    Where-Object { [Environment]::ExpandEnvironmentVariables($_.Program) -ieq $engine } |
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Block" } |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

# mDNS replies arrive on UDP 5353, and receivers send timing and control
# packets to the engine's ephemeral UDP session ports.
New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description "Allow AirPlay Mirror to receive discovery and session traffic from AirPlay receivers on the local network." `
    -Direction Inbound `
    -Action Allow `
    -Program $engine `
    -Protocol UDP `
    -RemoteAddress LocalSubnet `
    -Profile Private,Domain | Out-Null
