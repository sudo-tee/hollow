#!/usr/bin/env python3
"""From WSL, profile Windows Hollow/wsl.exe and Linux PTY-agent CPU during COMMAND.

The command can be an entire multi-pane benchmark coordinator. CPU is sampled
once for the whole run rather than being counted separately by each pane.
Windows and guest CPU are kept separate to avoid WSL VM double-counting.

Usage:
    bench.sh cpu bench.sh repaint 20000
    HOLLOW_BENCH_GUI_PID=1234 bench.sh cpu python3 multi_pane_bench.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


# Embedded to keep this a one-file bench helper (no PowerShell installation).
WINDOWS_SAMPLER = r"""
param([string]$Ready, [string]$Stop, [int]$GuiPid=0)

$ErrorActionPreference = 'Stop'
$prior = @{}
$total = @{ 'wsl'=0.0; 'hollow-native'=0.0 }
$peak = @{ 'wsl'=0; 'hollow-native'=0 }
$clock = [Diagnostics.Stopwatch]::StartNew()

function Sample-Cpu {
    $now = @{}
    foreach ($name in @('wsl', 'hollow-native')) {
        $count = 0
        foreach ($proc in [Diagnostics.Process]::GetProcessesByName($name)) {
            try {
                if ($name -eq 'hollow-native' -and $GuiPid -gt 0 -and $proc.Id -ne $GuiPid) {
                    continue
                }
                $count++
                # PID + start time avoids confusing recycled Windows PIDs.
                $key = '{0}:{1}:{2}' -f $name, $proc.Id, $proc.StartTime.ToFileTimeUtc()
                $seconds = $proc.TotalProcessorTime.TotalSeconds
                if ($script:prior.ContainsKey($key)) {
                    $script:total[$name] += [Math]::Max(0.0, $seconds - $script:prior[$key])
                }
                $now[$key] = $seconds
            } catch {
                # Processes can exit between listing and counter lookup.
            } finally {
                $proc.Dispose()
            }
        }
        $script:peak[$name] = [Math]::Max($script:peak[$name], $count)
    }
    $script:prior = $now
}

Sample-Cpu
[IO.File]::WriteAllText($Ready, 'ready')
while (-not [IO.File]::Exists($Stop)) {
    Start-Sleep -Milliseconds 100
    Sample-Cpu
}
Sample-Cpu
$clock.Stop()

