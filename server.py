"""Local web server for the speech practice recorder.

Run:  .venv/bin/python server.py   then open http://127.0.0.1:8765
The packaged Mac app (app.py) runs this same server behind a native window.

Data: sessions/<id>/session.json (+ audio) and practices/<id>/practice.json.
A session may belong to one practice; the practice's script drives key-point coverage.
"""
from __future__ import annotations

import json
import os
import shutil
import threading
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

import analysis
import coach
import coverage
import daily
import paths
import shadow

paths.ensure_dirs()
DATA = paths.SESSIONS_DIR
PRACTICES = paths.PRACTICES_DIR


@asynccontextmanager
async def lifespan(_app):
    # Warm the English model so the first recording is not slow. The Chinese model
    # (about 1.6 GB) loads the first time a Chinese recording comes in.
    threading.Thread(target=lambda: analysis.get_model(analysis.MODELS["default"]), daemon=True).start()
    if not os.environ.get("SPEECH_NO_DAILY"):
        threading.Thread(target=daily.scheduler, args=(all_sessions, plan_summary), daemon=True).start()
    yield


app = FastAPI(title="Speech Practice Recorder", lifespan=lifespan)

SUMMARY_KEYS = ["id", "created_at", "title", "scenario", "language", "duration_sec",
                "word_count", "wpm", "articulation_wpm", "self_rating", "practice_id", "drill"]
_busy = [0]   # recordings being analysed right now; the daily job waits for them
_busy_lock = threading.Lock()


class analysing:
    def __enter__(self):
        with _busy_lock:
            _busy[0] += 1

    def __exit__(self, *exc):
        with _busy_lock:
            _busy[0] -= 1
PRACTICE_FIELDS = ("title", "script", "scenario", "notes")
REFERENCE_JSON = "reference.json"


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


# Python's mimetypes maps .m4a to audio/mp4a-latm (a raw AAC stream), which AVPlayer
# refuses to open as a file. Say exactly what each container is.
AUDIO_TYPES = {".m4a": "audio/mp4", ".mp4": "video/mp4", ".mp3": "audio/mpeg", ".wav": "audio/wav",
               ".webm": "audio/webm", ".mov": "video/quicktime", ".aac": "audio/aac", ".ogg": "audio/ogg"}


def audio_response(path: Path) -> FileResponse:
    return FileResponse(path, media_type=AUDIO_TYPES.get(path.suffix.lower()))


def new_id() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


# ---------- sessions ----------

def session_path(sid: str) -> Path:
    p = DATA / sid
    if not (p / "session.json").exists():
        raise HTTPException(404, "session not found")
    return p


def load_session(sid: str) -> dict:
    return json.loads((session_path(sid) / "session.json").read_text())


def save_session(s: dict) -> None:
    (DATA / s["id"] / "session.json").write_text(json.dumps(s, ensure_ascii=False, indent=1))


def all_sessions() -> list[dict]:
    out = []
    for p in sorted(DATA.iterdir()):
        f = p / "session.json"
        if f.exists():
            out.append(json.loads(f.read_text()))
    # sessions in practices with a reference were read along with someone; keep them out of the baseline
    coach.SHADOW_PRACTICES = {d.name for d in PRACTICES.iterdir() if (d / REFERENCE_JSON).exists()} if PRACTICES.exists() else set()
    return out


def summarize(s: dict) -> dict:
    out = {k: s.get(k) for k in SUMMARY_KEYS}
    m = s["metrics"]
    out["fillers_per_minute"] = m["fillers"]["per_minute"]
    out["filler_count"] = m["fillers"]["count"]
    out["pause_count"] = m["pauses"]["count"]
    out["pauses_per_minute"] = m["pauses"]["per_minute"]
    out["longest_pause_sec"] = m["pauses"]["longest_sec"]
    out["hedge_count"] = m["hedges"]["count"]
    cov = m.get("coverage")
    out["coverage"] = cov["coverage"] if cov else None
    out["pitch_range"] = (m.get("pitch") or {}).get("range_semitones")
    return out


