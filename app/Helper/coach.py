#!/usr/bin/env python3
"""Helper for the lockin app: morning plan text, nightly recap, open time slots, and the AI day planner.
    coach.py plan                 -> today's plan: calendar events and sessions, plus lines from extras.py
    coach.py recap                -> today's focus and accountability record from log.jsonl
    coach.py slot MINUTES [SKIP]  -> the soonest start (HH:MM) around the calendar and what's already planned (no AI)
    coach.py todos [today|tomorrow] -> a message on stdin ("dump", "finished X", "free at 8 now") -> the AI edits that day
    coach.py questions TASK_ID    -> up to 3 questions the AI would ask about a to-do list task, to plan it well
    coach.py steps TASK_ID        -> a to-do list task broken into 5-10 minute steps, for a small-commitment day
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
TASKS = DATA / "tasks.json"     # the running to-do list (the app writes it; read-only here)
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


def load_tasks():
    """The running to-do list, open tasks only, most urgent first (overdue, due today, starred, due soon, the rest)."""
    try:
        tasks = json.loads(TASKS.read_text()).get("tasks", [])
    except (OSError, json.JSONDecodeError, AttributeError):
        return []
    today = plan_date()

    def key(t):
        try:
            n = (dt.date.fromisoformat(t["due"]) - today).days if t.get("due") else None
        except ValueError:
            n = None
        tier = 0 if n is not None and n < 0 else 1 if n == 0 else 2 if t.get("starred") else 3 if n is not None and n <= 3 else 4
        return (tier, n if n is not None else 10**6, t.get("created") or "")
    return sorted([t for t in tasks if isinstance(t, dict) and not t.get("done") and t.get("id") and t.get("title")], key=key)


def task_line(t):
    """A list task for the AI: its ref, title, due date, length, star and what you've said about it."""
    out = {"ref": "L:" + t["id"], "task": t["title"]}
    if t.get("due"):
        out["due"] = t["due"]
    if t.get("minutes"):
        out["minutes"] = t["minutes"]
    if t.get("starred"):
        out["starred"] = True
    if t.get("effort") in (1, 2, 3):
        out["difficulty"] = {1: "easy", 2: "medium", 3: "hard"}[t["effort"]]
    notes = [t.get("notes") or "", ("First step: " + t["first_step"]) if t.get("first_step") else ""]
    notes += [f'{qa.get("q", "")} {qa.get("a", "")}' for qa in t.get("qa") or [] if isinstance(qa, dict)]
    notes = " · ".join(n for n in notes if n)
    if notes:
        out["notes"] = notes[:400]
    return out


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


def day_end_time(cfg, day=None, shape=None):
    """When work stops that day: the finish time you gave for it, else the day_end setting."""
    end = (shape or {}).get("finish") or cfg.get("day_end") or "23:30"
    try:
        eh, em = map(int, end.split(":"))
    except ValueError:
        eh, em = 23, 30
    day = day or dt.date.today()
    return dt.datetime.combine(day, dt.time(eh, em))


def day_shape(doc, tomorrow=False):
    """The breaks and finish time you gave for the day when you planned it ({} if you weren't asked yet)."""
    s = doc.get("tomorrow_shape" if tomorrow else "shape")
    return s if isinstance(s, dict) else {}


def break_times(shape, day):
    """Your longer breaks that day as (start, end), kept free like calendar events."""
    out = []
    for b in shape.get("breaks") or []:
        try:
            h, m = map(int, str(b.get("start", "")).split(":"))
            a = dt.datetime.combine(day, dt.time(h, m))
            out.append((a, a + dt.timedelta(minutes=int(b.get("minutes", 0)))))
        except (ValueError, TypeError, AttributeError):
            continue
    return out


def break_after(cfg, minutes):
    """The break after a session this long: its length ÷ break_ratio (3-6), or the fixed break_minutes when that's 0.
    Configs from before break_ratio keep a break length changed by hand (the same rule as the app)."""
    fixed = int(cfg.get("break_minutes") or 5)
    ratio = cfg.get("break_ratio")
    if ratio is None:
        ratio = 5 if fixed == 5 else 0
    try:
        ratio = int(ratio)
    except (TypeError, ValueError):
        ratio = 5
    return max(1, round(minutes / ratio)) if ratio > 0 else max(1, fixed)


def busy_from(items, day, cfg=None):
    """(start, end) of to-dos that already have a time, plus the break after each."""
    cfg = cfg if cfg is not None else load_config()
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
        out.append((a, a + dt.timedelta(minutes=left + break_after(cfg, left))))
    return out


