"""Reads Codex's local session logs.

Only the standard library: this is a viewer, and asking a user to install packages to
look at their own usage data would defeat the point.

The format is newline-delimited JSON, one file per session, laid out as
`<root>/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`. Token usage appears on `event_msg`
lines whose payload carries an `info` object; every other line type is ignored.

Each reading carries both `last_token_usage` (this turn) and `total_token_usage` (the
session so far). Only the first is used. The second is a running total that includes the
whole conversation resent on every turn, so accumulating it across lines gives a figure
in the billions for a single long session — arithmetic that is self-consistent and
answers a different question from "how much did I use". The macOS build reads
`last_token_usage` the same way, and the two must agree.

A turn is `input_tokens + output_tokens`, and `reasoning_output_tokens` is **not** added
on top. Codex's own `total_tokens` field counts reasoning inside `output_tokens`: across
this machine's logs `total_tokens == input + output` in 35,894 of 38,460 readings, and on
four separate files the sum of per-turn `input + output` equals the file's own final
`total_token_usage` exactly, while adding reasoning overshoots by precisely the reasoning
total. Adding it here double-counted reasoning on every turn (~18.5M tokens, ~0.15% of
the total, across the corpus). `reasoning_output_tokens` is still recorded per sample
because it is worth showing, but it is a breakdown of the output, not an extra.

Turns are summed directly rather than differenced: each `last_token_usage` is already a
per-turn figure, and a session that is compacted still reports its own turns correctly.

Codex sometimes writes the same reading twice in a row without the running total moving —
a re-logged turn, not a second turn. Counting those as fresh turns inflated this machine's
corpus by 352M tokens across 244 of 536 files. `parse_session` therefore drops a reading
that repeats the previous one *and* leaves the running total unchanged; a genuinely new
turn always advances the running total, so this only ever discards true duplicates.
"""

from __future__ import annotations

import glob
import json
import os
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Tuple


def default_sessions_root() -> str:
    """Where Codex keeps its session logs.

    `CODEX_HOME` is honoured because Codex itself honours it, and because `accounts.py`
    already reads `config.toml` from that same override. Reading config from one home while
    reading sessions from another would report a provider that does not match the usage
    being displayed, with no visible sign that the two came from different places.
    """
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    return os.path.join(home, "sessions")


@dataclass
class UsageSample:
    """One recorded usage reading, already reduced to a per-turn increment."""

    timestamp: datetime
    input_tokens: int
    cached_input_tokens: int
    output_tokens: int
    reasoning_output_tokens: int

    @property
    def billable_tokens(self) -> int:
        """This turn's tokens, counted the way Codex counts them.

        `reasoning_output_tokens` is deliberately absent: it is a breakdown of
        `output_tokens`, not a quantity alongside it. See the module docstring for the
        measurement that established this.
        """
        return self.input_tokens + self.output_tokens


@dataclass
class SessionSummary:
    path: str
    session_id: Optional[str] = None
    started_at: Optional[datetime] = None
    samples: List[UsageSample] = field(default_factory=list)
    model: Optional[str] = None

    @property
    def total_tokens(self) -> int:
        return sum(s.billable_tokens for s in self.samples)


def _parse_timestamp(value: object) -> Optional[datetime]:
    """Parses an ISO-8601 timestamp, tolerating the trailing Z Codex writes."""
    if not isinstance(value, str) or not value:
        return None

    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None

    # A naive timestamp is read as UTC, which is what Codex writes.
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _int(value: object) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def _dict(value: object) -> Dict[str, object]:
    """Narrows a decoded JSON value to a dict.

    Every field this parser walks is reached through `.get`, and a decoded record is only
    as well-formed as whatever wrote it last. A half-written tail, an older schema, or a
    line that merely *mentions* these key names in its prose must all be skipped rather
    than raising `AttributeError` out of `parse_session` and taking the whole day's totals
    with it. Returning an empty dict makes every downstream `.get` yield None, which the
    existing zero/None handling already treats as "no reading here".
    """
    return value if isinstance(value, dict) else {}


