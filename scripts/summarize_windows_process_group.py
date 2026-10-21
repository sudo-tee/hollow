#!/usr/bin/env python3
"""Audit saved GUI sampler JSONL and include its recorded Windows descendants.

This is not machine-wide CPU or exhaustive WSL-service attribution. Older
sampler records lack parent creation times, so historical ancestry cannot be
fully revalidated. PID/start identities and pre-GUI processes are checked here.
"""
import argparse
from collections import defaultdict
from datetime import datetime
import json
import math
from pathlib import Path
import statistics


def timestamp(value):
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('process creation time has no timezone')
    return result


def summarize(rows):
    metadata = [r for r in rows if r.get('type') == 'metadata']
    if len(metadata) != 1:
        raise ValueError('exactly one metadata row required')
    meta = metadata[0]
    root_start = timestamp(meta['gui_start_time_utc'])
    root_key = (meta['gui_pid'], meta['gui_start_time_utc'])
    if not any(r.get('type') == 'end' and r.get('status') == 'complete' for r in rows):
        raise ValueError('sampler did not complete')
    samples = [r['sample'] for r in rows if r.get('type') == 'sample']
    if len(samples) < 2 or samples != sorted(set(samples)):
        raise ValueError('at least two ordered unique samples required')
    snapshots = {sample: {} for sample in samples}
    excluded = {}
    for row in rows:
        if row.get('type') not in ('process', 'process_error'):
            continue
        key = (row['pid'], row['start_time_utc'])
        if row.get('role') == 'descendant' and timestamp(key[1]) < root_start:
            excluded[key] = dict(pid=key[0], start_time_utc=key[1], name=row['name'],
                                 reason='created before GUI; cannot be its descendant')
            continue
        if row.get('type') == 'process_error' or row.get('absent'):
            raise ValueError(f'process unavailable during measurement: {key}')
        if row['sample'] not in snapshots:
            raise ValueError('process references unknown sample')
        if key in snapshots[row['sample']]:
            raise ValueError('duplicate process identity in snapshot')
        snapshots[row['sample']][key] = row
    first, last = snapshots[samples[0]], snapshots[samples[-1]]
    if root_key not in first or first[root_key]['role'] != 'gui':
        raise ValueError('GUI identity does not match metadata')
    identities = set(first)
    parent_evidence = any('parent_pid' in row for snapshot in snapshots.values() for row in snapshot.values())
    if any(set(snapshot) != identities for snapshot in snapshots.values()):
        raise ValueError('recorded process identities changed during measurement')
    for snapshot in snapshots.values():
        gui = [key for key, row in snapshot.items() if row['role'] == 'gui']
        if gui != [root_key]:
            raise ValueError('exactly one matching GUI required')
        if parent_evidence:
            by_pid = {key[0]: (key, row) for key, row in snapshot.items()}
            for key, row in snapshot.items():
                if key == root_key:
                    continue
                parent = by_pid.get(row.get('parent_pid'))
                if parent is None or not row.get('parent_start_time_utc'):
                    raise ValueError('recorded parent identity missing')
                parent_birth = timestamp(row['parent_start_time_utc'])
                if abs((timestamp(parent[0][1])-parent_birth).total_seconds()) > .001:
                    raise ValueError('recorded parent PID creation time changed')
                if timestamp(key[1]) < parent_birth:
                    raise ValueError('child predates recorded parent')
                seen = set()
                current = key[0]
                while current != root_key[0]:
                    if current in seen or current not in by_pid:
                        raise ValueError('recorded parent chain does not reach GUI')
                    seen.add(current)
                    current = by_pid[current][1].get('parent_pid')
    elapsed = (last[root_key]['measured_elapsed_ms'] - first[root_key]['measured_elapsed_ms']) / 1000
    if elapsed <= 0:
        raise ValueError('GUI measurement interval did not advance')
    families = defaultdict(lambda: dict(cpu_seconds=0.0, average_cores=0.0, process_count=0))
    processes = []
    for key in sorted(identities):
        series = [snapshots[sample][key] for sample in samples]
        counters = [r['cpu_seconds'] for r in series]
        times = [r['measured_elapsed_ms'] for r in series]
        if any(not math.isfinite(v) for v in times):
            raise ValueError('process measurement timestamps must be finite')
        if any(not math.isfinite(v) or v < 0 for v in counters):
            raise ValueError('CPU counters must be finite and nonnegative')
        if any(b < a for a, b in zip(counters, counters[1:])):
            raise ValueError('CPU counter decreased for same process identity')
        if any(b <= a for a, b in zip(times, times[1:])):
            raise ValueError('process measurement timestamps did not advance')
        name = series[0]['name'].lower().removesuffix('.exe')
        family = 'gui' if key == root_key else name if name in ('wsl', 'conhost', 'wslhost', 'openconsole') else 'other_descendants'
        delta = counters[-1] - counters[0]
        record = dict(pid=key[0], start_time_utc=key[1], name=series[0]['name'],
                      family=family, cpu_seconds=delta, average_cores=delta/elapsed,
                      own_interval_seconds=(times[-1]-times[0])/1000)
        processes.append(record)
        families[family]['cpu_seconds'] += delta
        families[family]['average_cores'] += delta/elapsed
        families[family]['process_count'] += 1
    skew = max(max(r['measured_elapsed_ms'] for r in snapshot.values()) -
               min(r['measured_elapsed_ms'] for r in snapshot.values()) for snapshot in snapshots.values())
    total = sum(p['cpu_seconds'] for p in processes)
    return dict(gui_interval_seconds=elapsed, sample_count=len(samples),
                ancestry_evidence='recorded parent PID and creation-time chains checked' if parent_evidence else 'legacy parent-PID discovery only; edges unavailable',
                snapshot_max_skew_ms=skew, families=dict(families), processes=processes,
                windows_recorded_group_cores=total/elapsed,
                excluded_pre_gui_processes=list(excluded.values()))


