#!/usr/bin/env python3
"""Fill an empty Melete data folder with three weeks of made-up practice, for screenshots.

Everything is synthetic: the two daily clips are original text read by macOS voices, and the
"practice" takes are another voice reading short talks, getting a little faster and dropping
fillers over the three weeks. No real recordings or personal data are involved.

Needs macOS (`say`, `afconvert`) and an analysis server on the same data folder:

    export SPEECH_DATA_DIR=/tmp/melete-demo
    SPEECH_NO_DAILY=1 .venv/bin/python server.py &
    python3 .github/screenshots/seed.py --lang en --audio /tmp/melete-audio

`--audio` caches the synthesized speech, so seeding a second language reuses it.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

SERVER = os.environ.get("SPEECH_SERVER_URL", "http://127.0.0.1:8765")
DATA = Path(os.environ.get("SPEECH_DATA_DIR", "")).expanduser()
LANG = "en"

# ---------------------------------------------------------------- the material

STORY = (
    "It was a Thursday, a little after nine, when the revenue dashboard went blank. Not wrong. Blank. "
    "Every chart on the page was empty, and the quarterly review was at eight the next morning. "
    "My first instinct was to fix it fast. I opened the pipeline logs, I restarted the jobs, and I refreshed "
    "the page every thirty seconds, as if refreshing would help. It did not. So I stopped. "
    "I made a cup of tea, and I wrote three questions on a sticky note. What changed today? What still works? "
    "And who else would notice? The answers came quickly once I asked them. "
    "A vendor had renamed one column in their export. One column. Everything downstream trusted that name, "
    "so everything downstream quietly returned nothing. The fix took four minutes. Finding it took two hours, "
    "because I spent the first ninety minutes moving fast in the wrong direction. "
    "The next morning I opened the review with that story instead of the numbers, and people leaned in. "
    "Nobody remembers the charts from that meeting, but three teams added a check for renamed columns that same week. "
    "Here is what I took from that night. When something breaks, speed feels like progress. It usually is not. "
    "The fastest way through a crisis is to slow down for one minute, write the questions down, and only then start typing."
)

EXPLAIN = (
    "Here is a simple idea that changes how a team ships: make the batches smaller. "
    "When a change is large, three things happen. First, it waits. A big pull request sits in review for days, "
    "because nobody has a free afternoon to read it. Second, it hides problems. When forty files change at once, "
    "a bug in one of them is hard to see and harder to trace. Third, it is scary to release, so it gets released "
    "less often, which makes the next batch even bigger. Small batches reverse all three. "
    "A small change gets reviewed the same day, because it takes ten minutes to read. When it breaks something, "
    "you know exactly where to look, because only one thing moved. And because each release is boring, you release "
    "more often, and each release stays small. There is a cost, of course. You need fast tests, a way to hide "
    "unfinished work behind a flag, and the discipline to split a feature into pieces that make sense on their own. "
    "But the payoff compounds. Teams that ship in small batches argue less, sleep better before a launch, and learn "
    "from real users weeks earlier. So the next time a task feels too big to start, do not ask how to finish it. "
    "Ask what the smallest useful piece is, and ship that first."
)

RETELL = (
    "The main idea is that smaller batches help a team ship faster. Big changes wait in review because nobody has "
    "time to read them. They hide bugs, and they feel risky to release, so the team releases less often and the next "
    "batch gets even bigger. Small changes get reviewed the same day, and when something breaks you know where to look. "
    "The cost is that you need fast tests and feature flags, and you have to split features into small pieces. "
    "But it compounds, and you learn from real users much earlier. So start with the smallest useful piece."
)

# Answers to generic prompts from coach.PROMPTS (nothing tied to a real person or company).
TALKS = {
    "weekly-update": (
        "Quick update from the data team. This week we shipped the new usage dashboard, and finance is already "
        "using it for the monthly close. What is blocked is the CRM sync. The vendor only sends full exports, so "
        "every run takes four hours. What I need from you is a decision by Friday. Either we accept a daily sync for "
        "now, or we spend two weeks building an incremental loader. My recommendation is the daily sync, and we "
        "revisit it next quarter."
    ),
    "build-or-buy": (
        "I would buy, not build. Reverse ETL looks simple, but the hard part is not moving rows. It is retries, rate "
        "limits, schema changes, and the alert when something fails at two in the morning. A vendor has already paid "
        "for those lessons. Building it would take one engineer about a quarter, and then we would own it forever. "
        "The trade-off is cost and control. We pay a subscription, and we wait on their roadmap for edge cases. "
        "For a team our size, that is the right trade."
    ),
    "one-semantic-layer": (
        "Yes, every shared metric should live in one semantic layer. Right now revenue has three definitions, and "
        "each one is correct for the team that wrote it. That is the problem. When leadership asks a simple question, "
        "we spend a day explaining why the numbers differ instead of answering it. One layer does not mean one team "
        "owns everything. It means one definition, reviewed in one place, and every tool reads from it. Teams can "
        "still explore. They just start from the same truth."
    ),
    "lead-without-authority": (
        "Last spring I led a migration across four teams, and none of them reported to me. The first thing I wrote "
        "was not a plan. It was one page on what each team would get out of it: faster builds for one, fewer pages at "
        "night for another. Then I asked each lead to pick their own deadline inside a six week window. Every team "
        "finished, and one finished early, because the deadline was theirs. You cannot borrow authority, but you can "
        "make the work worth choosing."
    ),
}
# Today's impromptu prompt: the result screen is labelled as an update, so the plan is
# reshuffled until it offers this one.
TODAY_PROMPT = "weekly-update"

TEXT = {
    # Daily clips keep their video's English title in both languages, as real ones do.
    "story_title": {"en": "The night the dashboard went dark", "zh": "The night the dashboard went dark"},
    "explain_title": {"en": "Why small batches ship faster", "zh": "Why small batches ship faster"},
    "speaker": {"en": "Melete sample talk", "zh": "Melete 示例演讲"},
    "story_notes": {
        "en": "One calm story with a single turn: listen for how the pace drops right before \"So I stopped.\"\n"
              "· Pause after each of the three questions.\n· Lean on \"one column\" both times.",
        "zh": "一个平静的故事，中间只有一个转折：听他在 “So I stopped.” 之前怎么把语速降下来。\n"
              "· 三个问题之间各停一下。\n· 两次 “one column” 都要重读。",
    },
    "explain_notes": {
        "en": "A clear three-part argument: problem, reversal, cost.\n"
              "· Count the three problems on your fingers as you retell.\n· End on the one-line takeaway.",
        "zh": "结构清楚的三段论证：问题、反转、代价。\n"
              "· 复述时用手指数出三个问题。\n· 最后落在那一句结论上。",
    },
    "event": {"en": "Architecture review: event pipeline", "zh": "架构评审：事件管道"},
    "shadow": {"en": "Shadow · {}", "zh": "跟读 · {}"},
    "retell": {"en": "Retell · {}", "zh": "复述 · {}"},
    "impromptu": {"en": "Impromptu: {}", "zh": "即兴：{}"},
}


def tr(key: str) -> str:
    return TEXT[key][LANG]


# Three weeks of practice, oldest first: (days ago, kind, prompt id). Some days are skipped,
# as in real life; yesterday and today are not, so the streak is alive.
SCHEDULE = [
    (20, "impromptu", "one-semantic-layer"),
    (19, "shadow", None),
    (18, "impromptu", "build-or-buy"),
    (16, "retell", None),
    (15, "impromptu", "weekly-update"),
    (13, "shadow", None),
    (13, "impromptu", "lead-without-authority"),
    (12, "retell", None),
    (11, "impromptu", "one-semantic-layer"),
    (9, "shadow", None),
    (8, "impromptu", "build-or-buy"),
    (7, "retell", None),
    (5, "impromptu", "lead-without-authority"),
    (4, "shadow", None),
    (3, "impromptu", "weekly-update"),
    (2, "retell", None),
    (1, "impromptu", "one-semantic-layer"),
    (0, "shadow", None),
    (0, "impromptu", None),   # today's prompt, whichever the plan shows
]

# ---------------------------------------------------------------- helpers


def log(msg: str) -> None:
    print(f"[seed {LANG}] {msg}", flush=True)


def request(method: str, path: str, body: dict | None = None, form: dict | None = None,
            file: Path | None = None, timeout: float = 900) -> dict:
    headers = {"X-Melete-Lang": LANG}
    data = None
    if form is not None or file is not None:
        boundary = "----melete" + uuid.uuid4().hex
        parts = []
        for k, v in (form or {}).items():
            parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
        if file is not None:
            parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"{file.name}\"\r\n"
                         "Content-Type: application/octet-stream\r\n\r\n".encode() + file.read_bytes() + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        data = b"".join(parts)
        headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(SERVER + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed: {e.code} {e.read().decode(errors='replace')[:500]}")


def wait_for_server(limit: float = 1200) -> None:
    start = time.time()
    while time.time() - start < limit:
        try:
            cfg = request("GET", "/api/config", timeout=5)
            if cfg.get("model_loaded"):
                log(f"server ready, model {cfg.get('model')} loaded after {time.time() - start:.0f} s")
                return
        except (urllib.error.URLError, ConnectionError, OSError, SystemExit):
            pass
        time.sleep(3)
    sys.exit("the analysis server did not become ready")


def english_voices() -> list[str]:
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    voices = []
    for line in out.splitlines():
        m = re.match(r"^(.+?)\s+(en_[A-Z]{2})\s+#", line)
        if m:
            voices.append(m.group(1).strip())
    return voices


def pick_voice(available: list[str], preferred: list[str], avoid: set[str]) -> str:
    for v in preferred:
        if v in available and v not in avoid:
            return v
    rest = [v for v in available if v not in avoid]
    if not rest:
        sys.exit("no English text-to-speech voice is installed")
    return rest[0]


def speak(text: str, voice: str, rate: int, out: Path) -> Path:
    """Synthesize `text` to an AAC .m4a file (cached)."""
    if out.exists():
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    txt, aiff = out.with_suffix(".txt"), out.with_suffix(".aiff")
    txt.write_text(text)
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(aiff), "-f", str(txt)], check=True)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(aiff), str(out)], check=True)
    aiff.unlink()
    txt.unlink()
    return out


def with_fillers(text: str, p: float, rnd: random.Random) -> str:
    """Sprinkle hesitations into a talk; p is roughly the share of sentences that get one."""
    out = []
    for s in re.split(r"(?<=[.!?])\s+", text):
        r = rnd.random()
        if r < p * 0.6:
            s = rnd.choice(["Um, ", "Uh, ", "So, um, ", "Basically, "]) + s
        elif r < p:
            words = s.split()
            if len(words) > 6:
                k = rnd.randint(2, len(words) - 3)
                words.insert(k, rnd.choice(["like,", "you know,", "um,", "I mean,"]))
                s = " ".join(words)
        out.append(s)
    return " ".join(out)


def stamp_session(sid: str, when: datetime) -> None:
    f = DATA / "sessions" / sid / "session.json"
    s = json.loads(f.read_text())
    s["created_at"] = when.isoformat(timespec="seconds")
    if s.get("drill"):
        s["drill"]["date"] = when.date().isoformat()
    f.write_text(json.dumps(s, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- seeding


def make_clip(title: str, notes: str, text: str, audio: Path, role: str, wpm_hint: int) -> str:
    p = request("POST", "/api/practices", {"title": title, "script": "", "scenario": "presentation",
                                           "notes": notes, "kind": "clip"})
    pid = p["id"]
    request("POST", f"/api/practices/{pid}/reference", form={"transcript": text, "language": "en"}, file=audio)
    f = DATA / "practices" / pid / "practice.json"
    pj = json.loads(f.read_text())
    pj["script"] = text
    pj["clip"] = {"date": date.today().isoformat(), "role": role, "source_id": "local", "video_id": None,
                  "video_title": title, "channel": tr("speaker"), "start": 0.0, "end": None, "url": None,
                  "picked_by": "heuristic", "wpm": wpm_hint}
    f.write_text(json.dumps(pj, ensure_ascii=False, indent=1))
    log(f"clip {role}: {title} ({pid})")
    return pid


def main() -> None:
    global LANG
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lang", choices=["en", "zh"], default="en")
    ap.add_argument("--audio", required=True, help="folder that caches the synthesized speech")
    args = ap.parse_args()
    LANG = args.lang
    if not DATA.name:
        sys.exit("set SPEECH_DATA_DIR to the server's data folder")
    cache = Path(args.audio)
    today = date.today()

    wait_for_server()

    # A pace-and-volume week (week 2 of Τάχος), so the plan has a clip to shadow, one to retell
    # and an impromptu prompt.
    monday = today - timedelta(days=today.weekday())
    request("PUT", "/api/settings", {"coach": {"cycle_start": (monday - timedelta(days=7)).isoformat(),
                                               "week_target_days": 5},
                                     "daily": {"enabled": True, "clips_per_day": 2},
                                     "ui": {"language": LANG}})

    voices = english_voices()
    log(f"English voices: {', '.join(voices) or 'none'}")
    you = pick_voice(voices, ["Samantha", "Allison", "Ava", "Susan", "Victoria"], set())
    narrator = pick_voice(voices, ["Daniel", "Arthur", "Oliver", "Tom", "Alex", "Fred"], {you})
    explainer = pick_voice(voices, ["Karen", "Moira", "Tessa", "Kate", "Serena", "Fiona"], {you, narrator})
    log(f"voices: you={you}, story={narrator}, explain={explainer}")

    story_audio = speak(STORY, narrator, 168, cache / "clip-story.m4a")
    explain_audio = speak(EXPLAIN, explainer, 172, cache / "clip-explain.m4a")
    story = make_clip(tr("story_title"), tr("story_notes"), STORY, story_audio, "story", 168)
    explain = make_clip(tr("explain_title"), tr("explain_notes"), EXPLAIN, explain_audio, "explain", 172)
    daily_dir = DATA / "daily"
    daily_dir.mkdir(parents=True, exist_ok=True)
    (daily_dir / "state.json").write_text(json.dumps(
        {"used_videos": {}, "days": {today.isoformat(): {"items": [story, explain], "errors": []}}}, indent=1))

    # A talk more than ten days out shows on Overview without replacing today's impromptu prompt.
    request("POST", "/api/agenda", {"title": tr("event"), "kind": "review", "minutes": 10,
                                    "date": (today + timedelta(days=16)).isoformat(), "notes": ""})

    plan = request("GET", "/api/today")
    for _ in range(40):   # the pool has about fifteen prompts, and each shuffle moves one along
        imp = next((i for i in plan["items"] if i["kind"] == "impromptu"), None)
        if imp and imp.get("prompt_id") == TODAY_PROMPT:
            break
        plan = request("POST", "/api/plan/shuffle")
    items = {i["kind"]: i for i in plan["items"]}
    log("today's plan: " + "; ".join(f"{i['kind']}: {i['title']}" for i in plan["items"]))

    prompts = {p["id"]: p for p in request("GET", "/api/prompts")}
    titles = {"shadow": tr("story_title"), "retell": tr("explain_title")}
    rnd = random.Random(7)
    now = datetime.now().replace(microsecond=0)
    # Today's two takes: half an hour ago and a quarter of an hour later (just after midnight, sooner).
    start = max(now - timedelta(minutes=40), datetime.combine(today, datetime.min.time()) + timedelta(minutes=1))
    n = len(SCHEDULE)
    for idx, (ago, kind, prompt_id) in enumerate(SCHEDULE):
        day = today - timedelta(days=ago)
        if ago == 0:
            when = start + (now - start) * (0.4 if kind == "impromptu" else 0.0)
        else:
            when = datetime.combine(day, datetime.min.time()) + timedelta(hours=rnd.choice([7, 8, 12, 20, 21]),
                                                                          minutes=rnd.randint(0, 55))
        progress = idx / (n - 1)
        rate = round(128 + 30 * progress)               # a little faster every week
        fillers = 0.55 * (1 - progress) + 0.05          # and fewer "um"s
        item = items.get(kind) if ago == 0 else None
        if kind == "impromptu" and ago == 0:
            prompt_id = (item or {}).get("prompt_id") or TODAY_PROMPT
        if kind == "shadow":
            text, practice, scenario = STORY, story, "presentation"
            title = tr("shadow").format(titles["shadow"])
        elif kind == "retell":
            text, practice, scenario = with_fillers(RETELL, fillers, rnd), explain, "presentation"
            title = tr("retell").format(titles["retell"])
        else:
            text, practice, scenario = with_fillers(TALKS.get(prompt_id, TALKS[TODAY_PROMPT]), fillers, rnd), "", "meeting"
            title = tr("impromptu").format(prompts[prompt_id]["text"][:40])
        audio = speak(text, you, rate if kind != "shadow" else 150 + round(14 * progress),
                      cache / f"take-{idx:02d}-{kind}.m4a")
        drill = {"item": item["id"] if item else None, "kind": kind,
                 "prompt_id": prompt_id if kind == "impromptu" else None, "date": day.isoformat()}
        s = request("POST", "/api/sessions", form={"language": "en", "title": title, "scenario": scenario,
                                                   "practice_id": practice, "drill": json.dumps(drill)}, file=audio)
        stamp_session(s["id"], when)
        log(f"{day} {kind:9s} {s['wpm']:5.0f} wpm  {s['duration_sec']:5.1f} s  {title}")
        if kind in ("shadow", "retell"):
            request("POST", "/api/activity", {"events": [{
                "at": (when - timedelta(minutes=6)).isoformat(timespec="seconds"), "kind": "listen_reference",
                "practice_id": practice, "wall_sec": 150, "media_sec": 140, "rate": 1.0}]})

    t = request("GET", "/api/today")
    log(f"week: {t['week']['done']}/{t['week']['target']} days, {t['session_count']} sessions, "
        f"baseline {t['baseline']['wpm']} wpm, block {t['block']['greek']} week {t['block']['week']}")


if __name__ == "__main__":
    main()
