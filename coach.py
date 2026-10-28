"""Coaching layer: training blocks, targets taken from your own recordings, a prompt bank,
today's plan, prep plans for real talks, one-line feedback and the weekly recap.

Everything here is a heuristic over data already on disk. Nothing calls the network
(the listening notes in listen.py are fetched separately and only shown, never scored).

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

import i18n
import paths
from i18n import t

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
    "ui": {
        "language": "zh",           # the app's interface language, so background jobs write in it too
    },
    "listen": {                     # listening notes from a cloud audio model, see listen.py
        "enabled": True,            # sends nothing until an OpenRouter key is saved
        "model": "google/gemini-3.8-flash",
        "openrouter_api_key": "",
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
    out["listen"]["has_key"] = bool(s["listen"].get("openrouter_api_key"))
    out["listen"].pop("openrouter_api_key", None)
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
     "tip": "开口前先想好第一句，后面的边说边想。句尾不要拖。",
     "name_en": "Pace and volume",
     "why_en": "First the two basics: speak a little faster and a little louder. Every point you make in a meeting, an update or a review starts here.",
     "tip_en": "Know your first sentence before you start; work out the rest as you go. Don't trail off at the end of a sentence."},
    {"key": "tonos", "greek": "Τόνος", "name": "语调与停顿", "weeks": 2,
     "focus": ["stress", "pitch", "fillers"],
     "why": "语调平，听众就跟不住。这两周练重读和停顿。",
     "tip": "每句挑一个关键词重读。想停的时候就停，用停顿代替 um 和 like。",
     "name_en": "Tone and pauses",
     "why_en": "A flat voice loses the room. These two weeks work on stress and pauses.",
     "tip_en": "Stress one key word in every sentence. When you want to stop, stop: a pause instead of um and like."},
    {"key": "mythos", "greek": "Μῦθος", "name": "讲故事", "weeks": 2,
     "focus": ["coverage", "wpm"],
     "why": "让人愿意听下去：开头抛钩子，中间有转折，结尾回到结论。",
     "tip": "先说结果或冲突，再补背景。一个故事只讲一个转折。",
     "name_en": "Storytelling",
     "why_en": "Make people want to keep listening: open with a hook, put a turn in the middle, end back at the point.",
     "tip_en": "Lead with the result or the conflict, then fill in the background. One turn per story."},
    {"key": "prosopon", "greek": "Πρόσωπον", "name": "看对象换说法", "weeks": 2,
     "focus": ["duration", "wpm"],
     "why": "同一件事，对团队、对业务方、对评审会、对全员会，说法不一样。",
     "tip": "先想对方最关心什么，再决定第一句。对做决定的人短，对全员慢。",
     "name_en": "Speak to the room",
     "why_en": "The same news sounds different to the team, to stakeholders, to a review board and to an all-hands.",
     "tip_en": "Think about what they care about most, then choose your first sentence. Short for decision makers, slower for everyone."},
    {"key": "anapausis", "greek": "Ἀνάπαυσις", "name": "减量周", "weeks": 1,
     "focus": [],
     "why": "像跑步的减量周：只跟读，不加量，让前面几周的练习沉淀下来。",
     "tip": "用 0.9 倍跟读，放松地读完就算数。",
     "name_en": "Taper week",
     "why_en": "Like a taper week in running: shadowing only, no extra load, so the past few weeks can settle in.",
     "tip_en": "Shadow at 0.9×. Reading it through, relaxed, counts."},
]
CYCLE_WEEKS = sum(b["weeks"] for b in BLOCKS)


def local_block(b: dict) -> dict:
    """The block with its name, reason and tip in the interface language."""
    return {**b, "name": i18n.field(b, "name"), "why": i18n.field(b, "why"), "tip": i18n.field(b, "tip")}


def blocks() -> list[dict]:
    return [local_block(b) for b in BLOCKS]


def current_block(today: date | None = None, settings: dict | None = None) -> dict:
    today = today or date.today()
    s = settings or load_settings()
    start = date.fromisoformat(s["coach"]["cycle_start"])
    weeks = max(0, (monday(today) - monday(start)).days // 7)
    override = s["coach"].get("block_override")
    if override:
        block = next((b for b in BLOCKS if b["key"] == override), BLOCKS[0])
        return {**local_block(block), "week": 1, "cycle_week": weeks % CYCLE_WEEKS + 1, "pinned": True}
    w = weeks % CYCLE_WEEKS
    for b in BLOCKS:
        if w < b["weeks"]:
            return {**local_block(b), "week": w + 1, "cycle_week": weeks % CYCLE_WEEKS + 1, "pinned": False}
        w -= b["weeks"]
    return {**local_block(BLOCKS[0]), "week": 1, "cycle_week": 1, "pinned": False}


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
        "stress": med([_stress_share(s) for s in pool], 40.0),
        "count": len(pool),
    }


def _stress_share(s: dict) -> float | None:
    """Share of sentences with a clearly stressed word (prosody.py), when enough were judged."""
    ps = (s["metrics"].get("prosody") or {}).get("summary") or {}
    return ps.get("stress_share") if (ps.get("stress_judged") or 0) >= 3 else None


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
        "stress": min(80, max(50, _round5(base.get("stress", 40.0) + 10))),
    }


# ---------------------------------------------------------------- prompt bank
# Exercise forms follow the progymnasmata, the graded speaking exercises of Greek
# rhetoric schools, adapted to the talks you actually give.

FORMS = {
    "diegema": {"greek": "Διήγημα", "name": "叙事", "hint": "开头一句说结果或冲突，中间一个转折，结尾说你学到什么。",
                "name_en": "Narrative", "hint_en": "Open with the result or the conflict, put one turn in the middle, end with what you learned."},
    "chreia": {"greek": "Χρεία", "name": "引申", "hint": "先表态，再给一个理由和一个例子，最后回到这句话。",
               "name_en": "Maxim", "hint_en": "Take a position, give one reason and one example, then come back to the saying."},
    "ekphrasis": {"greek": "Ἔκφρασις", "name": "描述", "hint": "从整体到局部：先给一张图，再沿着数据流讲。",
                  "name_en": "Description", "hint_en": "Whole to parts: give the big picture first, then follow the data flow."},
    "synkrisis": {"greek": "Σύγκρισις", "name": "比较", "hint": "先给结论，再说取舍。比较的维度不超过三个。",
                  "name_en": "Comparison", "hint_en": "Conclusion first, then the trade-off. No more than three dimensions."},
    "thesis": {"greek": "Θέσις", "name": "立论", "hint": "观点、理由、例子、再说一遍观点。",
               "name_en": "Argument", "hint_en": "Claim, reason, example, then the claim again."},
    "ethopoeia": {"greek": "Ἠθοποιία", "name": "换对象", "hint": "想清楚对方最关心什么，第一句就回答它。",
                  "name_en": "Change the audience", "hint_en": "Work out what they care about most and answer it in your first sentence."},
    "enkomion": {"greek": "Ἐγκώμιον", "name": "致谢", "hint": "说具体的事和它带来的结果，不说空话。",
                 "name_en": "Credit", "hint_en": "Name the specific thing and what it made possible. No empty praise."},
    "anaskeue": {"greek": "Ἀνασκευή", "name": "反驳", "hint": "先复述对方的观点，再指出最弱的一环，给替代方案。",
                 "name_en": "Refutation", "hint_en": "Restate their view, point to the weakest link, offer an alternative."},
    "apokrisis": {"greek": "Ἀπόκρισις", "name": "答问", "hint": "先一句话回答，再用一个例子撑住，最后收回来。",
                  "name_en": "Answer", "hint_en": "Answer in one sentence, back it with one example, then close."},
    "angelia": {"greek": "Ἀγγελία", "name": "汇报", "hint": "结论先行：做完了什么、卡在哪、需要谁做什么。",
                "name_en": "Update", "hint_en": "Bottom line first: what's done, what's blocked, who needs to do what."},
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

AUDIENCE_EN = {
    "团队": "the team", "面试官": "an interviewer", "社区": "the community", "朋友": "a friend",
    "新同事": "a new teammate", "业务方": "business stakeholders", "非技术的业务方": "non-technical stakeholders",
    "架构评审": "the architecture review", "管理层": "leadership", "成本评审": "a cost review",
    "团队站会": "team standup", "全员会": "an all-hands", "分析师": "analysts",
}


def prompt_view(p: dict) -> dict:
    f = FORMS[p["form"]]
    audience = AUDIENCE_EN.get(p["audience"], p["audience"]) if i18n.is_en() else p["audience"]
    return {**p, "audience": audience, "form_greek": f["greek"], "form_name": i18n.field(f, "name"), "hint": i18n.field(f, "hint")}


# ---------------------------------------------------------------- agenda

PREP_STEPS = [
    # days before, key, title, detail, then the same two in English
    (7, "outline", "写提纲", "把要讲的要点写进这次的原文，不用写成稿。",
     "Write the outline", "Put the points you'll make into this talk's text. No need for a full script."),
    (5, "first", "完整讲一遍", "不看稿讲完，录下来看要点覆盖。",
     "Run it once", "Talk it through without notes and record it to check coverage."),
    (3, "timed", "计时讲", "按规定时长讲，语速进目标带。",
     "Timed run", "Speak to the time limit, with your pace inside the target band."),
    (2, "outsider", "换个对象讲", "讲给一个不懂技术的人听，看哪里需要多解释一句。",
     "Explain it to an outsider", "Talk it through for someone non-technical and notice where you need one more sentence."),
    (1, "ends", "只练开头和结尾", "开头三十秒抛钩子，结尾二十秒回到你要的结论。",
     "Openings and endings only", "Thirty seconds to hook them at the start, twenty to land the conclusion you want."),
    (0, "warmup", "上场前热身", "跟读一段六十秒的片段，把嗓子和语速带起来，再讲一遍开头。",
     "Warm up before you go on", "Shadow a sixty-second clip to warm up your voice and pace, then run the opening once more."),
]

EVENT_KINDS = {
    "review": "架构评审", "one_on_one": "1:1", "team": "团队会", "stakeholder": "业务方",
    "allhands": "全员会", "interview": "面试", "talk": "分享", "other": "其他",
}
EVENT_KINDS_EN = {
    "review": "Architecture review", "one_on_one": "1:1", "team": "Team meeting", "stakeholder": "Stakeholders",
    "allhands": "All-hands", "interview": "Interview", "talk": "Talk", "other": "Other",
}

TEMPLATES = [
    {"title": "Architecture Review：数据基础设施", "kind": "review", "minutes": 10,
     "title_en": "Architecture Review: data infrastructure"},
    {"title": "双周 1:1：进展和卡点", "kind": "one_on_one", "minutes": 3,
     "title_en": "Biweekly 1:1: progress and blockers"},
    {"title": "数据团队 onsite：semantic layer", "kind": "talk", "minutes": 15,
     "title_en": "Data team onsite: semantic layer"},
    {"title": "面试：自我介绍与项目深挖", "kind": "interview", "minutes": 5,
     "title_en": "Interview: introduction and project deep dive"},
]


def event_kinds() -> dict:
    return EVENT_KINDS_EN if i18n.is_en() else EVENT_KINDS


def templates() -> list[dict]:
    return [{"title": i18n.field(tp, "title"), "kind": tp["kind"], "minutes": tp["minutes"]} for tp in TEMPLATES]


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
        "title": (body.get("title") or "").strip() or t("一次讲话", "A talk"),
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
    for offset, key, title_zh, detail_zh, title_en, detail_en in PREP_STEPS:
        title, detail = t(title_zh, title_en), t(detail_zh, detail_en)
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
        ev["kind_label"] = event_kinds().get(ev["kind"], t("其他", "Other"))
        ev["steps"] = prep_plan(ev, sessions, today)
        ev["past"] = d < today
        out.append(ev)
    return out


# ---------------------------------------------------------------- week and plan


# One rule for "practiced that day", used by the laurel, the streak, the recap and the year:
# at least PRACTICED_SEC of recording, where listening to an original counts half (hearing
# someone else is lighter work than speaking). Listening back to yourself is review and
# doesn't count toward the day, though its minutes still show.
PRACTICED_SEC = 20   # one real attempt is enough to count the day


def day_activity(sessions: list[dict], activity: list[dict]) -> dict[str, float]:
    """Seconds that count toward a practiced day: recordings plus half of listening to originals."""
    out: dict[str, float] = {}
    for s in sessions:
        out[s["created_at"][:10]] = out.get(s["created_at"][:10], 0) + float(s.get("duration_sec") or 0)
    for e in activity:
        if e.get("kind") == "listen_reference":
            out[e["at"][:10]] = out.get(e["at"][:10], 0) + float(e.get("wall_sec") or 0) * 0.5
    return out


def practiced_days(sessions: list[dict], activity: list[dict]) -> set[str]:
    """Every day (ISO date) that counts as practiced."""
    return {d for d, sec in day_activity(sessions, activity).items() if sec >= PRACTICED_SEC}


def day_seconds(sessions: list[dict], activity: list[dict]) -> dict[str, float]:
    """Time actually spent per day, at face value: recording and all listening. Every
    "minutes" figure shows this (the week's bars and total, the recap, the year)."""
    out: dict[str, float] = {}
    for s in sessions:
        out[s["created_at"][:10]] = out.get(s["created_at"][:10], 0) + float(s.get("duration_sec") or 0)
    for e in activity:
        out[e["at"][:10]] = out.get(e["at"][:10], 0) + float(e.get("wall_sec") or 0)
    return out


def week_view(sessions: list[dict], activity: list[dict], today: date | None = None, settings: dict | None = None) -> dict:
    today = today or date.today()
    s = settings or load_settings()
    per_day = day_activity(sessions, activity)
    spent = day_seconds(sessions, activity)
    start = monday(today)
    days = []
    for i in range(7):
        d = start + timedelta(days=i)
        practiced = per_day.get(d.isoformat(), 0.0) >= PRACTICED_SEC
        state = "done" if practiced else ("today" if d == today else ("missed" if d < today else "future"))
        days.append({"date": d.isoformat(), "state": state, "minutes": round(spent.get(d.isoformat(), 0.0) / 60, 1)})
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
            "title": clip.get("title") or t("今日片段", "Today's clip"),
            "subtitle": clip.get("subtitle") or "",
            "seconds": round(clip.get("duration") or 90),
            "detail": t("先听原文，再跟着读。外放时录音不放原声，戴耳机可以边听边跟。",
                        "Listen to the original first, then read along. On speakers the original stays quiet while you record; "
                        "with headphones you can listen and follow at the same time.") if kind == "shadow"
                      else t("先听原文，再用自己的话在九十秒内复述。看讲到了几个要点。",
                             "Listen to the original first, then retell it in your own words within ninety seconds. "
                             "See how many of its points you cover."),
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
            "title": t(f"{ev['title']}：{stp['title']}", f"{ev['title']}: {stp['title']}"),
            "subtitle": t(f"还有 {ev['days_left']} 天", _days_to_go(ev["days_left"])) + f" · {ev['kind_label']}",
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
                "title": t(f"{pv['form_name']}：{pv['audience']}", f"{pv['form_name']}, for {pv['audience']}"),
                "subtitle": pv["form_greek"],
                "prompt": p["text"],
                "seconds": p["seconds"],
                "detail": pv["hint"],
                "session_id": done(item_id),
            })
    return {"block": block, "items": items, "shuffle": st.get("shuffle", 0)}