def attach_practice(s: dict, pid: str | None) -> None:
    """Link (or unlink) a session and recompute coverage against the practice script."""
    if pid:
        practice = load_practice(pid)
        s["practice_id"] = pid
        s["metrics"]["coverage"] = coverage.analyze_coverage(practice["script"], s["metrics"]["transcript"])
    else:
        s["practice_id"] = None
        s["metrics"]["coverage"] = None


# ---------- practices ----------

def practice_path(pid: str) -> Path:
    p = PRACTICES / pid
    if not (p / "practice.json").exists():
        raise HTTPException(404, "practice not found")
    return p


def load_practice(pid: str) -> dict:
    return json.loads((practice_path(pid) / "practice.json").read_text())


def save_practice(p: dict) -> None:
    (PRACTICES / p["id"]).mkdir(exist_ok=True)
    (PRACTICES / p["id"] / "practice.json").write_text(json.dumps(p, ensure_ascii=False, indent=1))


def all_practices() -> list[dict]:
    out = []
    for p in sorted(PRACTICES.iterdir()):
        f = p / "practice.json"
        if f.exists():
            out.append(json.loads(f.read_text()))
    return out


def practice_sessions(pid: str) -> list[dict]:
    """Summaries of a practice's sessions, oldest first, numbered as attempts."""
    items = [summarize(s) for s in all_sessions() if s.get("practice_id") == pid]
    for n, it in enumerate(items, 1):
        it["attempt"] = n
    return items


def load_reference(pid: str) -> dict | None:
    f = PRACTICES / pid / REFERENCE_JSON
    return json.loads(f.read_text()) if f.exists() else None


def save_reference(pid: str, ref: dict) -> None:
    (PRACTICES / pid / REFERENCE_JSON).write_text(json.dumps(ref, ensure_ascii=False, indent=1))


def public_reference(ref: dict | None) -> dict | None:
    """Reference without the word list (sentences carry the timing the page needs)."""
    if not ref:
        return None
    return {k: v for k, v in ref.items() if k != "words"}


def set_script(p: dict, script: str) -> None:
    """Change a practice's script and recompute coverage for every attempt."""
    p["script"] = script
    p["updated_at"] = now()
    save_practice(p)
    for s in all_sessions():
        if s.get("practice_id") == p["id"]:
            attach_practice(s, p["id"])
            save_session(s)


# ---------- API: config ----------

@app.get("/api/config")
def config():
    models = analysis.loaded_models()
    return {"model": analysis.MODEL_NAME, "model_loaded": models.get(analysis.MODEL_NAME, False),
            "models": models, "model_zh": analysis.MODELS["zh"]}


# ---------- API: sessions ----------

@app.post("/api/sessions")
def create_session(audio: UploadFile = File(...), language: str = Form("en"),
                   title: str = Form(""), scenario: str = Form(""), practice_id: str = Form(""),
                   drill: str = Form("")):
    if practice_id:
        load_practice(practice_id)  # 404 early, before the slow part
    sid = new_id()
    folder = DATA / sid
    folder.mkdir()
    ext = os.path.splitext(audio.filename or "")[1] or ".webm"
    audio_path = folder / f"audio{ext}"
    with audio_path.open("wb") as f:
        shutil.copyfileobj(audio.file, f)
    try:
        with analysing():
            metrics = analysis.analyze(str(audio_path), None if language == "auto" else language)
    except Exception as e:
        shutil.rmtree(folder, ignore_errors=True)
        raise HTTPException(500, f"analysis failed: {e}")
    # A recording with no speech in it is a microphone problem, not practice: keep it out of the
    # record and out of today's plan, and say what to check.
    if metrics["duration_sec"] < 1.5 or metrics["word_count"] == 0:
        shutil.rmtree(folder, ignore_errors=True)
        raise HTTPException(422, f"这段录音（{metrics['duration_sec']:.1f} 秒）里没有听到说话的声音，没有保存。"
                                 "看看 系统设置 > 声音 > 输入 选的是哪个麦克风，以及它的音量。")
    try:
        drill_info = json.loads(drill) if drill else None
    except ValueError:
        drill_info = None
    session = {
        "id": sid,
        "created_at": now(),
        "title": title or datetime.now().strftime("%m-%d %H:%M 练习"),
        "scenario": scenario,
        "notes": "",
        "self_rating": None,
        "practice_id": None,
        "audio_file": audio_path.name,
        "language": metrics["language"],
        "duration_sec": metrics["duration_sec"],
        "word_count": metrics["word_count"],
        "wpm": metrics["wpm"],
        "articulation_wpm": metrics["articulation_wpm"],
        "drill": drill_info,
        "metrics": metrics,
    }
    attach_practice(session, practice_id or None)
    save_session(session)
    return with_review(session)


