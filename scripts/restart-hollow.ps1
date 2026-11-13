param(
  [ValidateSet('Close', 'Start')][string]$Action,
  [string[]]$AppArgs = @()
)

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$dir = 'C:\Applications\Hollow\'
if ($Action -eq 'Start') {
  $options = @{ FilePath = $dir + 'hollow-native.exe' }
  if ($AppArgs.Count -gt 0) { $options.ArgumentList = $AppArgs }
  Start-Process @options
  exit 0
}

$procs = @(Get-Process -Name 'hollow-native' -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and $_.Path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) })
if ($procs.Count -eq 0) { exit 3 }

# Close like the window button; never kill processes or interrupt layout flushing.
$timer = [Diagnostics.Stopwatch]::StartNew()
foreach ($p in $procs) { [void]$p.CloseMainWindow() }
foreach ($p in $procs) {
  $remaining = [int][Math]::Max(0, 3000 - $timer.ElapsedMilliseconds)
  if (-not $p.WaitForExit($remaining)) {
    Write-Error 'Hollow did not exit within 3 seconds; close it and retry.'
  }
}
exit 0
