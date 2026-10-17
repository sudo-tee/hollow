#!/usr/bin/env python3
"""Run native/Lua host tests with an owned, verified connector fixture."""
import argparse
import json
import os
import secrets
from pathlib import Path
import subprocess

from agent_connectors import ConnectorError, Podman


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connector", choices=("local-subprocess", "podman", "podman-bootstrap"), required=True)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--image", default="docker.io/library/alpine:3.21")
    parser.add_argument("--container-user", help="Fixture user for podman-bootstrap, e.g. 1000:1000")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.container_user and (args.connector != "podman-bootstrap" or
                                not all(part.isdecimal() for part in args.container_user.split(":")) or
                                len(args.container_user.split(":")) > 2):
        parser.error("--container-user requires podman-bootstrap and numeric UID[:GID]")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("test command required after --")
    fixture = None
    try:
        env = dict(os.environ)
        if args.connector in ("podman", "podman-bootstrap"):
            if args.image.rsplit(":", 1)[-1] == "latest":
                parser.error("use a pinned image tag")
            fixture = Podman(args.agent, image=args.image)
            rootless = fixture._run(["info", "--format", "{{.Host.Security.Rootless}}"])
            if rootless.stdout.strip() != b"true":
                raise ConnectorError("rootless Podman required")
            if args.connector == "podman-bootstrap":
                if args.container_user:
                    # Only this owned test fixture creates a container. Production
                    # Lua connects to the selected running container unchanged.
                    name = "hollow-host-user-" + secrets.token_hex(5)
                    fixture._run(["run", "--detach", "--name", name,
                                  "--user", args.container_user, "--env", "HOME=/tmp",
                                  "--entrypoint", "/bin/sh", args.image,
                                  "-c", "while :; do sleep 3600; done"])
                    fixture.container, fixture.created = name, True
                else:
                    fixture._ensure_container()
                agent = Path(args.agent).resolve(strict=True)
                env.update(HOLLOW_TEST_PODMAN_CONTAINER=fixture.container,
                           HOLLOW_TEST_PODMAN_UID=(args.container_user or "0").split(":", 1)[0])
                # Bootstrap must happen in production Lua, not this fixture.
                argv = [str(agent), "stdio"]
            else:
                agent = fixture.deploy()
                argv = ["podman", "exec", "-i", fixture.container, agent, "stdio"]
        else:
            agent = Path(args.agent).resolve(strict=True)
            if not agent.is_file():
                raise ConnectorError(f"not an agent file: {agent}")
            argv = [str(agent), "stdio"]
        env["HOLLOW_TEST_CONNECTOR_ARGV"] = json.dumps(argv)
        return subprocess.run(command, env=env, check=False).returncode
    finally:
        if fixture:
            fixture.close()


if __name__ == "__main__":
    raise SystemExit(main())
