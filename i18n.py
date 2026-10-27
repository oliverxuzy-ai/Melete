"""Interface language for the text the server writes: plans, feedback, recaps, clip notes.

The app sends X-Melete-Lang with every request. The last language it asked for is kept in
settings.json, so the morning clip job and the evening notification follow it too.
"""
from __future__ import annotations

from contextvars import ContextVar

LANGS = ("zh", "en")

_default = ["zh"]                     # last language the app asked for; used outside requests
_request: ContextVar[str | None] = ContextVar("melete_lang", default=None)


def lang() -> str:
    return _request.get() or _default[0]


def is_en() -> bool:
    return lang() == "en"


def t(zh: str, en: str) -> str:
    """Pick the Chinese or the English text."""
    return en if is_en() else zh


def field(d: dict, key: str) -> str:
    """d[key], or d[key + "_en"] when the interface is English and that field exists."""
    if is_en() and d.get(f"{key}_en"):
        return d[f"{key}_en"]
    return d.get(key, "")


def set_default(code: str | None) -> bool:
    """Remember the language for work outside a request. True when it changed."""
    if code in LANGS and code != _default[0]:
        _default[0] = code
        return True
    return False


def use_for_request(code: str | None):
    """Set the language for the current request. Returns a token for reset(), or None."""
    return _request.set(code) if code in LANGS else None


def reset(token) -> None:
    if token is not None:
        _request.reset(token)
