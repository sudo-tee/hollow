"""Binary-clean subprocess connectors for hollow-agent conformance tests."""
from __future__ import annotations

import hashlib
import ntpath
import os
import posixpath
import re
import secrets
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path


class ConnectorError(RuntimeError):
    pass


@dataclass
class ProcessConnection:
    process: subprocess.Popen
    def close(self):
        # EOF invokes the connection-scoped job cleanup policy. Give TERM/KILL
        # escalation time to finish before resorting to killing the launcher.
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


class LocalSubprocess:
    def __init__(self, agent: str, timeout: float = 10):
        self.agent, self.timeout = agent, timeout

    def connect(self):
        path = Path(self.agent).resolve()
        if not path.is_file():
            raise ConnectorError(f"agent binary not found: {path}")
        try:
            child = subprocess.Popen([str(path), "stdio"], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    bufsize=0, start_new_session=True)
        except OSError as exc:
            raise ConnectorError(f"cannot launch agent {path}: {exc}") from exc
        return ProcessConnection(child)


class Podman:
    """Rootless Podman bootstrap and long-lived `exec -i`; never allocate a TTY."""
    def __init__(self, agent: str, image: str = "docker.io/library/alpine:3.21",
                 container: str | None = None, keep_container: bool = False,
                  timeout: float = 20, agent_path: str | None = None):
        self.agent, self.image, self.container = agent, image, container
        self.keep_container, self.timeout = keep_container, timeout
        self.created = False
        self.agent_path = agent_path

    def _run(self, args, *, capture=True, check=True, timeout=None):
        try:
            result = subprocess.run(["podman", *map(str, args)], check=False,
                                    capture_output=capture, timeout=timeout or self.timeout)
        except FileNotFoundError as exc:
            raise ConnectorError("podman is not installed; Podman connector unavailable") from exc
        except subprocess.TimeoutExpired as exc:
            raise ConnectorError(f"podman command timed out: {args[0]}") from exc
        if check and result.returncode:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise ConnectorError(f"podman {' '.join(map(str,args))} failed: {detail}")
        return result

    def _ensure_container(self):
        if self.container:
            self._run(["container", "exists", self.container])
            return
        self.container = "hollow-agent-" + secrets.token_hex(5)
        self._run(["run", "--detach", "--name", self.container, "--entrypoint", "/bin/sh",
                   self.image, "-c", "while :; do sleep 3600; done"])
        self.created = True

    @staticmethod
    def _arch(arch):
        return {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64",
                "arm64": "aarch64"}.get(arch)

    def deploy(self):
        self._ensure_container()
        if self.agent_path:
            if not self.agent_path.startswith("/") or "\x00" in self.agent_path:
                raise ConnectorError("agent_install_unavailable: preinstalled agent path must be absolute")
            self._run(["exec", self.container, "test", "-x", self.agent_path])
            return self.agent_path
        local = Path(self.agent).resolve()
        if not local.is_file():
            raise ConnectorError(f"agent binary not found: {local}")
        remote_arch = self._run(["exec", self.container, "uname", "-m"]).stdout.decode().strip()
        # Select by artifact architecture, not the architecture of this client.
        # Cross-built agents may legitimately differ from the GUI/test host.
        elf = local.read_bytes()[:20]
        if len(elf) < 20 or elf[:4] != b"\x7fELF" or elf[4:6] != b"\x02\x01":
            raise ConnectorError("agent artifact must be a 64-bit little-endian Linux ELF")
        expected = {62: "x86_64", 183: "aarch64"}.get(int.from_bytes(elf[18:20], "little"))
        actual = self._arch(remote_arch)
        if not expected or actual != expected:
            raise ConnectorError(f"agent architecture mismatch: artifact {expected}, container {remote_arch}")
        digest = hashlib.sha256(local.read_bytes()).hexdigest()
        home_result = self._run(["exec", self.container, "printenv", "HOME"], check=False)
        try:
            home = home_result.stdout.rstrip(b"\n").decode("utf-8", "strict")
        except UnicodeDecodeError as exc:
            raise ConnectorError("agent_install_unavailable: configure preinstalled path for non-UTF-8 HOME") from exc
        if home_result.returncode or not home.startswith("/"):
            raise ConnectorError("agent_install_unavailable: container user has no usable HOME; provide a preinstalled agent path")
        target = f"{home}/.cache/hollow/agents/linux-{actual}/{digest}/hollow-agent"
        qtarget = shlex.quote(target)
        # Prefer already installed verified artifact. No elevated user or permission changes.
        existing = self._run(["exec", self.container, "/bin/sh", "-c",
                              f"test -x {qtarget} && echo {digest}  {qtarget} | sha256sum -c -"], check=False)
        if existing.returncode == 0:
            return target
        parent = target.rsplit("/", 1)[0]
        temp = target + ".tmp-" + secrets.token_hex(8)
        try:
            self._run(["exec", self.container, "mkdir", "-p", parent])
            self._run(["cp", str(local), f"{self.container}:{temp}"])
        except ConnectorError as exc:
            self._run(["exec", self.container, "rm", "-f", temp], check=False)
            raise ConnectorError("agent_install_unavailable: use a writable executable cache or preinstalled agent path") from exc
        # Verify bytes before chmod or execution; install by same-directory atomic rename.
        verify = self._run(["exec", self.container, "/bin/sh", "-c",
                            f"echo {digest}  {shlex.quote(temp)} | sha256sum -c -"] , check=False)
        if verify.returncode:
            self._run(["exec", self.container, "rm", "-f", temp], check=False)
            raise ConnectorError(f"uploaded agent checksum verification failed for {temp}")
        install = self._run(["exec", self.container, "/bin/sh", "-c",
                             f"chmod 700 {shlex.quote(temp)} && mv -f {shlex.quote(temp)} {qtarget}"], check=False)
        if install.returncode:
            self._run(["exec", self.container, "rm", "-f", temp], check=False)
            raise ConnectorError("agent_install_unavailable: container user cannot install executable; provide preinstalled executable path")
        return target

    def connect(self):
        agent = self.deploy()
        proc = subprocess.Popen(["podman", "exec", "-i", self.container, agent, "stdio"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                bufsize=0, start_new_session=True)
        return ProcessConnection(proc)

    def close(self):
        if self.created and not self.keep_container and self.container:
            self._run(["rm", "--force", self.container], check=False)


class WSL:
    """Connect to an already-installed Linux agent through the native WSL launcher."""
    def __init__(self, agent_path: str, distro: str, user: str | None = None,
                 executable: str = "wsl.exe"):
        if not isinstance(agent_path, str) or not agent_path.startswith("/") or "\x00" in agent_path:
            raise ConnectorError("WSL agent path must be an absolute Linux path without NUL")
        if not isinstance(distro, str) or not distro or distro.startswith("-") or "\x00" in distro:
            raise ConnectorError("WSL distro must be nonempty and must not start with '-' or contain NUL")
        if user is not None and (not isinstance(user, str) or not user or user.startswith("-") or "\x00" in user):
            raise ConnectorError("WSL user must be nonempty and must not start with '-' or contain NUL")
        if not isinstance(executable, str) or not executable or "\x00" in executable:
            raise ConnectorError("WSL executable must be a nonempty native executable name")
        self.agent_path, self.distro, self.user, self.executable = agent_path, distro, user, executable

    def connect(self):
        args = [self.executable, "--distribution", self.distro]
        if self.user is not None:
            args.extend(["--user", self.user])
        args.extend(["--cd", "/", "--exec", self.agent_path, "stdio"])
        try:
            proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        except OSError as exc:
            raise ConnectorError(f"cannot launch WSL agent via {self.executable}: {exc}") from exc
        return ProcessConnection(proc)

    def close(self):
        # WSL distro lifecycle belongs to the user, not this test harness.
        pass


class SSH:
    """Connect to a preinstalled Linux agent over a non-PTY SSH session."""
    _DESTINATION = re.compile(r"[A-Za-z0-9_.:%\-\[\]]+\Z", re.ASCII)
    _USER = re.compile(r"[A-Za-z0-9_.-]+\Z", re.ASCII)

    def __init__(self, agent_path: str, destination: str, port: int | None = None,
                 user: str | None = None, identity_file: str | None = None,
                 known_hosts: str | None = None, config_file: str | None = None,
                 executable: str = "ssh"):
        if not isinstance(agent_path, str) or not agent_path.startswith("/") or "\x00" in agent_path:
            raise ConnectorError("SSH agent path must be an absolute Linux path without NUL")
        if (not isinstance(destination, str) or not destination or destination.startswith("-")
                or not self._DESTINATION.fullmatch(destination)):
            raise ConnectorError("SSH destination must be a conservative alias, DNS name, or IPv6 address")
        if user is not None and (not isinstance(user, str) or user.startswith("-") or not self._USER.fullmatch(user)):
            raise ConnectorError("SSH user must contain only ASCII letters, digits, '_', '.', or '-' and not start with '-'")
        if port is not None and (isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535):
            raise ConnectorError("SSH port must be an integer from 1 to 65535")
        for label, value in (("identity file", identity_file), ("known-hosts file", known_hosts),
                             ("SSH config file", config_file)):
            if value is not None and (not isinstance(value, str) or "\x00" in value
                    or any(ord(char) < 32 or ord(char) == 127 for char in value)
                    or not (posixpath.isabs(value) or ntpath.isabs(value))):
                raise ConnectorError(f"SSH {label} must be an absolute POSIX or Windows path without controls")
        self.agent_path, self.destination, self.port = agent_path, destination, port
        self.user, self.identity_file, self.known_hosts = user, identity_file, known_hosts
        self.config_file, self.executable = config_file, executable

    @staticmethod
    def _config_path(path):
        # OpenSSH config options use its double-quoted parsing and % token expansion.
        return '"' + path.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"') + '"'

    def connect(self):
        args = [self.executable, "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                "-oControlMaster=no", "-oControlPath=none", "-oControlPersist=no",
                "-oRemoteCommand=none", "-oRequestTTY=no", "-oPermitLocalCommand=no",
                "-oClearAllForwardings=yes", "-oForwardAgent=no", "-oForwardX11=no", "-oEscapeChar=none"]
        if self.config_file is not None:
            args.extend(["-F", self.config_file])
        if self.identity_file is not None:
            args.extend(["-i", self.identity_file, "-oIdentitiesOnly=yes"])
        if self.known_hosts is not None:
            args.append("-oUserKnownHostsFile=" + self._config_path(self.known_hosts))
        if self.port is not None:
            args.extend(["-p", str(self.port)])
        if self.user is not None:
            args.extend(["-l", self.user])
        args.extend([self.destination, "exec " + shlex.quote(self.agent_path) + " " + shlex.quote("stdio")])
        try:
            proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        except OSError as exc:
            raise ConnectorError(f"cannot launch SSH agent via {self.executable}: {exc}") from exc
        return ProcessConnection(proc)

    def close(self):
        # Remote host/session lifecycle belongs to the user, not this connector.
        pass
