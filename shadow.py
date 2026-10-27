"""Timed sentences for shadowing.

Turns Whisper word timestamps into sentences with start/end times. If the user supplies
the transcript, its sentences are snapped onto the Whisper words by token alignment, so the
subtitles show the clean text while the timing comes from the audio.
"""
from __future__ import annotations

import difflib
import re

_TOKEN = re.compile(r"[一-鿿]|[A-Za-z0-9][A-Za-z0-9'\-]*")   # CJK per character, Latin per word
_SPEAKER = re.compile(r"^\s*[A-Za-z][\w .'\-]{0,24}[:：]\s*")
_BULLET = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+")
_SENT_END = re.compile(r"[.!?。！？]+[\"'”’)\]]*$")
_CLAUSE_END = re.compile(r"[,;:，；：、]$")
MAX_GAP = 1.2       # a silence longer than this ends a sentence when there is no punctuation
MAX_WORDS = 28      # hard cap so one sentence never fills the screen


def tokens(text: str) -> list[str]:
    return [t.lower() for t in _TOKEN.findall(text)]


def split_sentences(text: str) -> list[str]:
    out: list[str] = []
    for line in text.splitlines():
        line = _BULLET.sub("", _SPEAKER.sub("", line)).strip()
        if not line:
            continue
        for s in re.split(r"(?<=[.!?。！？])\s*", line):
            s = s.strip()
            if not s:
                continue
            if len(tokens(s)) > 40:  # long unpunctuated run: break at clause marks
                out.extend(x.strip() for x in re.split(r"(?<=[,;，；])\s*", s) if x.strip())
            else:
                out.append(s)
    return out


def sentences_from_words(words: list[dict]) -> list[dict]:
    """Group Whisper words into sentences using punctuation, silences and a length cap."""
    out, cur = [], []
    for k, w in enumerate(words):
        cur.append(w)
        nxt = words[k + 1] if k + 1 < len(words) else None
        text = w["text"]
        end = (
            _SENT_END.search(text) is not None
            or nxt is None
            or nxt["start"] - w["end"] > MAX_GAP
            or (len(cur) >= 18 and _CLAUSE_END.search(text) is not None)
            or len(cur) >= MAX_WORDS
        )
        if end:
            joiner = "" if all(_TOKEN.fullmatch(x["text"].strip(" ,.，。")) and re.match(r"[一-鿿]", x["text"]) for x in cur) else " "
            out.append({"text": joiner.join(x["text"] for x in cur).strip(), "start": cur[0]["start"], "end": cur[-1]["end"],
                        "w0": k + 1 - len(cur), "w1": k + 1})   # the sentence's words: words[w0:w1]
            cur = []
    return out


def align(sentences: list[str], words: list[dict]) -> list[dict]:
    """Snap transcript sentences onto Whisper words. Sentences with no matched token get
    their time interpolated from their neighbours."""
    units = []  # (token, start, end)
    for w in words:
        for t in tokens(w["text"]):
            units.append((t, w["start"], w["end"]))
    flat, owner = [], []
    for si, s in enumerate(sentences):
        for t in tokens(s):
            flat.append(t)
            owner.append(si)
    sm = difflib.SequenceMatcher(None, flat, [u[0] for u in units], autojunk=False)
    first: dict[int, float] = {}
    last: dict[int, float] = {}
    for a, b, n in sm.get_matching_blocks():
        for k in range(n):
            si = owner[a + k]
            first.setdefault(si, units[b + k][1])
            last[si] = units[b + k][2]
    out = []
    for si, s in enumerate(sentences):
        out.append({"text": s, "start": first.get(si), "end": last.get(si), "matched": si in first})
    # fill gaps: unmatched sentences take the span between their neighbours
    total_end = words[-1]["end"] if words else 0.0
    for i, s in enumerate(out):
        if s["start"] is None:
            prev_end = next((out[j]["end"] for j in range(i - 1, -1, -1) if out[j]["end"] is not None), 0.0)
            next_start = next((out[j]["start"] for j in range(i + 1, len(out)) if out[j]["start"] is not None), total_end)
            s["start"], s["end"] = prev_end, max(prev_end, next_start)
    # keep the timeline monotonic
    for i in range(1, len(out)):
        if out[i]["start"] < out[i - 1]["end"]:
            out[i]["start"] = out[i - 1]["end"]
        if out[i]["end"] < out[i]["start"]:
            out[i]["end"] = out[i]["start"]
    return out


def build_sentences(words: list[dict], transcript: str | None) -> list[dict]:
    if transcript and transcript.strip():
        sents = split_sentences(transcript)
        if sents:
            out = align(sents, words)
        else:
            out = sentences_from_words(words)
    else:
        out = sentences_from_words(words)
    for i, s in enumerate(out):
        s["i"] = i
        s["start"] = round(float(s["start"]), 2)
        s["end"] = round(float(s["end"]), 2)
        s.setdefault("matched", True)
    return out
