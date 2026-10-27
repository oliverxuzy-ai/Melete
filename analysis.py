"""Speech analysis for the practice recorder.

Pipeline: decode audio -> transcribe with local Whisper (word timestamps)
-> compute pace, pauses, fillers, hedges, vocabulary and loudness/pitch stats.
All numbers are heuristics meant for self-tracking, not clinical measurement.
"""
from __future__ import annotations

import os
import re
import threading
from collections import Counter
from dataclasses import dataclass, asdict

import numpy as np
import tqdm.std
from faster_whisper import WhisperModel

# tqdm (used by the model download) creates a multiprocessing RLock on first use, which
# spawns a resource-tracker process. In the frozen Mac app that re-runs the app itself.
# A thread lock is all we need. Setting the attribute first skips the creation.
tqdm.std.TqdmDefaultWriteLock.mp_lock = None
from faster_whisper.audio import decode_audio

SAMPLE_RATE = 16000
# One model per language family. The multilingual "small" model is fine for English but
# garbles Mandarin (dropped stretches, stray glyphs), so Chinese gets a bigger model.
MODELS = {
    "default": os.environ.get("WHISPER_MODEL", "small"),
    "zh": os.environ.get("WHISPER_MODEL_ZH", "large-v3-turbo"),
}
MODEL_NAME = MODELS["default"]  # kept for /api/config
PAUSE_SEC = 0.5          # gap between words counted as a pause
LONG_PAUSE_SEC = 2.0     # gap counted as a long pause
WINDOW_SEC = 30          # bucket size for pace-over-time

# Prompting Whisper with disfluencies makes it far more likely to keep them
# in the transcript instead of silently cleaning them up.
INITIAL_PROMPT = {
    "en": "Um, uh, so, like, you know, I mean, hmm, basically, actually...",
    # Simplified Chinese with plain punctuation steers the output script and keeps fillers.
    "zh": "以下是普通话的句子。嗯，呃，那个，然后，就是，其实。",
}

FILLERS = {
    "en": [
        "um", "uh", "uhm", "umm", "hmm", "mm", "er", "ah", "eh",
        "like", "so", "actually", "basically", "literally", "okay",
        "you know", "i mean", "kind of", "sort of", "i guess",
    ],
    "zh": ["嗯", "呃", "啊", "那个", "然后", "就是", "其实", "对吧", "这个", "怎么说"],
}
# These are ordinary words too ("那个方案"); count them only when they stand alone:
# followed by punctuation, the end, or themselves ("那个那个").
ZH_AMBIGUOUS = {"那个", "然后", "就是", "其实", "这个", "啊"}

HEDGES = {
    "en": [
        "maybe", "perhaps", "probably", "possibly", "hopefully", "somewhat",
        "a little", "a bit", "just", "i think", "i feel like", "i believe",
        "i guess", "kind of", "sort of", "not sure", "might", "seems like",
    ],
    "zh": ["可能", "大概", "也许", "应该", "好像", "我觉得", "我感觉", "差不多", "有点"],
}

STOPWORDS = set("""a an the and or but if of to in on at for with by from as is are was were be been being
am do does did have has had i you he she it we they me him her us them my your his its our their this that these
those there here not no yes so than then very can could should would will just about into over up down out off
what which who whom when where why how all any some more most other such only own same too s t don ve ll re""".split())

_CJK = re.compile(r"[一-鿿]")
# Whisper sometimes emits private-use glyphs, U+FFFD and odd punctuation forms for Chinese.
_JUNK = re.compile(r"[\ue000-\uf8ff\ufffd\x00-\x08\x0b-\x1f]")
_PUNCT_FIX = str.maketrans({"﹐": "，", "﹑": "、", "﹒": "。", "﹔": "；", "︰": "：", "﹖": "？", "﹗": "！"})
_models: dict[str, WhisperModel] = {}
_model_lock = threading.Lock()


def model_for(language: str | None) -> str:
    return MODELS["zh"] if language and language.startswith("zh") else MODELS["default"]


def get_model(name: str | None = None) -> WhisperModel:
    name = name or MODELS["default"]
    with _model_lock:
        if name not in _models:
            _models[name] = WhisperModel(name, device="cpu", compute_type="int8")
        return _models[name]


def loaded_models() -> dict[str, bool]:
    return {n: n in _models for n in dict.fromkeys(MODELS.values())}


def clean_text(text: str) -> str:
    return _JUNK.sub("", text).translate(_PUNCT_FIX)


@dataclass
class Word:
    text: str
    start: float
    end: float
    prob: float