@app.get("/api/sessions")
def list_sessions(practice: str = "all"):
    """practice=all | none | <practice id>"""
    items = all_sessions()
    if practice == "none":
        items = [s for s in items if not s.get("practice_id")]
    elif practice != "all":
        items = [s for s in items if s.get("practice_id") == practice]
    return [summarize(s) for s in items]


def with_review(s: dict) -> dict:
    """Attach the one-line feedback, judged against the current block's targets."""
    sessions = all_sessions()
    block = coach.current_block()
    tg = coach.targets(block, coach.baseline([x for x in sessions if x["created_at"] < s["created_at"]] or sessions))
    out = dict(s)
    out["review"] = coach.review(s, coach.previous_attempt(s, sessions), block, tg)
    return out


@app.get("/api/sessions/{sid}")
def get_session(sid: str):
    return with_review(load_session(sid))


@app.patch("/api/sessions/{sid}")
def update_session(sid: str, body: dict):
    s = load_session(sid)
    for k in ("title", "scenario", "notes", "self_rating"):
        if k in body:
            s[k] = body[k]
    if "practice_id" in body and (body["practice_id"] or None) != s.get("practice_id"):
        attach_practice(s, body["practice_id"] or None)
    save_session(s)
    return with_review(s)


@app.post("/api/sessions/{sid}/reanalyze")
def reanalyze_session(sid: str, body: dict | None = None):
    """Re-run transcription and metrics on the stored audio (after model or setting changes).
    Keeps title, notes, rating and practice link."""
    s = load_session(sid)
    language = (body or {}).get("language") or s.get("language") or "auto"
    with analysing():
        metrics = analysis.analyze(str(session_path(sid) / s["audio_file"]), None if language == "auto" else language)
    s["metrics"] = metrics
    for k in ("language", "duration_sec", "word_count", "wpm", "articulation_wpm"):
        s[k] = metrics[k]
    attach_practice(s, s.get("practice_id"))
    save_session(s)
    return with_review(s)


@app.delete("/api/sessions/{sid}")
def delete_session(sid: str):
    shutil.rmtree(session_path(sid))
    return JSONResponse({"ok": True})


@app.get("/api/sessions/{sid}/audio")
def get_audio(sid: str):
    s = load_session(sid)
    return audio_response(session_path(sid) / s["audio_file"])


# ---------- API: practices ----------

@app.get("/api/practices")
def list_practices(kind: str = "all"):
    """kind=all | user | clip | agenda"""
    sessions = all_sessions()
    out = []
    for p in all_practices():
        pk = p.get("kind") or "user"
        if kind != "all" and pk != kind:
            continue
        mine = [s for s in sessions if s.get("practice_id") == p["id"]]
        last = mine[-1] if mine else None
        # Clips brought in by hand (the first version's shadowing material) have original
        # audio too; the app sorts by that, so every kind reports it.
        ref = load_reference(p["id"])
        out.append({
            "id": p["id"], "title": p["title"], "scenario": p["scenario"],
            "created_at": p["created_at"], "updated_at": p.get("updated_at"),
            "has_script": bool(p["script"].strip()),
            "session_count": len(mine),
            "last_at": last["created_at"] if last else None,
            "last_coverage": (last["metrics"].get("coverage") or {}).get("coverage") if last else None,
            "kind": pk,
            "clip": p.get("clip"),
            "ref_duration": ref["duration_sec"] if ref else None,
            "ref_wpm": ref["metrics"]["wpm"] if ref else None,
        })
    return out


@app.post("/api/practices")
def create_practice(body: dict):
    p = {
        "id": new_id(),
        "created_at": now(),
        "updated_at": now(),
        "title": (body.get("title") or "").strip() or datetime.now().strftime("%m-%d 新练习"),
        "script": body.get("script") or "",
        "scenario": body.get("scenario") or "",
        "notes": body.get("notes") or "",
        "kind": body.get("kind") or "user",
    }
    save_practice(p)
    return get_practice(p["id"])


