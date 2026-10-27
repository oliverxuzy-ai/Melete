"""Prosody: how the voice moves, sentence by sentence.

Pitch and loudness are measured every 10 ms and kept at 50 ms steps. Whisper's word
timestamps cut them into sentences and words, which gives:

- the direction each sentence ends in (falls, rises or stays level) and whether its last
  word fades out,
- the stressed word of each sentence (higher, louder or longer than the words around it),
- monotone stretches (several seconds where the pitch hardly moves),
- the pace of each sentence,
- for shadowing, a sentence-by-sentence comparison with the reference speaker.

Plain numpy, no model. Every threshold below is a first guess, meant to be calibrated on
real takes; the stored 50 ms track lets the features be recomputed without the audio.
"""
from __future__ import annotations

import base64
import math
import re
import warnings

import numpy as np

import shadow

SR = 16000
HOP = 160                 # 10 ms between pitch frames
FRAME = 640               # 40 ms window: at least two periods of a 65 Hz voice
F0_MIN, F0_MAX = 65.0, 450.0
VOICING = 0.55            # normalized autocorrelation a frame needs to count as voiced
STEP = 0.05               # stored track resolution, seconds

FINAL_SEC = {"en": 0.5, "zh": 0.9}   # how much of a sentence's end decides its direction;
                                     # longer for Chinese so one syllable's tone doesn't decide it
FINAL_ST = 1.5            # semitones of change at the end that count as a rise or a fall
TRAIL_DB = 6.0            # last word this much quieter than its sentence: the end fades out
STRESS_MIN = 1.5          # prominence a word needs to count as clearly stressed
STRESS_WORDS = 3          # sentences shorter than this are not judged for stress
FINAL_LENGTHENING = 1.4   # a phrase's last word runs this much longer without being stressed
MONOTONE_SEC = 4.0        # window for monotone stretches
MONOTONE_ST = {"en": 3.0, "zh": 4.0}  # pitch range (p10-p90) below this in a window is monotone
PACE_MIN_SEC = 1.5        # shorter sentences give no pace
CONTOUR_POINTS = 24       # points per sentence when comparing contours with a reference

_CJK = re.compile(r"[一-鿿]")
_WORD = re.compile(r"[A-Za-z0-9']+")
_VOWELS = re.compile(r"[aeiouy]+")
_FILLERS = {"um", "uh", "uhm", "umm", "hmm", "mm", "er", "ah", "eh", "嗯", "呃", "啊"}


# ---------------------------------------------------------------- the track


class Track:
    """Pitch in semitones from the speaker's median (NaN where unvoiced) and level in dBFS,
    one value per `step` seconds; value j covers [j*step, (j+1)*step)."""

    def __init__(self, st: np.ndarray, db: np.ndarray, step: float, median_hz: float):
        self.st, self.db, self.step, self.median_hz = st, db, step, median_hz

    def __len__(self) -> int:
        return len(self.st)

    def span(self, a: float, b: float) -> slice:
        """The values covering a..b, never empty (word times can run past the last value)."""
        i0 = min(max(0, int(math.floor(a / self.step))), len(self) - 1)
        i1 = min(len(self), max(i0 + 1, int(math.ceil(b / self.step))))
        return slice(i0, i1)

    def times(self, sl: slice) -> np.ndarray:
        return (np.arange(sl.start, sl.stop) + 0.5) * self.step

    def to_json(self) -> dict:
        """Compact form for session.json: each series is base64 of signed bytes, pitch in
        tenths of a semitone (-128 = unvoiced, clipped at an octave), level in whole dB."""
        st = np.where(np.isnan(self.st), -128, np.clip(np.round(self.st * 10), -127, 127)).astype(np.int8)
        db = np.clip(np.round(self.db), -127, 127).astype(np.int8)
        return {"step": self.step, "median_hz": round(self.median_hz, 1), "encoding": "int8",
                "st": base64.b64encode(st.tobytes()).decode(), "db": base64.b64encode(db.tobytes()).decode()}

    @classmethod
    def from_json(cls, d: dict) -> "Track":
        st = np.frombuffer(base64.b64decode(d["st"]), dtype=np.int8).astype(float)
        st = np.where(st == -128, np.nan, st / 10)
        db = np.frombuffer(base64.b64decode(d["db"]), dtype=np.int8).astype(float)
        return cls(st, db, float(d["step"]), float(d["median_hz"]))


