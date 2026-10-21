# Dot-source for benchmark launch/sampling. All coordinates are physical pixels.
# This helper changes only the explicitly selected process's window.
if (-not ('HollowBenchWindow' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HollowBenchWindow {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
}
'@
}
# Per-monitor v2 prevents PowerShell's default DPI virtualization from turning
# requested bounds and sampled bounds into different coordinate systems.
if ([HollowBenchWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) -eq [IntPtr]::Zero) {
    throw 'Cannot enter per-monitor-v2 DPI context.'
}
Add-Type -AssemblyName System.Windows.Forms

function Get-HollowBenchWindow([int]$GuiPid) {
    $process = Get-Process -Id $GuiPid -ErrorAction Stop
    $process.Refresh()
    $handle = $process.MainWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw "GUI $GuiPid has no main window yet." }
    $outer = New-Object HollowBenchWindow+RECT
    $client = New-Object HollowBenchWindow+RECT
    if (-not [HollowBenchWindow]::GetWindowRect($handle, [ref]$outer) -or
        -not [HollowBenchWindow]::GetClientRect($handle, [ref]$client)) {
        throw 'Cannot read benchmark window geometry.'
    }
    return [pscustomobject]@{
        has_window=$true
        is_iconic=[HollowBenchWindow]::IsIconic($handle)
        is_maximized=[HollowBenchWindow]::IsZoomed($handle)
        is_foreground=([HollowBenchWindow]::GetForegroundWindow() -eq $handle)
        rect_left=$outer.Left; rect_top=$outer.Top; rect_right=$outer.Right; rect_bottom=$outer.Bottom
        client_width=($client.Right-$client.Left); client_height=($client.Bottom-$client.Top)
        dpi=[HollowBenchWindow]::GetDpiForWindow($handle)
        monitor=[System.Windows.Forms.Screen]::FromHandle($handle).DeviceName
    }
}

function Set-HollowBenchWindow {
    param(
        [Parameter(Mandatory=$true)][int]$GuiPid,
        [Parameter(Mandatory=$true)][string]$Monitor,
        [int]$ClientWidth=1280,
        [int]$ClientHeight=800,
        [IntPtr]$PreviousForeground=[IntPtr]::Zero,
        [double]$TimeoutSeconds=15
    )
    if ($ClientWidth -le 0 -or $ClientHeight -le 0 -or $TimeoutSeconds -le 0) { throw 'Size and timeout must be positive.' }
    $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $Monitor } | Select-Object -First 1
    if ($null -eq $screen) { throw "Benchmark monitor missing: $Monitor" }
    $area = $screen.WorkingArea
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $stableSince = $null
    $signature = $null
    $state = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $process = Get-Process -Id $GuiPid -ErrorAction Stop
        $process.Refresh()
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100; continue }
        $state = Get-HollowBenchWindow $GuiPid
        # Benchmark starts from a fresh, normal window. Do not silently restore
        # maximized/minimized state or fight user input during measurements.
        if ($state.is_iconic -or $state.is_maximized) { throw 'Benchmark window must be normal, not maximized/minimized.' }
        $width = $ClientWidth + ($state.rect_right-$state.rect_left-$state.client_width)
        $height = $ClientHeight + ($state.rect_bottom-$state.rect_top-$state.client_height)
        if ($width -gt $area.Width -or $height -gt $area.Height) { throw 'Requested client size does not fit benchmark monitor.' }
        $x = $area.X + [int][math]::Floor(($area.Width-$width)/2)
        $y = $area.Y + [int][math]::Floor(($area.Height-$height)/2)
        $matches = $state.client_width -eq $ClientWidth -and $state.client_height -eq $ClientHeight -and
            $state.rect_left -eq $x -and $state.rect_top -eq $y -and $state.monitor -eq $Monitor
        if (-not $matches) {
            # SWP_NOZORDER | SWP_NOACTIVATE; return value must be checked.
            if (-not [HollowBenchWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero, $x, $y, $width, $height, 0x0014)) {
                throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
            }
            $stableSince=$null
            Start-Sleep -Milliseconds 150
            continue
        }
        if ($state.is_foreground -and $PreviousForeground -ne [IntPtr]::Zero) {
            [void][HollowBenchWindow]::SetForegroundWindow($PreviousForeground)
            $stableSince=$null
            Start-Sleep -Milliseconds 150
            continue
        }
        if ($state.is_foreground) { throw 'Cannot establish background benchmark window.' }
        $current = $state | ConvertTo-Json -Compress
        if ($current -ne $signature) { $signature=$current; $stableSince=[DateTime]::UtcNow }
        if ($null -ne $stableSince -and ([DateTime]::UtcNow-$stableSince).TotalSeconds -ge 1) { return $state }
        Start-Sleep -Milliseconds 100
    }
    $lastState = if ($null -ne $state) { $state | ConvertTo-Json -Compress } else { 'No main window observed' }
    throw "Benchmark window failed to stabilize at requested physical client size/position. Last state: $lastState"
}

function Assert-HollowBenchWindow($Actual, $Expected) {
    foreach ($key in @('has_window','is_iconic','is_maximized','is_foreground','rect_left','rect_top','rect_right','rect_bottom','client_width','client_height','dpi','monitor')) {
        if ($null -eq $Actual.$key -or $null -eq $Expected.$key) { throw "Benchmark window metadata missing: $key" }
    }
    if (-not $Actual.has_window -or $Actual.client_width -le 0 -or $Actual.client_height -le 0 -or $Actual.dpi -eq 0) { throw 'Invalid benchmark window dimensions/handle/DPI.' }
    if ($Actual.is_iconic -or $Actual.is_maximized -or $Actual.is_foreground) {
        throw "Benchmark window state changed: minimized=$($Actual.is_iconic), maximized=$($Actual.is_maximized), foreground=$($Actual.is_foreground)."
    }
    foreach ($key in @('rect_left','rect_top','rect_right','rect_bottom','client_width','client_height','dpi','monitor')) {
        if ($Actual.$key -ne $Expected.$key) { throw "Benchmark window drift: $key expected $($Expected.$key), got $($Actual.$key)." }
    }
}