@app.get("/api/practices/{pid}")
def get_practice(pid: str):
    p = load_practice(pid)
    p["sessions"] = practice_sessions(pid)
    p["points"] = coverage.split_points(p["script"])
    p["terms"] = coverage.extract_terms(p["script"])
    p["reference"] = public_reference(load_reference(pid))
    return p


@app.patch("/api/practices/{pid}")
def update_practice(pid: str, body: dict):
    p = load_practice(pid)
    script_changed = "script" in body and body["script"] != p["script"]
    for k in PRACTICE_FIELDS:
        if k in body and k != "script":
            p[k] = body[k]
    p["updated_at"] = now()
    save_practice(p)
    if script_changed:  # coverage depends on the script; recompute for every attempt
        set_script(p, body["script"])
    return get_practice(pid)


@app.delete("/api/practices/{pid}")
def delete_practice(pid: str):
    """Deletes the practice only; its sessions become ungrouped."""
    path = practice_path(pid)
    for s in all_sessions():
        if s.get("practice_id") == pid:
            attach_practice(s, None)
            save_session(s)
    shutil.rmtree(path)
    return JSONResponse({"ok": True})


# ---------- API: shadowing reference audio ----------

def build_reference(path: Path, original_name: str | None, transcript: str, language: str) -> dict:
    metrics = analysis.analyze(str(path), None if language == "auto" else language)
    words = metrics.pop("words")
    return {
        "audio_file": path.name,
        "original_name": original_name,
        "uploaded_at": now(),
        "language": metrics["language"],
        "duration_sec": metrics["duration_sec"],
        "transcript": transcript,
        "subtitles_from": "transcript" if transcript.strip() else "whisper",
        "sentences": shadow.build_sentences(words, transcript),
        "metrics": metrics,
        "words": words,
    }


def create_clip_practice(title: str, script: str, audio_path: Path, clip: dict, notes_fn) -> str:
    """Used by the daily job: a practice whose reference is the cut clip."""
    pid = new_id()
    folder = PRACTICES / pid
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / f"reference{audio_path.suffix or '.m4a'}"
    shutil.copyfile(audio_path, dest)
    ref = build_reference(dest, f"{clip.get('channel', '')} {clip.get('video_title') or ''}".strip(), "", "en")
    p = {
        "id": pid, "created_at": now(), "updated_at": now(), "title": title,
        "script": script, "scenario": "presentation",
        "notes": notes_fn(ref["metrics"]), "kind": "clip", "clip": clip,
    }
    save_practice(p)
    save_reference(pid, ref)
    return pid


# The daily job makes practices through this factory; wired at import so the CLI test works too.
daily.configure(create_clip_practice, busy_fn=lambda: _busy[0] > 0)


@app.post("/api/practices/{pid}/reference")
def upload_reference(pid: str, audio: UploadFile = File(...), transcript: str = Form(""),
                     language: str = Form("auto")):
    """Attach a reference recording to a practice: transcribe it, time its sentences
    (snapped to `transcript` when given) and keep the speaker's metrics for comparison."""
    p = load_practice(pid)
    folder = practice_path(pid)
    for old_file in folder.glob("reference.*"):
        old_file.unlink()
    ext = os.path.splitext(audio.filename or "")[1].lower() or ".mp3"
    path = folder / f"reference{ext}"
    with path.open("wb") as f:
        shutil.copyfileobj(audio.file, f)
    try:
        with analysing():
            ref = build_reference(path, audio.filename, transcript, language)
    except Exception as e:
        path.unlink(missing_ok=True)
        raise HTTPException(500, f"analysis failed: {e}")
    save_reference(pid, ref)
    if transcript.strip() and not p["script"].strip():
        set_script(p, transcript)
    return get_practice(pid)


@app.put("/api/practices/{pid}/reference/transcript")
def retime_reference(pid: str, body: dict):
    """Re-snap the subtitles to an edited transcript (no re-transcription needed)."""
    ref = load_reference(pid)
    if not ref:
        raise HTTPException(404, "no reference")
    transcript = body.get("transcript") or ""
    ref["transcript"] = transcript
    ref["subtitles_from"] = "transcript" if transcript.strip() else "whisper"
    ref["sentences"] = shadow.build_sentences(ref["words"], transcript)
    save_reference(pid, ref)
    return get_practice(pid)