def _days_to_go(n: int) -> str:
    return "Today" if n == 0 else f"{n} day to go" if n == 1 else f"{n} days to go"


def shuffle_prompt(d: date) -> None:
    st = load_plan_state(d)
    st["shuffle"] = int(st.get("shuffle", 0)) + 1
    save_plan_state(d, st)


# ---------------------------------------------------------------- feedback


def review(session: dict, previous: dict | None, block: dict, tg: dict) -> dict:
    """One headline and up to three concrete lines, judged against this block's focus.
    `zh` is the language of the recording; t() picks the language of the interface."""
    m = session["metrics"]
    zh = m.get("language", "en").startswith("zh")
    unit = t("字/分", "chars/min") if zh else t("词/分", "wpm")
    lines: list[str] = []
    deferred: list[str] = []
    focus: list[dict] = []

    wpm = m["wpm"]
    lo, hi = (180, 260) if zh else (tg["wpm_low"], tg["wpm_high"])
    band = t(f"{lo} 到 {hi}", f"{lo}–{hi}")
    pace_state = "low" if wpm < lo else ("high" if wpm > hi else "in")
    prev_wpm = previous["metrics"]["wpm"] if previous else None
    focus.append({"key": "wpm", "label": t("语速", "Pace"), "value": round(wpm), "unit": unit,
                  "target": band, "state": pace_state,
                  "delta": round(wpm - prev_wpm) if prev_wpm is not None else None})
    if pace_state == "low":
        lines.append(t(f"语速 {round(wpm)} {unit}，比目标低 {round(lo - wpm)}。下一遍把每句的开头说快，不要等整句想好再开口。",
                       f"Pace {round(wpm)} {unit}, {round(lo - wpm)} below target. Next time start each sentence faster; "
                       "don't wait until the whole sentence is ready."))
    elif pace_state == "high":
        lines.append(t(f"语速 {round(wpm)} {unit}，超过目标带。在要点之间留半秒停顿，让听众跟上。",
                       f"Pace {round(wpm)} {unit}, above the target band. Leave half a second between points so listeners keep up."))
    else:
        moved = ""
        if prev_wpm is not None and abs(wpm - prev_wpm) >= 5:
            faster = wpm > prev_wpm
            moved = t(f"，比上一遍{'快' if faster else '慢'} {abs(round(wpm - prev_wpm))}",
                      f", {abs(round(wpm - prev_wpm))} {'faster' if faster else 'slower'} than last time")
        pace_ok = t(f"语速 {round(wpm)} {unit}，在目标带 {band} 里{moved}。",
                    f"Pace {round(wpm)} {unit}, inside the target band of {band}{moved}.")
        if block["key"] == "tonos":
            deferred.append(pace_ok)   # in the tone block the sentence-level findings come first
        else:
            lines.append(pace_ok)

    pitch = (m.get("pitch") or {}).get("range_semitones")
    if pitch is not None:
        prev_pitch = ((previous or {}).get("metrics", {}).get("pitch") or {}).get("range_semitones") if previous else None
        st = "in" if pitch >= tg["pitch"] else "low"
        focus.append({"key": "pitch", "label": t("音高起伏", "Pitch range"), "value": pitch, "unit": t("半音", "semitones"),
                      "target": f"≥ {tg['pitch']}", "state": st,
                      "delta": round(pitch - prev_pitch, 1) if prev_pitch is not None else None})
        if st == "low" and ("pitch" in block["focus"] or len(lines) < 2):
            lines.append(t(f"音高起伏 {pitch} 半音，偏平。每句挑一个关键词，重读并把音调抬上去。",
                           f"Pitch range {pitch} semitones, on the flat side. Pick one key word in each sentence, "
                           "stress it and lift your pitch."))

    _prosody_review(m, previous, block, tg, zh, lines, deferred, focus)

    fpm = m["fillers"]["per_minute"]
    top = next(iter(m["fillers"].get("breakdown") or {}), None)
    prev_f = previous["metrics"]["fillers"]["per_minute"] if previous else None
    fst = "in" if fpm <= tg["fillers"] else "high"
    focus.append({"key": "fillers", "label": t("填充词", "Fillers"), "value": round(fpm, 1), "unit": t("次/分", "/min"),
                  "target": f"≤ {tg['fillers']}", "state": fst,
                  "delta": round(fpm - prev_f, 1) if prev_f is not None else None})
    if fst == "high" and ("fillers" in block["focus"] or len(lines) < 3):
        word = t(f"，最多的是 {top}", f", mostly “{top}”") if top else ""
        lines.append(t(f"填充词每分钟 {round(fpm, 1)} 次{word}。想停就停，停顿比 um 好听。",
                       f"{round(fpm, 1)} fillers a minute{word}. When you want to stop, stop: a pause sounds better than um."))

    loud = (m.get("loudness") or {}).get("mean_db")
    if loud is not None and "loudness" in block["focus"]:
        st = "in" if loud >= tg["loudness"] else "low"
        rel = round(loud - (tg["loudness"] + 3.0), 1)   # against your recent median, not an absolute level
        focus.append({"key": "loudness", "label": t("音量", "Volume"), "value": rel, "unit": "dB",
                      "target": t("和最近几次比", "vs. recent takes"), "state": st, "delta": None})
        if st == "low":
            lines.append(t("这次比你最近几次小声了 3 dB 以上。坐直，对着房间最远的墙说。",
                           "This take was more than 3 dB quieter than your last few. Sit up and talk to the far wall of the room."))

    cov = m.get("coverage")
    if cov:
        missed = [p["text"] for p in cov["points"] if p["status"] == "missed"]
        focus.append({"key": "coverage", "label": t("要点覆盖", "Coverage"), "value": round(cov["coverage"] * 100), "unit": "%",
                      "target": "≥ 80", "state": "in" if cov["coverage"] >= 0.8 else "low", "delta": None})
        if missed and "coverage" in block["focus"]:
            first = missed[0][:40] + ("…" if len(missed[0]) > 40 else "")
            lines.append(t(f"漏掉了 {len(missed)} 个要点，比如「{first}」。",
                           f"Missed {len(missed)} key point{'s' if len(missed) != 1 else ''}, such as “{first}”."))

    lines.extend(deferred)

    # Headline: the block's first focus that is off target, otherwise the best news.
    order = block["focus"] or ["wpm"]
    off = [f for k in order for f in focus if f["key"] == k and f["state"] != "in"]
    if off:
        f = off[0]
        headline = {"wpm": t("语速还要再提一点", "Pick up the pace a little") if f["state"] == "low"
                           else t("语速偏快，留点停顿", "A bit fast; leave some pauses"),
                    "pitch": t("语调还偏平", "Still a little flat"), "fillers": t("填充词偏多", "Too many fillers"),
                    "stress": t("重读还不明显", "Stress one word per sentence"),
                    "melody": t("语调还没跟上原声", "Not yet the speaker's tune"),
                    "loudness": t("声音再大一点", "A little louder"),
                    "coverage": t("要点漏了几个", "A few key points missed")}.get(f["key"], t("继续", "Keep going"))
    else:
        headline = t("这一遍达标了", "On target this time") if focus else t("录好了", "Recorded")
    return {"headline": headline, "lines": lines[:3], "focus": focus, "block": block["key"]}


