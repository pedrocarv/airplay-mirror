$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent

foreach ($relativePath in @(
    "apps\windows\AirPlay.ps1",
    "apps\windows\Discovery.ps1",
    "apps\windows\Repair discovery.ps1"
)) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $relativePath),
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell syntax error in ${relativePath}: $($parseErrors[0].Message)"
    }
}

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
if ($devices[0].port -ne 7000 -or $devices[1].port -ne 7000) {
    throw "Receiver ports were not converted to integers."
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

$processOutput = [System.Threading.Tasks.Task[string]]::FromResult($twoReceivers).Result
$fromProcessOutput = @(ConvertFrom-AirPlayDiscoveryJson -Json $processOutput)
if ($fromProcessOutput.Count -ne 2) {
    throw "A string returned by an asynchronous process read did not preserve both receivers."
}

Write-Host "Windows discovery parsing passed."
