#!/usr/bin/env python3
"""Headless PTY/mux client and local transport-only A/B benchmark.

Not a production pane API. All I/O has deadlines; output credits are returned
only when frames are consumed. Requires Python 3 on both client and guest.
"""
import argparse
import json
import os
import platform
import resource
import select
import statistics
import struct
import subprocess
import time

HEADER = struct.Struct("<BII")
HELLO, SPAWN, INPUT, OUTPUT, RESIZE, EXIT, ERROR, CLOSE = range(1, 9)
NEGOTIATE, SPAWNED, CREDIT, FOCUS = range(9, 13)
WINDOW = 65536
MAX_DATA = 16384


class Client:
    def __init__(self, command, mode="mux", credit_batch=WINDOW // 2, env=None):
        self.mode = mode
        self.process = subprocess.Popen(
            [*command, mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        self.buffer = bytearray()
        self.input_credit = {}
        self.stopped = set()
        self.pending_credit = {}
        self.credit_batch = credit_batch
        self.diagnostics = None
        self.output_frames = 0
        self.output_bytes = 0
        os.set_blocking(self.process.stdin.fileno(), False)
        os.set_blocking(self.process.stdout.fileno(), False)
        try:
            kind, sid, body = self.recv()
            assert kind == HELLO
            hello = json.loads(body)
            if mode == "mux":
                assert sid == 0 and hello["protocol"] == "hollow-mux"
                assert hello["version"] == 1 and hello["window"] == WINDOW
                self.send(NEGOTIATE, 0, b'{"protocol":"hollow-mux","version":1}')
            else:
                assert hello["version"] == 1
        except BaseException:
            self.close()
            raise

    def send(self, kind, sid, body=b"", timeout=5):
        data = memoryview(HEADER.pack(kind, sid, len(body)) + body)
        deadline = time.monotonic() + timeout
        while data:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("agent input stalled")
            try:
                count = os.write(self.process.stdin.fileno(), data)
            except BlockingIOError:
                if not select.select([], [self.process.stdin], [], left)[1]:
                    raise TimeoutError("agent input stalled")
                continue
            data = data[count:]

    def buffered(self):
        if len(self.buffer) < HEADER.size:
            return False
        _, _, size = HEADER.unpack_from(self.buffer)
        if size > 1024 * 1024:
            raise ValueError("oversized frame")
        return len(self.buffer) >= HEADER.size + size

    def recv(self, timeout=5):
        deadline = time.monotonic() + timeout
        while not self.buffered():
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.process.stdout], [], [], left)[0]:
                raise TimeoutError("agent output stalled")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("agent disconnected")
            self.buffer.extend(chunk)
        kind, sid, size = HEADER.unpack_from(self.buffer)
        body = bytes(self.buffer[HEADER.size:HEADER.size + size])
        del self.buffer[:HEADER.size + size]
        if kind == OUTPUT:
            self.output_frames += 1
            self.output_bytes += size
        if self.mode == "mux":
            if kind in (SPAWNED, CREDIT):
                self.input_credit[sid] = self.input_credit.get(sid, 0) + struct.unpack("<I", body)[0]
                assert self.input_credit[sid] <= WINDOW
            elif kind == OUTPUT and sid not in self.stopped:
                consumed = self.pending_credit.get(sid, 0) + size
                if consumed >= self.credit_batch:
                    self.send(CREDIT, sid, struct.pack("<I", consumed))
                    consumed = 0
                self.pending_credit[sid] = consumed
            elif kind == EXIT:
                self.pending_credit.pop(sid, None)
        return kind, sid, body

    def spawn(self, sid, argv, **kwargs):
        options = dict(argv=argv, shell_integration=False)
        options.update(kwargs)
        self.send(SPAWN, sid, json.dumps(options).encode())

    def input(self, sid, body):
        if self.mode == "mux":
            if len(body) > min(MAX_DATA, self.input_credit.get(sid, 0)):
                raise ValueError("input exceeds available stream credit")
            self.input_credit[sid] -= len(body)
        self.send(INPUT, sid, body)

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        # Drain stdout so dedicated pty can finish its final write.
        deadline = time.monotonic() + 3
        while self.process.poll() is None and time.monotonic() < deadline:
            if select.select([self.process.stdout], [], [], .02)[0]:
                os.read(self.process.stdout.fileno(), 65536)
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        self.process.stdout.close()
        if not self.process.stderr.closed:
            for line in self.process.stderr.read().splitlines():
                if line.startswith(b"mux diagnostics: {"):
                    self.diagnostics = json.loads(line.removeprefix(b"mux diagnostics: "))
            self.process.stderr.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def pump(clients, timeout=5):
    """Yield one ready frame, fairly rotating callers via the OS readiness set."""
    for index, client in enumerate(clients):
        if client.buffered():
            clients.append(clients.pop(index))
            return client, client.recv(timeout)
    ready = select.select([c.process.stdout for c in clients], [], [], timeout)[0]
    if not ready:
        raise TimeoutError("no client made progress")
    client = next(c for c in clients if c.process.stdout in ready)
    clients.append(clients.pop(clients.index(client)))
    return client, client.recv(timeout)


def agent_cpu(process):
    """Agent's own user+system seconds (all threads, not reaped children)."""
    try:
        with open(f"/proc/{process.pid}/stat") as stat:
            fields = stat.read().rsplit(")", 1)[1].split()
    except OSError:
        return 0.0
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * p))]