def _clip(text: str, n: int) -> str:
    text = text.strip()
    return text if len(text) <= n else text[:n].rstrip() + "…"


def _clock(sec: float) -> str:
    sec = int(round(sec))
    return f"{sec // 60}:{sec % 60:02d}"


_ENDING = {"fall": ("下沉", "falls"), "rise": ("上扬", "rises"), "level": ("拖平", "stays level")}


def _melody_line(r: dict) -> str:
    """The shadowed sentence furthest from the speaker, and what differs."""
    text = _clip(r["text"], 30)
    ref, yours = r.get("ref_final"), r.get("your_final")
    if ref and yours and ref != yours:
        return t(f"跟原声比，「{text}」这句差得最多：原声句尾{_ENDING[ref][0]}，你的{_ENDING[yours][0]}。",
                 f"Against the speaker, “{text}” is furthest off: their ending {_ENDING[ref][1]}, yours {_ENDING[yours][1]}.")
    if r.get("ref_stress") and (r.get("your_stress") or "").lower() != r["ref_stress"].lower():
        rs, ys = r["ref_stress"], r.get("your_stress")
        return t(f"跟原声比，「{text}」这句差得最多：原声重读「{rs}」，" + (f"你重读的是「{ys}」。" if ys else "你没有明显的重读。"),
                 f"Against the speaker, “{text}” is furthest off: they stress “{rs}”, "
                 + (f"you stress “{ys}”." if ys else "you stress nothing in particular."))
    return t(f"跟原声比，「{text}」这句的语调走向差得最多。回放这一句，再跟一遍。",
             f"Against the speaker, the tune of “{text}” is furthest off. Replay that sentence and shadow it again.")


