"""Daily clips: every day, pick one or two short passages from talks that fit the
current training block, cut them, and add them as practices with a reference recording.

Free path: yt-dlp reads metadata and downloads only the needed section of audio,
local Whisper transcribes it, and a heuristic picks a monologue window of about
a minute and a half. YouTube's caption endpoint rate-limits (HTTP 429), so captions
are never used. Optional: when a Claude API key is set, Claude picks the window among
the best candidates and writes the notes.

Runs in a background thread inside the server. Nothing here is on the app's launch path.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

import analysis
import coach
import i18n
import paths

DAILY_DIR = paths.DATA_DIR / "daily"
CACHE_DIR = DAILY_DIR / "cache"
SOURCES_FILE = DAILY_DIR / "sources.json"
STATE_FILE = DAILY_DIR / "state.json"

# Talks and lectures first: one speaker for minutes at a time is what shadowing needs.
# "role" decides which slot a source fills: a story to shadow, or an explanation to retell.
DEFAULT_SOURCES = [
    {"id": "ecorner", "name": "Stanford eCorner", "url": "https://www.youtube.com/@ecorner/videos",
     "kind": "talk", "role": "story", "enabled": True, "weight": 3, "min_sec": 60},
    {"id": "yc", "name": "Y Combinator", "url": "https://www.youtube.com/@ycombinator/videos",
     "kind": "talk", "role": "story", "enabled": True, "weight": 3},
    {"id": "gsb", "name": "Stanford GSB", "url": "https://www.youtube.com/@StanfordGSB/videos",
     "kind": "talk", "role": "story", "enabled": True, "weight": 1},
    {"id": "ted", "name": "TED", "url": "https://www.youtube.com/@TED/videos",
     "kind": "talk", "role": "story", "enabled": True, "weight": 2},
    {"id": "tfts", "name": "Think Fast, Talk Smart", "query": "Think Fast Talk Smart Matt Abrahams communication",
     "kind": "search", "role": "story", "enabled": True, "weight": 1},
    {"id": "aicouncil", "name": "AI Council (Data Council)", "url": "https://www.youtube.com/@aicouncilconf/videos",
     "kind": "talk", "role": "story", "enabled": True, "weight": 3},
    {"id": "dbt", "name": "dbt Labs · Coalesce", "url": "https://www.youtube.com/@dbt-labs/videos",
     "kind": "talk", "role": "explain", "enabled": True, "weight": 2},
    {"id": "aie", "name": "AI Engineer", "url": "https://www.youtube.com/@aiDotEngineer/videos",
     "kind": "talk", "role": "explain", "enabled": True, "weight": 3},
    {"id": "anthropic", "name": "Anthropic", "url": "https://www.youtube.com/@anthropic-ai/videos",
     "kind": "talk", "role": "explain", "enabled": True, "weight": 1, "min_sec": 60},
    {"id": "snowflake", "name": "Snowflake", "url": "https://www.youtube.com/@SnowflakeInc/videos",
     "kind": "keynote", "role": "explain", "enabled": False, "weight": 1},
    {"id": "lenny", "name": "Lenny's Podcast", "url": "https://www.youtube.com/@LennysPodcast/videos",
     "kind": "interview", "role": "story", "enabled": False, "weight": 1},
    {"id": "winston", "name": "Patrick Winston · How to Speak", "video": "Unzc731iCUY",
     "kind": "video", "role": "explain", "enabled": True, "weight": 1},
    {"id": "treasure", "name": "Julian Treasure · How to speak so that people want to listen", "video": "eIho2S0ZahI",
     "kind": "video", "role": "story", "enabled": True, "weight": 1},
]

SKIP_TITLE = re.compile(r"#shorts|trailer|teaser|livestream|live stream|\bpodcast trailer\b", re.I)
# Formats where several people take turns: fine to watch, poor to shadow.
MULTI_VOICE = re.compile(r"panel|discussion|screening|q\s*&\s*a|roundtable|debate|in conversation|conversation with|"
                         r"fireside|podcast|interview|webinar|\bama\b|town hall|live from", re.I)
# Product demos and workshops narrate a screen; poor material to retell.
DEMO_TITLE = re.compile(r"launchpad|\bdemo\b|demo day|walkthrough|tutorial|workshop|hands[- ]on|live coding|how to use|getting started", re.I)
DEMO_SPEECH = re.compile(r"\b(let's go to|click on|as you can see|on the screen|this button|let me show you|scroll down|"
                         r"go back to|we can modify|let's redo|over here|right here)\b", re.I)
# A moderator running the room: questions, mics, polls, slides.
LOGISTICS = re.compile(r"\b(next question|questions? (from|for) the audience|the mic|microphone|let's bring|poll|"
                       r"next slide|this slide|housekeeping|welcome everyone|thank you all for|round of applause|"
                       r"we're gonna take you through|raise your hand)\b", re.I)
SPONSOR = re.compile(r"\b(sponsor|brought to you by|promo code|discount code|use code|subscribe|link in the description)\b", re.I)
STORY_WORDS = re.compile(r"\b(I remember|the first time|when I|when we|story|years ago|one day|turned out|realized)\b", re.I)
EXPLAIN_WORDS = re.compile(r"\b(the reason|because|the way it works|think of it|for example|imagine|the key|which means|in other words)\b", re.I)

_status = {"state": "idle", "message": "", "date": None, "progress": 0.0, "updated_at": None}
_lock = threading.Lock()
_create_practice = None
_busy = None   # callable returning True while the server is analysing a recording


def configure(create_practice_fn, busy_fn=None) -> None:
    global _create_practice, _busy
    _create_practice = create_practice_fn
    _busy = busy_fn


def status() -> dict:
    return dict(_status)


def _set(state: str, message: str = "", progress: float | None = None, day: str | None = None) -> None:
    _status.update({"state": state, "message": message, "updated_at": datetime.now().isoformat(timespec="seconds")})
    if progress is not None:
        _status["progress"] = round(progress, 2)
    if day is not None:
        _status["date"] = day


# ---------------------------------------------------------------- files and tools


def ensure_dirs() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if not SOURCES_FILE.exists():
        SOURCES_FILE.write_text(json.dumps(DEFAULT_SOURCES, ensure_ascii=False, indent=1))


def load_sources() -> list[dict]:
    ensure_dirs()
    try:
        return json.loads(SOURCES_FILE.read_text())
    except ValueError:
        return list(DEFAULT_SOURCES)


def save_sources(items: list[dict]) -> None:
    ensure_dirs()
    SOURCES_FILE.write_text(json.dumps(items, ensure_ascii=False, indent=1))


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except ValueError:
            pass
    return {"used_videos": {}, "days": {}}


def save_state(st: dict) -> None:
    ensure_dirs()
    STATE_FILE.write_text(json.dumps(st, ensure_ascii=False, indent=1))


# Apps launched from Finder get a minimal PATH; look where Homebrew, uv and bun install.
EXTRA_PATHS = ["/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin"),
               str(Path.home() / ".bun/bin"), str(Path.home() / ".deno/bin")]


def tool_env() -> dict:
    env = dict(os.environ)
    parts = env.get("PATH", "").split(":")
    env["PATH"] = ":".join([p for p in EXTRA_PATHS if p not in parts] + parts)
    return env


def tool(name: str) -> str | None:
    return shutil.which(name, path=tool_env()["PATH"])


def tools_report() -> dict:
    return {"yt_dlp": tool("yt-dlp"), "ffmpeg": tool("ffmpeg")}


def run(cmd: list[str], timeout: int = 300) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=tool_env())
    if p.returncode != 0:
        tail = (p.stderr or p.stdout or "").strip().splitlines()[-1:] or [f"exit {p.returncode}"]
        raise RuntimeError(tail[0][:300])
    return p.stdout


# ---------------------------------------------------------------- choosing a video


def list_videos(src: dict, limit: int = 12) -> list[dict]:
    if src.get("video"):
        return [{"id": src["video"], "title": src.get("name"), "duration": None}]
    url = src.get("url") or f"ytsearch{limit}:{src.get('query', '')}"
    out = run([tool("yt-dlp"), "--flat-playlist", "-I", f"1:{limit}", "--no-warnings", "-J", url], timeout=120)
    data = json.loads(out)
    vids = []
    for e in data.get("entries") or []:
        title = e.get("title") or ""
        if not e.get("id") or SKIP_TITLE.search(title):
            continue
        if src.get("kind") != "interview" and (MULTI_VOICE.search(title) or DEMO_TITLE.search(title)):
            continue
        vids.append({"id": e["id"], "title": title, "duration": e.get("duration")})
    return vids


def video_info(vid: str) -> dict:
    out = run([tool("yt-dlp"), "-J", "--skip-download", "--no-warnings", f"https://www.youtube.com/watch?v={vid}"], timeout=120)
    d = json.loads(out)
    return {k: d.get(k) for k in ("id", "title", "channel", "uploader", "duration", "chapters", "heatmap",
                                  "language", "upload_date", "webpage_url", "view_count")}


def pick_sources(sources: list[dict], role: str, day: date, salt: str) -> list[dict]:
    """Deterministic per day and role, weighted, no network involved."""
    pool = [s for s in sources if s.get("enabled") and s.get("role") == role]
    if not pool:
        pool = [s for s in sources if s.get("enabled")]
    ranked = []
    for s in pool:
        h = int(hashlib.sha1(f"{day.isoformat()}:{role}:{salt}:{s['id']}".encode()).hexdigest(), 16) % 1000 / 1000
        ranked.append((h / max(1, s.get("weight", 1)), s))
    return [s for _, s in sorted(ranked, key=lambda t: t[0])]


def choose_section(info: dict, role: str, length: float = 200.0) -> tuple[float, float]:
    """Where to listen inside a long video: the most replayed moment if YouTube has one,
    else a chapter that sounds like a story or an explanation, else a stretch past the intro."""
    dur = float(info.get("duration") or 0)
    if dur <= 150:
        return 0.0, dur
    lo, hi = min(90.0, dur * 0.1), max(dur - 60.0, 120.0)
    heat = [h for h in (info.get("heatmap") or []) if lo <= h.get("start_time", 0) <= hi - 60]
    if heat:
        peak = max(heat, key=lambda h: h.get("value", 0))
        start = max(lo, float(peak["start_time"]) - 60)
        return start, min(dur, start + length)
    chapters = [c for c in (info.get("chapters") or []) if c.get("end_time", 0) - c.get("start_time", 0) >= 80]
    inner = [c for c in chapters if c["start_time"] >= lo and c["end_time"] <= dur - 30] or chapters
    if inner:
        words = STORY_WORDS if role == "story" else EXPLAIN_WORDS
        def score(c):
            title = c.get("title") or ""
            pos = c["start_time"] / dur
            return (2 if words.search(title) else 0) + (1 - abs(pos - 0.45)) + (0.5 if re.search(r"how|why|lesson|story|mistake|first", title, re.I) else 0)
        c = max(inner, key=score)
        start = float(c["start_time"]) + 3
        return start, min(float(c["end_time"]), start + length)
    seed = int(hashlib.sha1((info.get("id") or "").encode()).hexdigest(), 16) % 1000 / 1000
    start = max(lo, dur * (0.25 + 0.3 * seed))
    return start, min(dur, start + length)


def download_section(vid: str, start: float, end: float, base: Path) -> Path:
    for old in base.parent.glob(base.name + ".*"):
        old.unlink()
    cmd = [tool("yt-dlp"), "-f", "bestaudio[ext=m4a]/bestaudio", "--download-sections", f"*{start:.0f}-{end:.0f}",
           "--no-warnings", "--no-progress", "-q", "--ffmpeg-location", tool("ffmpeg"),
           "-o", str(base) + ".%(ext)s", f"https://www.youtube.com/watch?v={vid}"]
    run(cmd, timeout=900)
    found = sorted(base.parent.glob(base.name + ".*"))
    if not found:
        raise RuntimeError(i18n.t("音频没有下载下来", "The audio didn't download"))
    return found[0]


# ---------------------------------------------------------------- choosing the passage


def sentences_from_words(words: list[dict]) -> list[dict]:
    out, cur = [], []
    for w in words:
        cur.append(w)
        if re.search(r"[.!?。！？]$", w["text"].strip()):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    sents = []
    for ws in out:
        text = " ".join(x["text"].strip() for x in ws).replace(" ,", ",")
        sents.append({"start": ws[0]["start"], "end": ws[-1]["end"], "text": text, "n": len(ws),
                      "question": text.rstrip().endswith("?")})
    return sents


def candidate_windows(sents: list[dict], min_sec: float = 55, max_sec: float = 105) -> list[dict]:
    wins = []
    for i in range(len(sents)):
        if i > 0 and sents[i]["start"] - sents[i - 1]["end"] < 0.15:
            continue   # start where the speaker actually paused
        n_words, j = 0, i
        while j < len(sents) and sents[j]["end"] - sents[i]["start"] <= max_sec:
            n_words += sents[j]["n"]
            dur = sents[j]["end"] - sents[i]["start"]
            if dur >= min_sec:
                wins.append({"i": i, "j": j, "start": sents[i]["start"], "end": sents[j]["end"], "words": n_words})
            j += 1
    return wins


def sentence_pitches(sents: list[dict], audio) -> None:
    """Median pitch per sentence (Hz), or None when too short to tell. Two people taking
    turns show up as sentences that jump back and forth in pitch."""
    sr = analysis.SAMPLE_RATE
    for snt in sents:
        a, b = int(snt["start"] * sr), int(snt["end"] * sr)
        est = analysis.estimate_pitch(audio[a:b]) if b - a > sr * 0.8 else {}
        snt["f0"] = est.get("median_hz")


def other_voice_ratio(part: list[dict]) -> float:
    """Share of sentences whose pitch sits far from the window's main voice."""
    import math
    f0s = [snt["f0"] for snt in part if snt.get("f0")]
    if len(f0s) < 4:
        return 0.0
    ref = sorted(f0s)[len(f0s) // 2]
    off = sum(1 for f in f0s if abs(12 * math.log2(f / ref)) > 3.5)
    return off / len(f0s)


def score_window(w: dict, sents: list[dict], role: str, pace: tuple[float, float]) -> float:
    part = sents[w["i"]:w["j"] + 1]
    dur = w["end"] - w["start"]
    wpm = w["words"] / dur * 60
    short = sum(1 for s in part if s["n"] <= 3) / len(part)          # "Yeah." "Right." means a second voice
    questions = sum(1 for s in part if s["question"]) / len(part)
    avg_len = w["words"] / len(part)
    gaps = sum(1 for a, b in zip(part, part[1:]) if b["start"] - a["end"] > 1.4)
    text = " ".join(s["text"] for s in part)
    lo, hi = pace
    pace_fit = 1.0 if lo <= wpm <= hi else max(0.0, 1 - min(abs(wpm - lo), abs(wpm - hi)) / 40)
    words = STORY_WORDS if role == "story" else EXPLAIN_WORDS
    others = other_voice_ratio(part)
    w["others"] = round(others, 2)
    return (2.0 * (1 - short) + 1.5 * (1 - questions) + min(avg_len, 24) / 24 + 1.2 * pace_fit
            + 0.4 * min(3, len(words.findall(text))) - 0.6 * gaps - 4.0 * bool(SPONSOR.search(text))
            + 0.3 * (1 - abs(dur - 85) / 50) - 6.0 * others - 1.5 * min(2, len(LOGISTICS.findall(text)))
            - 1.2 * min(3, len(DEMO_SPEECH.findall(text))))


def window_text(w: dict, sents: list[dict]) -> str:
    return " ".join(s["text"] for s in sents[w["i"]:w["j"] + 1])


def best_windows(words: list[dict], role: str, pace: tuple[float, float], k: int = 6, audio=None) -> tuple[list[dict], list[dict]]:
    sents = sentences_from_words(words)
    if audio is not None:
        sentence_pitches(sents, audio)
    wins = candidate_windows(sents)
    for w in wins:
        w["score"] = score_window(w, sents, role, pace)
        w["wpm"] = round(w["words"] / (w["end"] - w["start"]) * 60)
    wins.sort(key=lambda w: -w["score"])
    picked: list[dict] = []
    for w in wins:   # keep candidates that do not overlap each other
        if all(w["end"] <= p["start"] or w["start"] >= p["end"] for p in picked):
            picked.append(w)
        if len(picked) >= k:
            break
    return picked, sents


# ---------------------------------------------------------------- optional Claude pick


def claude_pick(cands: list[dict], sents: list[dict], role: str, meta: dict, settings: dict) -> dict | None:
    """Let Claude choose among the heuristic's top windows and write the notes.
    Returns None on any problem, so the free path always works."""
    key = settings["daily"].get("claude_api_key") or os.environ.get("ANTHROPIC_API_KEY")
    if not settings["daily"].get("use_claude") or not key or not cands:
        return None
    try:
        import anthropic
    except ImportError:
        return None
    listing = "\n\n".join(f"[{n}] ({round(c['end'] - c['start'])} s, {c['wpm']} wpm)\n{window_text(c, sents)}"
                          for n, c in enumerate(cands))
    purpose = ("shadowing: the learner repeats it aloud right behind the speaker, so it should be one speaker, "
               "vivid, with clear emphasis and a story arc"
               if role == "story" else
               "retelling: the learner listens once and then explains it in their own words, so it should be one "
               "speaker explaining one idea with a clear structure")
    lang = i18n.t("Chinese", "English")   # the notes appear in the app, in its interface language
    prompt = (
        f"I am a senior data engineer practising spoken English for work: pace, tone, storytelling. "
        f"These passages come from '{meta.get('title')}' ({meta.get('channel')}). "
        f"Choose the one best suited to {purpose}. Skip anything that is two people talking, an ad, or a fragment.\n\n"
        f"{listing}\n\n"
        f"Reply in JSON. title: a short {lang} title for the passage. why: one {lang} sentence on why it fits. "
        f"notice: two short {lang} notes on what to imitate in the delivery (pauses, emphasis, structure)."
    )
    schema = {
        "type": "object",
        "properties": {
            "choice": {"type": "integer"},
            "title": {"type": "string"},
            "why": {"type": "string"},
            "notice": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["choice", "title", "why", "notice"],
        "additionalProperties": False,
    }
    try:
        client = anthropic.Anthropic(api_key=key, timeout=120.0)
        response = client.beta.messages.create(
            model=settings["daily"].get("claude_model") or "claude-opus-5-5",
            max_tokens=4000,
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            output_config={"effort": "medium", "format": {"type": "json_schema", "schema": schema}},
            messages=[{"role": "user", "content": prompt}],
        )
        if response.stop_reason == "refusal":
            return None
        text = next((b.text for b in response.content if b.type == "text"), "")
        data = json.loads(text)
        if not 0 <= int(data["choice"]) < len(cands):
            return None
        return data
    except Exception as e:   # network, auth, quota: fall back to the free path
        print("claude pick failed:", e)
        return None


# ---------------------------------------------------------------- notes


def heuristic_notes(ref_metrics: dict, base: dict, role: str) -> tuple[str, list[str]]:
    t = i18n.t
    wpm = round(ref_metrics["wpm"])
    diff = round(ref_metrics["wpm"] - base["wpm"])
    notes = []
    if role == "story":
        if diff >= 15:
            notes.append(t(f"他的语速 {wpm} 词/分，比你最近快 {diff}。先用 0.85 倍跟两遍，再回到原速。",
                           f"The speaker talks at {wpm} wpm, {diff} faster than you lately. Shadow it twice at 0.85×, then at full speed."))
        elif diff <= -10:
            notes.append(t(f"他的语速 {wpm} 词/分，比你还慢。学他怎么用慢来压住重点。",
                           f"The speaker talks at {wpm} wpm, slower than you. Notice how slowing down lands the key points."))
        else:
            notes.append(t(f"他的语速 {wpm} 词/分，和你差不多。这段练的是重音和停顿，不是速度。",
                           f"The speaker talks at {wpm} wpm, about your pace. This one is about stress and pauses, not speed."))
    p = ref_metrics["pauses"]
    if role == "story":
        if p["count"]:
            notes.append(t(f"这段停顿 {p['count']} 次，最长 {p['longest_sec']} 秒。跟读时在同样的地方停。",
                           f"{p['count']} pauses here, the longest {p['longest_sec']} s. Pause in the same places when you shadow."))
        pr = (ref_metrics.get("pitch") or {}).get("range_semitones")
        if pr and pr >= base["pitch"] + 1.5:
            more = round(pr - base["pitch"], 1)
            notes.append(t(f"音高起伏 {pr} 半音，比你多 {more}。听他把哪几个词说重。",
                           f"Pitch range {pr} semitones, {more} more than yours. Listen for the words that get the stress."))
    else:
        notes.append(t("听的时候只抓三样：他的观点，一个理由，一个例子。复述时按这个顺序讲。",
                       "Listen for three things only: the point, one reason, one example. Retell them in that order."))
        notes.append(t(f"原段 {round(ref_metrics['duration_sec'])} 秒，复述控制在九十秒内，用你自己的词。",
                       f"The original runs {round(ref_metrics['duration_sec'])} s. Keep your retelling under ninety seconds, in your own words."))
    why = (t("一个人连续讲的故事段落，适合跟读，练开头抛钩子和语气推进。",
             "One person telling a story without a break: good for shadowing, and for practising a hook and a building tone.")
           if role == "story" else
           t("一段技术或观点的解释，适合听一遍后用自己的话复述。",
             "One explanation of a technical idea or a view: listen once, then retell it in your own words."))
    return why, notes[:3]


# ---------------------------------------------------------------- one clip end to end


def cut(src: Path, start: float, end: float, out: Path) -> None:
    dur = end - start
    run([tool("ffmpeg"), "-loglevel", "error", "-y", "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", "-i", str(src),
         "-af", f"afade=t=in:st=0:d=0.12,afade=t=out:st={max(0.0, dur - 0.2):.2f}:d=0.2",
         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", str(out)], timeout=180)


def make_clip(section: Path, offset: float, meta: dict, role: str, day: date, settings: dict, base: dict) -> str:
    """section: audio that starts at `offset` seconds into the source video."""
    ensure_dirs()
    block = coach.current_block(day, settings)
    tg = coach.targets(block, base)
    pace = (max(tg["wpm_low"] + 10, 145), 200) if role == "story" else (130, 185)
    while _busy and _busy():
        time.sleep(3)   # a recording is being analysed; it goes first
    m = analysis.analyze(str(section), "en")
    from faster_whisper.audio import decode_audio
    audio = decode_audio(str(section), sampling_rate=analysis.SAMPLE_RATE)
    cands, sents = best_windows(m["words"], role, pace, audio=audio)
    if not cands:
        raise RuntimeError(i18n.t("这一段里没有找到一个人连续讲一分钟以上的地方", "No stretch of one person talking for over a minute in this section"))
    pick = claude_pick(cands, sents, role, meta, settings)
    w = cands[int(pick["choice"])] if pick else cands[0]
    clip_path = CACHE_DIR / f"clip-{meta.get('id', 'local')}-{int(offset + w['start'])}.m4a"
    cut(section, max(0.0, w["start"] - 0.15), w["end"] + 0.35, clip_path)
    abs_start = offset + w["start"]
    speaker = meta.get("channel") or meta.get("uploader") or i18n.t("参照", "Reference")
    title = (pick or {}).get("title") or (meta.get("title") or i18n.t("今日片段", "Today's clip"))
    link = f"https://www.youtube.com/watch?v={meta['id']}&t={int(abs_start)}s" if meta.get("id") and meta.get("source") != "local" else meta.get("url")
    clip_meta = {
        "date": day.isoformat(), "role": role, "source_id": meta.get("source_id"), "video_id": meta.get("id"),
        "video_title": meta.get("title"), "channel": speaker, "start": round(abs_start, 1),
        "end": round(offset + w["end"], 1), "url": link, "picked_by": "claude" if pick else "heuristic",
        "wpm": w["wpm"],
    }
    pid = _create_practice(title=title, script=window_text(w, sents), audio_path=clip_path,
                           clip=clip_meta, notes_fn=lambda ref: notes_for(ref, base, role, pick))
    clip_path.unlink(missing_ok=True)
    return pid


def notes_for(ref_metrics: dict, base: dict, role: str, pick: dict | None) -> str:
    why, notes = heuristic_notes(ref_metrics, base, role)
    if pick:
        why = pick.get("why") or why
        notes = (pick.get("notice") or [])[:2] + notes[:1]
    return "\n".join([why] + [f"· {n}" for n in notes])


def clip_from_video(vid: str, role: str, day: date, settings: dict, base: dict, source: dict | None = None,
                    start: float | None = None, end: float | None = None) -> str:
    info = video_info(vid)
    if info.get("language") and not str(info["language"]).startswith("en"):
        raise RuntimeError(i18n.t(f"这个视频不是英文（{info['language']}）", f"This video isn't in English ({info['language']})"))
    if start is None:
        start, end = choose_section(info, role)
    end = end if end is not None else start + 200
    base_path = CACHE_DIR / f"sec-{vid}-{int(start)}"
    section = download_section(vid, start, end, base_path)
    try:
        meta = {**info, "source_id": (source or {}).get("id"), "source": "youtube"}
        return make_clip(section, start, meta, role, day, settings, base)
    finally:
        section.unlink(missing_ok=True)


# ---------------------------------------------------------------- the daily job


def day_record(day: date) -> dict:
    return load_state()["days"].get(day.isoformat()) or {}


def clips_for(day: date) -> list[str]:
    return list(day_record(day).get("items") or [])


def prepare(day: date, sessions: list[dict], force: bool = False) -> None:
    """Make today's clips (or tomorrow's, prepared the night before)."""
    if not _lock.acquire(blocking=False):
        return
    try:
        _prepare(day, sessions, force)
    finally:
        _lock.release()


def _prepare(day: date, sessions: list[dict], force: bool) -> None:
    settings = coach.load_settings()
    want = int(settings["daily"].get("clips_per_day") or 2)
    st = load_state()
    rec = st["days"].get(day.isoformat()) or {"items": [], "errors": []}
    if force:
        rec = {"items": [], "errors": []}
    if len(rec["items"]) >= want and not force:
        return
    missing = [t for t in ("yt-dlp", "ffmpeg") if not tool(t)]
    if missing:
        _set("failed", i18n.t(f"缺少 {' 和 '.join(missing)}。在终端运行 brew install {' '.join(missing)} 后再试。",
                              f"Missing {' and '.join(missing)}. Run brew install {' '.join(missing)} in Terminal, then try again."),
             0, day.isoformat())
        return
    base = coach.baseline(sessions)
    sources = load_sources()
    roles = ["story", "explain"][:want] if want <= 2 else ["story", "explain"] + ["story"] * (want - 2)
    roles = roles[len(rec["items"]):]
    used = st.get("used_videos", {})
    errors = list(rec.get("errors") or [])
    for n, role in enumerate(roles):
        done = False
        for attempt, src in enumerate(pick_sources(sources, role, day, str(len(rec["items"])))[:4]):
            _set("running", i18n.t(f"正在从 {src['name']} 找{'故事' if role == 'story' else '讲解'}片段",
                                   f"Looking for {'a story' if role == 'story' else 'an explanation'} in {src['name']}"),
                 (len(rec["items"]) + 0.1) / want, day.isoformat())
            try:
                lo = int(src.get("min_sec", 150))
                vids = [v for v in list_videos(src) if v["id"] not in used
                        and (v.get("duration") is None or lo <= v["duration"] <= 6000)]
                if not vids:
                    continue
                seed = int(hashlib.sha1(f"{day}:{src['id']}".encode()).hexdigest(), 16)
                vid = vids[seed % min(len(vids), 5)]["id"]
                _set("running", i18n.t(f"正在下载并转写 {src['name']} 的一段音频", f"Downloading and transcribing audio from {src['name']}"),
                     (len(rec["items"]) + 0.4) / want)
                pid = clip_from_video(vid, role, day, settings, base, source=src)
                rec["items"].append(pid)
                used[vid] = day.isoformat()
                done = True
                break
            except Exception as e:
                errors.append(src["name"] + i18n.t("：", ": ") + str(e))
                print("daily clip failed:", src["id"], e)
        if not done:
            break
    st = load_state()
    st["used_videos"] = {**st.get("used_videos", {}), **used}
    rec["errors"] = errors[-6:]
    rec["prepared_at"] = datetime.now().isoformat(timespec="seconds")
    st["days"][day.isoformat()] = {**(st["days"].get(day.isoformat()) or {}), **rec}
    save_state(st)
    n = len(rec["items"])
    clips = f"{n} clip{'s' if n != 1 else ''}"
    if n >= want:
        _set("ready", i18n.t(f"今天的 {n} 段已备好", f"Today's {clips} {'are' if n != 1 else 'is'} ready"), 1.0, day.isoformat())
    elif rec["items"]:
        _set("partial", i18n.t(f"备好了 {n} 段，其余没找到合适的", f"{clips} ready; no good match for the rest"), 1.0, day.isoformat())
    else:
        _set("failed", errors[-1] if errors else i18n.t("没有找到合适的片段", "No suitable clip found"), 0, day.isoformat())


def add_url(url: str, role: str, day: date, sessions: list[dict], start: float | None = None, end: float | None = None) -> None:
    """A video you found yourself: paste the link, get a clip in today's plan."""
    if not _lock.acquire(blocking=False):
        raise RuntimeError(i18n.t("正在准备片段，稍后再试", "Clips are being prepared; try again in a moment"))
    try:
        m = re.search(r"(?:v=|youtu\.be/|shorts/)([\w-]{11})", url)
        if not m:
            raise RuntimeError(i18n.t("只支持 YouTube 链接", "Only YouTube links are supported"))
        t = re.search(r"[?&]t=(\d+)", url)
        if start is None and t:
            start = max(0.0, float(t.group(1)) - 5)
            end = start + 200
        settings = coach.load_settings()
        _set("running", i18n.t("正在处理你贴的视频", "Working on the video you pasted"), 0.3, day.isoformat())
        pid = clip_from_video(m.group(1), role, day, settings, coach.baseline(sessions), start=start, end=end)
        st = load_state()
        rec = st["days"].get(day.isoformat()) or {"items": [], "errors": []}
        rec["items"] = list(rec.get("items") or []) + [pid]
        st["days"][day.isoformat()] = rec
        st.setdefault("used_videos", {})[m.group(1)] = day.isoformat()
        save_state(st)
        _set("ready", i18n.t("你贴的视频已经做成片段", "The video you pasted is now a clip"), 1.0, day.isoformat())
    except Exception as e:
        _set("failed", str(e), 0, day.isoformat())
        raise
    finally:
        _lock.release()


def import_local(path: str, title: str, speaker: str, role: str, day: date, sessions: list[dict], url: str | None = None) -> str:
    """Make a clip from a local audio or video file (also used to test the pipeline offline)."""
    settings = coach.load_settings()
    meta = {"id": None, "title": title, "channel": speaker, "source": "local", "url": url, "source_id": "local"}
    pid = make_clip(Path(path), 0.0, meta, role, day, settings, coach.baseline(sessions))
    st = load_state()
    rec = st["days"].get(day.isoformat()) or {"items": [], "errors": []}
    rec["items"] = list(rec.get("items") or []) + [pid]
    st["days"][day.isoformat()] = rec
    save_state(st)
    return pid


# ---------------------------------------------------------------- push and schedule


def push_ntfy(topic: str, title: str, body: str) -> None:
    """Phone push through ntfy.sh (free, no account). JSON publishing keeps Chinese intact."""
    payload = json.dumps({"topic": topic, "title": title, "message": body, "tags": ["speaking_head"]}).encode("utf-8")
    req = urllib.request.Request("https://ntfy.sh/", data=payload, method="POST",
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=15).read()


def _notify_due(settings: dict, now: datetime) -> bool:
    hh, mm = (settings["daily"].get("notify_time") or "21:30").split(":")
    return (now.hour, now.minute) >= (int(hh), int(mm))


def scheduler(get_sessions, plan_summary) -> None:
    """Background loop: prepare today's clips after the prep hour, tomorrow's in the evening,
    and send the optional phone push at the reminder time."""
    time.sleep(int(os.environ.get("DAILY_START_DELAY", "120")))   # never compete with launch
    while True:
        try:
            s = coach.load_settings()
            now = datetime.now()
            today = now.date()
            if s["daily"].get("enabled"):
                want = int(s["daily"].get("clips_per_day") or 2)
                if now.hour >= int(s["daily"].get("prep_hour", 5)) and len(clips_for(today)) < want and not day_record(today).get("gave_up"):
                    prepare(today, get_sessions())
                    rec = day_record(today)
                    if len(rec.get("items") or []) < want:
                        st = load_state()
                        st["days"].setdefault(today.isoformat(), {})["gave_up"] = True   # retry tomorrow, not every minute
                        save_state(st)
                tomorrow = today + timedelta(days=1)
                if now.hour >= 20 and len(clips_for(tomorrow)) < want and not day_record(tomorrow).get("gave_up"):
                    prepare(tomorrow, get_sessions())
            topic = (s["daily"].get("ntfy_topic") or "").strip()
            if topic and _notify_due(s, now):
                st = load_state()
                rec = st["days"].setdefault(today.isoformat(), {})
                if not rec.get("pushed"):
                    title, body = plan_summary()
                    push_ntfy(topic, title, body)
                    rec["pushed"] = True
                    save_state(st)
        except Exception as e:
            print("daily scheduler:", e)
        time.sleep(60)


if __name__ == "__main__":   # offline test: python daily.py --local FILE "Title" "Speaker" [story|explain]
    import sys
    if len(sys.argv) >= 5 and sys.argv[1] == "--local":
        import server   # wires the practice factory into the imported `daily` module
        role = sys.argv[5] if len(sys.argv) > 5 else "story"
        print(server.daily.import_local(sys.argv[2], sys.argv[3], sys.argv[4], role, date.today(), server.all_sessions()))
