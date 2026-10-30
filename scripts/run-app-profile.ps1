param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$Fixture,
    [Parameter(Mandatory=$true)][string]$OutputDir,
    [Parameter(Mandatory=$true)][ValidateSet('palette','workspace')][string]$Picker,
    [Parameter(Mandatory=$true)][ValidateSet('idle','selection','scroll','resize')][string]$Scenario,
    [ValidateRange(1,300)][int]$Seconds=10
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputDir) { throw 'OutputDir must not exist.' }
$Exe = (Resolve-Path -LiteralPath $Exe).ProviderPath
$Fixture = (Resolve-Path -LiteralPath $Fixture).ProviderPath
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
[void](New-Item -ItemType Directory -Path $OutputDir)
. (Join-Path $PSScriptRoot 'windows_bench_window.ps1')
if (-not ('HollowProfileInput' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HollowProfileInput {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@
}
$names = @('APPDATA','LOCALAPPDATA','HOLLOW_CONFIG_PATH','HOLLOW_PROFILE_FRAMES','HOLLOW_PROFILE_PICKER','HOLLOW_COMMAND_ADDR')
$old = @{}
foreach ($name in $names) { $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$env:APPDATA = Join-Path $OutputDir 'roaming'
$env:LOCALAPPDATA = Join-Path $OutputDir 'local'
$env:HOLLOW_CONFIG_PATH = $Fixture
$env:HOLLOW_PROFILE_FRAMES = Join-Path $OutputDir 'frames.csv'
$env:HOLLOW_PROFILE_PICKER = $Picker
Remove-Item Env:HOLLOW_COMMAND_ADDR -ErrorAction SilentlyContinue
$foreground = [HollowBenchWindow]::GetForegroundWindow()
$process = $null
try {
    $process = Start-Process -FilePath $Exe -PassThru
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process') }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) { throw 'Application exited before window appeared.' }
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Application window did not appear.' }
    $handle = $process.MainWindowHandle
    if ($foreground -ne [IntPtr]::Zero) { [void][HollowBenchWindow]::SetForegroundWindow($foreground) }
    Start-Sleep -Seconds 3
    $initial = Get-HollowBenchWindow $process.Id
    $initial = Set-HollowBenchWindow -GuiPid $process.Id -Monitor $initial.monitor -ClientWidth 1200 -ClientHeight 800 -PreviousForeground $foreground
    $log = Join-Path $OutputDir 'roaming\hollow\hollow.log'
    $marker = "HOLLOW_PROFILE_FIXTURE_READY $Picker"
    if (-not (Test-Path -LiteralPath $log) -or -not (Select-String -LiteralPath $log -SimpleMatch $marker -Quiet)) {
        throw "Fixture did not confirm picker; inspect $log."
    }
    $addressLine = Select-String -LiteralPath $log -Pattern 'command-ipc: listening on (127\.0\.0\.1:\d+)' | Select-Object -First 1
    if ($null -eq $addressLine) { throw 'Owned process command endpoint unavailable.' }
    $address = $addressLine.Matches[0].Groups[1].Value
    $cli = Join-Path (Split-Path -Parent $Exe) 'hollow-cli.exe'
    if (-not (Test-Path -LiteralPath $cli)) { throw 'hollow-cli.exe missing beside native application.' }
    function Save-Semantics([string]$Path) {
        $previous = [Environment]::GetEnvironmentVariable('HOLLOW_COMMAND_ADDR', 'Process')
        try {
            $env:HOLLOW_COMMAND_ADDR = $address
            $json = (& $cli --transport socket get ui-nodes | Out-String)
            if ($LASTEXITCODE -ne 0) { throw 'Owned process semantic query failed.' }
            $tree = $json | ConvertFrom-Json
            $panel = @($tree.nodes | Where-Object { $_.surface -eq 'overlay' -and $_.role -eq 'dialog' })
            if (-not $tree.valid -or $panel.Count -ne 1 -or $panel[0].bounds.width -le 0 -or $panel[0].bounds.height -le 0) { throw 'Native overlay dialog missing or invalid.' }
            $json | Set-Content -LiteralPath $Path -Encoding UTF8
        } finally { [Environment]::SetEnvironmentVariable('HOLLOW_COMMAND_ADDR', $previous, 'Process') }
    }
    Save-Semantics (Join-Path $OutputDir 'semantics-before.json')
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new(($initial.rect_right-$initial.rect_left), ($initial.rect_bottom-$initial.rect_top))
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $dc = $graphics.GetHdc()
    try {
        if (-not [HollowProfileInput]::PrintWindow($handle, $dc, 2)) { throw 'PrintWindow failed for owned window.' }
    } finally { $graphics.ReleaseHdc($dc); $graphics.Dispose() }
    try { $bitmap.Save((Join-Path $OutputDir 'window.png'), [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
    # Win32 QPC matches Zig's Windows awake clock; use absolute timestamps for phase filtering.
    $phaseStartNs = [int64]([Diagnostics.Stopwatch]::GetTimestamp() * (1000000000.0 / [Diagnostics.Stopwatch]::Frequency))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $samples = [Collections.Generic.List[object]]::new()
    $i = 0
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        $process.Refresh()
        if ($process.HasExited -or $process.MainWindowHandle -ne $handle) { throw 'Benchmark window exited or changed.' }
        if ($Scenario -eq 'selection') {
            # Page Down / Page Up, targeted at this new window only; no mouse injection.
            $vk = if ($i % 2 -eq 0) { 0x22 } else { 0x21 }
            $scan = if ($i % 2 -eq 0) { 0x151 } else { 0x149 }
            if (-not [HollowProfileInput]::PostMessage($handle, 0x100, [IntPtr]$vk, [IntPtr](1 -bor ($scan -shl 16))) -or
                -not [HollowProfileInput]::PostMessage($handle, 0x101, [IntPtr]$vk, [IntPtr]([int64]0xC0000001 -bor ($scan -shl 16)))) { throw 'PostMessage failed.' }
        } elseif ($Scenario -eq 'scroll') {
            # Sokol uses its last client mouse position for wheel events. Post a
            # targeted move; never move the physical cursor or foreground window.
            $point = [IntPtr](600 -bor (400 -shl 16))
            $delta = if ($i % 2 -eq 0) { -120 } else { 120 }
            if (-not [HollowProfileInput]::PostMessage($handle, 0x200, [IntPtr]::Zero, $point) -or
                -not [HollowProfileInput]::PostMessage($handle, 0x20A, [IntPtr]($delta -shl 16), [IntPtr]::Zero)) { throw 'Wheel PostMessage failed.' }
        } elseif ($Scenario -eq 'resize') {
            $clientWidth = if ($i % 2 -eq 0) { 1000 } else { 1200 }
            $now = Get-HollowBenchWindow $process.Id
            $width = $clientWidth + ($now.rect_right-$now.rect_left-$now.client_width)
            $height = 800 + ($now.rect_bottom-$now.rect_top-$now.client_height)
            if (-not [HollowBenchWindow]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, $width, $height, 0x0016)) { throw 'Resize failed.' }
            $now = Get-HollowBenchWindow $process.Id
            if ($now.client_width -ne $clientWidth -or $now.client_height -ne 800) { throw 'Client resize did not match requested physical dimensions.' }
            if ($i -eq 0) {
                Start-Sleep -Milliseconds 250
                Save-Semantics (Join-Path $OutputDir 'semantics-resized.json')
                $beforeTree = Get-Content -LiteralPath (Join-Path $OutputDir 'semantics-before.json') -Raw | ConvertFrom-Json
                $narrowTree = Get-Content -LiteralPath (Join-Path $OutputDir 'semantics-resized.json') -Raw | ConvertFrom-Json
                $beforePanel = @($beforeTree.nodes | Where-Object { $_.surface -eq 'overlay' -and $_.role -eq 'dialog' })[0]
                $narrowPanel = @($narrowTree.nodes | Where-Object { $_.surface -eq 'overlay' -and $_.role -eq 'dialog' })[0]
                if ($beforePanel.bounds.x -eq $narrowPanel.bounds.x -and $beforePanel.bounds.width -eq $narrowPanel.bounds.width) { throw 'Native overlay panel geometry did not change after resize.' }
            }
        }
        $geometry = Get-HollowBenchWindow $process.Id
        if ($geometry.is_iconic -or $geometry.is_maximized -or $geometry.is_foreground -or $geometry.monitor -ne $initial.monitor -or $geometry.dpi -ne $initial.dpi) { throw 'Window state, monitor, or DPI changed.' }
        $samples.Add([pscustomobject]@{ elapsed_ms=$clock.Elapsed.TotalMilliseconds; working_set_bytes=$process.WorkingSet64; private_bytes=$process.PrivateMemorySize64; process_cpu_ms=$process.TotalProcessorTime.TotalMilliseconds; client_width=$geometry.client_width; client_height=$geometry.client_height })
        $i++
        Start-Sleep -Milliseconds 250
    }
    $phaseEndNs = [int64]([Diagnostics.Stopwatch]::GetTimestamp() * (1000000000.0 / [Diagnostics.Stopwatch]::Frequency))
    if ($Scenario -eq 'scroll' -and -not (Select-String -LiteralPath $log -SimpleMatch 'HOLLOW_PROFILE_SCROLL_CHANGED' -Quiet)) { throw 'No verified wheel-driven viewport change.' }
    if ($Scenario -eq 'selection' -and -not (Select-String -LiteralPath $log -SimpleMatch 'HOLLOW_PROFILE_KEY_CHANGED' -Quiet)) { throw 'No verified page-key selection change.' }
    if ($Scenario -eq 'resize' -and @((Select-String -LiteralPath $log -SimpleMatch 'HOLLOW_PROFILE_RESIZED')).Count -lt 2) { throw 'Fewer than two native window:resized sizes observed.' }
    Save-Semantics (Join-Path $OutputDir 'semantics-after.json')
    $samples | Export-Csv -LiteralPath (Join-Path $OutputDir 'memory.csv') -NoTypeInformation -Encoding UTF8
    @{ picker=$Picker; scenario=$Scenario; seconds=$Seconds; pid=$process.Id; executable=$Exe; fixture=$Fixture; phase_start_ns=$phaseStartNs; phase_end_ns=$phaseEndNs; initial_window=$initial; start_utc=[DateTime]::UtcNow.AddMilliseconds(-$clock.Elapsed.TotalMilliseconds).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'metadata.json')
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(15000)) { Write-Warning "Owned process $($process.Id) did not exit; left running." }
        }
    }
}