def _nccf(x: np.ndarray, lo: int, hi: int) -> np.ndarray:
    """Normalized cross-correlation of each frame with itself at lags lo..hi (rows = frames)."""
    n = x.shape[1]
    spec = np.fft.rfft(x, 2 * n, axis=1)
    ac = np.fft.irfft(spec.real ** 2 + spec.imag ** 2, 2 * n, axis=1)[:, :n]
    cs = np.cumsum(x * x, axis=1)
    lags = np.arange(lo, hi + 1)
    head = cs[:, n - 1 - lags]                       # energy of x[0 : n-k]
    tail = cs[:, n - 1][:, None] - cs[:, lags - 1]   # energy of x[k : n]
    return ac[:, lags] / (np.sqrt(np.maximum(head * tail, 0)) + 1e-12)


def _frame_pitch(audio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """f0 in Hz (NaN when unvoiced) and level in dBFS for 40 ms frames every 10 ms."""
    n = 1 + (len(audio) - FRAME) // HOP
    lo, hi = int(SR / F0_MAX), int(math.ceil(SR / F0_MIN))
    f0 = np.full(n, np.nan)
    db = np.empty(n)
    peak = np.zeros(n)
    base = np.arange(FRAME)[None, :]
    for c0 in range(0, n, 2000):                     # chunks keep memory flat on long takes
        rows = np.arange(c0, min(n, c0 + 2000))
        x = audio[base + HOP * rows[:, None]].astype(np.float64)
        x -= x.mean(axis=1, keepdims=True)
        db[rows] = 10 * np.log10(np.mean(x * x, axis=1) + 1e-12)
        r = _nccf(x, lo, hi)
        rmax = r.max(axis=1)
        # The first strong peak, not simply the highest: a period of 2T correlates almost as
        # well as T, and taking it would halve the pitch.
        cand = np.zeros_like(r, dtype=bool)
        cand[:, 1:-1] = (r[:, 1:-1] > r[:, :-2]) & (r[:, 1:-1] >= r[:, 2:]) & (r[:, 1:-1] >= 0.9 * rmax[:, None])
        k = np.where(cand.any(axis=1), cand.argmax(axis=1), r.argmax(axis=1))
        idx = np.arange(len(rows))
        kk = np.clip(k, 1, r.shape[1] - 2)
        a, b, c = r[idx, kk - 1], r[idx, kk], r[idx, kk + 1]
        den = a - 2 * b + c
        with np.errstate(divide="ignore", invalid="ignore"):
            delta = np.where(np.abs(den) > 1e-9, 0.5 * (a - c) / den, 0.0)
        delta = np.where((k > 0) & (k < r.shape[1] - 1), np.clip(delta, -0.5, 0.5), 0.0)
        f0[rows] = SR / (lo + k + delta)
        peak[rows] = r[idx, k]
    # Voice is periodic and well above the room's floor. A take with no quiet part at all
    # has no floor to measure, so only the level below the loudest part counts then.
    floor, top = np.percentile(db, 10), np.percentile(db, 99)
    level = top - 40.0 if floor > top - 15.0 else max(floor + 6.0, top - 40.0)
    voiced = (peak >= VOICING) & (db > level)
    f0[~voiced] = np.nan
    return f0, db


def _nan_runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """[start, end) runs where mask is True."""
    if not mask.any():
        return []
    d = np.diff(np.concatenate([[0], mask.astype(np.int8), [0]]))
    return list(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)))


def _clean(f0: np.ndarray) -> np.ndarray:
    """Drop octave jumps and voiced blips shorter than 40 ms."""
    f0 = f0.copy()
    v = ~np.isnan(f0)
    if v.sum() < 10:
        return np.full_like(f0, np.nan)
    st = np.full_like(f0, np.nan)
    st[v] = 12 * np.log2(f0[v] / np.median(f0[v]))
    pad = np.pad(st, 5, constant_values=np.nan)
    win = np.lib.stride_tricks.sliding_window_view(pad, 11)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        local = np.nanmedian(win, axis=1)
    f0[np.abs(st - local) > 4.0] = np.nan
    for a, b in _nan_runs(~np.isnan(f0)):
        if b - a < 4:
            f0[a:b] = np.nan
    return f0


