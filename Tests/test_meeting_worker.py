import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "meeting_worker", Path(__file__).resolve().parents[1] / "Resources/meeting_worker.py"
)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MeetingWorkerTests(unittest.TestCase):
    def test_long_turns_cover_every_second(self):
        self.assertEqual(list(worker.split_turn(2, 59)), [(2, 27), (27, 52), (52, 59)])
        self.assertEqual(list(worker.split_turn(0, 0)), [])

    def test_names_require_timed_evidence(self):
        segments = [dict(speaker="remote-0", start=10, end=15), dict(speaker="me", start=20, end=25)]
        self.assertEqual(worker.name_speakers(segments, [dict(time=1, name="Stale")]), {})
        self.assertEqual(worker.name_speakers(segments, [dict(time=10, name="Taylor")]), {"remote-0": "Taylor"})
        self.assertEqual(worker.name_speakers(segments, [dict(time=20, name="Taylor")]), {})

    def test_ambiguous_names_are_not_guessed(self):
        segments = [dict(speaker="remote-0", start=0, end=5)]
        observations = [dict(time=0, name="Taylor"), dict(time=2.5, name="Morgan")]
        self.assertEqual(worker.name_speakers(segments, observations), {})
        segments.append(dict(speaker="remote-1", start=5, end=10))
        self.assertEqual(worker.name_speakers(segments, [dict(time=0, name="Taylor"), dict(time=5, name="Taylor")]), {})


if __name__ == "__main__":
    unittest.main()
