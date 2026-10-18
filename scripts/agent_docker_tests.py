#!/usr/bin/env python3
"""Run production Docker bootstrap against a uniquely owned disposable container.

--docker podman exercises CLI compatibility only, not Docker qualification.
Only production Lua deploys the agent; this fixture never implements deployment.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys

from agent_connectors import ConnectorError, Docker


class DockerFixture:
    def __init__(self, executable="docker", context=None, image="docker.io/library/alpine:3.21", user="1000:1000"):
        # Reuse effect-free connector validation, without opening any connection.
        self.prefix = Docker("/unused", "unused", executable, context).prefix
        basename = image.rsplit("/", 1)[-1]
        if ":" not in basename or basename.rsplit(":", 1)[-1] in ("", "latest"):
            raise ConnectorError("fixture image requires a pinned tag")
        if not re.fullmatch(r"[0-9]+(?::[0-9]+)?", user):
            raise ConnectorError("fixture user must be numeric UID[:GID]")
        self.executable, self.context, self.image, self.user = executable, context, image, user
        self.name, self.token = "hollow-docker-test-" + secrets.token_hex(8), secrets.token_hex(16)
        self.container = None

    def run(self, args, check=True, timeout=30):
        try:
            result = subprocess.run([*self.prefix, *args], capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ConnectorError(f"container fixture command unavailable: {exc}") from exc
        if check and result.returncode:
            raise ConnectorError(result.stderr.decode("utf-8", "replace")[:16384])
        return result

    def start(self):
        try:
            result = self.run(["create", "--name", self.name, "--label", "io.hollow.docker-fixture=" + self.token,
                               "--user", self.user, "--env", "HOME=/tmp", "--entrypoint", "/bin/sh", self.image,
                               "-c", "while :; do sleep 3600; done"], timeout=120)
            identifier = result.stdout.strip().decode("ascii")
            if not re.fullmatch(r"[a-fA-F0-9]{64}", identifier):
                raise ConnectorError("fixture create returned invalid container ID")
            self.container = identifier.lower()
        except (ConnectorError, UnicodeDecodeError):
            # Creation may succeed despite a lost/invalid command response.
            # Check a random ownership label before touching the named object.
            try:
                probe = self.run(["container", "inspect", "--format", '{{.Id}} {{index .Config.Labels "io.hollow.docker-fixture"}}', self.name], check=False)
                match = re.fullmatch(rb"([a-fA-F0-9]{64}) " + self.token.encode() + rb"\s*", probe.stdout)
                if probe.returncode == 0 and match:
                    self.container = match[1].decode("ascii").lower()
            except ConnectorError:
                pass
            raise ConnectorError("fixture creation failed; checked owned-container cleanup")
        self.run(["start", self.container])

    def close(self):
        if self.container:
            self.run(["rm", "--force", self.container], check=False)
            self.container = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--context")
    parser.add_argument("--image", default="docker.io/library/alpine:3.21")
    parser.add_argument("--container-user", default="1000:1000")
    parser.add_argument("--conformance", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("native test command required after --")
    agent = Path(args.agent).resolve(strict=True)
    if not agent.is_file():
        parser.error("--agent must be a regular file")
    fixture = DockerFixture(args.docker, args.context, args.image, args.container_user)
    try:
        fixture.start()
        env = dict(os.environ)
        # Keep this run limited to the fixture explicitly requested, even if
        # caller inherited environment from another connector test wrapper.
        for key in list(env):
            if key.startswith(("HOLLOW_TEST_PODMAN_", "HOLLOW_TEST_WSL_", "HOLLOW_TEST_SSH_", "HOLLOW_TEST_DOCKER_")):
                del env[key]
        env.update(HOLLOW_TEST_DOCKER_CONTAINER=fixture.container, HOLLOW_TEST_DOCKER_EXE=args.docker,
                   HOLLOW_TEST_DOCKER_UID=args.container_user.split(":", 1)[0],
                   HOLLOW_TEST_CONNECTOR_ARGV=json.dumps([str(agent), "stdio"]))
        if args.context is not None:
            env["HOLLOW_TEST_DOCKER_CONTEXT"] = args.context
        result = subprocess.run(command, env=env, check=False).returncode
        if result or not args.conformance:
            return result
        found = fixture.run(["exec", fixture.container, "find", "/tmp/.cache/hollow/agents", "-type", "f", "-name", "hollow-agent"]).stdout.decode().splitlines()
        if len(found) != 1:
            raise ConnectorError("expected one production-deployed agent for conformance")
        argv = [sys.executable, str(Path(__file__).with_name("agent_conformance.py")), "--connector", "docker",
                "--docker", args.docker, "--container", fixture.container, "--agent-path", found[0]]
        if args.context is not None:
            argv += ["--context", args.context]
        return subprocess.run(argv, env=env, check=False).returncode
    finally:
        fixture.close()


if __name__ == "__main__":
    raise SystemExit(main())
