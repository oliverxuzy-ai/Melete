"""Coaching layer: training blocks, targets taken from your own recordings, a prompt bank,
today's plan, prep plans for real talks, one-line feedback and the weekly recap.

Everything here is a heuristic over data already on disk. Nothing calls the network.

The curriculum follows the most common feedback on spoken delivery: speak faster
and louder first, then tone and pauses, then storytelling, then changing register for
1:1 / team / stakeholders / all-hands. Blocks run like a training plan: a few weeks of
focus each, then a lighter week, then the cycle repeats.
"""
from __future__ import annotations

import hashlib
import json
import statistics
import uuid
from datetime import date, datetime, timedelta

import paths

SETTINGS_FILE = paths.DATA_DIR / "settings.json"
AGENDA_FILE = paths.DATA_DIR / "agenda.json"
PLAN_DIR = paths.DATA_DIR / "plans"

DEFAULT_SETTINGS = {
    "daily": {
        "enabled": True,
        "clips_per_day": 2,
        "notify_time": "21:30",
        "prep_hour": 5,
        "ntfy_topic": "",
        "use_claude": False,
        "claude_model": "claude-opus-5-5",
        "claude_api_key": "",
    },
    "coach": {
        "cycle_start": None,        # Monday the cycle started; set on first run
        "week_target_days": 5,
        "block_override": None,     # a block key to stay on, or None to follow the cycle
        "committed_week": None,     # Monday of the week the plan was committed to
    },
}

# ---------------------------------------------------------------- settings


