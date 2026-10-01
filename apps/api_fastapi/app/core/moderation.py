from __future__ import annotations

import re


CONTENT_BLOCKED_MESSAGE = (
    "This text breaks Tydes community rules. Please edit it and try again."
)


_BLOCKED_TEXT_PATTERNS = [
    # Racial and identity slurs, including common punctuation/number dodges.
    re.compile(r"\bn[\W_]*[i1!][\W_]*g[\W_]*g[\W_]*(?:e[\W_]*r|a)\b", re.I),
    re.compile(r"\bf[\W_]*a[\W_]*g[\W_]*(?:g[\W_]*o[\W_]*t|s?)\b", re.I),
    # Porn spam and explicit sexual solicitation. Keep this compact to avoid
    # blocking ordinary surf/travel conversations by accident.
    re.compile(
        r"\b(?:porn|porno|onlyfans|xxx|hardcore|camgirl|nudes?|nsfw|"
        r"blowjob|handjob|cumshot|sex[\W_]*tape|incest)\b",
        re.I,
    ),
    # Direct self-harm harassment.
    re.compile(r"\b(?:kys|kill[\W_]*yourself)\b", re.I),
]


def has_blocked_content(text: str | None) -> bool:
    if not text:
        return False
    normalized = text.strip()
    if not normalized:
        return False
    return any(pattern.search(normalized) for pattern in _BLOCKED_TEXT_PATTERNS)


def ensure_allowed_content(*values: str | None) -> None:
    if any(has_blocked_content(value) for value in values):
        raise ValueError(CONTENT_BLOCKED_MESSAGE)
