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

New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description "Allow AirPlay Mirror to receive local mDNS discovery replies." `
    -Direction Inbound `
    -Action Allow `
    -Program $engine `
    -Protocol UDP `
    -LocalPort 5353 `
    -RemotePort 5353 `
    -RemoteAddress LocalSubnet `
    -Profile Private,Domain | Out-Null