@app.get("/api/practices/{pid}/reference/audio")
def reference_audio(pid: str):
    ref = load_reference(pid)
    if not ref:
        raise HTTPException(404, "no reference")
    return audio_response(practice_path(pid) / ref["audio_file"])


@app.delete("/api/practices/{pid}/reference")
def delete_reference(pid: str):
    folder = practice_path(pid)
    for f in folder.glob("reference.*"):
        f.unlink()
    return get_practice(pid)


# ---------- API: activity ledger (listening time) and insights ----------

ACTIVITY = paths.ACTIVITY_DIR
ACTIVE_MIN_SEC = 30  # a day counts as active with at least this much recording or listening


@app.post("/api/activity")
def post_activity(body: dict):
    """Append listening events. The app batches them (every ~20 s of listening and on pause),
    so this is called rarely and never on seek. One JSONL file per day."""
    events = body.get("events") or []
    by_day: dict[str, list[dict]] = {}
    for e in events:
        at = e.get("at") or now()
        day = at[:10]
        rec = {
            "at": at, "kind": e.get("kind", "listen"), "practice_id": e.get("practice_id"),
            "session_id": e.get("session_id"), "wall_sec": round(float(e.get("wall_sec", 0)), 2),
            "media_sec": round(float(e.get("media_sec", 0)), 2), "rate": e.get("rate"),
        }
        if rec["wall_sec"] <= 0:
            continue
        by_day.setdefault(day, []).append(rec)
    for day, recs in by_day.items():
        with (ACTIVITY / f"{day}.jsonl").open("a") as f:
            for r in recs:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
    return {"ok": True, "stored": sum(len(v) for v in by_day.values())}


