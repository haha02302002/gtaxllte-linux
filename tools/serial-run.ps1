param(
    [string]$Port = "COM6",
    [int]$Baud = 115200,
    [string[]]$Commands = @("echo PING"),
    [int]$SettleMs = 1200
)

$ErrorActionPreference = "Stop"
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, "None", 8, "One"
$sp.ReadTimeout = 500
$sp.WriteTimeout = 3000
$sp.DtrEnable = $false
$sp.RtsEnable = $false

function Read-Burst([int]$ms) {
    $sb = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        try {
            $chunk = $sp.ReadExisting()
            if ($chunk) {
                [void]$sb.Append($chunk)
                $deadline = (Get-Date).AddMilliseconds(400)
            }
            else {
                Start-Sleep -Milliseconds 60
            }
        }
        catch {
            Start-Sleep -Milliseconds 60
        }
    }
    return $sb.ToString()
}

$sp.Open()
Start-Sleep -Milliseconds 300
[void](Read-Burst 400)
$sp.Write("`n")

foreach ($c in $Commands) {
    Write-Output "### SEND: $c"
    $sp.Write("$c`n")
    $out = Read-Burst $SettleMs
    Write-Output $out
}

$sp.Close()
