param(
    [Parameter(Mandatory=$true)][int]$GuiPid,
    [Parameter(Mandatory=$true)][string]$Output,
    [ValidateRange(1,3600)][int]$Seconds=10,
    [ValidateRange(20,10000)][int]$IntervalMs=100
)
# Read-only sampler. Caller owns selection/lifetime of the explicit process.
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Output) { throw 'Output already exists; choose a fresh path.' }
$process = Get-Process -Id $GuiPid
$startTime = $process.StartTime
$clock = [Diagnostics.Stopwatch]::StartNew()
$samples = [Collections.Generic.List[object]]::new()
while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
    $process.Refresh()
    if ($process.HasExited -or $process.StartTime -ne $startTime) { throw 'Selected process exited or changed.' }
    $samples.Add([pscustomobject]@{
        elapsed_ms=$clock.Elapsed.TotalMilliseconds
        working_set_bytes=$process.WorkingSet64
        private_bytes=$process.PrivateMemorySize64
        process_cpu_ms=$process.TotalProcessorTime.TotalMilliseconds
    })
    Start-Sleep -Milliseconds $IntervalMs
}
$samples | Export-Csv -LiteralPath $Output -NoTypeInformation -Encoding UTF8
