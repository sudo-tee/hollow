# Hollow Shell Integration for PowerShell
#
# Reports cwd via OSC 7 and updates the window title via OSC 0 so the
# host gets the same ambient metadata it receives from bash/zsh/fish.

if (-not $env:HOLLOW_PANE_ID) { return }
if ($global:_HOLLOW_PS_LOADED) { return }
$global:_HOLLOW_PS_LOADED = $true

# Capture the original prompt as a ScriptBlock snapshot. Storing the
# FunctionInfo directly and re-invoking it after redefining `prompt`
# re-enters the new function and recurses; .ScriptBlock is a value copy.
$global:_HOLLOW_ORIGINAL_PROMPT = if (Test-Path Function:\prompt) {
    (Get-Item Function:\prompt).ScriptBlock
} else { $null }

function global:prompt {
    $e = [char]27; $bel = [char]7
    $p = $executionContext.SessionState.Path.CurrentLocation

    $markers = ''
    if ($p.Provider.Name -eq 'FileSystem' -and $p.ProviderPath) {
        $path = $p.ProviderPath
        # OSC 7: cwd report. Emit the raw Windows path verbatim because
        # Hollow's file:// URI parser strips the host and keeps the
        # leading slash, which mangles Windows drive letters.
        # OSC 0: window title tracks the current directory.
        $markers = "$e]7;$path$bel$e]0;$path$bel"
    }

    $body = if ($global:_HOLLOW_ORIGINAL_PROMPT) {
        (& $global:_HOLLOW_ORIGINAL_PROMPT) -join "`r`n"
    } else {
        "PS $p$('>' * ($nestedPromptLevel + 1)) "
    }

    "$markers$body"
}
