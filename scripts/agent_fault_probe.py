#!/usr/bin/env python3
"""Probe exec guardian containment after transport loss and agent SIGKILL.

Exit 1 means a live workload descendant survived. A guardian zombie is reported
separately: it has exited, but container init may not yet have reaped it.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import shlex
import tempfile
import threading
import time
import uuid

from agent_conformance import AgentClient, RESPONSE, b64
from agent_connectors import ConnectorError, LocalSubprocess, Podman

TERM_GRACE = 1.5
PROBE_TIMEOUT = 5.0


def identity(pid):
    """Return (state, starttime, ppid), handling comm fields with spaces."""
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
        return fields[0], fields[19], int(fields[1])
    except (FileNotFoundError, ProcessLookupError):
        return None


def verified_identity(pid, expected, identify=None):
    identify = identify or identity
    current = identify(pid)
    return current if current is not None and expected is not None and current[1] == expected[1] else None


def kill_verified(pid, expected, sig=signal.SIGKILL, *, kill=os.kill, identify=identity):
    """Signal only when PID still has captured starttime; safe against reuse."""
    current = identify(pid)
    if current is None or expected is None or current[1] != expected[1]:
        return False
    try:
        kill(pid, sig)
    except ProcessLookupError:
        pass
    return True


def verified_job(agent_pid, guardian_pid, guardian, workloads, identify=None):
    """Validate exact agent->guardian and guardian->workload ancestry."""
    identify = identify or identity
    now_guardian = verified_identity(guardian_pid, guardian, identify)
    if now_guardian is None or now_guardian[2] != agent_pid:
        return False
    for pid, original in workloads.items():
        current = verified_identity(pid, original, identify)
        if current is None:
            continue
        # Walk the live PPID chain: setsid changes session, never ancestry.
        parent_pid = current[2]
        seen = set()
        while parent_pid not in (guardian_pid, agent_pid) and parent_pid not in seen:
            seen.add(parent_pid)
            parent = identify(parent_pid)
            if parent is None:
                break
            parent_pid = parent[2]
        if parent_pid != guardian_pid:
            return False
    return True


def _wait_snapshot(pids, deadline, identify=None, guardian_pid=None):
    identify = identify or identity
    while time.monotonic() < deadline:
        current = {pid: identify(pid) for pid in pids}
        # Zombie is not reaped: only absence counts as dead.
        guardian = identify(guardian_pid) if guardian_pid is not None else None
        # Workload disappearance can precede guardian exit by a scheduling turn.
        # Wait for both within the original cleanup deadline; never accept a
        # runnable guardian or treat a workload zombie as reaped.
        if all(item is None for item in current.values()) and (guardian is None or guardian[0] == "Z"):
            return current
        time.sleep(.02)
    return {pid: identify(pid) for pid in pids}


class LocalTarget:
    def __init__(self, agent):
        self.connector = LocalSubprocess(agent)

    def connect(self):
        return self.connector.connect()

    identity = staticmethod(identity)
    signal = staticmethod(os.kill)

    @staticmethod
    def read_text(path):
        return path.read_text()

    @staticmethod
    def agent_pid(client):
        return client.process.pid


class PodmanTarget:
    """An independent agent observes faulted agents in the same PID namespace.

    All normal observations use RPC, not a fresh `podman exec` per operation.
    """
    def __init__(self, agent, image):
        self.connector = Podman(agent, image=image)
        self.observer = None
        try:
            rootless = self.connector._run(["info", "--format", "{{.Host.Security.Rootless}}"])
            if rootless.stdout.strip() != b"true":
                raise ConnectorError("rootless Podman required for fault fixture")
            self.observer = AgentClient(self.connector.connect())
            self.observer.start()
        except BaseException:
            self.close()
            raise

    def connect(self):
        return self.connector.connect()

    def exec(self, argv):
        streams = self.observer.allocate_streams()
        kind, result, output = self.observer.request("EXEC", {"argv_b64": list(map(b64, argv)),
            "stdout_stream_id": streams[0], "stderr_stream_id": streams[1]}, stream_ids=streams)
        if kind != RESPONSE or result.get("exit_code") != 0:
            raise RuntimeError(f"fault fixture command failed: {result}")
        return output

    def read_text(self, path):
        kind, result, data = self.observer.request("FS_READ", {"path_b64": b64(os.fsencode(path)), "limit": 16384})
        if kind != RESPONSE:
            if result.get("code") == "not_found":
                raise FileNotFoundError(path)
            raise RuntimeError(f"fault fixture read failed: {result}")
        return bytes(data[0]).decode()

    def identity(self, pid):
        try:
            fields = self.read_text(Path(f"/proc/{pid}/stat")).rsplit(") ", 1)[1].split()
            return fields[0], fields[19], int(fields[1])
        except FileNotFoundError:
            return None

    def signal(self, pid, sig):
        try:
            self.exec([b"kill", f"-{int(sig)}".encode(), str(pid).encode()])
        except RuntimeError:
            if self.identity(pid) is not None:
                raise

    @staticmethod
    def agent_pid(client):
        kind, result, _ = client.request("HOST_INFO")
        if kind != RESPONSE:
            raise RuntimeError("agent did not identify its RPC process")
        return result["agent_pid"]

    def close(self):
        if self.observer:
            self.observer.close()
        self.connector.close()


def probe(agent, directory, scenario, fault="sigkill", target=None):
    path = directory / f"{scenario}-{fault}"
    target = target or LocalTarget(agent)
    client = AgentClient(target.connect(), timeout=PROBE_TIMEOUT)
    failures = []
    worker_errors = []
    worker = None
    pids = []
    originals = {}
    guardian_pid = None
    guardian_original = None
    try:
        client.start()
        agent_pid = target.agent_pid(client)
        agent_identity = target.identity(agent_pid)
        streams = client.allocate_streams()
        # Each child records PID, PPID, starttime. Detached case double-forks
        # after setsid; all PIDs remain explicit identities, never kill targets
        # inferred from a broad process listing.
        if scenario == "direct":
            script = b'printf "%s %s\\n" "$$" "$PPID" > "$1"; exec sleep 30'
        elif scenario == "grandchildren":
            script = b'trap \'\' TERM; (trap \'\' TERM; exec sleep 30) & c=$!; printf "%s %s\\n%s %s\\n" "$$" "$PPID" "$c" "$$" > "$1"; wait'
        elif scenario == "setsid-double-fork":
            # Intermediate shells exit without waiting, so the detached leaf
            # must be adopted by guardian rather than found by its old PGID.
            leaf = 'trap "" TERM; printf "%s %s\\n" "$$" "$PPID" >> "$1"; exec sleep 30'
            middle = '/bin/sh -c ' + shlex.quote(leaf) + ' probe "$1" &'
            detached = '/bin/sh -c ' + shlex.quote(middle) + ' probe "$1" &'
            script = ('printf "%s %s\\n" "$$" "$PPID" > "$1"; setsid /bin/sh -c ' +
                      shlex.quote(detached) + ' probe "$1" & sleep 30 & wait').encode()
        else:
            raise ValueError(f"unknown scenario: {scenario}")

        def run():
            try:
                client.request("EXEC", {"argv_b64": list(map(b64, [b"/bin/sh", b"-c", script, b"probe", os.fsencode(path)])),
                                         "stdout_stream_id": streams[0], "stderr_stream_id": streams[1]},
                               stream_ids=streams, timeout=PROBE_TIMEOUT + 60)
            except BaseException as exc:
                worker_errors.append(exc)

        worker = threading.Thread(target=run, name=f"fault-probe-{scenario}")
        worker.start()
        deadline = time.monotonic() + PROBE_TIMEOUT
        while time.monotonic() < deadline:
            try:
                records = [tuple(map(int, line.split())) for line in target.read_text(path).splitlines()]
            except (FileNotFoundError, ValueError):
                records = []
            if len(records) == (1 if scenario == "direct" else 2):
                pids = [pid for pid, _ in records]
                originals = {pid: target.identity(pid) for pid in pids}
                if all(originals[pid] is not None for pid in pids):
                    break
            time.sleep(.01)
        if not pids or any(originals.get(pid) is None for pid in pids):
            raise RuntimeError("workload identity fixture was not ready")
        # Workload leader's parent is guardian; guardian's parent is agent.
        leader = pids[0]
        guardian_pid = originals[leader][2]
        guardian_original = target.identity(guardian_pid)
        if guardian_original is None or guardian_original[2] != agent_pid:
            raise RuntimeError("workload is not under agent->guardian ancestry")
        expected = {pid: originals[pid] for pid in pids}
        if not verified_job(agent_pid, guardian_pid, guardian_original, expected, target.identity):
            raise RuntimeError("fixture process ancestry changed before fault injection")

        if fault == "sigkill":
            if not kill_verified(agent_pid, agent_identity, kill=target.signal, identify=target.identity):
                raise RuntimeError("agent identity changed before fault injection")
        elif fault == "eof":
            client.process.stdin.close()
        else:
            raise ValueError(f"unknown fault: {fault}")
        client.process.wait(timeout=PROBE_TIMEOUT)
        worker.join(PROBE_TIMEOUT)
        states = _wait_snapshot(pids, time.monotonic() + TERM_GRACE + 3, target.identity, guardian_pid)
        guardian_state = target.identity(guardian_pid)
        # Guardian exit may be visible as zombie if container init has not
        # reaped it. Never treat that as proof that recorded workloads are gone.
        unreaped_workloads = [pid for pid, state in states.items() if state is not None]
        passed = (bool(worker_errors) and isinstance(worker_errors[0], (EOFError, OSError)) and
                  not worker.is_alive() and not unreaped_workloads and
                  (guardian_state is None or guardian_state[0] == "Z"))
        return {"scenario": scenario, "fault": fault,
                "request_failed": bool(worker_errors), "worker_error": type(worker_errors[0]).__name__ if worker_errors else None,
                "workload_states": {str(pid): (state[0] if state else "reaped") for pid, state in states.items()},
                "guardian_state": guardian_state[0] if guardian_state else "reaped",
                "guardian_reaped_externally": guardian_state is None,
                "passed": bool(passed)}
    except BaseException as exc:
        failures.append(f"{type(exc).__name__}: {exc}")
        return {"scenario": scenario, "passed": False, "failure": failures[-1]}
    finally:
        # On setup or assertion failure, clean only exact captured identities.
        client.close()
        for pid in pids:
            kill_verified(pid, originals.get(pid), kill=target.signal, identify=target.identity)
        if guardian_pid is not None:
            # Ask the guardian to kill/reap, rather than killing the process
            # which holds responsibility for otherwise unrecorded descendants.
            current = target.identity(guardian_pid)
            if current is not None and current[0] != "Z":
                kill_verified(guardian_pid, guardian_original, signal.SIGUSR2, kill=target.signal, identify=target.identity)
        if worker:
            worker.join(PROBE_TIMEOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--connector", choices=("local-subprocess", "podman"), default="local-subprocess")
    parser.add_argument("--image", default="docker.io/library/alpine:3.21")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    cases = (("direct", "sigkill"), ("grandchildren", "sigkill"), ("setsid-double-fork", "sigkill"),
             ("direct", "eof"), ("grandchildren", "eof"), ("setsid-double-fork", "eof"))
    if args.connector == "local-subprocess":
        with tempfile.TemporaryDirectory(prefix="hollow-agent-fault-", dir=args.workdir) as directory:
            records = [probe(args.agent, Path(directory), case, fault) for case, fault in cases]
    else:
        target = PodmanTarget(args.agent, args.image)
        directory = Path("/tmp/hollow-agent-fault-" + uuid.uuid4().hex)
        try:
            target.exec([b"mkdir", b"-p", os.fsencode(directory)])
            records = [probe(args.agent, directory, case, fault, target) for case, fault in cases]
        finally:
            try:
                target.exec([b"rm", b"-rf", os.fsencode(directory)])
            finally:
                target.close()
    args.output.write_text(json.dumps(records, indent=2) + "\n")
    print(json.dumps(records, indent=2))
    return 0 if all(record["passed"] for record in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