def track(audio: np.ndarray) -> Track | None:
    """The 50 ms track for a 16 kHz recording, or None when it holds too little voice."""
    if len(audio) < FRAME * 4:
        return None
    f0, db = _frame_pitch(audio)
    f0 = _clean(f0)
    voiced = ~np.isnan(f0)
    if voiced.sum() < 20:
        return None
    median_hz = float(np.median(f0[voiced]))
    st = 12 * np.log2(f0 / median_hz)
    # Frame i is centred at 20 ms + i*10 ms, so bin j (50 ms) holds frames 5j-2 .. 5j+2.
    per = int(round(STEP / (HOP / SR)))
    lead = int(round((FRAME / 2 / SR) / (HOP / SR)))
    nb = int(math.ceil(len(audio) / SR / STEP))
    need = nb * per
    st_p = np.full(need, np.nan)
    db_p = np.full(need, np.nan)
    m = min(len(st), need - lead)
    st_p[lead:lead + m] = st[:m]
    db_p[lead:lead + m] = db[:m]
    st_b = st_p.reshape(nb, per)
    db_b = db_p.reshape(nb, per)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        st_out = np.nanmedian(st_b, axis=1)
        db_out = np.nanmean(db_b, axis=1)
    st_out[(~np.isnan(st_b)).sum(axis=1) < 2] = np.nan
    db_out = np.where(np.isnan(db_out), float(np.nanmin(db)), db_out)
    return Track(st_out, db_out, STEP, median_hz)


# ---------------------------------------------------------------- words and sentences


def _tokens(text: str, lang: str) -> int:
    return len(_CJK.findall(text)) if lang == "zh" else len(_WORD.findall(text))


def _norm(text: str) -> str:
    return re.sub(r"[^\w']", "", text.lower())


def _syllables(text: str, lang: str) -> int:
    if lang == "zh" or _CJK.search(text):
        return max(1, len(_CJK.findall(text)))
    w = _norm(text)
    n = len(_VOWELS.findall(w))
    if n > 1 and w.endswith("e") and not w.endswith("le"):
        n -= 1
    return max(1, n)


def _voiced(tr: Track, a: float, b: float) -> tuple[np.ndarray, np.ndarray]:
    sl = tr.span(a, b)
    t, v = tr.times(sl), tr.st[sl]
    keep = ~np.isnan(v)
    return t[keep], v[keep]


def _word_db(tr: Track, w: dict) -> float:
    return float(np.percentile(tr.db[tr.span(w["start"], w["end"])], 75))


def final_direction(tr: Track, words: list[dict], lang: str) -> dict | None:
    """How the sentence ends: the pitch change over its last half second (about a second
    for Chinese), fitted as a line."""
    if not words:
        return None
    end = words[-1]["end"]
    start = min(words[-1]["start"], end - FINAL_SEC.get(lang, 0.5))
    t, v = _voiced(tr, start, end)
    if len(t) < 4 or t[-1] - t[0] < 0.15:
        return None
    slope = float(np.polyfit(t, v, 1)[0])
    change = slope * float(t[-1] - t[0])
    d = "fall" if change <= -FINAL_ST else ("rise" if change >= FINAL_ST else "level")
    return {"dir": d, "change": round(change, 1)}


def fades(tr: Track, words: list[dict]) -> bool:
    """The last word is much quieter than the rest of the sentence."""
    if len(words) < 3:
        return False
    body = float(np.median([_word_db(tr, w) for w in words[:-1]]))
    return body - _word_db(tr, words[-1]) >= TRAIL_DB


