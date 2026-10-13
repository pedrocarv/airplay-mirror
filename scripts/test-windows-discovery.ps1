$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "apps\windows\Discovery.ps1")

$twoReceivers = @'
[
  {"name":"Living Room TV","model":"Example A","ip":"192.0.2.10","port":7000},
  {"name":"Office TV","model":"Example B","ip":"192.0.2.11","port":7000}
]
'@

$devices = @(ConvertFrom-AirPlayDiscoveryJson -Json $twoReceivers)
if ($devices.Count -ne 2) {
    throw "Expected two independent receivers, got $($devices.Count)."
}
if ($devices[0].name -ne "Living Room TV" -or $devices[1].name -ne "Office TV") {
    throw "Receiver order or names were not preserved."
}
if ($devices[0].ip -eq $devices[1].ip) {
    throw "Receiver addresses were collapsed into one value."
}

$oneReceiver = '{"name":"Bedroom TV","ip":"192.0.2.12","port":7000}'
$single = @(ConvertFrom-AirPlayDiscoveryJson -Json $oneReceiver)
if ($single.Count -ne 1 -or $single[0].name -ne "Bedroom TV") {
    throw "Single-receiver discovery was not preserved."
}

$empty = @(ConvertFrom-AirPlayDiscoveryJson -Json '[]')
if ($empty.Count -ne 0) {
    throw "Empty discovery should return no receivers."
}

Write-Host "Windows discovery parsing passed."
