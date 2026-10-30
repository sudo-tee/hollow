import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("profile", Path(__file__).parents[1] / "app_profile_summary.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class SummaryTest(unittest.TestCase):
    def test_nearest_rank_and_empty(self):
        self.assertIsNone(profile.stats([]))
        self.assertEqual(profile.stats([3_000_000, 1_000_000, 2_000_000])["p50_ms"], 2)
        self.assertEqual(profile.stats([3_000_000, 1_000_000, 2_000_000])["p95_ms"], 3)

    def test_filter_and_missing_cpu(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "samples.csv"
            path.write_text("# dropped=2\nstart_ns,elapsed_ns,thread_cpu_ns,rendered\n0,4,1,0\n10,5,,1\n30,7,3,1\n")
            result = profile.summarize(path, 1, True)
            self.assertEqual(result["dropped"], 2)
            self.assertEqual(result["selected_callbacks"], 2)
            self.assertEqual(result["thread_cpu"]["n"], 1)
            self.assertEqual(result["selected_start_intervals"]["p50_ms"], 20 / 1_000_000)
            self.assertEqual(profile.summarize(path, 0, False, 10, 30)["selected_callbacks"], 1)


if __name__ == "__main__":
    unittest.main()
