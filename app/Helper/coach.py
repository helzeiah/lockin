#!/usr/bin/env python3
"""Helper for the lockin app: morning plan text, nightly recap, open time slots, and the AI day planner.
    coach.py plan                 -> today's plan: calendar events and sessions, plus lines from extras.py
    coach.py recap                -> today's focus and accountability record from log.jsonl
    coach.py slot MINUTES [SKIP]  -> the soonest start (HH:MM) around the calendar and what's already planned (no AI)
    coach.py todos [today|tomorrow] -> a message on stdin ("dump", "finished X", "free at 8 now") -> the AI edits that day
    coach.py test                 -> checks the AI set up in Settings > AI planner
Data lives in $FOCUS_DATA (the app sets it to ~/Library/Application Support/lockin), else next to this file.
The app rolls the day over (tomorrow's plan becomes today's) before it calls this script, so this script never does.

Optional: an extras.py in the data folder can add lines to the morning plan (deadlines from your own tools, say).
It needs one function, plan_lines(now) -> list of "• text" strings. It isn't part of lockin and never leaves your Mac.
"""
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

import ai

ROOT = Path(__file__).parent
DATA = Path(os.environ.get("FOCUS_DATA") or ROOT)
LOG = DATA / "log.jsonl"
TODOS = DATA / "todos.json"
CONFIG = DATA / "config.json"
DAY_STARTS_AT = 4          # a day runs 4am to 4am, the same as the app's stats