def stress(tr: Track, words: list[dict], lang: str, offset: int = 0) -> dict | None:
    """The most prominent word: pitch peak above the sentence's typical word, louder, or
    longer per syllable. None when the sentence is too short to judge."""
    rows = []
    for k, w in enumerate(words):
        text = _norm(w["text"])
        if not text or text in _FILLERS:
            continue
        _, v = _voiced(tr, w["start"], w["end"])
        rows.append((k, float(v.max()) if len(v) else np.nan, _word_db(tr, w),
                     max(w["end"] - w["start"], 0.02) / _syllables(w["text"], lang)))
    if len(rows) < STRESS_WORDS:
        return None
    pitch = np.array([r[1] for r in rows])
    loud = np.array([r[2] for r in rows])
    dur = np.array([r[3] for r in rows])
    if rows[-1][0] == len(words) - 1:
        dur[-1] /= FINAL_LENGTHENING   # the last word of a phrase is longer anyway
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        p_med = np.nanmedian(pitch) if not np.isnan(pitch).all() else np.nan
    pe = np.nan_to_num(pitch - p_med, nan=0.0)
    le = loud - np.median(loud)
    dr = dur / np.median(dur)
    score = np.maximum(pe, 0) / 2.0 + np.maximum(le, 0) / 3.0 + np.maximum(dr - 1, 0) / 0.5
    best = int(np.argmax(score))
    k = rows[best][0]
    return {"w": offset + k, "word": words[k]["text"].strip(), "score": round(float(score[best]), 2),
            "clear": bool(score[best] >= STRESS_MIN)}


def monotone(tr: Track, a: float, b: float, lang: str) -> list[dict]:
    """Stretches of at least MONOTONE_SEC where the pitch hardly moves."""
    win = int(round(MONOTONE_SEC / tr.step))
    hop = max(1, int(round(0.5 / tr.step)))
    lo, hi = tr.span(a, b).start, tr.span(a, b).stop
    if hi - lo < win:
        return []
    thr = MONOTONE_ST.get(lang, 3.0)
    flat: list[list[int]] = []
    for i in range(lo, hi - win + 1, hop):
        v = tr.st[i:i + win]
        v = v[~np.isnan(v)]
        if len(v) < max(20, 0.3 * win):
            continue
        if np.percentile(v, 90) - np.percentile(v, 10) < thr:
            if flat and i <= flat[-1][1]:
                flat[-1][1] = i + win
            else:
                flat.append([i, i + win])
    out = []
    for i0, i1 in flat:
        v = tr.st[i0:i1]
        v = v[~np.isnan(v)]
        out.append({"start": round(i0 * tr.step, 2), "end": round(min(i1, hi) * tr.step, 2),
                    "range": round(float(np.percentile(v, 90) - np.percentile(v, 10)), 1)})
    return out


def _sentence(tr: Track, words: list[dict], lang: str, offset: int) -> dict:
    start, end = words[0]["start"], words[-1]["end"]
    n = sum(_tokens(w["text"], lang) for w in words)
    dur = end - start
    _, v = _voiced(tr, start, end)
    s = stress(tr, words, lang, offset)
    return {
        "start": round(start, 2),
        "end": round(end, 2),
        "pace": round(n / dur * 60) if dur >= PACE_MIN_SEC and n >= 4 else None,
        "range": round(float(np.percentile(v, 90) - np.percentile(v, 10)), 1) if len(v) >= 6 else None,
        "final": final_direction(tr, words, lang),
        "fades": fades(tr, words),
        "stress": s,
    }


def features(tr: Track, words: list[dict], lang: str) -> dict:
    """Sentence-by-sentence features and a summary, from a track and the timed words."""
    groups = shadow.sentences_from_words(words)
    sentences = []
    for i, g in enumerate(groups):
        ws = words[g["w0"]:g["w1"]]
        row = _sentence(tr, ws, lang, g["w0"])
        sentences.append({"i": i, "text": g["text"], **row})
    finals = [s["final"]["dir"] for s in sentences if s["final"]]
    judged = [s for s in sentences if s["stress"]]
    paces = [s["pace"] for s in sentences if s["pace"]]
    ranges = [s["range"] for s in sentences if s["range"] is not None]
    span = (words[0]["start"], words[-1]["end"]) if words else (0.0, 0.0)
    flat = monotone(tr, span[0], span[1], lang)
    flat_sec = sum(f["end"] - f["start"] for f in flat)
    speech = max(span[1] - span[0], 1e-6)
    return {
        "sentences": sentences,
        "summary": {
            "sentences": len(sentences),
            "final": {d: finals.count(d) for d in ("fall", "rise", "level")},
            "fades": sum(1 for s in sentences if s["fades"]),
            "stress_judged": len(judged),
            "stress_share": round(100 * sum(1 for s in judged if s["stress"]["clear"]) / len(judged)) if judged else None,
            "monotone": flat,
            "monotone_sec": round(flat_sec, 1),
            "monotone_share": round(flat_sec / speech, 3),
            "pace_cv": round(float(np.std(paces) / np.mean(paces)), 3) if len(paces) >= 3 else None,
            "range_median": round(float(np.median(ranges)), 1) if ranges else None,
        },
    }


