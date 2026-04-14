function ConvertTo-HollowHtpJsonString {
    param([string]$Value)

    if ($null -eq $Value) { return "" }
    return ($Value.Replace("\", "\\").Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t'))
}

function New-HollowHtpId {
    "pwsh-$PID-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
}

function Send-HollowHtpRaw {
    param([Parameter(Mandatory = $true)][string]$Json)

    $tty = [Console]::OpenStandardOutput()
    $bytes = [Text.Encoding]::UTF8.GetBytes("`e]1337;Hollow;$Json`e\")
    $tty.Write($bytes, 0, $bytes.Length)
    $tty.Flush()
}

function Send-HollowHtpEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$PayloadJson = '{}'
    )

    $id = New-HollowHtpId
    $escaped = ConvertTo-HollowHtpJsonString $Name
    Send-HollowHtpRaw "{\"kind\":\"event\",\"id\":\"$id\",\"name\":\"$escaped\",\"payload\":$PayloadJson}"
}

function Send-HollowHtpCwdChanged {
    param([string]$Cwd = (Get-Location).Path)

    $escaped = ConvertTo-HollowHtpJsonString $Cwd
    Send-HollowHtpEvent -Name 'cwd_changed' -PayloadJson "{\"cwd\":\"$escaped\"}"
}

function Read-HollowHtpFrame {
    param([double]$TimeoutSeconds = 1.5)

    throw 'Read-HollowHtpFrame is not implemented for PowerShell yet. PowerShell console input is line-buffered here, so raw OSC reply capture needs a dedicated console-mode implementation.'
}

function Invoke-HollowHtpQueryOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ParamsJson = '{}'
    )

    throw 'Invoke-HollowHtpQueryOnce is not implemented for PowerShell yet. Use bash/zsh/fish helpers for now.'
}

# Examples:
#   . ./examples/htp/Hollow.Htp.ps1
#   Send-HollowHtpCwdChanged
#   Invoke-HollowHtpQueryOnce -Name current_pane