def parse_session(path: str) -> Optional[SessionSummary]:
    """Reads one session file.

    Returns None when the file has no usable readings, so a caller can skip it rather than
    carrying an empty session into every total. A malformed line is skipped: one bad write
    must not hide an entire day of usage.
    """
    summary = SessionSummary(path=path)

    try:
        handle = open(path, errors="ignore")
    except OSError:
        return None

    # Tracks the previous accepted reading so a re-logged turn can be recognised. `seen_total`
    # is the running total reported alongside it; a duplicate is only skipped when that total
    # has not moved, which distinguishes a re-emission from a real turn that happens to cost
    # the same. See the module docstring.
    previous_key: Optional[Tuple[int, int, int, int]] = None
    previous_total: Optional[int] = None

    with handle:
        for line in handle:
            # Cheap pre-filter before parsing: these files are mostly conversation text, and
            # json.loads on every line of 2.6 GB is not affordable.
            if '"info"' not in line or "last_token_usage" not in line:
                if summary.session_id is None and '"session_meta"' in line:
                    try:
                        meta = json.loads(line)
                        payload = _dict(_dict(meta).get("payload"))
                        summary.session_id = payload.get("id") or payload.get("session_id")
                        summary.started_at = _parse_timestamp(
                            payload.get("timestamp")
                        ) or _parse_timestamp(_dict(meta).get("timestamp"))
                    except (ValueError, TypeError, AttributeError):
                        pass
                continue

            try:
                record = json.loads(line)
            except ValueError:
                continue

            record = _dict(record)
            payload = _dict(record.get("payload"))
            info = _dict(payload.get("info"))
            turn = _dict(info.get("last_token_usage"))
            timestamp = _parse_timestamp(record.get("timestamp"))
            if timestamp is None:
                continue

            input_tokens = _int(turn.get("input_tokens"))
            output_tokens = _int(turn.get("output_tokens"))
            reasoning = _int(turn.get("reasoning_output_tokens"))
            cached = _int(turn.get("cached_input_tokens"))

            # A reading of nothing at all is noise, not a turn worth recording.
            if input_tokens == 0 and output_tokens == 0 and reasoning == 0:
                continue

            running_total = _dict(info.get("total_token_usage")).get("total_tokens")
            running_total = None if running_total is None else _int(running_total)
            key = (input_tokens, output_tokens, reasoning, cached)

            if key == previous_key and running_total is not None and running_total == previous_total:
                # Identical reading, unchanged running total: Codex re-logged the same turn.
                continue

            previous_key = key
            previous_total = running_total

            summary.samples.append(
                UsageSample(
                    timestamp=timestamp,
                    input_tokens=input_tokens,
                    cached_input_tokens=cached,
                    output_tokens=output_tokens,
                    reasoning_output_tokens=reasoning,
                )
            )

    if not summary.samples:
        return None

    if summary.started_at is None:
        summary.started_at = summary.samples[0].timestamp
    return summary


def iter_session_files(root: Optional[str] = None) -> List[str]:
    """Every session file under the root, oldest path first.

    Directories are filtered out even when their name ends in `.jsonl`: `glob` matches on
    name, and a directory called `something.jsonl` would otherwise be handed to
    `parse_session`, which would read it as an empty file and report a day as having no
    usage rather than reporting nothing at all.
    """
    base = root or default_sessions_root()
    if not os.path.isdir(base):
        return []
    return sorted(
        path
        for path in glob.glob(os.path.join(base, "**", "*.jsonl"), recursive=True)
        if os.path.isfile(path)
    )


def load_sessions(paths: Iterable[str]) -> List[SessionSummary]:
    sessions = []
    for path in paths:
        parsed = parse_session(path)
        if parsed is not None:
            sessions.append(parsed)
    return sessions


def daily_tokens(sessions: Iterable[SessionSummary]) -> Dict[date, int]:
    """Tokens per local day.

    Keyed by the local date, because a user asking about "today" means their own day, not
    UTC's.
    """
    totals: Dict[date, int] = {}
    for session in sessions:
        for sample in session.samples:
            day = sample.timestamp.astimezone().date()
            totals[day] = totals.get(day, 0) + sample.billable_tokens
    return totals


def summarise(sessions: Iterable[SessionSummary], now: Optional[datetime] = None) -> Dict[str, object]:
    """Aggregate figures for the panel."""
    reference = now or datetime.now(timezone.utc)
    sessions = list(sessions)
    per_day = daily_tokens(sessions)

    today = reference.astimezone().date()
    week_start = today - timedelta(days=6)

    today_tokens = per_day.get(today, 0)
    week_tokens = sum(count for day, count in per_day.items() if week_start <= day <= today)

    return {
        "session_count": len(sessions),
        "day_count": len(per_day),
        "today_tokens": today_tokens,
        "week_tokens": week_tokens,
        "total_tokens": sum(per_day.values()),
        "first_day": min(per_day).isoformat() if per_day else None,
        "last_day": max(per_day).isoformat() if per_day else None,
        "daily": {day.isoformat(): count for day, count in sorted(per_day.items())},
    }


if __name__ == "__main__":
    import sys
    import time

    started = time.time()
    files = iter_session_files(sys.argv[1] if len(sys.argv) > 1 else None)
    loaded = load_sessions(files)
    result = summarise(loaded)
    result["elapsed_seconds"] = round(time.time() - started, 2)

    # Printed whole. An earlier version truncated the text, which produced invalid JSON and
    # made the output unusable to anything but a human reading the first screenful.
    print(json.dumps(result, indent=2))