def soonest_slot(minutes, skip=None):
    """Earliest start today for a `minutes`-long session: not before now, not overlapping calendar events or
    to-dos that already have a time. Returns "HH:MM", or "" if nothing fits today."""
    cfg = load_config()
    today = dt.date.today()
    doc = load_doc()
    shape = day_shape(doc)
    busy = ([(a, b) for a, b, _ in calendar_events()] + break_times(shape, today)
            + busy_from([t for t in doc["items"] if t.get("id") != skip], today, cfg))
    need = dt.timedelta(minutes=minutes)
    for a, b in free_windows(busy, dt.datetime.now(), day_end_time(cfg, today, shape), min_minutes=minutes):
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
    shape = day_shape(doc, tomorrow)
    day_end = day_end_time(cfgj, pdate, shape)
    events = calendar_events(1 if tomorrow else 0)
    breaks = break_times(shape, pdate)
    cal = "\n".join(f"- {a:%H:%M}-{b:%H:%M} {t}" for a, b, t in events) or "none"
    brk = ", ".join(f"{a:%H:%M}-{b:%H:%M}" for a, b in breaks) or "none"
    first_hour = (cfgj.get("active_hours") or [8, 23])[0]
    start_from = dt.datetime.combine(pdate, dt.time(first_hour)) if tomorrow else dt.datetime.now()
    free = ", ".join(f"{a:%H:%M}-{b:%H:%M}" for a, b in free_windows([(a, b) for a, b, _ in events] + breaks, start_from, day_end)) or "none left"
    current = [{"ref": t["id"], "task": t["task"], "minutes": t["minutes"], "start": t.get("start", ""), "done": bool(t.get("done")),
                "minutes_already_worked": t.get("spent", 0)} for t in items]
    history = "\n".join(f"{m['role']}: {m['text']}" for m in chat[-8:]) if not tomorrow else ""
    back = [{"ref": b["id"], "task": b["task"], "minutes": b["minutes"], "from": b.get("from")} for b in backlog]
    planned = {t.get("task_id") for t in items if t.get("task_id")}
    todo_list = [task_line(t) for t in load_tasks() if t["id"] not in planned][:30]
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
    level = shape.get("level")
    sizes = {"small": "5-10", "medium": "25-45", "large": "60-90"}
    level_rule = {
        "small": "Starting feels hard today. Break every task into tiny, concrete 5-10 minute steps, each one simple enough to start without thinking (\"open the doc and write the first heading\"), one item per step.",
        "medium": "A normal day. Sessions of 25-45 minutes; split longer tasks into pieces that size.",
        "large": "They have room for deep work today. Long unbroken blocks of 60-90 minutes; split anything longer into blocks that size, and don't chop shorter work into small bits.",
    }.get(level, "")
    breaks_rule = f"{break_after(cfgj, 30)} min after a 30-minute one, {break_after(cfgj, 90)} min after 90 minutes"
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
- TO-DO LIST = their running list of everything they need to do (refs start with "L:"). When they ask you to plan
  the day, fill free time, or "what should I do", pull from it: overdue and due-soon first, then starred. Add one
  using its "L:" ref, its title as the task, and its minutes if it has them; use its notes to size and order it.
  For a narrow edit ("done X", "free at 8") leave the list alone.
- One concrete action per item ("Write the intro section of the essay"). {("Chunks of " + sizes[level] + " minutes.") if level in sizes else "Chunks of 25-90 minutes."}
{("- COMMITMENT TODAY: " + level_rule + chr(10)) if level_rule else ""}- Order unfinished items hardest first while they're fresh: most time-sensitive (overdue, due today, then tomorrow),
  then the hardest (list "difficulty", else the longest), then the longest. Easier, lower-stress items go later in the day.
- "why": at most 8 words.
- SCHEDULE unfinished items: a 24h HH:MM "start", back to back with a break after each ({breaks_rule}), inside the free windows,
  never overlapping calendar events or their breaks{"" if tomorrow else ", never before now"}. Timing they state always wins.
  They finish work at {day_end:%H:%M}: nothing may run past it. If it doesn't fit, start "" and why "doesn't fit".
- reply: plain and specific, e.g. "Marked stats homework done and moved everything after 8 PM." No fluff.

Now: {dt.datetime.now():%A %B %d, %H:%M}. Planning {which}. The day ends around {day_end:%H:%M}.
Calendar that day:
{cal}
Their longer breaks (keep free): {brk}
Free windows: {free}
{("Notes from their own tools:" + chr(10) + notes + chr(10)) if notes else ""}
Current plan: {json.dumps(current)}
Backlog (not part of the plan unless they ask): {json.dumps(back)}
To-do list (not on the plan yet): {json.dumps(todo_list)}
{("Earlier today: " + history) if history else ""}

Their message:
{text[:4000]}"""
    return {"cfg": cfgj, "prompt": prompt, "schema": schema, "doc": doc, "items": items, "backlog": backlog, "chat": chat, "tomorrow": tomorrow}


def questions_context(task_id):
    """The prompt for the AI's questions about one to-do list task, and the answer's schema."""
    cfg = load_config()
    try:
        tasks = json.loads(TASKS.read_text()).get("tasks", [])
    except (OSError, json.JSONDecodeError, AttributeError):
        tasks = []
    t = next((x for x in tasks if isinstance(x, dict) and x.get("id") == task_id), None)
    if not t:
        raise ai.AIError("that task isn't on the list")
    about = (cfg.get("about_me") or "").strip() or "no details given"
    schema = {"type": "object", "properties": {"questions": {"type": "array", "items": {"type": "string"},
              "description": "0 to 3 short questions"}}, "required": ["questions"], "additionalProperties": False}
    prompt = f"""You help someone plan a task from their to-do list inside a focus app. About them: {about}
