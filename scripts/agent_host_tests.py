#!/usr/bin/env python3
"""Run native/Lua host tests with an owned, verified connector fixture."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from agent_connectors import ConnectorError, Podman


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connector", choices=("local-subprocess", "podman"), required=True)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--image", default="docker.io/library/alpine:3.21")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("test command required after --")
    fixture = None
    try:
        if args.connector == "podman":
            if args.image.rsplit(":", 1)[-1] == "latest":
                parser.error("use a pinned image tag")
            fixture = Podman(args.agent, image=args.image)
            rootless = fixture._run(["info", "--format", "{{.Host.Security.Rootless}}"])
            if rootless.stdout.strip() != b"true":
                raise ConnectorError("rootless Podman required")
            agent = fixture.deploy()
            argv = ["podman", "exec", "-i", fixture.container, agent, "stdio"]
        else:
            agent = Path(args.agent).resolve(strict=True)
            if not agent.is_file():
                raise ConnectorError(f"not an agent file: {agent}")
            argv = [str(agent), "stdio"]
        env = dict(os.environ, HOLLOW_TEST_CONNECTOR_ARGV=json.dumps(argv))
        return subprocess.run(command, env=env, check=False).returncode
    finally:
        if fixture:
            fixture.close()


if __name__ == "__main__":
    raise SystemExit(main())