def load_activity() -> list[dict]:
    out = []
    for f in sorted(ACTIVITY.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            if line.strip():
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


@app.get("/api/insights")
def insights(days: int = 371):
    """Per-day activity for the heatmap plus totals and per-practice breakdown.
    Recording time comes from saved sessions; listening time from the activity ledger."""
    from datetime import date, timedelta

    sessions = all_sessions()
    practices = {p["id"]: p for p in all_practices()}
    refs = {pid: load_reference(pid) for pid in practices}
    day_stats: dict[str, dict] = {}

    def day(d: str) -> dict:
        return day_stats.setdefault(d, {"date": d, "record_sec": 0.0, "record_count": 0, "listen_ref_sec": 0.0,
                                        "listen_ref_media_sec": 0.0, "listen_self_sec": 0.0, "listen_self_media_sec": 0.0})

    per_practice: dict[str | None, dict] = {}

    def prac(pid):
        return per_practice.setdefault(pid, {"practice_id": pid, "title": practices.get(pid, {}).get("title", "未分组") if pid else "未分组",
                                             "record_count": 0, "record_sec": 0.0, "listen_ref_sec": 0.0,
                                             "listen_ref_media_sec": 0.0, "listen_self_sec": 0.0, "reference_sec": None})

    for s in sessions:
        d = day(s["created_at"][:10])
        d["record_sec"] += s["duration_sec"]
        d["record_count"] += 1
        pp = prac(s.get("practice_id"))
        pp["record_count"] += 1
        pp["record_sec"] += s["duration_sec"]
    for e in load_activity():
        d = day(e["at"][:10])
        pp = prac(e.get("practice_id"))
        if e["kind"] == "listen_reference":
            d["listen_ref_sec"] += e["wall_sec"]; d["listen_ref_media_sec"] += e["media_sec"]
            pp["listen_ref_sec"] += e["wall_sec"]; pp["listen_ref_media_sec"] += e["media_sec"]
        else:
            d["listen_self_sec"] += e["wall_sec"]; d["listen_self_media_sec"] += e["media_sec"]
            pp["listen_self_sec"] += e["wall_sec"]
    for pid, pp in per_practice.items():
        ref = refs.get(pid)
        if ref:
            pp["reference_sec"] = ref["duration_sec"]
            pp["listen_ref_passes"] = round(pp["listen_ref_media_sec"] / ref["duration_sec"], 1) if ref["duration_sec"] else 0
        else:
            pp["listen_ref_passes"] = None
        pp["record_sec"] = round(pp["record_sec"], 1)
        pp["listen_ref_sec"] = round(pp["listen_ref_sec"], 1)
        pp["listen_self_sec"] = round(pp["listen_self_sec"], 1)

    today = date.today()
    series = []
    for i in range(days - 1, -1, -1):
        d = (today - timedelta(days=i)).isoformat()
        st = day_stats.get(d, {"date": d, "record_sec": 0.0, "record_count": 0, "listen_ref_sec": 0.0,
                               "listen_ref_media_sec": 0.0, "listen_self_sec": 0.0, "listen_self_media_sec": 0.0})
        st = {k: (round(v, 1) if isinstance(v, float) else v) for k, v in st.items()}
        st["total_sec"] = round(st["record_sec"] + st["listen_ref_sec"] + st["listen_self_sec"], 1)
        series.append(st)

    active_days = {d for d, st in day_stats.items() if st["record_sec"] + st["listen_ref_sec"] + st["listen_self_sec"] >= ACTIVE_MIN_SEC}
    streak, cursor = 0, today
    if today.isoformat() not in active_days:
        cursor = today - timedelta(days=1)
    while cursor.isoformat() in active_days:
        streak += 1
        cursor -= timedelta(days=1)
    longest, run, prev = 0, 0, None
    for d in sorted(active_days):
        cur = date.fromisoformat(d)
        run = run + 1 if prev and (cur - prev).days == 1 else 1
        longest = max(longest, run)
        prev = cur

    totals = {
        "record_sec": round(sum(s["duration_sec"] for s in sessions), 1),
        "record_count": len(sessions),
        "listen_ref_sec": round(sum(st["listen_ref_sec"] for st in day_stats.values()), 1),
        "listen_ref_media_sec": round(sum(st["listen_ref_media_sec"] for st in day_stats.values()), 1),
        "listen_self_sec": round(sum(st["listen_self_sec"] for st in day_stats.values()), 1),
        "listen_passes": round(sum(pp.get("listen_ref_passes") or 0 for pp in per_practice.values()), 1),
        "active_days": len(active_days),
        "current_streak": streak,
        "longest_streak": longest,
        "first_day": min(day_stats) if day_stats else None,
    }
    week = [st for st in series[-7:]]
    prev_week = [st for st in series[-14:-7]]
    totals["this_week_sec"] = round(sum(st["total_sec"] for st in week), 1)
    totals["last_week_sec"] = round(sum(st["total_sec"] for st in prev_week), 1)
    return {"days": series, "totals": totals,
            "practices": sorted(per_practice.values(), key=lambda x: -(x["record_sec"] + x["listen_ref_sec"] + x["listen_self_sec"]))}


# ---------- API: today, coaching, daily clips, agenda, recap ----------

WEEKDAYS = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]


def clip_card(p: dict) -> dict:
    ref = load_reference(p["id"])
    clip = p.get("clip") or {}
    return {
        "id": p["id"], "title": p["title"],
        "subtitle": clip.get("channel") or "",
        "duration": ref["duration_sec"] if ref else None,
        "wpm": ref["metrics"]["wpm"] if ref else None,
    }