def analyze(root, phase='capped'):
    runs = []
    for directory in sorted(root.glob('trial-*')):
        source = directory / f'{phase}-windows.jsonl'
        if not source.is_file():
            continue
        run = dict(run=directory.name, trial=int(directory.name.split('-')[1]),
                   variant=directory.name.split('-')[-1])
        try:
            rows = [json.loads(line) for line in source.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
            run.update(summarize(rows), validation='PASS')
        except (ValueError, KeyError, TypeError) as exc:
            run.update(validation='FAIL', error=str(exc))
        runs.append(run)
    if not runs:
        raise ValueError('no saved Windows samples found')
    valid = [r for r in runs if r['validation'] == 'PASS']
    groups = {}
    for variant in sorted({r['variant'] for r in valid}):
        group = [r for r in valid if r['variant'] == variant]
        groups[variant] = dict(n=len(group), median_group_cores=statistics.median(r['windows_recorded_group_cores'] for r in group),
                               median_gui_cores=statistics.median(r['families']['gui']['average_cores'] for r in group),
                               median_families={family: statistics.median(r['families'].get(family, {}).get('average_cores', 0) for r in group)
                                                for family in sorted({f for r in group for f in r['families']})})
    pairs = []
    for trial in sorted({r['trial'] for r in runs}):
        by_variant = {r['variant']: r for r in runs if r['trial'] == trial}
        for a, b in (('pty', 'mux'), ('mux', 'candidate'), ('pty', 'candidate')):
            if a not in by_variant or b not in by_variant:
                continue
            pair = dict(trial=trial, comparison=f'{b}_vs_{a}')
            if any(by_variant[v]['validation'] != 'PASS' for v in (a, b)):
                pair['validation'] = 'FAIL'
            else:
                baseline = by_variant[a]['windows_recorded_group_cores']
                pair.update(validation='PASS', group_change_percent=100*(by_variant[b]['windows_recorded_group_cores']/baseline-1) if baseline else None)
            pairs.append(pair)
    return dict(validation='PASS' if len(valid) == len(runs) else 'FAIL', phase=phase,
                groups=groups, pairs=pairs, runs=runs,
                scope='GUI plus recorded, creation-time-filtered Windows descendants; not system-wide or all WSL services.',
                caveats=['CPU deltas use common endpoint sample indices divided by the GUI measured interval; snapshots are not simultaneous (skew reported).',
                         'Historical sampler did not record parent creation times. Excluding pre-GUI processes fixes obvious stale-parent PID matches but cannot prove every ancestry edge.',
                         'Process-group validation audits saved Windows counters only; check original experiment load, window, and cleanup validation separately.',
                         'Shared WSL/VM service CPU and Linux CPU are not included or added. Zero sampled CPU deltas are limited by counter resolution.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--phase', default='capped')
    args = parser.parse_args()
    result = analyze(args.root, args.phase)
    path = args.root / f'{args.phase}-windows-process-group.json'
    path.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(output=str(path), validation=result['validation'], groups=result['groups'], pairs=result['pairs']), indent=2))
    return 0 if result['validation'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