def _prosody_review(m: dict, previous: dict | None, block: dict, tg: dict, zh: bool,
                    lines: list[str], deferred: list[str], focus: list[dict]) -> None:
    """Sentence-level findings from prosody.py: tune against the reference when shadowing,
    stressed words, and in the tone block one more of monotone stretches, rising statements
    or fading ends. In the pace-and-volume block fading ends come after the block's own lines."""
    pros = m.get("prosody") or {}
    ps = pros.get("summary") or {}
    sents = pros.get("sentences") or []
    prev_pros = ((previous or {}).get("metrics") or {}).get("prosody") or {}

    sh = pros.get("shadow") or {}
    shs = sh.get("summary") or {}
    if shs.get("similarity") is not None:
        sim = shs["similarity"]
        prev_sim = ((prev_pros.get("shadow") or {}).get("summary") or {}).get("similarity")
        st = "in" if sim >= 60 else "low"
        focus.insert(1, {"key": "melody", "label": t("语调贴合", "Tune match"), "value": sim, "unit": "%",
                         "target": "≥ 60", "state": st, "delta": sim - prev_sim if prev_sim is not None else None})
        worst = next((r for r in sh.get("sentences") or [] if shs.get("worst") and r["i"] == shs["worst"][0]), None)
        if worst and st == "low":
            lines.append(_melody_line(worst))

    if block["key"] == "tonos" and ps.get("stress_share") is not None and (ps.get("stress_judged") or 0) >= 3:
        share, judged = ps["stress_share"], ps["stress_judged"]
        prev_share = _stress_share(previous) if previous else None
        st = "in" if share >= tg["stress"] else "low"
        focus.append({"key": "stress", "label": t("有重读的句子", "Stressed sentences"), "value": share, "unit": "%",
                      "target": f"≥ {tg['stress']}", "state": st,
                      "delta": round(share - prev_share) if prev_share is not None else None})
        if st == "low":
            clear = round(share * judged / 100)
            ex = next((x for x in sents if x.get("stress") and not x["stress"]["clear"] and len(x["text"]) >= 8), None)
            lines.append(t(f"{judged} 句里有 {clear} 句听得出重读词"
                           + (f"，「{_clip(ex['text'], 30)}」整句没有重点" if ex else "")
                           + "。每句挑一个关键词，说得更高、更响、稍慢一点。",
                           f"{clear} of {judged} sentences have a word that stands out"
                           + (f"; “{_clip(ex['text'], 30)}” has none" if ex else "")
                           + ". Pick one key word per sentence and say it higher, louder and a touch slower."))

    extra = []
    if block["key"] == "tonos" and ps.get("monotone"):
        f = max(ps["monotone"], key=lambda x: x["end"] - x["start"])
        dur = round(f["end"] - f["start"])
        extra.append(t(f"{_clock(f['start'])}–{_clock(f['end'])} 这 {dur} 秒音高几乎没有起伏。回放听一下，这里正适合加一个重读。",
                       f"From {_clock(f['start'])} to {_clock(f['end'])} ({dur} s) your pitch barely moves. "
                       "Play it back: that's the place to stress a word."))
    if block["key"] == "tonos" and not zh:
        ups = [x for x in sents if (x.get("final") or {}).get("dir") == "rise" and not x["text"].rstrip().endswith("?")]
        ended = sum((ps.get("final") or {}).values())
        if len(ups) >= 2 and len(ups) >= 0.3 * ended:
            extra.append(t(f"有 {len(ups)} 句陈述句句尾上扬，比如「{_clip(ups[0]['text'], 30)}」，听起来像在提问。陈述句的句尾往下收。",
                           f"{len(ups)} statements rise at the end, such as “{_clip(ups[0]['text'], 30)}”, "
                           "so they sound like questions. Let statements fall at the end."))
    fading = [x for x in sents if x.get("fades")]
    if block["key"] in ("tachos", "tonos") and len(fading) >= 2:
        (extra if block["key"] == "tonos" else deferred).append(t(f"有 {len(fading)} 句句尾的音量掉下去了，比如「{_clip(fading[0]['text'], 30)}」。最后一个词也要送到。",
                       f"{len(fading)} sentences fade out at the end, such as “{_clip(fading[0]['text'], 30)}”. "
                       "Carry your voice through the last word."))
    if extra:
        lines.append(extra[0])


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
    spent = day_seconds(sessions, activity)
    days = []
    for i in range(7):
        d = start + timedelta(days=i)
        days.append({"date": d.isoformat(), "practiced": per_day.get(d.isoformat(), 0.0) >= PRACTICED_SEC,
                     "minutes": round(spent.get(d.isoformat(), 0.0) / 60, 1)})
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