def today_payload(d=None) -> dict:
    from datetime import date as _date
    d = d or _date.today()
    settings = coach.load_settings()
    sessions = all_sessions()
    activity = load_activity()
    practices = {p["id"]: p for p in all_practices()}
    agenda = coach.agenda_view(sessions, practices, d)
    clips = [clip_card(practices[pid]) for pid in daily.clips_for(d) if pid in practices]
    plan = coach.build_plan(d, sessions, clips, agenda, settings)
    block = plan["block"]
    base = coach.baseline(sessions)
    tg = coach.targets(block, base)
    nxt = next((e for e in agenda if e["days_left"] >= 0), None)
    last = None
    if sessions:
        s = sessions[-1]
        rv = coach.review(s, coach.previous_attempt(s, sessions), block, tg)
        last = {"id": s["id"], "title": s.get("title"), "created_at": s["created_at"], "wpm": s["wpm"],
                "duration_sec": s["duration_sec"], "headline": rv["headline"], "focus": rv["focus"]}
    ds = daily.status()
    want = int(settings["daily"].get("clips_per_day") or 2)
    rec = daily.day_record(d)
    if len(clips) >= want:
        dstate = "ready"
    elif ds.get("state") == "running":
        dstate = "running"
    elif not settings["daily"].get("enabled"):
        dstate = "off"
    elif rec.get("errors") and not clips:
        dstate = "failed"
    else:
        dstate = "waiting"
    return {
        "date": d.isoformat(),
        "weekday": WEEKDAYS[d.weekday()],
        "block": {k: block[k] for k in ("key", "greek", "name", "why", "tip", "week", "weeks", "cycle_week", "focus", "pinned")},
        "baseline": base,
        "targets": tg,
        "week": coach.week_view(sessions, activity, d, settings),
        "items": plan["items"],
        "daily": {"state": dstate, "message": ds.get("message") if ds.get("date") == d.isoformat() else "",
                  "progress": ds.get("progress", 0), "errors": rec.get("errors") or [], "want": want},
        "next_event": nxt,
        "last": last,
        "session_count": len(sessions),
    }


def plan_summary() -> tuple[str, str]:
    t = today_payload()
    lines = [f"{i + 1}. {it['title']}" for i, it in enumerate(t["items"])]
    title = f"今天练 {len(t['items'])} 项 · {t['block']['name']}"
    return title, "\n".join(lines) or "打开 Melete，录一段一分钟的即兴。"


@app.get("/api/today")
def today():
    return today_payload()


@app.post("/api/plan/shuffle")
def plan_shuffle():
    from datetime import date as _date
    coach.shuffle_prompt(_date.today())
    return today_payload()


@app.post("/api/week/commit")
def week_commit():
    from datetime import date as _date
    coach.update_settings({"coach": {"committed_week": coach.monday(_date.today()).isoformat()}})
    return today_payload()


@app.get("/api/settings")
def get_settings():
    out = coach.public_settings(coach.load_settings())
    out["tools"] = daily.tools_report()
    out["blocks"] = [{k: b[k] for k in ("key", "greek", "name", "weeks", "why")} for b in coach.BLOCKS]
    return out


@app.put("/api/settings")
def put_settings(body: dict):
    patch = dict(body or {})
    dl = dict(patch.get("daily") or {})
    if "claude_api_key" in dl and dl["claude_api_key"] in (None, "********"):
        dl.pop("claude_api_key")   # unchanged
    if dl:
        patch["daily"] = dl
    coach.update_settings(patch)
    return get_settings()


@app.get("/api/prompts")
def prompts():
    return [coach.prompt_view(p) for p in coach.PROMPTS]


@app.get("/api/daily")
def daily_status():
    from datetime import date as _date, timedelta as _td
    st = daily.load_state()
    practices = {p["id"]: p for p in all_practices()}
    days = []
    for k in sorted(st.get("days", {}), reverse=True)[:30]:
        rec = st["days"][k]
        days.append({"date": k, "items": [clip_card(practices[i]) for i in rec.get("items", []) if i in practices],
                     "errors": rec.get("errors", [])})
    return {"status": daily.status(), "tools": daily.tools_report(), "days": days,
            "tomorrow_ready": len(daily.clips_for(_date.today() + _td(days=1)))}


@app.post("/api/daily/refresh")
def daily_refresh(body: dict | None = None):
    """Prepare today's clips now (force=True replaces them)."""
    from datetime import date as _date
    force = bool((body or {}).get("force"))
    if force:
        st = daily.load_state()
        old = st["days"].pop(_date.today().isoformat(), None) or {}
        daily.save_state(st)
        # Replaced clips you never recorded are removed so the library does not fill with rejects.
        recorded = {s.get("practice_id") for s in all_sessions()}
        for pid in old.get("items") or []:
            folder = PRACTICES / pid
            if pid not in recorded and (folder / "practice.json").exists():
                shutil.rmtree(folder, ignore_errors=True)
    threading.Thread(target=daily.prepare, args=(_date.today(), all_sessions(), force), daemon=True).start()
    return {"started": True, "status": daily.status()}


