"""Listening notes: a cloud audio model hears the take and says how it sounds.

Melete measures pace, pitch, pauses and stress itself. Audio models are poor at those
numbers and tend to follow the words rather than the sound, so the model gets the recording
together with the numbered sentences and the measured numbers, is told to take the numbers
as given, and only judges what they can't show: tone, confidence, energy, and one thing to
change.

The call goes through OpenRouter (default model google/gemini-3.8-flash) in a background
thread after the local analysis and writes sessions/<id>/listen.json. Nothing is sent
without an OpenRouter key; a failure leaves the local results as they are.
"""
from __future__ import annotations

import base64
import io
import json
import re
import ssl
import threading
import urllib.error
import urllib.request
import wave
from datetime import datetime
from pathlib import Path

import numpy as np

import shadow

ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
DEFAULT_MODEL = "google/gemini-3.8-flash"
MODELS = ["google/gemini-3.8-flash", "google/gemini-3.5-flash-lite"]
FILE = "listen.json"
MAX_SEC = 600            # longer takes are not sent: the upload and the wait grow with length
MAX_SENTENCES = 80
TIMEOUT = 240
SAMPLE_RATE = 16000

_running: set[str] = set()
_lock = threading.Lock()
_slots = threading.BoundedSemaphore(2)

SYSTEM = """You are a speaking coach. You will hear one practice recording. With it come the \
transcript, split into numbered sentences with their times, and numbers measured from the \
audio by signal processing.

Judge only what those numbers cannot show: how the speaker sounds. Emotional tone, \
confidence, energy and engagement, warmth, whether the emphasis lands, whether it sounds \
read aloud or spoken, nervous or at ease.

Rules:
- The measured pace, pitch movement, pauses, stressed words and sentence endings are \
correct. Do not estimate pitch, pace or volume yourself and do not contradict the numbers; \
you may refer to them.
- Listen to the voice, not the words: a sentence can say "I'm excited" and sound flat.
- Do not comment on grammar, word choice or content.
- Write every text field in {language}. Tone labels are one to three words. A note is one \
short sentence to the speaker ("you ..."); leave it empty when nothing stands out.
- confidence and energy are whole numbers from 1 (very low) to 5 (very high).
- Give one concrete tip the speaker can try on the next take.
- Return one entry in "sentences" for every numbered sentence you were given, with its "i"."""

