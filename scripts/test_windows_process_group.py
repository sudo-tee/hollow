#!/usr/bin/env python3
"""Synthetic saved-counter checks; no Windows or active GUI required."""
import copy
import unittest

from summarize_windows_process_group import summarize


START = '2026-10-20T12:00:00.0000000Z'
CHILD = '2026-10-20T12:00:01.0000000Z'


def fixture():
    rows = [dict(type='metadata', gui_pid=1, gui_start_time_utc=START)]
    for sample in range(2):
        rows.append(dict(type='sample', sample=sample))
        for pid, name, cpu in ((1, 'hollow-native', 1+2*sample),
                               (2, 'wsl', .1+.4*sample),
                               (3, 'conhost', .1),
                               (4, 'wslhost', .1+.2*sample)):
            rows.append(dict(type='process', sample=sample, pid=pid, name=name,
                             start_time_utc=START if pid == 1 else CHILD,
                             role='gui' if pid == 1 else 'descendant',
                             measured_elapsed_ms=1000+2000*sample+pid,
                             cpu_seconds=cpu))
    rows.append(dict(type='end', status='complete'))
    return rows


class ProcessGroupTests(unittest.TestCase):
    def parent_fixture(self):
        rows = fixture()
        for row in rows:
            if row.get('type') == 'process':
                row['parent_pid'] = None if row['pid'] == 1 else 1
                row['parent_start_time_utc'] = None if row['pid'] == 1 else START
        return rows

    def test_counts_gui_and_all_captured_helpers(self):
        result = summarize(fixture())
        self.assertAlmostEqual(result['windows_recorded_group_cores'], 1.3)
        self.assertAlmostEqual(result['families']['wsl']['average_cores'], .2)
        self.assertAlmostEqual(result['families']['wslhost']['average_cores'], .1)
        self.assertEqual(result['families']['conhost']['average_cores'], 0)
        self.assertEqual(result['snapshot_max_skew_ms'], 3)

    def test_old_process_cannot_be_gui_descendant(self):
        rows = fixture()
        for sample in range(2):
            rows.insert(-1, dict(type='process', sample=sample, pid=9, name='unrelated',
                                 start_time_utc='2026-10-19T12:00:00Z', role='descendant',
                                 measured_elapsed_ms=1000+2000*sample, cpu_seconds=100*sample))
        result = summarize(rows)
        self.assertAlmostEqual(result['windows_recorded_group_cores'], 1.3)
        self.assertEqual(len(result['excluded_pre_gui_processes']), 1)

    def test_pid_reuse_is_not_combined(self):
        rows = fixture()
        for row in rows:
            if row.get('sample') == 1 and row.get('pid') == 2:
                row['start_time_utc'] = '2026-10-20T12:00:02Z'
        with self.assertRaisesRegex(ValueError, 'identities changed'):
            summarize(rows)

    def test_missing_child_is_not_silently_zero(self):
        rows = [r for r in fixture() if not (r.get('sample') == 1 and r.get('pid') == 3)]
        with self.assertRaisesRegex(ValueError, 'identities changed'):
            summarize(rows)

    def test_cpu_counter_decrease_rejected(self):
        rows = fixture()
        for row in rows:
            if row.get('sample') == 1 and row.get('pid') == 2:
                row['cpu_seconds'] = 0
        with self.assertRaisesRegex(ValueError, 'counter decreased'):
            summarize(rows)

    def test_failed_run_rejected(self):
        rows = fixture()
        rows[-1]['status'] = 'failure'
        with self.assertRaisesRegex(ValueError, 'did not complete'):
            summarize(rows)

    def test_unknown_child_is_reported_not_discarded(self):
        rows = fixture()
        for row in rows:
            if row.get('pid') == 2:
                row['name'] = 'another-helper.exe'
        result = summarize(rows)
        self.assertAlmostEqual(result['families']['other_descendants']['average_cores'], .2)
        self.assertAlmostEqual(result['windows_recorded_group_cores'], 1.3)

    def test_gui_identity_must_match_metadata(self):
        rows = copy.deepcopy(fixture())
        rows[0]['gui_pid'] = 99
        with self.assertRaisesRegex(ValueError, 'GUI identity'):
            summarize(rows)

    def test_recorded_parent_chain_checked(self):
        result = summarize(self.parent_fixture())
        self.assertIn('chains checked', result['ancestry_evidence'])

    def test_stale_parent_pid_rejected(self):
        rows = self.parent_fixture()
        for row in rows:
            if row.get('pid') == 2:
                row['parent_start_time_utc'] = '2026-10-19T12:00:00Z'
        with self.assertRaisesRegex(ValueError, 'parent PID creation time changed'):
            summarize(rows)

    def test_parent_chain_cannot_skip_missing_parent(self):
        rows = self.parent_fixture()
        for row in rows:
            if row.get('pid') == 2:
                row['parent_pid'] = 99
        with self.assertRaisesRegex(ValueError, 'parent identity missing'):
            summarize(rows)


if __name__ == '__main__':
    unittest.main()
