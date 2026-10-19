function ConvertFrom-AirPlayDiscoveryJson {
    param([Parameter(Mandatory = $true)][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return
    }

    # Use the .NET Framework deserializer instead of ConvertFrom-Json. Different
    # Windows PowerShell 5.1 builds disagree about whether a top-level JSON
    # array is emitted as one nested object or as individual pipeline objects.
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $parsed = $serializer.DeserializeObject($Json)

    $items = New-Object System.Collections.ArrayList
    if ($parsed -is [System.Collections.IDictionary]) {
        [void]$items.Add($parsed)
    } else {
        foreach ($item in $parsed) {
            if ($null -ne $item) {
                [void]$items.Add($item)
            }
        }
    }

    foreach ($item in $items) {
        if (-not ($item -is [System.Collections.IDictionary])) {
            continue
        }
        $address = [string]$item["ip"]
        if (-not [string]::IsNullOrWhiteSpace($address)) {
            [PSCustomObject]@{
                name = [string]$item["name"]
                model = [string]$item["model"]
                ip = $address
                port = [int]$item["port"]
            }
        }
    }
}