SCHEMA = {
    "type": "object",
    "properties": {
        "overall": {
            "type": "object",
            "properties": {
                "tone": {"type": "string"},
                "confidence": {"type": "integer"},
                "energy": {"type": "integer"},
                "summary": {"type": "string"},
                "tip": {"type": "string"},
            },
            "required": ["tone", "confidence", "energy", "summary", "tip"],
            "additionalProperties": False,
        },
        "sentences": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "i": {"type": "integer"},
                    "tone": {"type": "string"},
                    "confidence": {"type": "integer"},
                    "note": {"type": "string"},
                },
                "required": ["i", "tone", "confidence", "note"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["overall", "sentences"],
    "additionalProperties": False,
}


class ListenError(Exception):
    pass


# ---------------------------------------------------------------- settings and state


def settings_of(settings: dict) -> dict:
    return settings.get("listen") or {}


def ready(settings: dict) -> bool:
    ls = settings_of(settings)
    return bool(ls.get("enabled") and ls.get("openrouter_api_key"))


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _write(folder: Path, data: dict) -> None:
    tmp = folder / (FILE + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    tmp.replace(folder / FILE)


def state(folder: Path) -> dict | None:
    """What listen.json says, with a pending call that can no longer finish shown as failed."""
    f = folder / FILE
    if not f.exists():
        return None
    try:
        data = json.loads(f.read_text())
    except ValueError:
        return None
    if data.get("status") == "pending" and folder.name not in _running:
        data = {**data, "status": "error", "error": "interrupted"}   # the app quit mid-call
    return data


def start(folder: Path, session: dict, settings: dict, ui_lang: str) -> dict | None:
    """Ask for listening notes in the background. Returns the new state, or None when the
    feature is off or the take is too long."""
    if not ready(settings):
        return None
    sid = folder.name
    ls = settings_of(settings)
    model = ls.get("model") or DEFAULT_MODEL
    if session["metrics"].get("duration_sec", 0) > MAX_SEC:
        data = {"status": "skipped", "reason": "too_long", "model": model, "started_at": now()}
        _write(folder, data)
        return data
    with _lock:
        if sid in _running:
            return state(folder)
        _running.add(sid)
    data = {"status": "pending", "model": model, "started_at": now()}
    _write(folder, data)
    threading.Thread(target=_run, args=(folder, session, ls["openrouter_api_key"], model, ui_lang), daemon=True).start()
    return data


def _run(folder: Path, session: dict, key: str, model: str, ui_lang: str) -> None:
    started = now()
    try:
        try:
            with _slots:
                result = listen(folder / session["audio_file"], session, key, model, ui_lang)
            data = {"status": "done", "model": model, "started_at": started, "finished_at": now(), **result}
        except Exception as e:
            print("listen failed:", session.get("id"), repr(e))
            data = {"status": "error", "model": model, "started_at": started, "finished_at": now(),
                    "error": str(e) if isinstance(e, ListenError) else "failed"}
        if folder.exists():   # the session may have been deleted meanwhile
            _write(folder, data)
    except OSError as e:
        print("listen write failed:", repr(e))
    finally:
        with _lock:
            _running.discard(folder.name)


# ---------------------------------------------------------------- the request


def wav_bytes(path: Path) -> bytes:
    """The take as 16 kHz mono 16-bit WAV, the format every audio model accepts."""
    from faster_whisper.audio import decode_audio
    audio = decode_audio(str(path), sampling_rate=SAMPLE_RATE)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def sentences_for(metrics: dict) -> list[dict]:
    """Numbered sentences with what was measured in each; the model answers by these numbers."""
    pros = metrics.get("prosody") or {}
    rows = pros.get("sentences")
    if not rows:
        rows = [{"i": i, "text": g["text"], "start": g["start"], "end": g["end"]}
                for i, g in enumerate(shadow.sentences_from_words(metrics.get("words") or []))]
    out = []
    for r in rows[:MAX_SENTENCES]:
        item = {"i": r["i"], "start": round(r["start"], 1), "end": round(r["end"], 1), "text": r["text"]}
        if r.get("pace"):
            item["pace"] = r["pace"]
        if r.get("final"):
            item["ending"] = r["final"]["dir"]
        if (r.get("stress") or {}).get("clear"):
            item["stressed_word"] = r["stress"]["word"]
        if r.get("fades"):
            item["last_word_fades"] = True
        out.append(item)
    return out


def context(session: dict) -> dict:
    """The measured numbers the model is told to take as given."""
    m = session["metrics"]
    ps = (m.get("prosody") or {}).get("summary") or {}
    zh = m.get("language", "en").startswith("zh")
    take = {
        "duration_sec": m["duration_sec"],
        ("pace_chars_per_min" if zh else "pace_words_per_min"): m["wpm"],
        "pauses_per_min": m["pauses"]["per_minute"],
        "longest_pause_sec": m["pauses"]["longest_sec"],
        "fillers_per_min": m["fillers"]["per_minute"],
    }
    pitch = (m.get("pitch") or {}).get("range_semitones")
    if pitch is not None:
        take["pitch_range_semitones"] = pitch
    if ps:
        take["sentence_endings"] = ps.get("final")
        take["sentences_with_clear_stress_pct"] = ps.get("stress_share")
        take["monotone_stretches"] = [[x["start"], x["end"]] for x in ps.get("monotone") or []]
    drill = (session.get("drill") or {}).get("kind")
    return {
        "recording_language": "Chinese" if zh else ("English" if m.get("language") == "en" else m.get("language")),
        "exercise": {"shadow": "shadowing a recorded speaker", "retell": "retelling a clip in own words",
                     "topic": "speaking on a prompt"}.get(drill or "", "free practice"),
        "scenario": session.get("scenario") or None,
        "measured": take,
        "sentences": sentences_for(m),
    }


def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _post(body: dict, key: str) -> dict:
    req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/oliverxuzy-ai/Melete",
        "X-Title": "Melete",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=_ssl_context()) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = (json.loads(e.read()).get("error") or {}).get("message", "")
        except Exception:
            pass
        raise ListenError(_http_message(e.code, detail)) from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise ListenError("network: " + str(getattr(e, "reason", e))) from None


def _http_message(code: int, detail: str) -> str:
    known = {401: "invalid_key", 402: "no_credit", 403: "forbidden", 404: "model_not_found", 429: "rate_limited"}
    return f"http {code}: {known.get(code, '')} {detail}".strip()[:300]


def parse(content: str) -> dict:
    """The JSON in a reply, also when it comes in a code fence or with words around it."""
    text = content.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        text = fence.group(1)
    a, b = text.find("{"), text.rfind("}")
    if a < 0 or b < a:
        raise ListenError("no_json")
    try:
        return json.loads(text[a:b + 1])
    except ValueError:
        raise ListenError("bad_json") from None


def _level(v) -> int | None:
    try:
        return min(5, max(1, int(round(float(v)))))
    except (TypeError, ValueError):
        return None


def clean(data: dict, ids: set[int]) -> dict:
    """Keep the reply to the expected shape and sizes."""
    ov = data.get("overall") or {}
    out = {
        "overall": {
            "tone": str(ov.get("tone") or "")[:40],
            "confidence": _level(ov.get("confidence")),
            "energy": _level(ov.get("energy")),
            "summary": str(ov.get("summary") or "")[:400],
            "tip": str(ov.get("tip") or "")[:300],
        },
        "sentences": [],
    }
    seen = set()
    for s in data.get("sentences") or []:
        try:
            i = int(s.get("i"))
        except (TypeError, ValueError, AttributeError):
            continue
        if i not in ids or i in seen:
            continue
        seen.add(i)
        out["sentences"].append({"i": i, "tone": str(s.get("tone") or "")[:30],
                                 "confidence": _level(s.get("confidence")), "note": str(s.get("note") or "")[:200]})
    out["sentences"].sort(key=lambda s: s["i"])
    if not out["overall"]["summary"] and not out["sentences"]:
        raise ListenError("empty")
    return out


def listen(audio_path: Path, session: dict, key: str, model: str, ui_lang: str) -> dict:
    """One call: the audio, the sentences and the numbers in; notes on how it sounds out."""
    ctx = context(session)
    language = "English" if ui_lang == "en" else "Simplified Chinese"
    audio = base64.b64encode(wav_bytes(audio_path)).decode()
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM.format(language=language)},
            {"role": "user", "content": [
                {"type": "text", "text": "The recording, its sentences and the measured numbers:\n"
                                         + json.dumps(ctx, ensure_ascii=False)},
                {"type": "input_audio", "input_audio": {"data": audio, "format": "wav"}},
            ]},
        ],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "listening_notes", "strict": True, "schema": SCHEMA}},
        # Only providers that neither store nor train on the request.
        "provider": {"data_collection": "deny"},
        "usage": {"include": True},
        "max_tokens": 12000,
    }
    try:
        reply = _post(body, key)
    except ListenError as e:
        if not str(e).startswith("http 400"):
            raise
        # Some routes refuse a response schema; the prompt alone still asks for the same JSON.
        body.pop("response_format")
        body["messages"][0]["content"] += "\n\nReply with JSON only, shaped like:\n" + json.dumps(SCHEMA)
        reply = _post(body, key)
    if reply.get("error"):
        raise ListenError(str((reply["error"] or {}).get("message") or reply["error"])[:300])
    choice = (reply.get("choices") or [{}])[0]
    content = (choice.get("message") or {}).get("content") or ""
    if isinstance(content, list):   # some providers return content parts
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    out = clean(parse(content), {s["i"] for s in ctx["sentences"]})
    usage = reply.get("usage") or {}
    out["usage"] = {k: usage[k] for k in ("prompt_tokens", "completion_tokens", "cost") if k in usage}
    return out