def _merge(base: dict, extra: dict) -> dict:
    out = json.loads(json.dumps(base))
    for k, v in (extra or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


def load_settings() -> dict:
    data = {}
    if SETTINGS_FILE.exists():
        try:
            data = json.loads(SETTINGS_FILE.read_text())
        except ValueError:
            data = {}
    s = _merge(DEFAULT_SETTINGS, data)
    if not s["coach"]["cycle_start"]:
        s["coach"]["cycle_start"] = monday(date.today()).isoformat()
        save_settings(s)
    return s


def save_settings(s: dict) -> None:
    SETTINGS_FILE.write_text(json.dumps(s, ensure_ascii=False, indent=1))
    try:
        SETTINGS_FILE.chmod(0o600)   # may hold an API key
    except OSError:
        pass


def public_settings(s: dict) -> dict:
    """Settings for the app: the API key is reported as present or not, never sent back."""
    out = json.loads(json.dumps(s))
    out["daily"]["has_claude_key"] = bool(s["daily"].get("claude_api_key"))
    out["daily"].pop("claude_api_key", None)
    return out


def update_settings(patch: dict) -> dict:
    s = load_settings()
    s = _merge(s, patch or {})
    save_settings(s)
    return s


# ---------------------------------------------------------------- blocks

BLOCKS = [
    {"key": "tachos", "greek": "Τάχος", "name": "语速与音量", "weeks": 2,
     "focus": ["wpm", "loudness"],
     "why": "先把两个基本功拉起来：说快一点，大声一点。会议里的发言、汇报和评审，都从这里开始。",
     "tip": "开口前先想好第一句，后面的边说边想。句尾不要拖。"},
    {"key": "tonos", "greek": "Τόνος", "name": "语调与停顿", "weeks": 2,
     "focus": ["pitch", "fillers"],
     "why": "语调平，听众就跟不住。这两周练重读和停顿。",
     "tip": "每句挑一个关键词重读。想停的时候就停，用停顿代替 um 和 like。"},
    {"key": "mythos", "greek": "Μῦθος", "name": "讲故事", "weeks": 2,
     "focus": ["coverage", "wpm"],
     "why": "让人愿意听下去：开头抛钩子，中间有转折，结尾回到结论。",
     "tip": "先说结果或冲突，再补背景。一个故事只讲一个转折。"},
    {"key": "prosopon", "greek": "Πρόσωπον", "name": "看对象换说法", "weeks": 2,
     "focus": ["duration", "wpm"],
     "why": "同一件事，对团队、对业务方、对评审会、对全员会，说法不一样。",
     "tip": "先想对方最关心什么，再决定第一句。对做决定的人短，对全员慢。"},
    {"key": "anapausis", "greek": "Ἀνάπαυσις", "name": "减量周", "weeks": 1,
     "focus": [],
     "why": "像跑步的减量周：只跟读，不加量，让前面几周的练习沉淀下来。",
     "tip": "用 0.9 倍跟读，放松地读完就算数。"},
]
CYCLE_WEEKS = sum(b["weeks"] for b in BLOCKS)


def current_block(today: date | None = None, settings: dict | None = None) -> dict:
    today = today or date.today()
    s = settings or load_settings()
    start = date.fromisoformat(s["coach"]["cycle_start"])
    weeks = max(0, (monday(today) - monday(start)).days // 7)
    override = s["coach"].get("block_override")
    if override:
        block = next((b for b in BLOCKS if b["key"] == override), BLOCKS[0])
        return {**block, "week": 1, "cycle_week": weeks % CYCLE_WEEKS + 1, "pinned": True}
    w = weeks % CYCLE_WEEKS
    for b in BLOCKS:
        if w < b["weeks"]:
            return {**b, "week": w + 1, "cycle_week": weeks % CYCLE_WEEKS + 1, "pinned": False}
        w -= b["weeks"]
    return {**BLOCKS[0], "week": 1, "cycle_week": 1, "pinned": False}


# ---------------------------------------------------------------- baseline and targets


SHADOW_PRACTICES: set[str] = set()   # practices with a reference recording; filled by the server


def _is_shadow(s: dict) -> bool:
    d = s.get("drill") or {}
    if d.get("kind"):
        return d["kind"] == "shadow"
    return s.get("practice_id") in SHADOW_PRACTICES   # older recordings carry no drill tag


def baseline(sessions: list[dict]) -> dict:
    """Your own recent numbers, from attempts that were not read along with someone."""
    own = [s for s in sessions if not _is_shadow(s) and s.get("language", "en") == "en"]
    pool = own[-10:] or sessions[-10:]

    def med(vals, default):
        vals = [v for v in vals if v is not None]
        return round(statistics.median(vals), 1) if vals else default

    # Loudness in dBFS depends on the microphone and how far you sit from it, so it is only
    # compared with your last few recordings (same setup, most likely), never across months.
    recent = sessions[-5:]
    return {
        "wpm": med([s.get("wpm") for s in pool], 120.0),
        "pitch": med([(s["metrics"].get("pitch") or {}).get("range_semitones") for s in pool], 7.0),
        "loudness": med([(s["metrics"].get("loudness") or {}).get("mean_db") for s in recent], -28.0),
        "fillers": med([s["metrics"]["fillers"]["per_minute"] for s in pool], 4.0),
        "count": len(pool),
    }


def _round5(x: float) -> int:
    return int(round(x / 5.0) * 5)


def targets(block: dict, base: dict) -> dict:
    """Targets move with you: the pace band starts a little above your own pace and
    steps up during the pace block, like adding a little distance each week."""
    step = (block.get("week", 1) - 1) * 5 if block["key"] == "tachos" else 5
    low = min(155, max(125, _round5(base["wpm"] + 5 + step)))
    return {
        "wpm_low": low,
        "wpm_high": low + 25,
        "pitch": round(max(base["pitch"] + 2.0, 8.5), 1),
        "loudness": round(base["loudness"] - 3.0, 1),   # not quieter than your recent self
        "fillers": round(max(1.5, base["fillers"] * 0.7), 1),
    }


# ---------------------------------------------------------------- prompt bank
# Exercise forms follow the progymnasmata, the graded speaking exercises of Greek
# rhetoric schools, adapted to the talks you actually give.

FORMS = {
    "diegema": {"greek": "Διήγημα", "name": "叙事", "hint": "开头一句说结果或冲突，中间一个转折，结尾说你学到什么。"},
    "chreia": {"greek": "Χρεία", "name": "引申", "hint": "先表态，再给一个理由和一个例子，最后回到这句话。"},
    "ekphrasis": {"greek": "Ἔκφρασις", "name": "描述", "hint": "从整体到局部：先给一张图，再沿着数据流讲。"},
    "synkrisis": {"greek": "Σύγκρισις", "name": "比较", "hint": "先给结论，再说取舍。比较的维度不超过三个。"},
    "thesis": {"greek": "Θέσις", "name": "立论", "hint": "观点、理由、例子、再说一遍观点。"},
    "ethopoeia": {"greek": "Ἠθοποιία", "name": "换对象", "hint": "想清楚对方最关心什么，第一句就回答它。"},
    "enkomion": {"greek": "Ἐγκώμιον", "name": "致谢", "hint": "说具体的事和它带来的结果，不说空话。"},
    "anaskeue": {"greek": "Ἀνασκευή", "name": "反驳", "hint": "先复述对方的观点，再指出最弱的一环，给替代方案。"},
    "apokrisis": {"greek": "Ἀπόκρισις", "name": "答问", "hint": "先一句话回答，再用一个例子撑住，最后收回来。"},
    "angelia": {"greek": "Ἀγγελία", "name": "汇报", "hint": "结论先行：做完了什么、卡在哪、需要谁做什么。"},
}

BLOCK_FORMS = {
    "tachos": ["angelia", "apokrisis", "synkrisis", "thesis"],
    "tonos": ["chreia", "thesis", "anaskeue", "enkomion"],
    "mythos": ["diegema", "ekphrasis", "apokrisis"],
    "prosopon": ["ethopoeia", "angelia", "ekphrasis"],
    "anapausis": [],
}

PROMPTS = [
    # narration
    {"id": "outage-story", "form": "diegema", "seconds": 90, "audience": "团队",
     "text": "Tell the story of an outage you handled: what broke, how you found it, and what you changed so it cannot happen again."},
    {"id": "tool-adoption-story", "form": "diegema", "seconds": 90, "audience": "面试官",
     "text": "Tell how a tool you built went from an idea to something other teams rely on. Pick one turning point and build the story around it."},
    {"id": "stakeholder-question", "form": "diegema", "seconds": 75, "audience": "团队",
     "text": "Tell the story of a time one stakeholder question changed what you built."},
    {"id": "physics-to-data", "form": "diegema", "seconds": 90, "audience": "面试官",
     "text": "Tell how you went from studying physics at UCSB to building data and AI systems. Make it a story, not a resume."},
    {"id": "vat-origin", "form": "diegema", "seconds": 75, "audience": "社区",
     "text": "Tell why you started knowledge-in-a-vat and the moment you knew it was worth publishing."},
    # chreia
    {"id": "pg-want", "form": "chreia", "seconds": 60, "audience": "团队",
     "text": "Paul Graham says: make something people want. What does that mean for an internal data team? Take a position."},
    {"id": "jensen-pain", "form": "chreia", "seconds": 60, "audience": "朋友",
     "text": "Jensen Huang wished Stanford students ample doses of pain and suffering. Agree or disagree, with one story of your own."},
    {"id": "festina-lente", "form": "chreia", "seconds": 60, "audience": "团队",
     "text": "Festina lente: make haste slowly. When should a data team deliberately move slowly?"},
    # description
    {"id": "platform-tour", "form": "ekphrasis", "seconds": 90, "audience": "新同事",
     "text": "Describe your company's data platform end to end so a new engineer can picture it: sources, ingestion, warehouse, transformations, orchestration, and who reads what."},
    {"id": "semantic-layer-sales", "form": "ekphrasis", "seconds": 60, "audience": "业务方",
     "text": "Explain what a semantic layer is to a salesperson, with one concrete example from their world."},
    {"id": "eval-harness", "form": "ekphrasis", "seconds": 75, "audience": "非技术的业务方",
     "text": "Describe the BI Agent's eval harness so a non-technical stakeholder understands why it matters."},
    # comparison
    {"id": "build-or-buy", "form": "synkrisis", "seconds": 60, "audience": "架构评审",
     "text": "Build or buy reverse ETL into your CRM: recommend one in sixty seconds and name the trade-off."},
    {"id": "dbt-fusion", "form": "synkrisis", "seconds": 75, "audience": "团队",
     "text": "dbt Fusion versus the current dbt setup: what actually changes for the team, and is it worth it now?"},
    {"id": "cortex-vs-claude", "form": "synkrisis", "seconds": 75, "audience": "架构评审",
     "text": "Snowflake Cortex Agents versus building the agent directly on Claude: which would you pick for the next project, and why?"},
    # thesis
    {"id": "one-semantic-layer", "form": "thesis", "seconds": 60, "audience": "架构评审",
     "text": "Should every metric in the company live in one semantic layer? Argue yes or no."},
    {"id": "ai-chargeback", "form": "thesis", "seconds": 60, "audience": "管理层",
     "text": "Should AI usage be charged back to each business function? Make the case."},
    {"id": "analyze-once", "form": "thesis", "seconds": 60, "audience": "业务方",
     "text": "Argue for analyzing sales call transcripts once and storing the results in the warehouse, instead of every team analyzing them again."},
    # register switching: one finding, four rooms
    {"id": "cost-1on1", "form": "ethopoeia", "seconds": 45, "audience": "成本评审",
     "text": "In a cost review, say it in one breath: which line item drives most of your AI spend, and how much of it can go. Direct and short."},
    {"id": "cost-standup", "form": "ethopoeia", "seconds": 45, "audience": "团队站会",
     "text": "Same finding at the data team standup: what it means for everyone's work this sprint."},
    {"id": "cost-allhands", "form": "ethopoeia", "seconds": 40, "audience": "全员会",
     "text": "Same finding for the whole company: one number, one sentence on why it matters, one ask."},
    {"id": "cost-sales", "form": "ethopoeia", "seconds": 45, "audience": "业务方",
     "text": "Same finding for a sales leader whose reports depend on what you want to cut: what changes for them, and when."},
    {"id": "arch-review", "form": "ethopoeia", "seconds": 120, "audience": "架构评审",
     "text": "Present the data infrastructure architecture to the Architecture Review committee and end with the one decision you need from them."},
    # praise
    {"id": "credit-teammate", "form": "enkomion", "seconds": 45, "audience": "团队",
     "text": "Give credit to a teammate in front of the team for one specific thing they did this month, and what it made possible."},
    # refutation
    {"id": "agents-replace-de", "form": "anaskeue", "seconds": 60, "audience": "朋友",
     "text": "Someone says agents will fully automate data engineering within two years. Refute it in sixty seconds."},
    {"id": "just-more-yaml", "form": "anaskeue", "seconds": 60, "audience": "团队",
     "text": "Someone says a semantic layer is just more YAML to maintain. Answer them."},
    # interview answers
    {"id": "tell-me-about-yourself", "form": "apokrisis", "seconds": 60, "audience": "面试官",
     "text": "Tell me about yourself. Sixty seconds, interview opener."},
    {"id": "why-this-company", "form": "apokrisis", "seconds": 60, "audience": "面试官",
     "text": "Why do you want this role, and why here?"},
    {"id": "lead-without-authority", "form": "apokrisis", "seconds": 90, "audience": "面试官",
     "text": "Tell me about a time you led a project without formal authority."},
    {"id": "hardest-problem", "form": "apokrisis", "seconds": 90, "audience": "面试官",
     "text": "Walk me through the hardest technical problem you solved in the last year."},
    {"id": "build-first", "form": "apokrisis", "seconds": 60, "audience": "面试官",
     "text": "If you joined a new data and AI team, what would you build first, and why?"},
    {"id": "got-it-wrong", "form": "apokrisis", "seconds": 75, "audience": "面试官",
     "text": "Tell me about a decision you got wrong and what you changed afterwards."},
    # status updates
    {"id": "weekly-update", "form": "angelia", "seconds": 45, "audience": "团队站会",
     "text": "Give a forty five second status update at standup: what shipped this week, what is blocked, and what you need from the team."},
    {"id": "onsite-opener", "form": "angelia", "seconds": 60, "audience": "团队",
     "text": "Open your semantic layer session at the data team onsite: the hook, the agenda, and the one outcome you want."},
    {"id": "breaking-change", "form": "angelia", "seconds": 45, "audience": "分析师",
     "text": "Announce a breaking change in a shared dbt model to downstream analysts: what changes, when, and what they must do."},
]
PROMPTS_BY_ID = {p["id"]: p for p in PROMPTS}


def prompt_view(p: dict) -> dict:
    f = FORMS[p["form"]]
    return {**p, "form_greek": f["greek"], "form_name": f["name"], "hint": f["hint"]}


# ---------------------------------------------------------------- agenda

PREP_STEPS = [
    (7, "outline", "写提纲", "把要讲的要点写进这次的原文，不用写成稿。"),
    (5, "first", "完整讲一遍", "不看稿讲完，录下来看要点覆盖。"),
    (3, "timed", "计时讲", "按规定时长讲，语速进目标带。"),
    (2, "outsider", "换个对象讲", "讲给一个不懂技术的人听，看哪里需要多解释一句。"),
    (1, "ends", "只练开头和结尾", "开头三十秒抛钩子，结尾二十秒回到你要的结论。"),
    (0, "warmup", "上场前热身", "跟读一段六十秒的片段，把嗓子和语速带起来，再讲一遍开头。"),
]

EVENT_KINDS = {
    "review": "架构评审", "one_on_one": "1:1", "team": "团队会", "stakeholder": "业务方",
    "allhands": "全员会", "interview": "面试", "talk": "分享", "other": "其他",
}

TEMPLATES = [
    {"title": "Architecture Review：数据基础设施", "kind": "review", "minutes": 10},
    {"title": "双周 1:1：进展和卡点", "kind": "one_on_one", "minutes": 3},
    {"title": "数据团队 onsite：semantic layer", "kind": "talk", "minutes": 15},
    {"title": "面试：自我介绍与项目深挖", "kind": "interview", "minutes": 5},
]


def load_agenda() -> list[dict]:
    if not AGENDA_FILE.exists():
        return []
    try:
        return json.loads(AGENDA_FILE.read_text())
    except ValueError:
        return []


def save_agenda(items: list[dict]) -> None:
    AGENDA_FILE.write_text(json.dumps(items, ensure_ascii=False, indent=1))


def new_event(body: dict) -> dict:
    return {
        "id": "ev-" + uuid.uuid4().hex[:8],
        "title": (body.get("title") or "").strip() or "一次讲话",
        "date": body.get("date") or (date.today() + timedelta(days=7)).isoformat(),
        "kind": body.get("kind") if body.get("kind") in EVENT_KINDS else "other",
        "minutes": int(body.get("minutes") or 5),
        "notes": body.get("notes") or "",
        "practice_id": body.get("practice_id"),
        "created_at": datetime.now().isoformat(timespec="seconds"),
    }


def prep_plan(ev: dict, sessions: list[dict], today: date | None = None) -> list[dict]:
    """Steps counted back from the day of the talk, like a taper before a race."""
    today = today or date.today()
    d = date.fromisoformat(ev["date"])
    created = datetime.fromisoformat(ev["created_at"]).date() if ev.get("created_at") else today
    mine = [s for s in sessions if ev.get("practice_id") and s.get("practice_id") == ev["practice_id"] and s.get("word_count", 0) > 0]
    days_done = {s["created_at"][:10] for s in mine}
    steps = []
    for offset, key, title, detail in PREP_STEPS:
        when = d - timedelta(days=offset)
        if when < created and offset != 0:
            continue   # the talk was added late; skip steps that were already past
        item_id = f"{ev['id']}:{key}"
        done = any((s.get("drill") or {}).get("item") == item_id for s in mine) or (key != "outline" and when.isoformat() in days_done)
        if key == "outline":
            done = done or bool(ev.get("has_script"))
        state = "done" if done else ("today" if when == today else ("missed" if when < today else "upcoming"))
        steps.append({"id": item_id, "key": key, "title": title, "detail": detail, "date": when.isoformat(), "offset": offset, "state": state})
    return steps


def agenda_view(sessions: list[dict], practices: dict, today: date | None = None) -> list[dict]:
    today = today or date.today()
    out = []
    for ev in sorted(load_agenda(), key=lambda e: e["date"]):
        p = practices.get(ev.get("practice_id") or "")
        ev = {**ev, "has_script": bool(p and p.get("script", "").strip())}
        d = date.fromisoformat(ev["date"])
        ev["days_left"] = (d - today).days
        ev["kind_label"] = EVENT_KINDS.get(ev["kind"], "其他")
        ev["steps"] = prep_plan(ev, sessions, today)
        ev["past"] = d < today
        out.append(ev)
    return out


# ---------------------------------------------------------------- week and plan


def day_activity(sessions: list[dict], activity: list[dict]) -> dict[str, float]:
    """Seconds of practice per day: recordings plus listening to references."""
    out: dict[str, float] = {}
    for s in sessions:
        out[s["created_at"][:10]] = out.get(s["created_at"][:10], 0) + float(s.get("duration_sec") or 0)
    for e in activity:
        if e.get("kind") == "listen_reference":
            out[e["at"][:10]] = out.get(e["at"][:10], 0) + float(e.get("wall_sec") or 0) * 0.5
    return out


PRACTICED_SEC = 20   # one real attempt is enough to count the day


def week_view(sessions: list[dict], activity: list[dict], today: date | None = None, settings: dict | None = None) -> dict:
    today = today or date.today()
    s = settings or load_settings()
    per_day = day_activity(sessions, activity)
    start = monday(today)
    days = []
    for i in range(7):
        d = start + timedelta(days=i)
        sec = per_day.get(d.isoformat(), 0.0)
        practiced = sec >= PRACTICED_SEC
        state = "done" if practiced else ("today" if d == today else ("missed" if d < today else "future"))
        days.append({"date": d.isoformat(), "state": state, "minutes": round(sec / 60, 1)})
    yesterday = (today - timedelta(days=1)).isoformat()
    before = (today - timedelta(days=2)).isoformat()
    missed_yesterday = per_day.get(yesterday, 0) < PRACTICED_SEC
    had_history = bool(per_day)
    practiced_days = sorted(d for d, sec in per_day.items() if sec >= PRACTICED_SEC and d <= today.isoformat())
    since = (today - date.fromisoformat(practiced_days[-1])).days if practiced_days else None
    return {
        "start": start.isoformat(),
        "days": days,
        "days_since": since,
        "done": sum(1 for d in days if d["state"] == "done"),
        "target": s["coach"]["week_target_days"],
        "committed": s["coach"].get("committed_week") == start.isoformat(),
        # never miss twice: a gentle nudge only when yesterday was skipped
        "missed_yesterday": had_history and missed_yesterday,
        "missed_two": had_history and missed_yesterday and per_day.get(before, 0) < PRACTICED_SEC,
        "today_done": per_day.get(today.isoformat(), 0) >= PRACTICED_SEC,
    }


def _plan_file(d: date):
    PLAN_DIR.mkdir(parents=True, exist_ok=True)
    return PLAN_DIR / f"{d.isoformat()}.json"


def load_plan_state(d: date) -> dict:
    f = _plan_file(d)
    if f.exists():
        try:
            return json.loads(f.read_text())
        except ValueError:
            pass
    return {"date": d.isoformat(), "shuffle": 0}


def save_plan_state(d: date, st: dict) -> None:
    _plan_file(d).write_text(json.dumps(st, ensure_ascii=False, indent=1))


def pick_prompt(d: date, block: dict, shuffle: int = 0) -> dict | None:
    forms = BLOCK_FORMS.get(block["key"]) or []
    pool = [p for p in PROMPTS if p["form"] in forms]
    if not pool:
        return None
    seed = int(hashlib.sha1(d.isoformat().encode()).hexdigest(), 16)
    return pool[(seed + shuffle) % len(pool)]


def build_plan(d: date, sessions: list[dict], clips: list[dict], agenda: list[dict], settings: dict) -> dict:
    """Today's sequence. Any one finished item counts the day; the rest is a bonus."""
    block = current_block(d, settings)
    st = load_plan_state(d)
    items = []
    # only recordings with speech in them complete a step
    today_sessions = [s for s in sessions if s["created_at"][:10] == d.isoformat() and s.get("word_count", 0) > 0]

    def done(item_id: str):
        for s in today_sessions:
            if (s.get("drill") or {}).get("item") == item_id:
                return s["id"]
        return None

    for n, clip in enumerate(clips):
        kind = "shadow" if n == 0 or block["key"] == "anapausis" else "retell"
        item_id = f"{d.isoformat()}:{kind}:{n}"
        items.append({
            "id": item_id, "kind": kind, "practice_id": clip["id"],
            "title": clip.get("title") or "今日片段",
            "subtitle": clip.get("subtitle") or "",
            "seconds": round(clip.get("duration") or 90),
            "detail": "先听原文，再跟着读。外放时录音不放原声，戴耳机可以边听边跟。" if kind == "shadow"
                      else "先听原文，再用自己的话在九十秒内复述。看讲到了几个要点。",
            "session_id": done(item_id),
        })

    # A real talk inside ten days takes the impromptu slot.
    upcoming = [e for e in agenda if 0 <= e.get("days_left", 99) <= 10]
    step = None
    for ev in upcoming:
        for stp in ev["steps"]:
            if stp["state"] == "today":
                step = (ev, stp)
                break
        if step:
            break
    if step:
        ev, stp = step
        items.append({
            "id": stp["id"], "kind": "agenda", "practice_id": ev.get("practice_id"),
            "title": f"{ev['title']}：{stp['title']}",
            "subtitle": f"还有 {ev['days_left']} 天 · {ev['kind_label']}",
            "seconds": int(ev.get("minutes", 5)) * 60 if stp["key"] in ("first", "timed") else 90,
            "detail": stp["detail"],
            "session_id": done(stp["id"]) or (stp["id"] if stp["state"] == "done" else None),
        })
    elif block["key"] != "anapausis":
        p = pick_prompt(d, block, st.get("shuffle", 0))
        if p:
            pv = prompt_view(p)
            item_id = f"{d.isoformat()}:impromptu:{p['id']}"
            items.append({
                "id": item_id, "kind": "impromptu", "practice_id": None, "prompt_id": p["id"],
                "title": f"{pv['form_name']}：{pv['audience']}",
                "subtitle": pv["form_greek"],
                "prompt": p["text"],
                "seconds": p["seconds"],
                "detail": pv["hint"],
                "session_id": done(item_id),
            })
    return {"block": block, "items": items, "shuffle": st.get("shuffle", 0)}


def shuffle_prompt(d: date) -> None:
    st = load_plan_state(d)
    st["shuffle"] = int(st.get("shuffle", 0)) + 1
    save_plan_state(d, st)


# ---------------------------------------------------------------- feedback


def review(session: dict, previous: dict | None, block: dict, tg: dict) -> dict:
    """One headline and up to three concrete lines, judged against this block's focus."""
    m = session["metrics"]
    zh = m.get("language", "en").startswith("zh")
    unit = "字/分" if zh else "词/分"
    lines: list[str] = []
    focus: list[dict] = []

    wpm = m["wpm"]
    lo, hi = (180, 260) if zh else (tg["wpm_low"], tg["wpm_high"])
    pace_state = "low" if wpm < lo else ("high" if wpm > hi else "in")
    prev_wpm = previous["metrics"]["wpm"] if previous else None
    focus.append({"key": "wpm", "label": "语速", "value": round(wpm), "unit": unit,
                  "target": f"{lo} 到 {hi}", "state": pace_state,
                  "delta": round(wpm - prev_wpm) if prev_wpm is not None else None})
    if pace_state == "low":
        lines.append(f"语速 {round(wpm)} {unit}，比目标低 {round(lo - wpm)}。下一遍把每句的开头说快，不要等整句想好再开口。")
    elif pace_state == "high":
        lines.append(f"语速 {round(wpm)} {unit}，超过目标带。在要点之间留半秒停顿，让听众跟上。")
    else:
        moved = ""
        if prev_wpm is not None and abs(wpm - prev_wpm) >= 5:
            moved = f"，比上一遍{'快' if wpm > prev_wpm else '慢'} {abs(round(wpm - prev_wpm))}"
        lines.append(f"语速 {round(wpm)} {unit}，在目标带 {lo} 到 {hi} 里{moved}。")

    pitch = (m.get("pitch") or {}).get("range_semitones")
    if pitch is not None:
        prev_pitch = ((previous or {}).get("metrics", {}).get("pitch") or {}).get("range_semitones") if previous else None
        st = "in" if pitch >= tg["pitch"] else "low"
        focus.append({"key": "pitch", "label": "音高起伏", "value": pitch, "unit": "半音",
                      "target": f"≥ {tg['pitch']}", "state": st,
                      "delta": round(pitch - prev_pitch, 1) if prev_pitch is not None else None})
        if st == "low" and ("pitch" in block["focus"] or len(lines) < 2):
            lines.append(f"音高起伏 {pitch} 半音，偏平。每句挑一个关键词，重读并把音调抬上去。")

    fpm = m["fillers"]["per_minute"]
    top = next(iter(m["fillers"].get("breakdown") or {}), None)
    prev_f = previous["metrics"]["fillers"]["per_minute"] if previous else None
    fst = "in" if fpm <= tg["fillers"] else "high"
    focus.append({"key": "fillers", "label": "填充词", "value": round(fpm, 1), "unit": "次/分",
                  "target": f"≤ {tg['fillers']}", "state": fst,
                  "delta": round(fpm - prev_f, 1) if prev_f is not None else None})
    if fst == "high" and ("fillers" in block["focus"] or len(lines) < 3):
        word = f"，最多的是 {top}" if top else ""
        lines.append(f"填充词每分钟 {round(fpm, 1)} 次{word}。想停就停，停顿比 um 好听。")

    loud = (m.get("loudness") or {}).get("mean_db")
    if loud is not None and "loudness" in block["focus"]:
        st = "in" if loud >= tg["loudness"] else "low"
        rel = round(loud - (tg["loudness"] + 3.0), 1)   # against your recent median, not an absolute level
        focus.append({"key": "loudness", "label": "音量", "value": rel, "unit": "dB",
                      "target": "和最近几次比", "state": st, "delta": None})
        if st == "low":
            lines.append("这次比你最近几次小声了 3 dB 以上。坐直，对着房间最远的墙说。")

    cov = m.get("coverage")
    if cov:
        missed = [p["text"] for p in cov["points"] if p["status"] == "missed"]
        focus.append({"key": "coverage", "label": "要点覆盖", "value": round(cov["coverage"] * 100), "unit": "%",
                      "target": "≥ 80", "state": "in" if cov["coverage"] >= 0.8 else "low", "delta": None})
        if missed and "coverage" in block["focus"]:
            first = missed[0][:40] + ("…" if len(missed[0]) > 40 else "")
            lines.append(f"漏掉了 {len(missed)} 个要点，比如「{first}」。")

    # Headline: the block's first focus that is off target, otherwise the best news.
    order = block["focus"] or ["wpm"]
    off = [f for k in order for f in focus if f["key"] == k and f["state"] != "in"]
    if off:
        f = off[0]
        headline = {"wpm": "语速还要再提一点" if f["state"] == "low" else "语速偏快，留点停顿",
                    "pitch": "语调还偏平", "fillers": "填充词偏多", "loudness": "声音再大一点",
                    "coverage": "要点漏了几个"}.get(f["key"], "继续")
    else:
        headline = "这一遍达标了" if focus else "录好了"
    return {"headline": headline, "lines": lines[:3], "focus": focus, "block": block["key"]}


def previous_attempt(session: dict, sessions: list[dict]) -> dict | None:
    """The attempt to compare with: same practice if any, else the previous recording."""
    earlier = [s for s in sessions if s["created_at"] < session["created_at"]]
    if session.get("practice_id"):
        same = [s for s in earlier if s.get("practice_id") == session["practice_id"]]
        if same:
            return same[-1]
    return earlier[-1] if earlier else None


# ---------------------------------------------------------------- weekly recap


def recap(sessions: list[dict], activity: list[dict], offset_weeks: int = 0, today: date | None = None) -> dict:
    today = today or date.today()
    start = monday(today) - timedelta(days=7 * offset_weeks)
    end = start + timedelta(days=6)
    prev_start = start - timedelta(days=7)
    s_all = load_settings()

    def in_range(s, a, b):
        d = s["created_at"][:10]
        return a.isoformat() <= d <= b.isoformat()

    week = [s for s in sessions if in_range(s, start, end)]
    prev = [s for s in sessions if in_range(s, prev_start, prev_start + timedelta(days=6))]
    per_day = day_activity(sessions, activity)
    days = []
    for i in range(7):
        d = start + timedelta(days=i)
        sec = per_day.get(d.isoformat(), 0.0)
        days.append({"date": d.isoformat(), "practiced": sec >= PRACTICED_SEC, "minutes": round(sec / 60, 1)})
    listen = sum(float(e.get("wall_sec") or 0) for e in activity if start.isoformat() <= e["at"][:10] <= end.isoformat())

    def avg(rows, fn):
        vals = [fn(r) for r in rows]
        vals = [v for v in vals if v is not None]
        return round(sum(vals) / len(vals), 1) if vals else None

    def metric(fn):
        return {"this": avg(week, fn), "last": avg(prev, fn)}

    metrics = {
        "wpm": metric(lambda s: s.get("wpm")),
        "pitch": metric(lambda s: (s["metrics"].get("pitch") or {}).get("range_semitones")),
        "fillers": metric(lambda s: s["metrics"]["fillers"]["per_minute"]),
    }
    block = current_block(start, s_all)
    nxt = current_block(start + timedelta(days=7), s_all)
    practiced = sum(1 for d in days if d["practiced"])
    target = s_all["coach"]["week_target_days"]
    best = None
    if week:
        b = max(week, key=lambda s: (s["metrics"].get("pitch") or {}).get("range_semitones") or 0)
        best = {"id": b["id"], "title": b.get("title"), "wpm": b.get("wpm"),
                "pitch": (b["metrics"].get("pitch") or {}).get("range_semitones")}

    return {
        "start": start.isoformat(), "end": end.isoformat(), "days": days,
        "practiced": practiced, "target": target,
        "record_minutes": round(sum(s["duration_sec"] for s in week) / 60, 1),
        "listen_minutes": round(listen / 60, 1),
        "sessions": len(week), "metrics": metrics, "best": best,
        "block": {"key": block["key"], "name": block["name"], "greek": block["greek"]},
        "next": {"key": nxt["key"], "name": nxt["name"], "greek": nxt["greek"], "why": nxt["why"]},
    }
