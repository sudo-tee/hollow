param(
    [string]$ProcessName = "hollow-native",
    [int]$PreMinimizeDelayMs = 2000,
    [int]$MinimizedDelayMs = 1000,
    [int]$PostRestoreDelayMs = 1200,
    [switch]$Close
)

$ErrorActionPreference = "Stop"

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class HollowWin32 {
    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Get-MainWindowHandle {
    param([string]$Name)

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $proc -and $proc.MainWindowHandle -ne 0) {
            return $proc
        }
        Start-Sleep -Milliseconds 100
    }

    throw "Could not find process '$Name' with a main window"
}

$proc = Get-MainWindowHandle -Name $ProcessName
$hwnd = $proc.MainWindowHandle

Start-Sleep -Milliseconds $PreMinimizeDelayMs
[void][HollowWin32]::ShowWindowAsync($hwnd, 6)
Start-Sleep -Milliseconds $MinimizedDelayMs
[void][HollowWin32]::ShowWindowAsync($hwnd, 9)
[void][HollowWin32]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds $PostRestoreDelayMs

if ($Close) {
    try {
        $proc.CloseMainWindow() | Out-Null
    } catch {
    }
}