Ask at most 3 short questions whose answers would change how this task gets planned: what exactly is involved or
how big it is, what it depends on or who it's waiting on, what "done" looks like, or a deadline detail that isn't clear.
Don't ask what they've already said below. Don't ask when it's due or how long it takes unless it's still unclear.
Each question under 15 words, plain and specific to this task. If the task is already clear, return no questions.

Task: {t.get("title", "")}
What they've said about it: {json.dumps(task_line(t))}
Today: {plan_date():%A %B %d}"""
    return {"cfg": cfg, "prompt": prompt, "schema": schema}


def questions_from_ai(task_id):
    ctx = questions_context(task_id)
    res = ai.ask_json(ctx["cfg"], ctx["prompt"], ctx["schema"])
    qs = res.get("questions") if isinstance(res, dict) else None
    if not isinstance(qs, list):
        raise ai.AIError("the AI's answer wasn't a list of questions")
    return [" ".join(str(q).split())[:160] for q in qs if str(q).strip()][:3]


def steps_context(task_id):
    """The prompt for breaking one to-do list task into 5-10 minute steps (a small-commitment day), and its schema.
    The answer uses the planner's item shape so Apple Intelligence can reuse the planner's fixed structure."""
    cfg = load_config()
    try:
        tasks = json.loads(TASKS.read_text()).get("tasks", [])
    except (OSError, json.JSONDecodeError, AttributeError):
        tasks = []
    t = next((x for x in tasks if isinstance(x, dict) and x.get("id") == task_id), None)
    if not t:
        raise ai.AIError("that task isn't on the list")
    total = int(t.get("minutes") or 45)
    step = {"type": "object", "properties": {"ref": {"type": "string"}, "task": {"type": "string"}, "minutes": {"type": "integer"},
            "start": {"type": "string"}, "done": {"type": "boolean"}, "why": {"type": "string"}},
            "required": ["ref", "task", "minutes", "start", "done", "why"], "additionalProperties": False}
    schema = {"type": "object", "properties": {"items": {"type": "array", "items": step}, "reply": {"type": "string"}},
              "required": ["items", "reply"], "additionalProperties": False}
    prompt = f"""Someone finds it hard to start anything today. Break this task from their to-do list into tiny steps they
can do one at a time: each one concrete, physical and simple enough to start without thinking ("open the problem set
PDF", "write 3 bullet points for the intro"), 5-10 minutes each, in the order they'd do them, about {total} minutes in all.
Return them as items: ref "new", the step as task, its minutes, start "", done false, why "". reply: "ok".

Task: {t.get("title", "")}
What they've said about it: {json.dumps(task_line(t))}"""
    return {"cfg": cfg, "prompt": prompt, "schema": schema}


def steps_from_ai(task_id):
    ctx = steps_context(task_id)
    res = ai.ask_json(ctx["cfg"], ctx["prompt"], ctx["schema"])
    items = res.get("items") if isinstance(res, dict) else None
    if not isinstance(items, list):
        raise ai.AIError("the AI's answer wasn't a list of steps")
    out = []
    for it in items[:24]:
        if not isinstance(it, dict):
            continue
        task = " ".join(str(it.get("task") or "").split())[:120]
        try:
            minutes = min(max(int(it.get("minutes") or 10), 5), 15)
        except (TypeError, ValueError):
            minutes = 10
        if task:
            out.append({"task": task, "minutes": minutes})
    return out


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
    listed = {"L:" + t["id"]: t for t in load_tasks()}
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
        if old:   # what the app knows about an item survives a re-plan: time worked, its apps, its rule, repeat, list task
            for k in ("spent", "apps", "block", "source", "ref", "task_id", "effort", "group", "whole", "part", "parts"):
                if old.get(k):
                    it[k] = old[k]
        elif ref in listed and ref not in used:   # pulled in from the to-do list
            it["task_id"] = listed[ref]["id"]
            if listed[ref].get("effort") in (1, 2, 3):
                it["effort"] = listed[ref]["effort"]
            used.add(ref)
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
    elif cmd in ("questions", "qprompt"):   # qprompt: Apple Intelligence runs in the app, so just the prompt
        try:
            tid = sys.argv[2] if len(sys.argv) > 2 else ""
            print(json.dumps({"questions": questions_from_ai(tid)} if cmd == "questions" else {"prompt": questions_context(tid)["prompt"]}))
        except Exception as e:
            print(json.dumps({"error": str(e)[:200]}))
    elif cmd in ("steps", "sprompt"):   # sprompt: Apple Intelligence runs in the app, so just the prompt
        try:
            tid = sys.argv[2] if len(sys.argv) > 2 else ""
            print(json.dumps({"steps": steps_from_ai(tid)} if cmd == "steps" else {"prompt": steps_context(tid)["prompt"]}))
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
