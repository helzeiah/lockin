"""Tests for the helper script (coach.py) and the AI client's safety checks. Run with ./app/test.sh."""
import datetime as dt
import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "Helper"
sys.path.insert(0, str(HELPER))


def load(data_dir, today="2026-11-23"):
    os.environ["FOCUS_DATA"] = str(data_dir)
    os.environ["FOCUS_TODAY"] = today
    os.environ["FOCUS_CALEVENTS"] = str(Path(data_dir) / "no-calendar")
    import coach
    return importlib.reload(coach)


class CleanItem(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.coach = load(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_keeps_a_good_item(self):
        it = self.coach.clean_item({"ref": "a1", "task": "Write intro", "minutes": 45, "start": "09:30", "done": False, "why": "due soon"})
        self.assertEqual(it, {"ref": "a1", "task": "Write intro", "minutes": 45, "start": "09:30", "done": False, "why": "due soon"})

    def test_clamps_and_cleans(self):
        it = self.coach.clean_item({"task": "  x " * 100, "minutes": 9999, "start": "25:99", "done": "yes"})
        self.assertLessEqual(len(it["task"]), 120)
        self.assertEqual(it["minutes"], 240)
        self.assertEqual(it["start"], "")
        self.assertFalse(it["done"])
        self.assertEqual(it["ref"], "new")

    def test_pads_single_digit_hours_and_rejects_junk(self):
        self.assertEqual(self.coach.clean_item({"task": "a", "minutes": "30", "start": "9:05"})["start"], "09:05")
        self.assertEqual(self.coach.clean_item({"task": "a", "minutes": None})["minutes"], 45)
        self.assertEqual(self.coach.clean_item({"task": "a", "minutes": "abc"})["minutes"], 45)
        self.assertIsNone(self.coach.clean_item({"task": "   "}))


class Windows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.coach = load(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_gaps_between_busy_times(self):
        d = dt.datetime(2026, 11, 23)
        busy = [(d.replace(hour=10), d.replace(hour=11)), (d.replace(hour=13), d.replace(hour=14))]
        got = self.coach.free_windows(busy, d.replace(hour=9, minute=2), d.replace(hour=17))
        self.assertEqual([(a.strftime("%H:%M"), b.strftime("%H:%M")) for a, b in got],
                         [("09:05", "10:00"), ("11:00", "13:00"), ("14:00", "17:00")])

    def test_break_times_skip_junk(self):
        d = dt.date(2026, 11, 23)
        got = self.coach.break_times({"breaks": [{"start": "12:30", "minutes": 45}, {"start": "noon"}, "x"]}, d)
        self.assertEqual(got, [(dt.datetime(2026, 11, 23, 12, 30), dt.datetime(2026, 11, 23, 13, 15))])
        self.assertEqual(self.coach.day_end_time({}, d, {"finish": "17:00"}), dt.datetime(2026, 11, 23, 17, 0))
        self.assertEqual(self.coach.day_end_time({"day_end": "22:00"}, d, {}), dt.datetime(2026, 11, 23, 22, 0))

    def test_breaks_scale_with_the_session(self):
        self.assertEqual(self.coach.break_after({}, 25), 5)
        self.assertEqual(self.coach.break_after({}, 90), 18)
        self.assertEqual(self.coach.break_after({"break_ratio": 3}, 90), 30)
        self.assertEqual(self.coach.break_after({"break_ratio": 0, "break_minutes": 7}, 90), 7)
        self.assertEqual(self.coach.break_after({"break_minutes": 10}, 90), 10)   # an old config keeps its hand-set break
        d = dt.date(2026, 11, 23)
        busy = self.coach.busy_from([{"start": "09:00", "minutes": 90}], d, {"break_ratio": 3})
        self.assertEqual(busy, [(dt.datetime(2026, 11, 23, 9, 0), dt.datetime(2026, 11, 23, 11, 0))])

    def test_short_gaps_are_dropped(self):
        d = dt.datetime(2026, 11, 23)
        busy = [(d.replace(hour=10, minute=10), d.replace(hour=12))]
        got = self.coach.free_windows(busy, d.replace(hour=10), d.replace(hour=12, minute=30), min_minutes=20)
        self.assertEqual([(a.strftime("%H:%M"), b.strftime("%H:%M")) for a, b in got], [("12:00", "12:30")])


class Doc(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.coach = load(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_stale_file_means_nothing_planned_and_is_not_rewritten(self):
        p = Path(self.tmp.name) / "todos.json"
        p.write_text(json.dumps({"date": "2026-11-20", "items": [{"id": "x", "task": "old", "minutes": 30}], "backlog": [{"id": "b"}]}))
        doc = self.coach.load_doc()
        self.assertEqual(doc["items"], [])
        self.assertEqual(doc["backlog"], [{"id": "b"}])
        self.assertIn("2026-11-20", p.read_text())     # the app does the rollover, not the helper

    def test_recap_counts_kept_early_and_skips(self):
        log = Path(self.tmp.name) / "log.jsonl"
        rows = [
            {"type": "gate_skipped", "reason": "sick", "ts": "2026-11-23T08:00:00"},
            {"type": "block_end", "name": "Focus", "task": "Essay", "completed": True, "focused_min": 45, "ts": "2026-11-23T10:00:00"},
            {"type": "block_end", "name": "Focus", "task": "Pset", "completed": False, "how": "stopped", "focused_min": 10, "ts": "2026-11-23T11:00:00"},
            {"type": "block_end", "name": "Focus", "task": "Old", "completed": True, "focused_min": 99, "ts": "2026-11-22T10:00:00"},
            {"type": "pass", "what": "youtube.com", "ts": "2026-11-23T12:00:00"},
        ]
        log.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        text = self.coach.recap()
        self.assertIn("0h 55m focused", text)
        self.assertIn("1 kept, 1 ended early", text)
        self.assertIn("sick", text)
        self.assertIn("1 pass", text)


class AIClient(unittest.TestCase):
    def setUp(self):
        import ai
        self.ai = importlib.reload(ai)

    def test_refuses_keys_over_plain_http(self):
        with self.assertRaises(self.ai.AIError) as e:
            self.ai._post("http://example.com/v1/chat/completions", {"Authorization": "Bearer k"}, {})
        self.assertIn("https", str(e.exception))

    def test_refuses_odd_schemes(self):
        with self.assertRaises(self.ai.AIError):
            self.ai._post("file:///etc/passwd", {}, {})

    def test_never_follows_redirects(self):
        handler = self.ai._NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example/"))

    def test_parses_fenced_json(self):
        self.assertEqual(self.ai._parse('```json\n{"ok": true}\n```'), {"ok": True})


if __name__ == "__main__":
    unittest.main()


class PromptAndApply(unittest.TestCase):
    """Apple Intelligence runs in the app: the helper builds the prompt, then applies the model's answer."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.coach = load(self.tmp.name)
        (Path(self.tmp.name) / "config.json").write_text(json.dumps({"ai": {"provider": "apple"}}))
        (Path(self.tmp.name) / "todos.json").write_text(json.dumps({"date": "2026-11-23", "items": [
            {"id": "a1", "task": "Essay", "minutes": 45, "start": "10:00", "apps": ["Pages"], "block": "Writing"}]}))

    def tearDown(self):
        self.tmp.cleanup()

    def test_prompt_mentions_the_plan(self):
        p = self.coach.plan_context("finished the essay", "today")["prompt"]
        self.assertIn("Essay", p)
        self.assertIn("finished the essay", p)

    def test_apply_keeps_apps_and_checks_the_answer(self):
        ctx = self.coach.plan_context("add gym", "today")
        out = self.coach.apply_plan(ctx, "add gym", {"items": [
            {"ref": "a1", "task": "Essay", "minutes": 45, "start": "10:00", "done": False, "why": ""},
            {"ref": "new", "task": "Gym", "minutes": 999, "start": "7pm", "done": False, "why": ""}], "reply": "Added gym."})
        essay, gym = out["items"]
        self.assertEqual(essay["apps"], ["Pages"])
        self.assertEqual(essay["block"], "Writing")
        self.assertEqual(gym["minutes"], 240)
        self.assertEqual(gym["start"], "")
        self.assertEqual(gym["block"], "")
        saved = json.loads((Path(self.tmp.name) / "todos.json").read_text())
        self.assertEqual([t["task"] for t in saved["items"]], ["Essay", "Gym"])

    def test_prompt_keeps_breaks_free_and_ends_at_the_finish(self):
        doc = json.loads((Path(self.tmp.name) / "todos.json").read_text())
        doc["shape"] = {"breaks": [{"start": "12:30", "minutes": 60}], "finish": "17:00"}
        (Path(self.tmp.name) / "todos.json").write_text(json.dumps(doc))
        p = self.coach.plan_context("plan my day", "today")["prompt"]
        self.assertIn("Their longer breaks (keep free): 12:30-13:30", p)
        self.assertIn("They finish work at 17:00", p)

    def test_the_planner_sees_the_list_and_can_pull_from_it(self):
        (Path(self.tmp.name) / "tasks.json").write_text(json.dumps({"tasks": [
            {"id": "t1", "title": "Sell fridge", "due": "2026-11-22", "minutes": 30, "first_step": "take photos"},
            {"id": "t2", "title": "Done thing", "done": "2026-11-20"}]}))
        ctx = self.coach.plan_context("plan my day", "today")
        self.assertIn('"ref": "L:t1"', ctx["prompt"])
        self.assertIn("First step: take photos", ctx["prompt"])
        self.assertNotIn("Done thing", ctx["prompt"])
        out = self.coach.apply_plan(ctx, "plan my day", {"items": [
            {"ref": "a1", "task": "Essay", "minutes": 45, "start": "10:00", "done": False, "why": ""},
            {"ref": "L:t1", "task": "Sell fridge", "minutes": 30, "start": "11:00", "done": False, "why": "overdue"}], "reply": "ok"})
        fridge = out["items"][1]
        self.assertEqual(fridge["task_id"], "t1")
        self.assertNotEqual(fridge["id"], "L:t1")

    def test_questions_prompt_is_about_the_task(self):
        (Path(self.tmp.name) / "tasks.json").write_text(json.dumps({"tasks": [{"id": "t1", "title": "Policy memo for gened 1120"}]}))
        self.assertIn("Policy memo for gened 1120", self.coach.questions_context("t1")["prompt"])
        with self.assertRaises(Exception):
            self.coach.questions_context("nope")

    def test_rejects_a_non_plan(self):
        ctx = self.coach.plan_context("x", "today")
        with self.assertRaises(Exception):
            self.coach.apply_plan(ctx, "x", {"nope": 1})
