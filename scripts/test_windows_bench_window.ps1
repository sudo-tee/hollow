# Synthetic checks only; never moves, activates, or closes a real window.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_bench_window.ps1')
$expected = @{
    has_window=$true; is_iconic=$false; is_maximized=$false; is_foreground=$false
    rect_left=-1800; rect_top=40; rect_right=-520; rect_bottom=840
    client_width=1280; client_height=800; dpi=96; monitor='\\.\DISPLAY1'
}
Assert-HollowBenchWindow ([pscustomobject]$expected) ([pscustomobject]$expected)
$count=1
foreach ($change in @(
    @{is_iconic=$true}, @{is_maximized=$true}, @{is_foreground=$true}, @{has_window=$false}, @{dpi=$null},
    @{rect_left=-1799}, @{rect_top=41}, @{rect_right=-519}, @{rect_bottom=841},
    @{client_width=1279}, @{client_height=799}, @{dpi=120}, @{monitor='\\.\DISPLAY2'}
)) {
    $actual=$expected.Clone()
    foreach ($key in $change.Keys) { $actual[$key]=$change[$key] }
    $rejected=$false
    try { Assert-HollowBenchWindow ([pscustomobject]$actual) ([pscustomobject]$expected) } catch { $rejected=$true }
    if (-not $rejected) { throw "Failed to reject drift: $($change | ConvertTo-Json -Compress)" }
    $count++
}
Write-Output "PASS: $count benchmark window invariant checks; no live windows modified."
