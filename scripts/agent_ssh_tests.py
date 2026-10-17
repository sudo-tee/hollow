#!/usr/bin/env python3
"""Run an agent test against an isolated, host-key-verified SSH fixture."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time


DEFAULT_IMAGE = "docker.io/library/alpine:3.21"


def config_quote(value):
    return '"' + str(value).replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"') + '"'


class FixtureError(RuntimeError):
    pass


class SSHFixture:
    def __init__(self, agent, image=DEFAULT_IMAGE, podman="podman"):
        self.agent = Path(agent).resolve(strict=True)
        if not self.agent.is_file():
            raise FixtureError(f"not an agent file: {self.agent}")
        basename = image.rsplit("/", 1)[-1]
        if ":" not in basename or not basename.rsplit(":", 1)[-1] or basename.rsplit(":", 1)[-1] == "latest":
            raise FixtureError("SSH fixture image must use a pinned tag")
        self.image = image
        self.podman = podman
        self.name = "hollow-ssh-test-" + secrets.token_hex(8)
        self.owner_token = secrets.token_hex(16)
        self.created = False
        self.directory = None
        self.home = "/home/agent space'quote"

    def _run(self, args, *, timeout=30, check=True, capture_output=True):
        try:
            result = subprocess.run([self.podman, *args], capture_output=capture_output,
                                    timeout=timeout, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise FixtureError(f"Podman command failed: {error}") from error
        if check and result.returncode:
            stderr = result.stderr.decode("utf-8", "replace").strip()
            raise FixtureError(f"podman {' '.join(args[:3])} failed: {stderr}")
        return result

    def _exec(self, command, *, timeout=30, check=True):
        return self._run(["exec", self.name, "/bin/sh", "-c", command],
                         timeout=timeout, check=check)

    def start(self):
        info = self._run(["info", "--format", "{{.Host.Security.Rootless}}"])
        if info.stdout.strip() != b"true":
            raise FixtureError("rootless Podman required")

        self.directory = tempfile.TemporaryDirectory(prefix="hollow ssh '\"-", dir="/tmp/opencode")
        self.path = Path(self.directory.name)
        self.identity = self.path / "client_ed25519"
        self.identity_public = self.path / "client_ed25519.pub"
        self.known_hosts = self.path / "known_hosts"
        self.bad_known_hosts = self.path / "bad_known_hosts"
        self.empty_known_hosts = self.path / "empty_known_hosts"
        self.bad_identity = self.path / "unauthorized_ed25519"
        self.config = self.path / "ssh_config"
        self.authorized_keys = self.path / "authorized_keys"

        try:
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                             str(self.identity)], check=True, capture_output=True, timeout=30)
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                             str(self.bad_identity)], check=True, capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as error:
            raise FixtureError(f"cannot generate client SSH key: {error}") from error
        self.authorized_keys.write_bytes(self.identity_public.read_bytes())
        self.authorized_keys.chmod(0o644)
        self.config.write_text("")
        self.config.chmod(0o600)

        # Container lifecycle is limited to this random name, even on partial setup failure.
        try:
            self._run(["run", "--detach", "--publish", "127.0.0.1::22", "--name", self.name,
                       "--label", "io.hollow.ssh-fixture=" + self.owner_token,
                       "--entrypoint", "/bin/sh", self.image, "-c",
                       "while :; do sleep 3600; done"], timeout=60)
            self.created = True
        except FixtureError:
            # A failed start can leave a created container. Never infer ownership
            # from its name alone (a name collision must not trigger deletion).
            try:
                probe = self._run(["inspect", "--format", '{{ index .Config.Labels "io.hollow.ssh-fixture" }}', self.name], check=False)
                self.created = probe.returncode == 0 and probe.stdout.strip() == self.owner_token.encode()
            except FixtureError:
                pass
            raise
        setup = r"""set -eu