def benchmark(command, mode, panes, size, samples, credit_batch=WINDOW // 2):
    clients = []
    started = time.perf_counter()
    client_cpu = time.process_time()
    child_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    try:
        clients = [Client(command, mode, credit_batch)]
        if mode == "pty":
            for _ in range(panes - 1):
                clients.append(Client(command, mode, credit_batch))
        streams = [(clients[0] if mode == "mux" else clients[i], i + 1 if mode == "mux" else 1) for i in range(panes)]
        owners = tuple(clients)
        code = (
            "import os,tty; tty.setraw(0); os.write(1,b'READY'); "
            f"exec('for _ in range({samples}):\\n b=os.read(0,1); os.write(1,b)'); "
            "os.read(0,1); "
            f"exec('left={size}\\nwhile left:\\n n=os.write(1,b\"x\"*min(left,65536)); left-=n')"
        )
        # Independent children, identical workload and PTY dimensions in both modes.
        sent_at = {}
        for client, sid in streams:
            sent_at[client, sid] = time.perf_counter()
            client.spawn(sid, ["python3", "-c", code], cols=80, rows=24)
        pending = {key: bytearray() for key in sent_at}
        spawn_ms = []
        while pending:
            client, (kind, sid, body) = pump(clients)
            if kind == ERROR:
                raise RuntimeError(body.decode())
            if kind == OUTPUT:
                key = (client, sid)
                pending[key].extend(body)
                if pending[key] == b"READY":
                    spawn_ms.append((time.perf_counter() - sent_at[key]) * 1000)
                    del pending[key]
        startup_ms = (time.perf_counter() - started) * 1000
        # Sample actual input-to-echo latency, not enqueue time. No output floods
        # in this initial diagnostic workload; mixed-load qualification is separate.
        echo_ms = []
        for _ in range(samples):
            for client, sid in streams:
                before = time.perf_counter()
                client.input(sid, b"q")
                while True:
                    owner, (kind, stream, body) = pump(clients)
                    if kind == ERROR:
                        raise RuntimeError(body.decode())
                    if kind == OUTPUT:
                        assert (owner, stream, body) == (client, sid, b"q")
                        echo_ms.append((time.perf_counter() - before) * 1000)
                        break
        # Snapshot live agent RSS/threads, not shell or connector tree totals.
        rss_kib = threads = 0
        for client in clients:
            with open(f"/proc/{client.process.pid}/status") as status:
                values = dict(line.split(":", 1) for line in status if ":" in line)
            rss_kib += int(values["VmRSS"].split()[0])
            threads += int(values["Threads"])
        before = time.perf_counter()
        for client, sid in streams:
            client.input(sid, b"g")
        remaining = set(streams)
        received = 0
        own_cpu = 0.0
        while remaining:
            client, (kind, sid, body) = pump(clients)
            if kind == OUTPUT:
                assert body == b"x" * len(body)
                received += len(body)
            elif kind == EXIT:
                assert struct.unpack("<I", body)[0] == 0
                remaining.remove((client, sid))
                if mode == "pty":
                    own_cpu += agent_cpu(client.process)
                    clients.remove(client)
                    client.close()
            elif kind == ERROR:
                raise RuntimeError(body.decode())
        seconds = time.perf_counter() - before
        if mode == "mux":
            own_cpu = agent_cpu(clients[0].process)
        assert received == panes * size, (received, panes * size)
        result = dict(
            mode=mode, panes=panes, bytes=received, seconds=seconds,
            mux_read_workers=int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0")) if mode == "mux" else 0,
            mux_read_batch_jobs=int(os.environ.get("HOLLOW_MUX_READ_BATCH_JOBS", "1")) if mode == "mux" else 0,
            mib_per_second=received / seconds / 2**20,
            cold_startup_ms=startup_ms,
            spawn_ms=dict(p50=statistics.median(spawn_ms), p95=percentile(spawn_ms, .95)),
            echo_ms=dict(p50=statistics.median(echo_ms), p95=percentile(echo_ms, .95), p99=percentile(echo_ms, .99)),
            live_agent_rss_kib=rss_kib, agent_processes=1 if mode == "mux" else panes,
            live_agent_threads=threads,
            # Agent processes only, through bulk completion (includes startup/echo).
            agent_cpu_seconds=own_cpu,
            output_frames=sum(c.output_frames for c in owners),
            mean_output_frame_bytes=sum(c.output_bytes for c in owners) / sum(c.output_frames for c in owners),
        )
    finally:
        for client in clients:
            client.close()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    result["agent_tree_cpu_seconds"] = usage.ru_utime + usage.ru_stime - child_cpu.ru_utime - child_cpu.ru_stime
    result["client_cpu_seconds"] = time.process_time() - client_cpu
    if any(client.diagnostics for client in clients):
        result["mux_diagnostics"] = [client.diagnostics for client in clients]
    return result


def mixed_benchmark(command, mode, panes, samples, credit_batch=WINDOW // 2):
    """One focused echo stream against sustained, independently counted floods.

    Drain throughout warmup and between keystrokes. Measure receipt of each
    actual echo, including transport backlog, rather than send/enqueue latency.
    """
    clients = []
    client_cpu = time.process_time()
    child_cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
    try:
        clients.append(Client(command, mode, credit_batch))
        if mode == "pty":
            for _ in range(panes - 1):
                clients.append(Client(command, mode, credit_batch))
        streams = [(clients[0] if mode == "mux" else clients[i], i + 1 if mode == "mux" else 1) for i in range(panes)]
        focused = streams[-1]
        floods = streams[:-1]
        for client, sid in streams:
            action = (
                "exec('while True:\\n b=os.read(0,1); os.write(1,b)')"
                if (client, sid) == focused else
                "os.read(0,1); data=b'x'*65536; exec('while True:\\n os.write(1,data)')"
            )
            client.spawn(sid, ["python3", "-c", "import os,tty; tty.setraw(0); os.write(1,b'READY'); " + action], cols=80, rows=24)
        pending = {key: bytearray() for key in streams}
        while pending:
            client, (kind, sid, body) = pump(clients)
            if kind == ERROR:
                raise RuntimeError(body.decode())
            if kind == OUTPUT:
                pending[client, sid].extend(body)
                if pending[client, sid] == b"READY":
                    del pending[client, sid]
        if mode == "mux":
            focused[0].send(FOCUS, focused[1])
        for client, sid in floods:
            client.input(sid, b"g")
        counts = {key: 0 for key in floods}
        echoes = []
        started = time.perf_counter()
        next_send = started + .05  # Drain/warm up sustained floods first.
        sent = None
        deadline = started + max(10, samples * .1)
        while len(echoes) < samples:
            now = time.perf_counter()
            if now >= deadline:
                raise TimeoutError("mixed-load echo deadline exceeded")
            if sent is None and now >= next_send:
                sent = time.perf_counter()
                focused[0].input(focused[1], b"q")
            # Idle interval also serves the transport. Without floods there is
            # nothing to pump until the next keystroke is due.
            if not floods and sent is None:
                time.sleep(max(0, next_send - now))
                continue
            client, (kind, sid, body) = pump(clients, min(5, deadline - now))
            key = client, sid
            if kind == ERROR:
                raise RuntimeError(body.decode())
            if kind == EXIT:
                raise RuntimeError("workload exited before measurement finished")
            if kind == OUTPUT:
                if key == focused:
                    assert sent is not None and body == b"q", body
                    received = time.perf_counter()
                    echoes.append((received - sent) * 1000)
                    sent = None
                    next_send = received + .005
                else:
                    assert body == b"x" * len(body)
                    counts[key] += len(body)
        elapsed = time.perf_counter() - started
        assert all(count > 0 for count in counts.values()), counts
        result = dict(
            mode=mode, workload="focused echo under sustained floods", panes=panes,
            mux_read_workers=int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0")) if mode == "mux" else 0,
            mux_read_batch_jobs=int(os.environ.get("HOLLOW_MUX_READ_BATCH_JOBS", "1")) if mode == "mux" else 0,
            samples=len(echoes), seconds=elapsed,
            echo_ms=dict(p50=statistics.median(echoes), p95=percentile(echoes, .95), p99=percentile(echoes, .99), max=max(echoes)),
            flood_bytes=list(counts.values()),
            flood_mib_per_second=sum(counts.values()) / elapsed / 2**20,
        )
    finally:
        # Abort infinite producers via transport EOF. Teardown time is excluded
        # from the echo/flood interval (but included in CPU accounting).
        for client in clients:
            client.close()
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    result["agent_tree_cpu_seconds"] = usage.ru_utime + usage.ru_stime - child_cpu.ru_utime - child_cpu.ru_stime
    result["client_cpu_seconds"] = time.process_time() - client_cpu
    if any(client.diagnostics for client in clients):
        result["mux_diagnostics"] = [client.diagnostics for client in clients]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", default="zig-out/bin/hollow-agent")
    parser.add_argument("--mode", choices=["pty", "mux", "both"], default="both")
    parser.add_argument("--panes", type=int, nargs="+", default=[1, 4, 16, 32])
    parser.add_argument("--bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--samples", type=int, default=25)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--workload", choices=["bulk", "mixed"], default="bulk",
                        help="mixed measures focused echo while other panes continuously flood")
    parser.add_argument("--build-mode", default="unknown", help="record the agent's build mode in result metadata")
    parser.add_argument("--credit-batch", type=int, default=WINDOW // 2,
                        help="return mux output credit after this many consumed bytes (1 restores per-frame updates)")
    args = parser.parse_args()
    if not all(1 <= n <= 32 for n in args.panes) or min(args.bytes, args.samples, args.runs) < 1:
        parser.error("panes must be 1..32; bytes/samples/runs must be positive")
    if not 1 <= args.credit_batch <= WINDOW // 2:
        parser.error("credit-batch must be 1..32768 to retain at least half-window headroom")
    print(json.dumps(dict(metadata=dict(
        platform=platform.platform(), command=[args.agent], terminal=[80, 24],
        scope="local Linux transport only; no GUI parsing/rendering or network",
        build_mode=args.build_mode, state="cold agent per run; OS caches uncontrolled",
        workload="idle sequential echo, then concurrent bulk output" if args.workload == "bulk" else "focused echo under sustained floods",
        credit_batch=args.credit_batch,
        mux_read_workers=int(os.environ.get("HOLLOW_MUX_READ_WORKERS", "0")),
        mux_read_batch_jobs=int(os.environ.get("HOLLOW_MUX_READ_BATCH_JOBS", "1")),
    ))), flush=True)
    modes = ["pty", "mux"] if args.mode == "both" else [args.mode]
    for panes in args.panes:
        for run in range(args.runs):
            # Alternate order to reduce systematic warm-cache bias.
            for mode in modes[::1 if run % 2 == 0 else -1]:
                result = (benchmark([args.agent], mode, panes, args.bytes, args.samples, args.credit_batch)
                          if args.workload == "bulk" else
                          mixed_benchmark([args.agent], mode, panes, args.samples, args.credit_batch))
                print(json.dumps(dict(run=run, **result)), flush=True)


if __name__ == "__main__":
    main()
