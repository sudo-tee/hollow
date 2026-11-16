"""Round-trip restart arguments through the real Windows argv parser."""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell.exe")


@unittest.skipUnless(POWERSHELL, "requires Windows PowerShell")
class RestartHollowTests(unittest.TestCase):
    def test_start_preserves_argument_boundaries(self):
        arguments = [
            "--match-font", "JetBrains Mono", "", "plain",
            'embedded"quote', 'backslash\\"quote', "C:\\path with spaces\\",
            "\\\\", "apostrophe's", "tab\there",
        ]
        # Replace process creation with a capture that uses CommandLineToArgvW.
        # No installed GUI is started, stopped, or accessed.
        capture = r'''
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HollowTestArgv {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr pointer);
}
'@
function Start-Process {
    param($FilePath, $ArgumentList)
    $count = 0
    $pointer = [HollowTestArgv]::CommandLineToArgvW(('test.exe ' + $ArgumentList), [ref]$count)
    if ($pointer -eq [IntPtr]::Zero) { throw 'CommandLineToArgvW failed' }
    try {
        $values = @()
        for ($i = 1; $i -lt $count; $i++) {
            $arg = [Runtime.InteropServices.Marshal]::ReadIntPtr($pointer, $i * [IntPtr]::Size)
            $values += [Runtime.InteropServices.Marshal]::PtrToStringUni($arg)
        }
        ConvertTo-Json -InputObject $values -Compress
    } finally {
        [void][HollowTestArgv]::LocalFree($pointer)
    }
}
'''
        values = "@(" + ",".join("'" + arg.replace("'", "''") + "'" for arg in arguments) + ")"
        script = capture + "\n& {\n" + (ROOT / "scripts/restart-hollow.ps1").read_text()
        script += "\n} -Action Start -AppArgs " + values
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), arguments)


if __name__ == "__main__":
    unittest.main()
