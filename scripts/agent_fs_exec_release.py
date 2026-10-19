#!/usr/bin/env python3
"""Reproducible fs/exec release checks, independent of experimental PTY gates.

Requested checks must all pass. Omitted connectors are explicitly unverified,
never promoted by a local-only pass. Fixtures create only owned test containers.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ("local", "podman", "ssh", "docker", "socket", "wsl")


def commands(args):
    python = sys.executable
    build = [args.zig, "build", "--build-file", "build-agent.zig", "-Doptimize=ReleaseSafe", *args.build_option]
    agent = str(ROOT / "zig-out/bin/hollow-agent")
    native = [*build, "test-host-lua", "test-host-lua-flat"]
    checks = [
        ("build-and-native", [*build, "agent", "agent-all", "test-agent", "test-agent-fs", "test-host-transport", "test-host-operations", "test-host-manager", "test-host-local", "test-host-lua", "test-host-lua-flat"]),
        ("unit-harness", [python, "-m", "unittest", "discover", "-s", "scripts/tests"]),
        ("lua-contracts", ["bash", "scripts/test-lua.sh"]),
        ("bundle-checksums", ["sha256sum", "-c", "SHA256SUMS"]),
        ("local-conformance", [python, "scripts/agent_conformance.py", "--connector", "local-subprocess", "--agent", agent]),
        ("local-containment", [python, "scripts/agent_fault_probe.py", "--agent", agent, "--output", str(args.output / "faults-local.json")]),
    ]
    if "podman" in args.profile:
        checks += [
            ("podman-conformance", [python, "scripts/agent_conformance.py", "--connector", "podman", "--agent", agent]),
            ("podman-containment", [python, "scripts/agent_fault_probe.py", "--connector", "podman", "--agent", agent, "--output", str(args.output / "faults-podman.json")]),
            ("podman-production", [python, "scripts/agent_host_tests.py", "--connector", "podman-bootstrap", "--agent", agent, "--container-user", "1000:1000", "--", *native]),
        ]
    if "ssh" in args.profile:
        checks.append(("ssh-production", [python, "scripts/agent_ssh_tests.py", "--agent", agent, "--conformance", "--", *native]))
    if "docker" in args.profile:
        checks.append(("docker-production", [python, "scripts/agent_docker_tests.py", "--agent", agent, "--conformance", "--", *native]))
    if "socket" in args.profile:
        checks.append(("socket-conformance-and-loss", [python, "scripts/agent_socket_tests.py", "--agent", agent, "--fragment", "257", "--conformance", "--", *native]))
    if "wsl" in args.profile:
        conformance = [python, "scripts/agent_conformance.py", "--connector", "wsl", "--distro", args.distro, "--agent-path", args.wsl_agent_path]
        command = [python, "scripts/agent_host_tests.py", "--connector", "wsl-bootstrap", "--agent", agent, "--distro", args.distro]
        if args.wsl_user:
            command += ["--wsl-user", args.wsl_user]
            conformance += ["--wsl-user", args.wsl_user]
        if args.wsl_artifact:
            command += ["--wsl-artifact", args.wsl_artifact]
        checks.append(("wsl-production", [*command, "--", *native]))
        checks.append(("wsl-conformance", conformance))
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="Zig 0.16 executable")
    parser.add_argument("--build-option", action="append", default=[], help="repeatable Zig build argument; use --build-option=-Dhost-lua-include=...")
    parser.add_argument("--lua", default="luajit", help="Lua 5.1-compatible interpreter for Busted")
    parser.add_argument("--profile", nargs="+", choices=PROFILES, default=["local"], help="local checks always run; other profiles require their real runner/fixture")
    parser.add_argument("--distro", help="explicit existing WSL distribution, required for wsl profile")
    parser.add_argument("--wsl-user")
    parser.add_argument("--wsl-artifact", help="Windows-accessible Linux agent artifact for interop qualification")
    parser.add_argument("--wsl-agent-path", help="explicit existing absolute Linux agent path for WSL wire conformance")
    parser.add_argument("--output", type=Path, required=True, help="new report directory; never overwritten")
    args = parser.parse_args()
    if "wsl" in args.profile and (not args.distro or not args.wsl_agent_path or not args.wsl_agent_path.startswith("/")):
        parser.error("wsl profile requires --distro and absolute --wsl-agent-path")
    if any(not option.startswith("-D") or "\0" in option for option in args.build_option):
        parser.error("build options must be -D arguments")
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, LUA=args.lua)
    cleared = []
    for key in list(env):
        if key.startswith("HOLLOW_AGENT_") or key.startswith("HOLLOW_TEST_") or key == "HOLLOW_EXPERIMENTAL_AGENT_PTY":
            cleared.append(key)
            del env[key]
    report = dict(schema=1, scope="fs/exec only; no PTY/GUI qualification", checks_passed=False,
                  selected_profiles=sorted(set(["local", *args.profile])),
                  unverified_profiles=[p for p in PROFILES if p != "local" and p not in args.profile],
                  unverified_platforms=["native Windows client execution", "ARM64 execution"],
                  cleared_environment_keys=sorted(cleared), checks=[])
    report["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "src/agent", "src/host", "src/lua", "src/host_lua_test.zig", "scripts", "build-agent.zig"], cwd=ROOT, text=True).splitlines()
    files += [str(Path(__file__).relative_to(ROOT))]
    report["source_sha256"] = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sorted(set(files)) if (ROOT / name).is_file()}

    def save():
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    for name, command in commands(args):
        record = dict(name=name, command=command, passed=False)
        report["checks"].append(record)
        save()
        started = time.monotonic_ns()
        try:
            with (args.output / (name + ".log")).open("xb") as log:
                completed = subprocess.run(command, cwd=ROOT / "zig-out/agents" if name == "bundle-checksums" else ROOT,
                                           env=env, stdout=log, stderr=subprocess.STDOUT)
            record.update(returncode=completed.returncode, passed=completed.returncode == 0)
        except KeyboardInterrupt:
            record["error"] = "interrupted"
            save()
            return 130
        except OSError as error:
            record["error"] = str(error)
        record["elapsed_ns"] = time.monotonic_ns() - started
        save()
        print(name, "PASS" if record["passed"] else "FAIL", flush=True)
    report["changed_sources"] = [name for name, digest in report["source_sha256"].items()
        if not (ROOT / name).is_file() or hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest]
    report["checks_passed"] = all(check["passed"] for check in report["checks"]) and not report["changed_sources"]
    report["artifacts_sha256"] = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (ROOT / "zig-out/agents").glob("**/*") if path.is_file()}
    save()
    print("Selected fs/exec checks", "PASS" if report["checks_passed"] else "FAIL", "—", args.output / "report.json")
    return 0 if report["checks_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