def analyze(audio: np.ndarray, words: list[dict], lang: str) -> dict | None:
    """Everything for one recording: the stored track plus the features."""
    if not words:
        return None
    tr = track(audio)
    if tr is None:
        return None
    return {"version": 1, "track": tr.to_json(), **features(tr, words, lang)}


# ---------------------------------------------------------------- shadowing


def _in_span(words: list[dict], a: float, b: float) -> list[dict]:
    return [w for w in words if a - 0.05 <= (w["start"] + w["end"]) / 2 <= b + 0.05]


def _contour(tr: Track, a: float, b: float) -> np.ndarray | None:
    t, v = _voiced(tr, a, b)
    if len(t) < 6 or b - a < 0.4:
        return None
    x = np.linspace(a, b, CONTOUR_POINTS)
    return np.interp(x, t, v)


def compare(ref: Track, ref_words: list[dict], ref_sentences: list[dict],
            you: Track, your_words: list[dict], lang: str) -> dict | None:
    """Your pitch movement against the reference speaker's, sentence by sentence. Each
    side is in semitones from its own speaker's median, so different voices compare."""
    if not ref_sentences or not your_words:
        return None
    placed = shadow.align([s["text"] for s in ref_sentences], your_words)
    rows = []
    for rs, ys in zip(ref_sentences, placed):
        if not ys.get("matched"):
            continue
        a, b = _contour(ref, rs["start"], rs["end"]), _contour(you, ys["start"], ys["end"])
        if a is None or b is None:
            continue
        corr = float(np.corrcoef(a, b)[0, 1]) if a.std() > 0.3 and b.std() > 0.3 else None
        rw, yw = _in_span(ref_words, rs["start"], rs["end"]), _in_span(your_words, ys["start"], ys["end"])
        rf, yf = final_direction(ref, rw, lang), final_direction(you, yw, lang)
        rst, yst = stress(ref, rw, lang), stress(you, yw, lang)
        rr = float(np.percentile(a, 90) - np.percentile(a, 10))
        yr = float(np.percentile(b, 90) - np.percentile(b, 10))
        rows.append({
            "i": rs.get("i", len(rows)),
            "text": rs["text"],
            "start": round(ys["start"], 2), "end": round(ys["end"], 2),
            "similarity": round(max(corr, 0.0) * 100) if corr is not None else None,
            "range_ratio": round(yr / rr, 2) if rr >= 0.5 else None,
            "ref_final": rf["dir"] if rf else None, "your_final": yf["dir"] if yf else None,
            "ref_stress": rst["word"] if rst and rst["clear"] else None,
            "your_stress": yst["word"] if yst and yst["clear"] else None,
            "ref_contour": [round(float(x), 1) for x in a],
            "your_contour": [round(float(x), 1) for x in b],
        })
    if not rows:
        return None
    sims = [r["similarity"] for r in rows if r["similarity"] is not None]
    ratios = [r["range_ratio"] for r in rows if r["range_ratio"] is not None]
    finals = [r for r in rows if r["ref_final"] and r["your_final"]]
    stressed = [r for r in rows if r["ref_stress"]]
    worst = sorted((r for r in rows if r["similarity"] is not None), key=lambda r: r["similarity"])[:3]
    return {
        "sentences": rows,
        "summary": {
            "compared": len(rows),
            "of": len(ref_sentences),
            "similarity": round(float(np.mean(sims))) if sims else None,
            "range_ratio": round(float(np.median(ratios)), 2) if ratios else None,
            "same_final": round(100 * sum(1 for r in finals if r["ref_final"] == r["your_final"]) / len(finals)) if finals else None,
            "same_stress": round(100 * sum(1 for r in stressed if r["your_stress"] and _norm(r["your_stress"]) == _norm(r["ref_stress"])) / len(stressed)) if stressed else None,
            "worst": [r["i"] for r in worst],
        },
    }