@app.post("/api/daily/add")
def daily_add(body: dict):
    """Paste a YouTube link (with or without &t=) and get a clip in today's plan."""
    from datetime import date as _date
    url = (body or {}).get("url") or ""
    role = (body or {}).get("role") or "story"
    if not url:
        raise HTTPException(400, "缺少链接")

    def work():
        try:
            daily.add_url(url, role, _date.today(), all_sessions())
        except Exception as e:
            print("daily add failed:", e)
    threading.Thread(target=work, daemon=True).start()
    return {"started": True}


@app.post("/api/daily/import")
def daily_import(body: dict):
    """Make a clip from a local audio or video file."""
    from datetime import date as _date
    path = (body or {}).get("path") or ""
    if not path or not Path(path).exists():
        raise HTTPException(400, "找不到这个文件")
    try:
        pid = daily.import_local(path, body.get("title") or Path(path).stem, body.get("speaker") or "",
                                 body.get("role") or "story", _date.today(), all_sessions(), body.get("url"))
    except Exception as e:
        raise HTTPException(500, f"没能做成片段：{e}")
    return get_practice(pid)


@app.get("/api/sources")
def get_sources():
    return daily.load_sources()


@app.put("/api/sources")
def put_sources(body: list):
    daily.save_sources(body)
    return daily.load_sources()


SCENARIO_FOR_EVENT = {"review": "presentation", "one_on_one": "meeting", "team": "meeting", "stakeholder": "meeting",
                      "allhands": "presentation", "interview": "interview", "talk": "presentation", "other": "other"}


@app.get("/api/agenda")
def agenda():
    practices = {p["id"]: p for p in all_practices()}
    return {"events": coach.agenda_view(all_sessions(), practices), "templates": coach.TEMPLATES,
            "kinds": coach.EVENT_KINDS}


@app.post("/api/agenda")
def agenda_create(body: dict):
    ev = coach.new_event(body or {})
    p = {"id": new_id(), "created_at": now(), "updated_at": now(), "title": ev["title"],
         "script": ev["notes"], "scenario": SCENARIO_FOR_EVENT.get(ev["kind"], "other"),
         "notes": f"{ev['date']} · {coach.EVENT_KINDS.get(ev['kind'], '')} · {ev['minutes']} 分钟",
         "kind": "agenda", "agenda_id": ev["id"]}
    save_practice(p)
    ev["practice_id"] = p["id"]
    items = coach.load_agenda()
    items.append(ev)
    coach.save_agenda(items)
    return agenda()


@app.patch("/api/agenda/{eid}")
def agenda_update(eid: str, body: dict):
    items = coach.load_agenda()
    for ev in items:
        if ev["id"] == eid:
            for k in ("title", "date", "kind", "minutes", "notes"):
                if k in body:
                    ev[k] = body[k]
    coach.save_agenda(items)
    return agenda()


@app.delete("/api/agenda/{eid}")
def agenda_delete(eid: str):
    """Removes the event; its practice and recordings stay."""
    coach.save_agenda([e for e in coach.load_agenda() if e["id"] != eid])
    return agenda()


@app.get("/api/recent")
def recent(limit: int = 12):
    """Latest recordings, newest first, with the one-line verdict and which space they came from."""
    sessions = all_sessions()
    practices = {p["id"]: p for p in all_practices()}
    block = coach.current_block()
    tg = coach.targets(block, coach.baseline(sessions))
    out = []
    for s in reversed(sessions[-max(1, limit):]):
        it = summarize(s)
        rv = coach.review(s, coach.previous_attempt(s, sessions), block, tg)
        kind = (s.get("drill") or {}).get("kind")
        if not kind:
            kind = "shadow" if s.get("practice_id") in coach.SHADOW_PRACTICES else ("topic" if s.get("practice_id") else "free")
        it["headline"] = rv["headline"]
        it["kind"] = kind
        it["space"] = "shadow" if kind in ("shadow", "retell") else "topic"
        it["practice_title"] = practices.get(s.get("practice_id") or "", {}).get("title")
        out.append(it)
    return out


@app.get("/api/recap")
def recap(offset: int = 0):
    return coach.recap(all_sessions(), load_activity(), max(0, offset))


app.mount("/", StaticFiles(directory=paths.STATIC_DIR, html=True), name="static")


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8765")))