apk add --no-cache openssh
adduser -D -u 1000 -h /home/agent agent
echo 'agent:hollow-test-only' | chpasswd
mkdir -p /home/agent/.ssh
chmod 700 /home/agent/.ssh
ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
cat > /etc/ssh/sshd_config <<'EOF'
Port 22
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers agent
Subsystem sftp internal-sftp
EOF
"""
        self._exec(setup.replace("/home/agent", shlex.quote(self.home)), timeout=180)
        self._run(["cp", str(self.authorized_keys), f"{self.name}:/tmp/authorized_keys"], timeout=30)
        self._exec(("install -o 1000 -g 1000 -m 600 /tmp/authorized_keys /home/agent/.ssh/authorized_keys; "
                    "chown 1000:1000 /home/agent/.ssh; "
                    "(/usr/sbin/sshd -D -e &)").replace("/home/agent", shlex.quote(self.home)), timeout=30)

        port_result = self._run(["port", self.name, "22/tcp"])
        match = re.search(rb"127\.0\.0\.1:(\d+)", port_result.stdout)
        if not match:
            raise FixtureError("Podman did not report a loopback SSH port")
        self.port = int(match.group(1))

        host_key = self._exec("cat /etc/ssh/ssh_host_ed25519_key.pub").stdout.decode().strip()
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?", host_key):
            raise FixtureError("container returned invalid SSH host public key")
        self.known_hosts.write_text(f"[127.0.0.1]:{self.port} {host_key}\n")
        self.known_hosts.chmod(0o600)
        self.bad_known_hosts.write_text(f"[127.0.0.1]:{self.port} {self.identity_public.read_text().strip()}\n")
        self.empty_known_hosts.write_text("")
        self._probe()

    def _probe(self):
        command = ["ssh", "-F", str(self.config), "-T", "-o", "BatchMode=yes",
                   "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={config_quote(self.known_hosts)}",
                   "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ControlMaster=no",
                   "-o", "ControlPath=none", "-p", str(self.port), "-i", str(self.identity),
                   "-l", "agent", "127.0.0.1", "id -un"]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                result = subprocess.run(command, capture_output=True, timeout=5, check=False)
            except (OSError, subprocess.SubprocessError) as error:
                raise FixtureError(f"SSH probe failed: {error}") from error
            if result.returncode == 0:
                if result.stdout.strip() != b"agent":
                    raise FixtureError("SSH probe connected as unexpected user")
                return
            time.sleep(0.05)
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise FixtureError(f"SSH fixture did not become ready: {detail}")

    def environment(self):
        argv = [str(self.agent), "stdio"]
        return dict(HOLLOW_TEST_SSH_DESTINATION="127.0.0.1",
                    HOLLOW_TEST_SSH_PORT=str(self.port), HOLLOW_TEST_SSH_USER="agent",
                    HOLLOW_TEST_SSH_IDENTITY_FILE=str(self.identity),
                     HOLLOW_TEST_SSH_KNOWN_HOSTS=str(self.known_hosts),
                     HOLLOW_TEST_SSH_BAD_KNOWN_HOSTS=str(self.bad_known_hosts),
                     HOLLOW_TEST_SSH_EMPTY_KNOWN_HOSTS=str(self.empty_known_hosts),
                     HOLLOW_TEST_SSH_BAD_IDENTITY=str(self.bad_identity),
                    HOLLOW_TEST_SSH_CONFIG_FILE=str(self.config),
                    HOLLOW_TEST_CONNECTOR_ARGV=json.dumps(argv))

    def close(self):
        try:
            if self.created:
                self._run(["rm", "--force", self.name], timeout=30, check=False)
                self.created = False
        finally:
            if self.directory:
                self.directory.cleanup()
                self.directory = None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--image", default=DEFAULT_IMAGE,
                         help=f"pinned SSH fixture image (default: {DEFAULT_IMAGE})")
    parser.add_argument("--conformance", action="store_true", help="Run shared wire/fs/exec tests after native bootstrap succeeds")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("test command required after --")
    fixture = None
    try:
        fixture = SSHFixture(args.agent, image=args.image)
        fixture.start()
        env = dict(os.environ)
        env.update(fixture.environment())
        result = subprocess.run(command, env=env, check=False).returncode
        if fixture.empty_known_hosts.read_bytes():
            raise FixtureError("strict host-key test unexpectedly modified empty known_hosts")
        if result or not args.conformance:
            return result
        installed = fixture._exec("find " + shlex.quote(fixture.home + "/.cache/hollow/agents") + " -type f -name hollow-agent").stdout.decode().splitlines()
        if len(installed) != 1:
            raise FixtureError("expected one verified deployed agent for conformance")
        conformance = [os.sys.executable, str(Path(__file__).with_name("agent_conformance.py")),
                       "--connector", "ssh", "--destination", "127.0.0.1", "--port", str(fixture.port),
                       "--ssh-user", "agent", "--identity-file", str(fixture.identity),
                       "--known-hosts", str(fixture.known_hosts), "--ssh-config", str(fixture.config),
                       "--agent-path", installed[0]]
        return subprocess.run(conformance, env=env, check=False).returncode
    except FixtureError as error:
        parser.exit(1, f"SSH fixture: {error}\n")
    finally:
        if fixture:
            fixture.close()


if __name__ == "__main__":
    raise SystemExit(main())