@{
    elapsed_seconds = $clock.Elapsed.TotalSeconds
    processes = @{
        wsl = @{ cpu_seconds=$total['wsl']; max_processes=$peak['wsl'] }
        hollow_native = @{ cpu_seconds=$total['hollow-native']; max_processes=$peak['hollow-native'] }
    }
} | ConvertTo-Json -Compress -Depth 5
"""


def linux_agents():
    """Map live PTY/mux (pid, start-time) to total process CPU ticks."""
    found = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            proc = Path(entry.path)
            if (proc / "comm").read_text().strip() != "hollow-agent":
                continue
            argv = (proc / "cmdline").read_bytes().split(b"\0")
            if b"pty" not in argv and b"mux" not in argv:
                continue
            # /proc/[pid]/stat fields after the last ')', starting at field 3:
            # utime=14 (index 11), stime=15 (12), starttime=22 (19).
            fields = (proc / "stat").read_text().rsplit(") ", 1)[1].split()
            found[(int(entry.name), int(fields[19]))] = (
                int(fields[11]) + int(fields[12])
            )
        except (OSError, ValueError, IndexError):
            continue
    return found


def sample_linux(stop, ready, output):
    previous = linux_agents()
    started = time.monotonic()
    ticks = 0
    peak = len(previous)
    ready.set()
    while not stop.wait(0.1):
        current = linux_agents()
        peak = max(peak, len(current))
        ticks += sum(
            max(0, value - previous[key])
            for key, value in current.items()
            if key in previous
        )
        previous = current
    current = linux_agents()
    ticks += sum(
        max(0, value - previous[key])
        for key, value in current.items()
        if key in previous
    )
    output.update(
        cpu_seconds=ticks / os.sysconf("SC_CLK_TCK"),
        elapsed_seconds=time.monotonic() - started,
        max_processes=max(peak, len(current)),
    )


def winpath(path):
    return subprocess.check_output(
        ["wslpath", "-w", str(path)], text=True
    ).strip()


def main():
    command = sys.argv[1:]
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        prog = os.environ.get("HOLLOW_BENCH_PROG", "bench.sh")
        print(f"usage: {prog} cpu COMMAND [ARGS...]", file=sys.stderr)
        return 2
    if not sys.platform.startswith("linux") or "WSL_INTEROP" not in os.environ and "WSL_DISTRO_NAME" not in os.environ:
        print("bench CPU sampling requires WSL with Windows interop", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="hollow-bench-cpu-") as directory:
        root = Path(directory)
        ps_file = root / "sample.ps1"
        ps_file.write_text(WINDOWS_SAMPLER)
        ready = root / "ready"
        stop_file = root / "stop"
        ps_args = [
            "powershell.exe", "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-File", winpath(ps_file),
            "-Ready", winpath(ready), "-Stop", winpath(stop_file),
        ]
        gui_pid = os.environ.get("HOLLOW_BENCH_GUI_PID")
        if gui_pid:
            try:
                if int(gui_pid) <= 0:
                    raise ValueError
            except ValueError:
                print("HOLLOW_BENCH_GUI_PID must be a positive Windows PID", file=sys.stderr)
                return 2
            ps_args.extend(["-GuiPid", gui_pid])

        try:
            ps = subprocess.Popen(
                ps_args, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
        except OSError as exc:
            print(f"Unable to launch PowerShell sampler: {exc}", file=sys.stderr)
            return 1

        stop = threading.Event()
        linux_ready = threading.Event()
        linux = {}
        thread = None
        result = 1
        try:
            deadline = time.monotonic() + 15
            while not ready.exists() and ps.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not ready.exists():
                print("Windows CPU sampler did not become ready", file=sys.stderr)
                return 1

            thread = threading.Thread(
                target=sample_linux, args=(stop, linux_ready, linux), daemon=True,
            )
            thread.start()
            linux_ready.wait()
            print("[bench-cpu] sampling Windows Hollow, all wsl.exe, and Linux PTY agents", flush=True)
            try:
                result = subprocess.call(command)
            except KeyboardInterrupt:
                result = 130
        finally:
            stop.set()
            if thread:
                thread.join(timeout=5)
            stop_file.touch()
            try:
                stdout, stderr = ps.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                ps.kill()
                stdout, stderr = ps.communicate()

            if ps.returncode == 0:
                try:
                    windows = json.loads(stdout)
                    duration = windows["elapsed_seconds"]
                    for key, label in (
                        ("hollow_native", "hollow-native.exe"),
                        ("wsl", "wsl.exe"),
                    ):
                        row = windows["processes"][key]
                        seconds = row["cpu_seconds"]
                        print(
                            f"[Windows] {label}: {seconds:.3f} CPU-s, "
                            f"{seconds / max(duration, 1e-9):.3f} avg cores, "
                            f"sampled peak {row['max_processes']} processes"
                        )
                    seconds = linux["cpu_seconds"]
                    print(
                        f"[Linux] hollow-agent (pty/mux): {seconds:.3f} CPU-s, "
                        f"{seconds / max(linux['elapsed_seconds'], 1e-9):.3f} avg cores, "
                        f"sampled peak {linux['max_processes']} processes"
                    )
                    print("BENCH_CPU_JSON=" + json.dumps(
                        {"windows": windows, "linux_agent": linux},
                        sort_keys=True, separators=(",", ":"),
                    ))
                except (KeyError, ValueError, TypeError, ZeroDivisionError) as exc:
                    print(f"Invalid CPU sampler result: {exc}", file=sys.stderr)
                    result = result or 1
            else:
                print(f"Windows CPU sampler failed: {stderr or stdout}", file=sys.stderr)
                result = result or 1
        return result


if __name__ == "__main__":
    sys.exit(main())