def transcribe(audio: np.ndarray, language: str | None):
    """Return (words, detected_language). language=None means auto-detect."""
    if language is None:  # detect with the default model, then pick the model for that language
        language = get_model().detect_language(audio)[0]
    model = get_model(model_for(language))
    prompt = INITIAL_PROMPT.get(language or "", None)
    segments, info = model.transcribe(
        audio,
        language=language,
        initial_prompt=prompt,
        word_timestamps=True,
        beam_size=5,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=False,
    )
    words: list[Word] = []
    for seg in segments:
        for w in seg.words or []:
            text = clean_text(w.word).strip()
            if not text:  # junk token: fold its time span into the previous word so no fake pause appears
                if words:
                    words[-1].end = max(words[-1].end, float(w.end))
                continue
            words.append(Word(text, float(w.start), float(w.end), float(w.probability)))
    return words, info.language


# ---------- text helpers ----------

def norm_token(text: str) -> str:
    return re.sub(r"[^\w']", "", text.lower())


def count_phrases(text: str, phrases: list[str], lang: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for p in phrases:
        if lang == "zh":
            if p in ZH_AMBIGUOUS:
                n = len(re.findall(re.escape(p) + r"(?=[，。、？！,.!?;；:：\s]|" + re.escape(p) + r"|$)", text))
            else:
                n = text.count(p)
        elif p == "so":  # only a filler when it opens a clause: "So, um, ..." not "so that"
            n = len(re.findall(r"(?:^|[.!?,;:]\s*)so\b", text))
        else:
            n = len(re.findall(r"\b" + re.escape(p) + r"\b", text))
        if n:
            counts[p] = n
    return counts


def split_sentences(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?。！？])\s*", text)
    return [p.strip() for p in parts if p.strip()]


# ---------- audio helpers ----------

