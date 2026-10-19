#!/usr/bin/env python3
"""Bounded Linux /proc sampling of an explicitly launched command's local tree.

Observer only: no rollout qualification, remote memory accounting or PSS claim.
Short processes and CPU tails between samples can be missed. RSS sums count
shared pages more than once. Use identical monitor-off controls for timings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import time

PROCESS_CAPACITY = 4096
SAMPLE_CAPACITY = 16384
TASK_CAPACITY = 256


def parse_stat(text):
    prefix, fields = text.rsplit(") ", 1)
    pid = int(prefix.split(" (", 1)[0])
    fields = fields.split()
    result = dict(pid=pid, state=fields[0], ppid=int(fields[1]),
                  cpu_ticks=int(fields[11]) + int(fields[12]), threads=int(fields[17]),
                  start_ticks=int(fields[19]), rss_pages=max(0, int(fields[21])))
    if min(result[k] for k in ("pid", "ppid", "cpu_ticks", "threads", "start_ticks")) < 0:
        raise ValueError("negative proc counters")
    return result


def identity(stat):
    return stat["pid"], stat["start_ticks"]


class Records:
    def __init__(self, process_capacity=PROCESS_CAPACITY, sample_capacity=SAMPLE_CAPACITY):
        self.process_capacity, self.sample_capacity = process_capacity, sample_capacity
        self.processes, self.samples = {}, []
        self.dropped_process_observations = self.dropped_samples = 0

    def observe(self, stat, elapsed_ns):
        key = identity(stat)
        if key not in self.processes:
            if len(self.processes) == self.process_capacity:
                self.dropped_process_observations += 1
                return False
            self.processes[key] = dict(pid=key[0], start_ticks=key[1], first_seen_ns=elapsed_ns,
                                       max_cpu_ticks=0, peak_rss_pages=0, peak_threads=0)
        record = self.processes[key]
        record.update(last_seen_ns=elapsed_ns, last_state=stat["state"], last_ppid=stat["ppid"],
                      max_cpu_ticks=max(record["max_cpu_ticks"], stat["cpu_ticks"]),
                      peak_rss_pages=max(record["peak_rss_pages"], stat["rss_pages"]),
                      peak_threads=max(record["peak_threads"], stat["threads"]))
        return True

    def sample(self, stats, elapsed_ns, page_size):
        live = [s for s in stats if s["state"] not in ("Z", "X")]
        row = dict(elapsed_ns=elapsed_ns, live_processes=len(live), zombies=len(stats) - len(live),
                   summed_rss_bytes=sum(s["rss_pages"] for s in live) * page_size,
                   threads=sum(s["threads"] for s in live),
                   observed_cpu_ticks=sum(p["max_cpu_ticks"] for p in self.processes.values()))
        if len(self.samples) < self.sample_capacity:
            self.samples.append(row)
        else:
            self.dropped_samples += 1
        return row


class Sampler:
    def __init__(self, root_pid):
        self.records = Records()
        self.active = {}  # Identity -> pidfd. Never signal a recycled numeric PID.
        self.read_races = self.task_censored = 0
        self.page_size = os.sysconf("SC_PAGE_SIZE")
        self.root = self.read(root_pid)
        if self.root is None:
            raise RuntimeError("root exited before initial identity capture")

    def read(self, pid):
        try:
            return parse_stat(Path(f"/proc/{pid}/stat").read_text())
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            self.read_races += 1
            return None

    def children(self, stat):
        try:
            # Children may be forked by any transport thread, not just main TID.
            tasks = list(Path(f"/proc/{stat['pid']}/task").iterdir())
            self.task_censored += len(tasks) > TASK_CAPACITY
            children = set()
            for task in tasks[:TASK_CAPACITY]:
                try:
                    children.update(map(int, (task / "children").read_text().split()))
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    self.read_races += 1
            return children
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            self.read_races += 1
            return ()

    def sample(self, elapsed_ns):
        pending = [identity(self.root), *self.active]
        seen, stats = set(), []
        while pending and len(seen) < PROCESS_CAPACITY:
            key = pending.pop()
            if key in seen:
                continue
            seen.add(key)
            stat = self.read(key[0])
            if stat is None or identity(stat) != key:
                if key in self.active:
                    os.close(self.active.pop(key))
                continue
            if key not in self.active:
                try:
                    fd = os.pidfd_open(key[0])
                except ProcessLookupError:
                    self.read_races += 1
                    continue
                current = self.read(key[0])
                if current is None or identity(current) != key:
                    os.close(fd)
                    continue
                if not self.records.observe(stat, elapsed_ns):
                    os.close(fd)
                    continue
                self.active[key] = fd
            else:
                self.records.observe(stat, elapsed_ns)
            stats.append(stat)
            for pid in self.children(stat):
                child = self.read(pid)
                if child is not None and child["ppid"] == stat["pid"]:
                    pending.append(identity(child))
        if pending:
            self.records.dropped_process_observations += len(pending)
        return self.records.sample(stats, elapsed_ns, self.page_size)

    def signal_live(self, sig):
        signaled = []
        for key, fd in self.active.items():
            current = self.read(key[0])
            if current is None or identity(current) != key or current["state"] in ("Z", "X"):
                continue
            try:
                signal.pidfd_send_signal(fd, sig)
                signaled.append(dict(pid=key[0], start_ticks=key[1], signal=sig))
            except ProcessLookupError:
                pass
        return signaled

    def close(self):
        for fd in self.active.values():
            os.close(fd)
        self.active.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval-ms", type=int, default=50)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not 10 <= args.interval_ms <= 1000 or not 1 <= args.timeout <= 600 or not command or any("\0" in s for s in command):
        parser.error("bounded interval 10..1000 ms, timeout 1..600 s and command argv required")
    if sys.platform != "linux" or not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        parser.error("Linux /proc and pidfds required")
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    observer_start, started = time.process_time_ns(), time.monotonic_ns()
    # File-backed child output cannot fill an undrained pipe. Never overwrite.
    with args.output.open("x") as output, Path(str(args.output) + ".stdout").open("xb") as stdout, Path(str(args.output) + ".stderr").open("xb") as stderr:
        child = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        sampler = None
        timed_out = False
        signals = []
        interrupted = False
        try:
            sampler = Sampler(child.pid)
            while True:
                row = sampler.sample(time.monotonic_ns() - started)
                if child.poll() is not None:
                    break
                if time.monotonic_ns() - started >= args.timeout * 1_000_000_000:
                    timed_out = True
                    break
                time.sleep(args.interval_ms / 1000)
        except KeyboardInterrupt:
            interrupted = True
        finally:
            if sampler is not None:
                signals += sampler.signal_live(signal.SIGTERM)
                if signals:
                    time.sleep(1.5)  # Let owned agent guardians reap workloads.
                    sampler.sample(time.monotonic_ns() - started)
                    signals += sampler.signal_live(signal.SIGKILL)
                sampler.close()
            if child.poll() is None:
                child.kill()  # Unreaped, directly owned subprocess only.
            child.wait()
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        records = sampler.records if sampler is not None else Records()
        result = dict(schema=1, qualification=False, command=command, interval_ms=args.interval_ms,
                      root_pid=child.pid, returncode=child.returncode, timed_out=timed_out, interrupted=interrupted,
                      wall_ns=time.monotonic_ns() - started, observer_cpu_ns=time.process_time_ns() - observer_start,
                      clock_ticks=os.sysconf("SC_CLK_TCK"), page_size=os.sysconf("SC_PAGE_SIZE"),
                      monitor_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      scope="Local observed process tree including launcher, not remote/GUI. Summed RSS double-counts shared pages; short processes and final CPU tails may be missed.",
                      reaped_child_user_s=usage.ru_utime - usage_before.ru_utime,
                      reaped_child_system_s=usage.ru_stime - usage_before.ru_stime,
                      reaped_child_maxrss_kib=usage.ru_maxrss,
                      reaped_usage_note="Wait accounting includes only propagated/reaped descendants; not added to sampled CPU; maxrss is not simultaneous tree RSS.",
                      cleanup_signals=signals, proc_read_races=sampler.read_races if sampler else 0,
                      task_censored=sampler.task_censored if sampler else 0,
                      short_processes_and_cpu_tails_may_be_missing=True,
                      process_capacity=PROCESS_CAPACITY, sample_capacity=SAMPLE_CAPACITY,
                      dropped_process_observations=records.dropped_process_observations,
                      dropped_samples=records.dropped_samples, processes=list(records.processes.values()), samples=records.samples)
        json.dump(result, output, separators=(",", ":"))
        output.write("\n")
    return 124 if timed_out else 130 if interrupted else child.returncode if child.returncode >= 0 else 128 - child.returncode


if __name__ == "__main__":
    sys.exit(main())
