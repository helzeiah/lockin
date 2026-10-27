#!/usr/bin/env python3
"""Helper for the Focus app: morning plan text, nightly recap, open time slots, and the AI day planner.
    coach.py plan         -> today's suggested focus: classes, to-dos, deadlines
    coach.py recap        -> today's focus stats from log.jsonl
    coach.py slot MINUTES -> the soonest start (HH:MM) that fits around the calendar and what's already planned (no AI)
    coach.py todos        -> a message on stdin ("dump", "finished X", "free at 8 now") -> the AI creates/edits todos.json
    coach.py test         -> checks the AI set up in Settings > AI planner
Data lives in $FOCUS_DATA (the app sets it to ~/Library/Application Support/Focus), else next to this file.
"""
import datetime as dt
import json
import os
import sqlite3
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


def load_config():
    try:
        return json.loads(CONFIG.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def integration(name):
    """Optional local files from other tools (config "integrations"), e.g. a job tracker's SQLite deadlines."""
    p = (load_config().get("integrations") or {}).get(name)
    return Path(p).expanduser() if p else None


JOBS_DB = integration("job_tracker_db")
OA_ATTEMPTS = integration("oa_attempts")


BACKLOG_DAYS = 7


def rollover(doc):
    """New day: unfinished to-dos move to the backlog (shown in the planner, never nudged about); today starts empty."""
    today = dt.date.today().isoformat()
    if doc.get("date") and doc["date"] != today:
        back = {b["task"].lower(): b for b in doc.get("backlog", [])}
        for t in doc.get("items", []):
            if not t.get("done"):
                back[t["task"].lower()] = dict(t, start="", why="", **{"from": doc["date"]})
        cutoff = (dt.date.today() - dt.timedelta(days=BACKLOG_DAYS)).isoformat()
        doc = {"date": today, "items": [], "chat": [],
               "backlog": sorted((b for b in back.values() if b.get("from", today) >= cutoff), key=lambda b: b["from"], reverse=True)}
    doc.setdefault("date", today)
    doc.setdefault("backlog", [])
    return doc


def load_doc():
    try:
        d = json.loads(TODOS.read_text())
    except (OSError, json.JSONDecodeError):
        d = {}
    new = rollover(d)
    if new is not d and TODOS.exists():
        TODOS.write_text(json.dumps(new, indent=1))
    return new


def load_todos():
    return load_doc().get("items", [])


def deadlines(days=7):
    if not JOBS_DB or not JOBS_DB.exists():
        return []
    now = dt.datetime.now()
    db = sqlite3.connect(JOBS_DB)
    return db.execute(
        "SELECT j.company, t.title, t.due FROM tasks t JOIN jobs j ON j.id=t.job_id WHERE t.done=0 "
        "AND t.kind IN ('assessment','interview','offer') AND t.due>=? AND t.due<=? ORDER BY t.due",
        (now.isoformat(timespec="minutes"), (now + dt.timedelta(days=days)).isoformat(timespec="minutes"))).fetchall()


CALEVENTS = Path(os.environ.get("FOCUS_CALEVENTS") or ROOT / "bin" / "calevents")
FIXED_HINTS = ("room", "class", "lecture", "lab", "exam", "midterm", "gym", "meeting", "interview", "appointment")


def calendar_today():
    """Today's events from macOS Calendar: [(start, end, title, is_class_or_fixed)]."""
    if not CALEVENTS.exists():
        return []
    try:
        out = subprocess.run([str(CALEVENTS), "1"], capture_output=True, text=True, timeout=20).stdout
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
        fixed = any(h in e["title"].lower() for h in FIXED_HINTS) or "|" in e["title"]
        res.append((st, en, e["title"], fixed))
    return sorted(res)


def free_windows(events, day_end, min_minutes=20):
    """Gaps from now until day_end not covered by fixed events (classes, gym...)."""
    t = dt.datetime.now().replace(second=0, microsecond=0)
    t += dt.timedelta(minutes=(5 - t.minute % 5) % 5)
    out = []
    for st, en, _, fixed in events:
        if not fixed or en <= t:
            continue
        if st > t:
            out.append((t, min(st, day_end)))
        t = max(t, en)
    if t < day_end:
        out.append((t, day_end))
    return [(a, b) for a, b in out if (b - a).total_seconds() >= min_minutes * 60]


def day_end_time(cfg):
    eh, em = map(int, cfg.get("day_end", "23:30").split(":"))
    return dt.datetime.now().replace(hour=eh, minute=em, second=0, microsecond=0)


def soonest_slot(minutes, skip=None):
    """Earliest start today for a `minutes`-long block: not before now, not overlapping fixed calendar events or
    to-dos that already have a time (5 min break after each). Returns "HH:MM", or "" if nothing fits today."""
    cfg = load_config()
    day_end = day_end_time(cfg)
    busy = [(a, b) for a, b, _, fixed in calendar_today() if fixed]
    today = dt.date.today()
    for t in load_todos():
        if t.get("done") or t.get("id") == skip or len(t.get("start") or "") < 4:
            continue
        h, m = map(int, t["start"].split(":"))
        a = dt.datetime.combine(today, dt.time(h, m))
        busy.append((a, a + dt.timedelta(minutes=t["minutes"] + 5)))
    need = dt.timedelta(minutes=minutes)
    for a, b in free_windows([(a, b, "", True) for a, b in sorted(busy)], day_end, min_minutes=minutes):
        if b - a >= need:
            return f"{a:%H:%M}"
    return ""


def todos_from_claude(text):
    """Conversational planner: creates today's plan from a dump, or edits the current plan from a message like
    "finished the stats hw", "free at 8 now", "add laundry", "push blockpilot to tomorrow"."""
    cfgj = load_config()
    blocks = [b["name"] for b in cfgj["blocks"]]
    doc = load_doc()
    today = dt.date.today().isoformat()
    items = doc.get("items", [])
    chat = doc.get("chat", [])
    backlog = doc.get("backlog", [])
    dl = "\n".join(f"- {c}: {t} (due {d})" for c, t, d in deadlines(10)) or "none"
    day_end = day_end_time(cfgj)
    events = calendar_today()
    cal = "\n".join(f"- {a:%H:%M}-{b:%H:%M} {t}" + ("" if f else "  (their own planned work session)")
                    for a, b, t, f in events) or "none"
    free = ", ".join(f"{a:%H:%M}-{b:%H:%M}" for a, b in free_windows(events, day_end)) or "none left today"
    current = [{"ref": t["id"], "task": t["task"], "block": t["block"], "minutes": t["minutes"],
                "start": t.get("start", ""), "done": bool(t.get("done"))} for t in items]
    history = "\n".join(f"{m['role']}: {m['text']}" for m in chat[-8:]) or "none"
    back = [{"ref": b["id"], "task": b["task"], "block": b["block"], "minutes": b["minutes"], "from": b.get("from")} for b in backlog]
    item = {"type": "object", "properties": {
        "ref": {"type": "string", "description": "the existing item's ref, or \"new\""},
        "task": {"type": "string"}, "block": {"type": "string", "enum": blocks}, "minutes": {"type": "integer"},
        "start": {"type": "string", "description": "24h HH:MM start today; empty if done or it doesn't fit today"},
        "done": {"type": "boolean"}, "why": {"type": "string"}},
        "required": ["ref", "task", "block", "minutes", "start", "done", "why"], "additionalProperties": False}
    schema = {"type": "object", "properties": {"items": {"type": "array", "items": item},
              "reply": {"type": "string", "description": "one short sentence telling the user what you changed"}},
              "required": ["items", "reply"], "additionalProperties": False}
    about = (cfgj.get("about_me") or "").strip() or "no details given"
    dl_section = f"Upcoming deadlines from their tracker:\n{dl}\n" if JOBS_DB else ""
    prompt = f"""You are the day planner inside a focus app. About the user: {about}
They talk to you about their day; you return the whole updated plan plus a one-sentence reply.

How to update:
- If there is no current plan, build one from their message. Otherwise EDIT the current plan to match what they say:
  mark things done ("I did X", "finished X"), add new tasks, remove or postpone ones he drops, change durations,
  and re-time everything when their availability changes ("free at 8 now", "only an hour left", "class ran late").
- Keep each existing item's "ref"; use "new" for added items. Keep done items in the list with done=true, start "".
- BACKLOG = unfinished items from earlier days. Do NOT add them on your own. Only if their message asks for one
  ("bring back X", "add my backlog", "add from backlog: X") include it, using its backlog "ref".
- One concrete action per item ("Write the intro section of the essay"). Chunks of 25-90 minutes.
- Order unfinished items by urgency (hard deadlines first), then importance; make the first one easy to start.
- "block" = best-matching focus mode from: {", ".join(blocks)}. "why": at most 8 words.
- SCHEDULE unfinished items: a 24h HH:MM "start" today, back to back with ~5 min breaks, inside their free windows,
  never overlapping classes/gym/fixed events, never before now. Timing they state always wins. If it doesn't fit
  before {day_end:%H:%M}, start "" and why "doesn't fit today" (or "tomorrow" if they postponed it).
- reply: plain and specific, e.g. "Marked stats homework done and moved everything after 8 PM." No fluff.

Now: {dt.datetime.now():%A %B %d, %H:%M}. Day ends around {day_end:%H:%M}.
Today's calendar:
{cal}
Free windows left today: {free}
{dl_section}
Current plan: {json.dumps(current)}
Backlog (not part of today unless he asks): {json.dumps(back)}
Earlier today: {history}

Their message:
{text}"""
    res = ai.ask_json(cfgj, prompt, schema)
    known = {t["id"] for t in items} | {b["id"] for b in backlog}
    new_items = []
    for it in res["items"]:
        ref = it.pop("ref", "new")
        it["id"] = ref if ref in known else uuid.uuid4().hex[:8]
        new_items.append(it)
    chat = (chat + [{"role": "user", "text": text}, {"role": "planner", "text": res["reply"]}])[-12:]
    if TODOS.exists():  # keep the previous version, in case an edit goes wrong
        (DATA / "todos.prev.json").write_text(TODOS.read_text())
    used = {it["id"] for it in new_items}
    backlog = [b for b in backlog if b["id"] not in used]
    TODOS.write_text(json.dumps({"date": today, "items": new_items, "chat": chat, "backlog": backlog}, indent=1))
    return {"items": new_items, "reply": res["reply"]}


def today_events(day=None):
    day = day or dt.date.today().isoformat()
    if not LOG.exists():
        return []
    return [e for e in (json.loads(l) for l in LOG.read_text().splitlines() if l.strip()) if e["ts"].startswith(day)]


def plan():
    now = dt.datetime.now()
    lines = []
    left = [(a, b, t) for a, b, t, f in calendar_today() if f and b > now]
    if left:
        lines.append("• Classes: " + ", ".join(f"{t.split('|')[0].strip()} {a:%-I:%M}" for a, b, t in left[:4]))
    open_todos = [t for t in load_todos() if not t.get("done")]
    for t in open_todos[:3]:
        lines.append(f"• {t['task']} ({t['minutes']} min)")
    if JOBS_DB and JOBS_DB.exists():
        db = sqlite3.connect(JOBS_DB)
        for company, title, due in deadlines():
            d = dt.datetime.fromisoformat(due)
            days = (d.date() - now.date()).days
            when = "TODAY" if days == 0 else "tomorrow" if days == 1 else f"in {days} days ({d:%a})"
            lines.append(f"• {company}: {title.replace(company, '').strip() or 'assessment'} due {when}")
        n = db.execute("SELECT COUNT(DISTINCT q.job_id) FROM questions q JOIN jobs j ON j.id=q.job_id "
                       "WHERE q.answer='' AND j.status='needs_answers'").fetchone()[0]
        if n:
            lines.append(f"• {n} applications waiting on your written answers (tracker > Write answers)")
    if OA_ATTEMPTS and OA_ATTEMPTS.exists():
        cutoff = (now - dt.timedelta(days=1)).timestamp()
        practiced = sum(1 for l in OA_ATTEMPTS.read_text().splitlines() if l.strip() and json.loads(l)["at"] > cutoff)
        lines.append("• LeetCode: 2 problems on the OA practice site" + ("" if practiced else " (none in the last day)"))
    if not lines:
        return "Today's plan\nNothing planned yet. Open Plan my day and add your first block."
    first = "Start with what's due soonest" if any("due TODAY" in l or "due tomorrow" in l for l in lines) else "Start with your hardest block"
    tip = "" if open_todos else "\nNo to-dos yet: open Plan my day and add them."
    when = " while you're fresh" if now.hour < 12 else ""
    return "Today's plan\n" + "\n".join(lines[:7]) + f"\n\n{first}{when}." + tip


def recap():
    ev = today_events()
    blocks = [e for e in ev if e["type"] == "block_end"]
    focused = sum(e.get("focused_min", 0) for e in blocks)
    drifts = [e for e in ev if e["type"] == "drift"]
    done = sorted({e["name"] for e in blocks if e.get("completed")})
    quit_ = sorted({e["name"] for e in blocks if not e.get("completed")})
    top = {}
    for d in drifts:
        top[d.get("what", "?")] = top.get(d.get("what", "?"), 0) + 1
    worst = ", ".join(f"{k} ({v})" for k, v in sorted(top.items(), key=lambda x: -x[1])[:3])
    if not blocks:
        return "Recap: no focus blocks today. Tomorrow, start with one 25-minute block. That's it."
    out = [f"Recap: {focused // 60}h {focused % 60}m focused in {len(blocks)} block(s), {len(drifts)} drift(s)."]
    if done:
        out.append("Finished: " + ", ".join(done))
    if quit_:
        out.append("Stopped early: " + ", ".join(quit_))
    if worst:
        out.append("Biggest pulls: " + worst)
    todos = load_todos()
    if todos:
        out.append(f"To-dos: {sum(t.get('done', False) for t in todos)}/{len(todos)} done")
    return "\n".join(out)


if __name__ == "__main__":
    cmd = (sys.argv[1:] or ["plan"])[0]
    if cmd == "todos":
        try:
            print(json.dumps(todos_from_claude(sys.stdin.read())))
        except Exception as e:  # reported back to the planner window
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
