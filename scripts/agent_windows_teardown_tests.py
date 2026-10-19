#!/usr/bin/env python3
"""Run an explicitly selected Windows/WSL teardown fixture from its Linux distro."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


def proc_identity(text):
    pid, rest = text.split(" (", 1)
    _, fields = rest.rsplit(") ", 1)
    fields = fields.split()
    return {"pid": int(pid), "state": fields[0], "ppid": int(fields[1]), "starttime": int(fields[19])}


def witnesses(stdout):
    result = {}
    for role, label in (("workload", "TEARDOWN"), ("guardian", "GUARDIAN"), ("agent", "AGENT")):
        found = re.findall(r"^WINDOWS_LUA_" + label + r"_BEFORE (.+)$", stdout, re.M)
        if len(found) != 1:
            raise ValueError(f"expected exactly one {role} witness")
        identity = proc_identity(found[0])
        if identity["pid"] <= 1 or identity["state"] in ("Z", "X"):
            raise ValueError(f"invalid live {role} witness")
        result[role] = identity
    if result["workload"]["ppid"] != result["guardian"]["pid"] or result["guardian"]["ppid"] != result["agent"]["pid"]:
        raise ValueError("witness ancestry mismatch")
    return result


def observe(original):
    """PID reuse is not survival; a same-identity zombie is still a failure."""
    try:
        current = proc_identity(Path(f"/proc/{original['pid']}/stat").read_text())
    except (FileNotFoundError, ProcessLookupError):
        return {"gone": True}
    return {"gone": current["starttime"] != original["starttime"], "current": current}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--distro", required=True, help="Must be this runner's Linux distro for /proc observations")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.runs <= 32:
        parser.error("--runs must be between 1 and 32")
    if os.environ.get("WSL_DISTRO_NAME") != args.distro:
        parser.error("selected distro must match runner's WSL_DISTRO_NAME")
    args.output.mkdir(parents=True, exist_ok=False)
    exe, fixture = args.exe.resolve(), args.fixture.resolve()
    report = {"scope": "headless Windows manager teardown under owned HOME launcher; not GUI or crash qualification", "distro": args.distro, "exe_sha256": sha(exe), "fixture_sha256": sha(fixture), "runs": []}
    fixture_windows = subprocess.check_output(["wslpath", "-w", str(fixture)], text=True).strip()
    for index in range(args.runs):
        home = subprocess.check_output(["mktemp", "-d", "/tmp/hollow-wsl-home-XXXXXXXXXXXX"], text=True).strip()
        if not re.fullmatch(r"/tmp/hollow-wsl-home-[A-Za-z0-9]{12}", home):
            raise ValueError("invalid owned fixture HOME")
        env = dict(os.environ)
        # No implicit inherited test selectors (especially missing-bundle mode).
        for key in list(env):
            if key.startswith("HOLLOW_TEST_"):
                del env[key]
        overrides = {"HOLLOW_TEST_REQUIRE_LUAJIT": "1", "HOLLOW_TEST_WSL_DISTRO": args.distro, "HOLLOW_TEST_WSL_HOME": home, "HOLLOW_TEST_WSL_FIXTURE": fixture_windows, "HOLLOW_TEST_WSL_TEARDOWN": "1"}
        env.update(overrides)
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV"), *overrides]))
        run = {"index": index, "home": home, "cache_absent_before": not (Path(home) / ".cache").exists(), "environment": overrides, "command": [str(exe)]}
        try:
            completed = subprocess.run([str(exe)], env=env, capture_output=True, text=True, timeout=180)
            # One deadline for all identities, starting immediately after Windows process exit.
            exited = time.monotonic()
            run.update(returncode=completed.returncode, stdout=completed.stdout, stderr=completed.stderr)
            identities = witnesses(completed.stdout)
            run["identities_before"] = identities
            while True:
                after = {role: observe(identity) for role, identity in identities.items()}
                if all(value["gone"] for value in after.values()) or time.monotonic() >= exited + 5:
                    break
                time.sleep(0.02)
            run.update(after=after, observation_elapsed_seconds=time.monotonic() - exited)
            timing = re.findall(r"WINDOWS_LUA_MANAGER_DEINIT_NS (\d+)", completed.stderr)
            run["deinit_ns"] = int(timing[0]) if len(timing) == 1 else None
            run["passed"] = (completed.returncode == 0 and run["cache_absent_before"] and all(value["gone"] for value in after.values()) and run["deinit_ns"] is not None and run["deinit_ns"] < 8_000_000_000 and "compiled-trace" in completed.stdout and "12 passed; 1 skipped; 0 failed." in completed.stderr and "WINDOWS_LUA_TEARDOWN_STALE_REJECTED " + home in completed.stdout)
        except subprocess.TimeoutExpired as error:
            def text(value):
                return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
            run.update(passed=False, error=str(error), stdout=text(error.stdout), stderr=text(error.stderr))
        except (ValueError, OSError) as error:
            run.update(passed=False, error=str(error))
        report["runs"].append(run)
        report["binaries_unchanged"] = sha(exe) == report["exe_sha256"] and sha(fixture) == report["fixture_sha256"]
        report["passed"] = all(r["passed"] for r in report["runs"]) and report["binaries_unchanged"]
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"run {index}: {'PASS' if run['passed'] else 'FAIL'}", flush=True)
        if not report["passed"]:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
