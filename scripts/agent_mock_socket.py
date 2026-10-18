#!/usr/bin/env python3
"""Test-only private AF_UNIX stream connector; not production vsock/hvsock.

The agent still uses stdio. Relays know no frames, RPCs, paths or terminal state.
No public listening port, privileged socket family or persistent service is used.
"""
import argparse
import errno
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import tempfile
import threading

from agent_connectors import ConnectorError, ProcessConnection

BUFFER_LIMIT = 65536
MAX_CONNECTIONS = 8


def relay(left_read, left_write, right_read, right_write, left_eof, right_eof, stop=None, fragment=BUFFER_LIMIT):
    """Two bounded queues, nonblocking short reads/writes, ordered half-closes.

    EOF from left is delivered to right only after all preceding bytes drain.
    Callbacks close/shutdown the destination's write side, never the read side.
    """
    if not 1 <= fragment <= BUFFER_LIMIT:
        raise ValueError("fragment must be 1..65536")
    directions = [dict(src=left_read, dst=right_write, eof=left_eof, data=bytearray(), ended=False, closed=False),
                  dict(src=right_read, dst=left_write, eof=right_eof, data=bytearray(), ended=False, closed=False)]
    for fd in {left_read, left_write, right_read, right_write}:
        os.set_blocking(fd, False)
    high_water = 0
    with selectors.DefaultSelector() as poll:
        while not stop or not stop.is_set():
            events = {}
            for direction in directions:
                if direction["ended"] and not direction["data"] and not direction["closed"]:
                    direction["eof"]()
                    direction["closed"] = True
                if not direction["ended"] and len(direction["data"]) < BUFFER_LIMIT:
                    fd = direction["src"]
                    events[fd] = events.get(fd, 0) | selectors.EVENT_READ
                if direction["data"]:
                    fd = direction["dst"]
                    events[fd] = events.get(fd, 0) | selectors.EVENT_WRITE
            if all(d["closed"] for d in directions):
                break
            for key in list(poll.get_map().values()):
                if key.fd not in events:
                    poll.unregister(key.fd)
            for fd, mask in events.items():
                if fd in poll.get_map():
                    poll.modify(fd, mask)
                else:
                    poll.register(fd, mask)
            for key, mask in poll.select(0.1):
                for direction in directions:
                    if key.fd == direction["src"] and mask & selectors.EVENT_READ and not direction["ended"]:
                        remaining = BUFFER_LIMIT - len(direction["data"])
                        if not remaining:
                            continue
                        try:
                            data = os.read(key.fd, min(fragment, remaining))
                        except BlockingIOError:
                            continue
                        if data:
                            direction["data"].extend(data)
                            high_water = max(high_water, len(direction["data"]))
                        else:
                            direction["ended"] = True
                    if key.fd == direction["dst"] and mask & selectors.EVENT_WRITE and direction["data"]:
                        try:
                            size = os.write(key.fd, direction["data"][:fragment])
                        except BlockingIOError:
                            continue
                        if size == 0:
                            raise BrokenPipeError("zero-byte socket relay write")
                        del direction["data"][:size]
    return high_water


def shutdown_write(stream):
    try:
        stream.shutdown(socket.SHUT_WR)
    except OSError as exc:
        if exc.errno not in (errno.ENOTCONN, errno.EBADF):
            raise


def bridge(path, fragment=BUFFER_LIMIT):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(5)
        stream.connect(path)
        relay(0, 1, stream.fileno(), stream.fileno(), lambda: shutdown_write(stream),
              lambda: os.close(1), fragment=fragment)


class MockSocket:
    """Owned fixture and connector argv for unchanged native subprocess transport."""
    def __init__(self, agent, *, fragment=BUFFER_LIMIT):
        self.agent = Path(agent).resolve(strict=True)
        if not self.agent.is_file() or not 1 <= fragment <= BUFFER_LIMIT:
            raise ConnectorError("invalid mock socket agent or fragment size")
        self.fragment = fragment
        self.directory = self.listener = self.thread = None
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.clients = set()
        self.workers = set()
        self.errors = []
        self.high_water = self.accepted = 0

    def start(self):
        if self.stop.is_set():
            raise ConnectorError("mock socket fixture is closed")
        if self.listener is not None:
            return
        # AF_UNIX pathname limits require a short private directory name.
        base = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
        self.directory = tempfile.TemporaryDirectory(prefix="hollow-sock-", dir=base)
        self.path = str(Path(self.directory.name) / "agent.sock")
        try:
            self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener.bind(self.path)
            os.chmod(self.path, 0o600)
            self.listener.listen(MAX_CONNECTIONS)
            self.listener.settimeout(0.1)
            self.thread = threading.Thread(target=self._accept, daemon=True)
            self.thread.start()
        except BaseException:
            self.close()
            raise

    def _accept(self):
        while not self.stop.is_set():
            try:
                stream, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError as exc:
                if not self.stop.is_set():
                    self._error(exc)
                break
            with self.lock:
                if self.stop.is_set() or len(self.clients) >= MAX_CONNECTIONS:
                    stream.close()
                    continue
                self.clients.add(stream)
                self.accepted += 1
                worker = threading.Thread(target=self._serve, args=(stream,), daemon=True)
                self.workers.add(worker)
                worker.start()

    def _error(self, exc):
        with self.lock:
            if len(self.errors) < MAX_CONNECTIONS:
                self.errors.append(str(exc)[:1024])

    def _serve(self, stream):
        child = None
        try:
            child = subprocess.Popen([str(self.agent), "stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, bufsize=0, start_new_session=True)
            high = relay(stream.fileno(), stream.fileno(), child.stdout.fileno(), child.stdin.fileno(),
                         child.stdin.close, lambda: shutdown_write(stream), self.stop, self.fragment)
            with self.lock:
                self.high_water = max(self.high_water, high)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when a fault probe or consumer deliberately drops a link.
        except BaseException as exc:
            if not self.stop.is_set():
                self._error(exc)
        finally:
            stream.close()
            if child:
                try:
                    ProcessConnection(child).close()
                except BaseException as exc:
                    self._error(exc)
            with self.lock:
                self.clients.discard(stream)
                self.workers.discard(threading.current_thread())

    def argv(self):
        self.start()
        return [sys.executable, str(Path(__file__).resolve()), "bridge", "--socket", self.path, "--fragment", str(self.fragment)]

    def connect(self):
        child = subprocess.Popen(self.argv(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        return ProcessConnection(child)

    def disconnect_all(self):
        with self.lock:
            for stream in self.clients:
                try:
                    stream.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def close(self):
        self.stop.set()
        self.disconnect_all()
        if self.listener:
            self.listener.close()
        if self.thread:
            self.thread.join(timeout=2)
        with self.lock:
            workers = list(self.workers)
        for worker in workers:
            worker.join(timeout=8)
        if any(worker.is_alive() for worker in workers):
            raise ConnectorError("mock socket worker did not stop")
        if self.directory:
            self.directory.cleanup()
        self.listener = None
        if self.errors:
            raise ConnectorError("mock socket fixture errors: " + "; ".join(self.errors))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("bridge",))
    parser.add_argument("--socket", required=True)
    parser.add_argument("--fragment", type=int, default=BUFFER_LIMIT)
    args = parser.parse_args()
    try:
        bridge(args.socket, args.fragment)
    except (OSError, ValueError) as exc:
        print(f"mock socket bridge: {str(exc)[:1024]}", file=sys.stderr)
        raise SystemExit(1)