def frame_db(audio: np.ndarray, frame: int = 400, hop: int = 160) -> np.ndarray:
    """RMS level in dBFS for 25 ms frames at 10 ms hop."""
    if len(audio) < frame:
        return np.array([])
    n = 1 + (len(audio) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    rms = np.sqrt(np.mean(audio[idx] ** 2, axis=1) + 1e-12)
    return 20 * np.log10(rms + 1e-9)


def estimate_pitch(audio: np.ndarray, sr: int = SAMPLE_RATE) -> dict:
    """Rough f0 via autocorrelation on loud frames. Good enough for range/variation."""
    frame, hop = int(0.04 * sr), int(0.02 * sr)
    if len(audio) < frame * 4:
        return {}
    db = frame_db(audio, frame, hop)
    if len(db) == 0:
        return {}
    thresh = np.percentile(db, 60)
    lo, hi = int(sr / 400), int(sr / 70)
    f0s = []
    for i, level in enumerate(db):
        if level < thresh:
            continue
        seg = audio[i * hop:i * hop + frame]
        seg = seg - seg.mean()
        if np.abs(seg).max() < 1e-4:
            continue
        ac = np.correlate(seg, seg, mode="full")[frame - 1:]
        ac = ac / (ac[0] + 1e-9)
        window = ac[lo:hi]
        k = int(np.argmax(window)) + lo
        if ac[k] > 0.5:
            f0s.append(sr / k)
    if len(f0s) < 10:
        return {}
    f0 = np.array(f0s)
    semis = 12 * np.log2(f0 / np.median(f0))
    return {
        "median_hz": round(float(np.median(f0)), 1),
        "p10_hz": round(float(np.percentile(f0, 10)), 1),
        "p90_hz": round(float(np.percentile(f0, 90)), 1),
        "range_semitones": round(float(np.percentile(semis, 90) - np.percentile(semis, 10)), 1),
        "std_semitones": round(float(semis.std()), 2),
    }


# ---------- main entry ----------

def analyze(path: str, language: str | None = None) -> dict:
    audio = decode_audio(path, sampling_rate=SAMPLE_RATE)
    duration = len(audio) / SAMPLE_RATE
    words, lang = transcribe(audio, language)
    lang = "zh" if lang.startswith("zh") else ("en" if lang == "en" else lang)

    if lang == "zh":
        transcript = "".join(w.text for w in words)
    else:  # keep "back" + "-end" together
        transcript = "".join(("" if i == 0 or w.text.startswith("-") else " ") + w.text for i, w in enumerate(words))
    transcript = re.sub(r"\s+", " ", transcript).strip()
    lower = transcript.lower()

    # --- word counting: CJK counts characters, everything else counts tokens
    if lang == "zh":
        unit = "字"
        tokens = _CJK.findall(transcript)
    else:
        unit = "words"
        tokens = [t for t in (norm_token(w.text) for w in words) if t]
    n_words = len(tokens)

    # --- pauses from word gaps
    pauses = []
    for a, b in zip(words, words[1:]):
        gap = b.start - a.end
        if gap >= PAUSE_SEC:
            pauses.append({"start": round(a.end, 2), "end": round(b.start, 2), "dur": round(gap, 2)})
    total_pause = sum(p["dur"] for p in pauses)
    speech_start = words[0].start if words else 0.0
    speech_end = words[-1].end if words else duration
    speaking_time = max(speech_end - speech_start - total_pause, 0.01)
    minutes = max(duration / 60, 1e-6)

    # --- pace over time
    n_bins = int(np.ceil(duration / WINDOW_SEC)) or 1
    bins = [0] * n_bins
    for w in words:
        i = min(int(w.start // WINDOW_SEC), n_bins - 1)
        bins[i] += len(_CJK.findall(w.text)) if lang == "zh" else 1
    pace_timeline = []
    for i, c in enumerate(bins):
        span = min(WINDOW_SEC, duration - i * WINDOW_SEC)
        if span >= 10:  # shorter tails give noisy numbers
            pace_timeline.append({"t": i * WINDOW_SEC, "wpm": round(c / (span / 60), 1)})

    # --- fillers / hedges / repeats
    fl = FILLERS.get(lang, FILLERS["en"])
    hd = HEDGES.get(lang, HEDGES["en"])
    filler_counts = count_phrases(lower, fl, lang)
    hedge_counts = count_phrases(lower, hd, lang)
    n_fillers = sum(filler_counts.values())
    # immediate repeats: "the the" or "let me let me"
    repeats = sum(1 for a, b in zip(tokens, tokens[1:]) if a == b and len(a) > 1)
    repeats += sum(1 for i in range(len(tokens) - 3)
                   if tokens[i:i + 2] == tokens[i + 2:i + 4])

    # --- vocabulary & sentences
    content = [t for t in tokens if t not in STOPWORDS and len(t) > 2] if lang != "zh" else tokens
    top_words = Counter(content).most_common(10)
    sentences = split_sentences(transcript)
    sent_lens = [len(_CJK.findall(s)) if lang == "zh" else len(s.split()) for s in sentences]

    # --- loudness
    db = frame_db(audio)
    loud = {}
    if len(db):
        voiced = db[db > np.percentile(db, 40)]
        loud = {
            "mean_db": round(float(voiced.mean()), 1),
            "std_db": round(float(voiced.std()), 2),
            "peak_db": round(float(db.max()), 1),
            "noise_floor_db": round(float(np.percentile(db, 5)), 1),
        }

    low_conf = sum(1 for w in words if w.prob < 0.5)

    return {
        "language": lang,
        "unit": unit,
        "duration_sec": round(duration, 2),
        "speaking_sec": round(speaking_time, 2),
        "word_count": n_words,
        "wpm": round(n_words / minutes, 1),
        "articulation_wpm": round(n_words / (speaking_time / 60), 1) if n_words else 0,
        "pace_timeline": pace_timeline,
        "pauses": {
            "count": len(pauses),
            "long_count": sum(1 for p in pauses if p["dur"] >= LONG_PAUSE_SEC),
            "total_sec": round(total_pause, 2),
            "longest_sec": round(max((p["dur"] for p in pauses), default=0), 2),
            "per_minute": round(len(pauses) / minutes, 2),
            "silence_ratio": round(1 - speaking_time / duration, 3) if duration else 0,
            "list": pauses,
        },
        "fillers": {
            "count": n_fillers,
            "per_minute": round(n_fillers / minutes, 2),
            "ratio": round(n_fillers / n_words, 4) if n_words else 0,
            "breakdown": dict(sorted(filler_counts.items(), key=lambda kv: -kv[1])),
        },
        "hedges": {
            "count": sum(hedge_counts.values()),
            "breakdown": dict(sorted(hedge_counts.items(), key=lambda kv: -kv[1])),
        },
        "repeats": repeats,
        "vocabulary": {
            "unique": len(set(tokens)),
            "type_token_ratio": round(len(set(tokens)) / n_words, 3) if n_words else 0,
            "top_words": top_words,
        },
        "sentences": {
            "count": len(sentences),
            "avg_len": round(float(np.mean(sent_lens)), 1) if sent_lens else 0,
            "max_len": max(sent_lens, default=0),
        },
        "loudness": loud,
        "pitch": estimate_pitch(audio),
        "low_confidence_words": low_conf,
        "transcript": transcript,
        "words": [asdict(w) for w in words],
    }
