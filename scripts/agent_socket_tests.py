#!/usr/bin/env python3
"""Run unchanged native/Lua host tests and link-fault probes over a mock socket.

This is AF_UNIX plus bounded stdio relays, not real vsock/hvsock qualification.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import time

from agent_conformance import AgentClient, RESPONSE, b64
from agent_connectors import ConnectorError
from agent_mock_socket import BUFFER_LIMIT, MockSocket


def link_fault_probe(connector):
    marker = Path(connector.directory.name) / "no-replay"
    client = AgentClient(connector.connect(), timeout=8)
    nonce = client.start()["connection_nonce"]
    streams = client.allocate_streams()
    # The marker is fixture-owned. No PID scans, distro changes or global kills.
    fields = {"argv_b64": list(map(b64, [b"/bin/sh", b"-c", b'printf x >> "$1"; exec sleep 30', b"probe", os.fsencode(marker)])),
              "stdout_stream_id": streams[0], "stderr_stream_id": streams[1], "timeout_ms": 30000}
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        request = pool.submit(client.request, "EXEC", fields, stream_ids=streams)
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not marker.exists():
                raise ConnectorError("mock socket EXEC did not start")
            connector.disconnect_all()
            try:
                request.result(timeout=8)
            except (EOFError, BrokenPipeError, ConnectionResetError):
                pass
            else:
                raise ConnectorError("link loss did not fail the in-flight EXEC")
        finally:
            client.close()
    fresh = AgentClient(connector.connect())
    try:
        if fresh.start()["connection_nonce"] == nonce:
            raise ConnectorError("reconnected socket reused connection nonce")
        kind, result, output = fresh.request("FS_READ", {"path_b64": b64(os.fsencode(marker)), "limit": 8})
        if kind != RESPONSE or result.get("eof") is not True or output[0] != b"x":
            raise ConnectorError("lost EXEC was replayed or marker read failed")
    finally:
        fresh.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--fragment", type=int, default=BUFFER_LIMIT)
    parser.add_argument("--conformance", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("native test command required after --")
    connector = MockSocket(args.agent, fragment=args.fragment)
    try:
        argv = connector.argv()
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(("HOLLOW_TEST_PODMAN_", "HOLLOW_TEST_WSL_", "HOLLOW_TEST_SSH_", "HOLLOW_TEST_DOCKER_")):
                del env[key]
        env["HOLLOW_TEST_CONNECTOR_ARGV"] = json.dumps(argv)
        result = subprocess.run(command, env=env, check=False).returncode
        if result:
            return result
        link_fault_probe(connector)
        if args.conformance:
            command = [os.sys.executable, str(Path(__file__).with_name("agent_conformance.py")),
                       "--connector", "mock-socket", "--agent", str(connector.agent),
                       "--socket-fragment", str(args.fragment)]
            result = subprocess.run(command, env=env, check=False).returncode
        return result
    finally:
        connector.close()
        if connector.errors:
            raise ConnectorError("mock socket fixture errors: " + "; ".join(connector.errors))


if __name__ == "__main__":
    raise SystemExit(main())