def load_config():
    try:
        return json.loads(CONFIG.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def plan_date(offset=0):
    """The plan day (4am boundary). The app passes its own in $FOCUS_TODAY so both always agree."""
    today = os.environ.get("FOCUS_TODAY")
    base = dt.date.fromisoformat(today) if today else (dt.datetime.now() - dt.timedelta(hours=DAY_STARTS_AT)).date()
    return base + dt.timedelta(days=offset)


def load_doc():
    try:
        d = json.loads(TODOS.read_text())
    except (OSError, json.JSONDecodeError):
        d = {}
    if d.get("date") != plan_date().isoformat():   # stale file: the app hasn't rolled it over yet, so nothing is planned
        d = {"date": plan_date().isoformat(), "items": [], "chat": [], "backlog": d.get("backlog", []), "tomorrow": []}
    for k in ("items", "chat", "backlog", "tomorrow"):
        d.setdefault(k, [])
    return d


def load_todos():
    return load_doc()["items"]


def extras():
    """The optional extras.py in the data folder (see the module docstring), or None."""
    path = DATA / "extras.py"
    if not path.exists():
        return None
    try:
        spec = importlib.util.spec_from_file_location("lockin_extras", path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


CALEVENTS = Path(os.environ.get("FOCUS_CALEVENTS") or ROOT / "calevents")


def calendar_events(offset=0):
    """Timed events from macOS Calendar on the plan day `offset` days from today: [(start, end, title)]."""
    if not CALEVENTS.exists():
        return []
    try:
        out = subprocess.run([str(CALEVENTS), "1", str(offset)], capture_output=True, text=True, timeout=20).stdout
        evs = json.loads(out)
    except Exception:
        return []
    if isinstance(evs, dict):
        return []
    res = []
    for e in evs:
        if e.get("allDay"):
            continue
        st, en = dt.datetime.fromisoformat(e["start"]), dt.datetime.fromisoformat(e["end"])
        res.append((st, en, e.get("title", "")))
    return sorted(res)


def free_windows(busy, start, day_end, min_minutes=20):
    """Gaps between `start` and `day_end` not covered by the busy (start, end) ranges."""
    t = start.replace(second=0, microsecond=0)
    t += dt.timedelta(minutes=(5 - t.minute % 5) % 5)
    out = []
    for a, b in sorted(busy):
        if b <= t:
            continue
        if a > t:
            out.append((t, min(a, day_end)))
        t = max(t, b)
    if t < day_end:
        out.append((t, day_end))
    return [(a, b) for a, b in out if (b - a).total_seconds() >= min_minutes * 60]


def day_end_time(cfg, day=None):
    eh, em = map(int, (cfg.get("day_end") or "23:30").split(":"))
    day = day or dt.date.today()
    return dt.datetime.combine(day, dt.time(eh, em))


def busy_from(items, day):
    """(start, end) of to-dos that already have a time, plus a 5 minute break after each."""
    out = []
    for t in items:
        if t.get("done") or len(t.get("start") or "") < 4:
            continue
        try:
            h, m = map(int, t["start"].split(":"))
        except ValueError:
            continue
        a = dt.datetime.combine(day, dt.time(h, m))
        left = max(1, int(t.get("minutes", 30)) - int(t.get("spent", 0) or 0))
        out.append((a, a + dt.timedelta(minutes=left + 5)))
    return out


def soonest_slot(minutes, skip=None):
    """Earliest start today for a `minutes`-long session: not before now, not overlapping calendar events or
    to-dos that already have a time. Returns "HH:MM", or "" if nothing fits today."""
    cfg = load_config()
    today = dt.date.today()
    busy = [(a, b) for a, b, _ in calendar_events()] + busy_from([t for t in load_todos() if t.get("id") != skip], today)
    need = dt.timedelta(minutes=minutes)
    for a, b in free_windows(busy, dt.datetime.now(), day_end_time(cfg, today), min_minutes=minutes):
        if b - a >= need:
            return f"{a:%H:%M}"
    return ""


HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def clean_item(it):
    """One item from the AI, made safe: a short task, 5-240 minutes, a real HH:MM time (or none), a real bool."""
    task = " ".join(str(it.get("task") or "").split())[:120]
    if not task:
        return None
    try:
        minutes = int(round(float(it.get("minutes") or 45)))
    except (TypeError, ValueError):
        minutes = 45
    start = str(it.get("start") or "").strip()
    if re.match(r"^\d:\d\d$", start):
        start = "0" + start
    return {"ref": str(it.get("ref") or "new")[:40], "task": task, "minutes": min(max(minutes, 5), 240),
            "start": start if HHMM.match(start) else "", "done": it.get("done") is True,
            "why": " ".join(str(it.get("why") or "").split())[:60]}


def plan_context(text, day="today"):
    """Everything the AI planner needs: the prompt, the answer's schema, and the plan it edits."""
    cfgj = load_config()
    tomorrow = day == "tomorrow"
    doc = load_doc()
    pdate = plan_date(1 if tomorrow else 0)
    items = doc["tomorrow"] if tomorrow else doc["items"]
    chat = doc.get("chat", [])
    backlog = doc.get("backlog", [])
    day_end = day_end_time(cfgj, pdate)
    events = calendar_events(1 if tomorrow else 0)
    cal = "\n".join(f"- {a:%H:%M}-{b:%H:%M} {t}" for a, b, t in events) or "none"
    first_hour = (cfgj.get("active_hours") or [8, 23])[0]
    start_from = dt.datetime.combine(pdate, dt.time(first_hour)) if tomorrow else dt.datetime.now()
    free = ", ".join(f"{a:%H:%M}-{b:%H:%M}" for a, b in free_windows([(a, b) for a, b, _ in events], start_from, day_end)) or "none left"
    current = [{"ref": t["id"], "task": t["task"], "minutes": t["minutes"], "start": t.get("start", ""), "done": bool(t.get("done")),
                "minutes_already_worked": t.get("spent", 0)} for t in items]
    history = "\n".join(f"{m['role']}: {m['text']}" for m in chat[-8:]) if not tomorrow else ""
    back = [{"ref": b["id"], "task": b["task"], "minutes": b["minutes"], "from": b.get("from")} for b in backlog]
    item = {"type": "object", "properties": {
        "ref": {"type": "string", "description": "the existing item's ref, or \"new\""},
        "task": {"type": "string"}, "minutes": {"type": "integer"},
        "start": {"type": "string", "description": "24h HH:MM start that day; empty if done or it doesn't fit"},
        "done": {"type": "boolean"}, "why": {"type": "string"}},
        "required": ["ref", "task", "minutes", "start", "done", "why"], "additionalProperties": False}
    schema = {"type": "object", "properties": {"items": {"type": "array", "items": item},
              "reply": {"type": "string", "description": "one short sentence telling the user what you changed"}},
              "required": ["items", "reply"], "additionalProperties": False}
    about = (cfgj.get("about_me") or "").strip() or "no details given"
    extra = extras()
    notes = ""
    if extra and hasattr(extra, "planner_notes"):
        try:
            notes = str(extra.planner_notes(dt.datetime.now()) or "")[:2000]
        except Exception:
            notes = ""
    which = f"tomorrow ({pdate:%A %B %d})" if tomorrow else "today"
    prompt = f"""You are the day planner inside a focus app. About the user: {about}
They talk to you about {which}; you return that day's whole updated plan plus a one-sentence reply.

How to update:
- If there is no current plan, build one from their message. Otherwise EDIT the current plan to match what they say:
  mark things done ("I did X", "finished X"), add new tasks, remove or postpone ones they drop, change durations,
  and re-time everything when their availability changes ("free at 8 now", "only an hour left", "class ran late").
- Keep each existing item's "ref"; use "new" for added items. Keep done items in the list with done=true, start "".
- "minutes" is an item's total length. If it has minutes_already_worked, only the rest still needs room in the schedule.
- BACKLOG = unfinished items from earlier days. Do NOT add them on your own. Only if their message asks for one
  ("bring back X", "add my backlog") include it, using its backlog "ref".
- One concrete action per item ("Write the intro section of the essay"). Chunks of 25-90 minutes.
- Order unfinished items by urgency (hard deadlines first), then importance; make the first one easy to start.
- "why": at most 8 words.
- SCHEDULE unfinished items: a 24h HH:MM "start", back to back with ~5 min breaks, inside the free windows,
  never overlapping calendar events{"" if tomorrow else ", never before now"}. Timing they state always wins. If it doesn't
  fit before {day_end:%H:%M}, start "" and why "doesn't fit".
- reply: plain and specific, e.g. "Marked stats homework done and moved everything after 8 PM." No fluff.

Now: {dt.datetime.now():%A %B %d, %H:%M}. Planning {which}. The day ends around {day_end:%H:%M}.
Calendar that day:
{cal}
Free windows: {free}
{("Notes from their own tools:" + chr(10) + notes + chr(10)) if notes else ""}
Current plan: {json.dumps(current)}
Backlog (not part of the plan unless they ask): {json.dumps(back)}
{("Earlier today: " + history) if history else ""}

Their message:
{text[:4000]}"""
    return {"cfg": cfgj, "prompt": prompt, "schema": schema, "doc": doc, "items": items, "backlog": backlog, "chat": chat, "tomorrow": tomorrow}


def todos_from_ai(text, day="today"):
    """Conversational planner: builds a day's plan from a dump, or edits it from a message like
    "finished the stats hw", "free at 8 now", "add laundry", "push the essay to tomorrow"."""
    ctx = plan_context(text, day)
    return apply_plan(ctx, text, ai.ask_json(ctx["cfg"], ctx["prompt"], ctx["schema"]))


def apply_plan(ctx, text, res):
    """Checks the AI's answer and writes it into the plan (keeping what the app knows about each item)."""
    doc, items, backlog, chat, tomorrow = ctx["doc"], ctx["items"], ctx["backlog"], ctx["chat"], ctx["tomorrow"]
    if not isinstance(res, dict) or not isinstance(res.get("items"), list):
        raise ai.AIError("the AI's answer wasn't a plan: try again")
    known = {t["id"]: t for t in items} | {b["id"]: b for b in backlog}
    new_items, used = [], set()
    for raw in res["items"][:40]:
        it = clean_item(raw) if isinstance(raw, dict) else None
        if not it:
            continue
        ref = it.pop("ref")
        old = known.get(ref)
        it["id"] = ref if old and ref not in used else uuid.uuid4().hex[:8]
        used.add(it["id"])
        it["block"] = ""
        if old:   # what the app knows about an item survives a re-plan: time worked, its apps, its rule, repeat
            for k in ("spent", "apps", "block", "source", "ref"):
                if old.get(k):
                    it[k] = old[k]
        new_items.append(it)
    reply = " ".join(str(res.get("reply") or "Updated your plan.").split())[:200]
    if TODOS.exists():  # keep the previous version, in case an edit goes wrong
        (DATA / "todos.prev.json").write_text(TODOS.read_text())
    doc["backlog"] = [b for b in backlog if b["id"] not in used]
    if tomorrow:
        doc["tomorrow"] = new_items
    else:
        doc["items"] = new_items
        doc["chat"] = (chat + [{"role": "user", "text": text[:500]}, {"role": "planner", "text": reply}])[-12:]
    TODOS.write_text(json.dumps(doc, indent=1))
    return {"items": new_items, "reply": reply}


def today_events():
    """Today's log entries (4am to 4am)."""
    if not LOG.exists():
        return []
    start = dt.datetime.combine(plan_date(), dt.time(DAY_STARTS_AT))
    end = start + dt.timedelta(days=1)
    out = []
    for line in LOG.read_text().splitlines():
        if not line.strip():
            continue
        try:
            e = json.loads(line)
            ts = dt.datetime.fromisoformat(e["ts"])
        except (ValueError, KeyError):
            continue
        if start <= ts < end:
            out.append(e)
    return out


def clock(t):
    return f"{t:%-I:%M %p}"


def todo_start(t, now):
    """A to-do's "HH:MM" start as a datetime today, or None."""
    try:
        h, m = map(int, (t.get("start") or "").split(":"))
        return now.replace(hour=h, minute=m, second=0, microsecond=0)
    except ValueError:
        return None


def plan():
    now = dt.datetime.now()
    lines = []
    # One timeline: calendar events still to come and today's sessions, each with its start time.
    timeline = [(a, f"• {clock(a)} · {t.split('|')[0].strip()} (until {clock(b)})") for a, b, t in calendar_events() if b > now]
    open_todos = [t for t in load_todos() if not t.get("done")]
    for t in open_todos:
        st = todo_start(t, now)
        left = max(1, t["minutes"] - t.get("spent", 0))
        timeline.append((st or dt.datetime.max, f"• {clock(st) + ' · ' if st else ''}{t['task']} ({left} min)"))
    lines += [l for _, l in sorted(timeline, key=lambda x: x[0])[:6]]
    extra = extras()
    if extra and hasattr(extra, "plan_lines"):
        try:
            lines += [str(l) for l in extra.plan_lines(now)][:4]
        except Exception:
            pass
    if not lines:
        return "Today's plan\nNothing planned yet. Open lockin and type what you'll lock in on."
    first = "Start with what's due soonest" if any(" due TODAY" in l or " due tomorrow" in l for l in lines) else "Start with your hardest session"
    tip = "" if open_todos else "\nNo sessions yet: open lockin and add them."
    when = " while you're fresh" if now.hour < 12 else ""
    return "Today's plan\n" + "\n".join(lines[:9]) + f"\n\n{first}{when}." + tip


def recap():
    ev = today_events()
    ends = [e for e in ev if e["type"] == "block_end"]
    focused = sum(e.get("focused_min", 0) for e in ends)
    kept = [e for e in ends if e.get("completed")]
    early = [e for e in ends if not e.get("completed") and e.get("how") != "replaced"]
    covers = [e for e in ev if e["type"] in ("drift", "blocked")]
    passes = [e for e in ev if e["type"] == "pass"]
    skipped = [e for e in ev if e["type"] == "gate_skipped"]
    quits = [e for e in ev if e["type"] == "quit_during_session"]
    top = {}
    for d in covers:
        top[d.get("what", "?")] = top.get(d.get("what", "?"), 0) + 1
    worst = ", ".join(f"{k} ({v})" for k, v in sorted(top.items(), key=lambda x: -x[1])[:3])
    out = []
    if skipped:
        out.append("Skipped the morning plan: " + "; ".join(e.get("reason", "no reason") for e in skipped)[:120])
    if not ends:
        out.insert(0, "Recap: no sessions today. Tomorrow, start with one 25-minute session. That's it.")
        return "\n".join(out)
    out.insert(0, f"Recap: {focused // 60}h {focused % 60}m focused · {len(kept)} kept, {len(early)} ended early.")
    if kept:
        out.append("Finished: " + ", ".join(sorted({e.get("task") or e["name"] for e in kept}))[:160])
    if worst:
        out.append("Biggest pulls: " + worst)
    if passes or quits:
        out.append(", ".join(x for x in [f"{len(passes)} pass{'es' if len(passes) != 1 else ''}" if passes else "",
                                         f"quit lockin mid-session {len(quits)}x" if quits else ""] if x))
    todos = load_todos()
    if todos:
        out.append(f"Plan: {sum(bool(t.get('done')) for t in todos)}/{len(todos)} done")
    return "\n".join(out)


if __name__ == "__main__":
    cmd = (sys.argv[1:] or ["plan"])[0]
    day = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] in ("today", "tomorrow") else "today"
    if cmd == "todos":
        try:
            print(json.dumps(todos_from_ai(sys.stdin.read(), day)))
        except Exception as e:  # reported back to the planner window
            print(json.dumps({"error": str(e)[:200]}))
    elif cmd == "prompt":     # Apple Intelligence runs in the app: hand it the prompt...
        try:
            print(json.dumps({"prompt": plan_context(sys.stdin.read(), day)["prompt"]}))
        except Exception as e:
            print(json.dumps({"error": str(e)[:200]}))
    elif cmd == "apply":      # ...then take its answer back: {"text": what they typed, "result": the model's JSON}
        try:
            payload = json.loads(sys.stdin.read() or "{}")
            text = str(payload.get("text") or "")
            print(json.dumps(apply_plan(plan_context(text, day), text, payload.get("result"))))
        except Exception as e:
            print(json.dumps({"error": str(e)[:200]}))
    elif cmd == "slot":
        mins = int(sys.argv[2]) if len(sys.argv) > 2 else 45
        print(json.dumps({"start": soonest_slot(mins, sys.argv[3] if len(sys.argv) > 3 else None)}))
    elif cmd == "test":
        provider, model, _, _ = ai.settings(load_config())
        try:
            ok = ai.ask_json(load_config(), "Reply with ok set to true.", {"type": "object", "properties": {"ok": {"type": "boolean"}},
                                                                     "required": ["ok"], "additionalProperties": False})
            print(json.dumps({"ok": bool(ok.get("ok")), "provider": provider, "model": model}))
        except Exception as e:
            print(json.dumps({"ok": False, "provider": provider, "model": model, "error": str(e)[:200]}))
    else:
        print(plan() if cmd == "plan" else recap())
