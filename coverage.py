"""Key-point coverage: how much of a script's content made it into a transcript.

The script is treated as talking points, not lines to read verbatim. Each script
sentence is scored by how many of its content words (lightly stemmed) show up in
the best-matching stretch of the transcript. Paraphrase is fine and order is only
reported, never penalised.
"""
from __future__ import annotations

import re

STOPWORDS = set("""a an the and or but if of to in on at for with by from as is are was were be been being am
do does did done have has had having i you he she it we they me him her us them my your his its our their this
that these those there here not no yes so than then very can could should would will shall may might must just
about into over up down out off what which who whom whose when where why how all any some more most other such
only own same too also because while until although though after before during through between again further
once each few both either neither like get got go going went come came make made take took give gave say said
let want need thing things way lot kind sort really actually basically okay well right um uh yeah know mean
think guess maybe one two three first second third next last new old good bad big small much many little""".split())

COVERED, PARTIAL = 0.6, 0.3          # score thresholds for the three states
MAX_TERMS = 30

_SPEAKER = re.compile(r"^\s*[A-Za-z][\w .'\-]{0,24}[:：]\s*")   # "Alice:"  "Interviewer:"
_BULLET = re.compile(r"^\s*(?:[-*•]|\d+[.)])\s+")
_CJK = re.compile(r"[一-鿿]")
_WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'\-]*")


# ---------- tokens ----------

def stem(w: str) -> str:
    for suf in ("ations", "ation", "ing", "ed", "ly", "es", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 4:
            return w[: -len(suf)]
    return w


def is_cjk(text: str) -> bool:
    return len(_CJK.findall(text)) > len(_WORD.findall(text))


def words(text: str) -> list[str]:
    return [w.lower() for w in _WORD.findall(text)]


def content(text: str) -> list[str]:
    """Stems of the content words, or overlapping character bigrams for Chinese."""
    if is_cjk(text):
        chars = _CJK.findall(text)
        return [a + b for a, b in zip(chars, chars[1:])] or chars
    return [stem(w) for w in words(text) if w not in STOPWORDS and (len(w) > 2 or w.isdigit())]


def same(a: str, b: str) -> bool:
    return a == b or (len(a) >= 5 and len(b) >= 5 and (a.startswith(b) or b.startswith(a)))


# ---------- script structure ----------

def split_points(script: str) -> list[str]:
    out: list[str] = []
    for line in script.splitlines():
        line = _BULLET.sub("", _SPEAKER.sub("", line)).strip()
        if not line:
            continue
        for s in re.split(r"(?<=[.!?;。！？；])\s*", line):
            s = s.strip()
            if s and content(s):
                out.append(s)
    # fold fragments with fewer than 3 content units into the previous point
    merged: list[str] = []
    for s in out:
        if merged and len(content(s)) < 3:
            merged[-1] = merged[-1] + " " + s
        else:
            merged.append(s)
    return merged


def extract_terms(script: str) -> list[str]:
    """Names, acronyms, numbers and technical tokens: the words that should survive paraphrase."""
    seen: dict[str, str] = {}
    for line in script.splitlines():
        line = _BULLET.sub("", _SPEAKER.sub("", line))
        for sent in re.split(r"(?<=[.!?;])\s+", line):
            toks = _WORD.findall(sent)
            for i, t in enumerate(toks):
                key = t.lower()
                if key in STOPWORDS or key in seen or len(t) < 2:
                    continue
                proper = t[0].isupper() and i > 0 and not t.isupper()
                acronym = t.isupper() and len(t) >= 2
                techy = any(ch.isdigit() for ch in t) or "-" in t or (t[1:] != t[1:].lower() and not t.isupper())
                if proper or acronym or techy:
                    seen[key] = t
    return list(seen.values())[:MAX_TERMS]


# ---------- main ----------

def analyze_coverage(script: str, transcript: str) -> dict | None:
    if not script.strip():
        return None
    points = split_points(script)
    if not points:
        return None
    t_content = content(transcript)
    t_words = words(transcript) if not is_cjk(transcript) else _CJK.findall(transcript)
    s_words = words(script) if not is_cjk(script) else _CJK.findall(script)

    results = []
    for idx, p in enumerate(points):
        units = list(dict.fromkeys(content(p)))  # unique, ordered
        surface = {}
        for w in (_WORD.findall(p) if not is_cjk(p) else []):
            surface.setdefault(stem(w.lower()), w)
        positions = [[j for j, t in enumerate(t_content) if same(u, t)] for u in units]
        width = max(12, 3 * len(units))
        best_hits, best_start = set(), None
        for start in range(max(1, len(t_content) - width + 1)):
            end = start + width
            hits = {u for u, pos in zip(units, positions) if any(start <= j < end for j in pos)}
            if len(hits) > len(best_hits):
                best_hits, best_start = hits, start
        score = len(best_hits) / len(units) if units else 0
        status = "covered" if score >= COVERED else "partial" if score >= PARTIAL else "missed"
        results.append({
            "i": idx, "text": p, "score": round(score, 2), "status": status,
            "hits": [surface.get(u, u) for u in units if u in best_hits],
            "misses": [surface.get(u, u) for u in units if u not in best_hits],
            "pos": best_start,
        })

    n = len(results)
    counts = {k: sum(1 for r in results if r["status"] == k) for k in ("covered", "partial", "missed")}
    coverage = (counts["covered"] + 0.5 * counts["partial"]) / n

    # order: do the points you did cover come out in the script's order?
    placed = [r["pos"] for r in results if r["status"] != "missed" and r["pos"] is not None]
    order = None
    if len(placed) >= 2:
        order = round(sum(1 for a, b in zip(placed, placed[1:]) if b >= a) / (len(placed) - 1), 2)

    # terms: exact-ish match anywhere in the transcript
    t_tokens = set(words(transcript))
    terms = []
    for term in extract_terms(script):
        key = term.lower()
        said = key in t_tokens or any(same(stem(key), stem(t)) for t in t_tokens if len(t) >= 4)
        terms.append({"term": term, "said": said})

    # content in the transcript that is not in the script at all (the "发散" part)
    script_units = set(content(script))
    extra = []
    for sent in re.split(r"(?<=[.!?。！？])\s*", transcript):
        units = content(sent)
        if len(units) < 3:
            continue
        novel = [u for u in units if not any(same(u, s) for s in script_units)]
        if len(novel) / len(units) >= 0.6:
            extra.append(sent.strip())

    return {
        "coverage": round(coverage, 3),
        "counts": counts,
        "points": results,
        "terms": terms,
        "terms_said": sum(1 for t in terms if t["said"]),
        "order": order,
        "script_words": len(s_words),
        "transcript_words": len(t_words),
        "expansion": round(len(t_words) / len(s_words), 2) if s_words else None,
        "extra": extra[:15],
    }
