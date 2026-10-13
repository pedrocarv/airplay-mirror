function ConvertFrom-AirPlayDiscoveryJson {
    param([Parameter(Mandatory = $true)][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return
    }

    $parsedDevices = $Json | ConvertFrom-Json

    # Windows PowerShell 5.1 can emit a top-level JSON array as one nested
    # pipeline object. Iterating the parsed value explicitly flattens that
    # array so each receiver becomes its own ComboBox item.
    foreach ($device in $parsedDevices) {
        if ($null -ne $device -and $device.ip) {
            Write-Output $device
        }
    }
}
