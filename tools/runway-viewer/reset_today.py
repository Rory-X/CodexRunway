"""Answers "did the quota reset today?".

Data comes from a public status endpoint that publishes the reset events the community
observes. Nothing here writes anything, and a failure to reach the endpoint is reported as
"unknown" rather than as "no" — the two mean very different things to a user deciding
whether to keep working.

The endpoint is reached through the project's own URL and follows redirects: the canonical
host has moved, and hard-coding the current host would break the moment it moves again.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

#: The status endpoint. Redirects are followed, so this stays correct across a host move.
STATUS_URL = "https://www.codexrunway.com/api/status.json"

#: The schema this module understands. A newer one is reported as unknown rather than
#: guessed at, because a renamed field would otherwise read as "no reset happened".
SUPPORTED_SCHEMA = 1

#: Requests are bounded: this is a side panel, not something worth hanging the view for.
#: Generous because the payload is tens of kilobytes and Python 3.9 on macOS links against
#: LibreSSL, which is noticeably slower at the handshake than the system curl — a 12-second
#: bound reliably timed out on a connection that curl completed in under two.
REQUEST_TIMEOUT_SECONDS = 30


@dataclass
class ResetEvent:
    """One observed reset."""

    kind: str
    reset_type: Optional[str]
    announced_at: Optional[datetime]
    effective_at: Optional[datetime]
    confidence: float
    rationale: Optional[str]
    text: Optional[str]
    url: Optional[str] = None
    plans: List[str] = field(default_factory=list)

    @property
    def when(self) -> Optional[datetime]:
        """When the reset took effect.

        `effectiveAt` is the precise moment but is often absent — a reset is frequently
        announced before a time is known — so the announcement time is the fallback. Using
        only `effectiveAt` would report "no reset today" on a day when one plainly happened.
        """
        return self.effective_at or self.announced_at

    @property
    def is_global(self) -> bool:
        return (self.reset_type or "").lower() == "global"


@dataclass
class ResetTodayReport:
    """The verdict, plus what it was based on."""

    verdict: str  # "yes" | "no" | "unknown"
    confidence: Optional[float] = None
    event: Optional[ResetEvent] = None
    generated_at: Optional[datetime] = None
    monitor_status: Optional[str] = None
    problem: Optional[str] = None
    last_check_at: Optional[datetime] = None
    recent_events: List[ResetEvent] = field(default_factory=list)

    @property
    def confidence_percent(self) -> Optional[int]:
        return None if self.confidence is None else round(self.confidence * 100)


def _parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_status(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Turns the endpoint's payload into the pieces this module needs.

    Split out from the fetch so the logic is exercisable against a recorded response.
    """
    events: List[ResetEvent] = []
    for raw in payload.get("events") or []:
        if not isinstance(raw, dict):
            continue
        source = raw.get("source") or {}
        scope = raw.get("scope") or {}
        events.append(
            ResetEvent(
                kind=str(raw.get("kind") or ""),
                reset_type=raw.get("resetType"),
                announced_at=_parse_time(raw.get("announcedAt")),
                effective_at=_parse_time(raw.get("effectiveAt")),
                confidence=_float(raw.get("confidence")),
                rationale=raw.get("rationale"),
                text=raw.get("text"),
                url=source.get("url"),
                plans=list(scope.get("plans") or []),
            )
        )

    monitor = payload.get("monitor") or {}
    return {
        "schema_version": payload.get("schemaVersion"),
        "generated_at": _parse_time(payload.get("generatedAt")),
        "last_check_at": _parse_time(payload.get("lastSuccessfulCheckAt")),
        "monitor_status": monitor.get("status"),
        "events": events,
    }


def evaluate(
    parsed: Dict[str, Any],
    now: Optional[datetime] = None,
) -> ResetTodayReport:
    """Decides the verdict for the local day containing `now`.

    "Today" is the user's own day. A reset at 23:40 local time is a reset today even though
    it is already tomorrow in UTC, and computing the day in UTC would tell that user the
    opposite.
    """
    reference = now or datetime.now(timezone.utc)
    local_today = reference.astimezone().date()

    report = ResetTodayReport(
        verdict="unknown",
        generated_at=parsed.get("generated_at"),
        monitor_status=parsed.get("monitor_status"),
        last_check_at=parsed.get("last_check_at"),
        recent_events=list(parsed.get("events") or [])[:5],
    )

    if parsed.get("schema_version") != SUPPORTED_SCHEMA:
        report.problem = "unsupported_schema"
        return report

    if (parsed.get("monitor_status") or "").lower() not in ("ok",):
        # The upstream monitor itself is unsure. Reporting "no" here would be inventing an
        # answer it explicitly declined to give.
        report.problem = "monitor_not_ok"
        return report

    # A completed reset is what matters; a scheduled one has not happened yet.
    completed = [e for e in parsed.get("events") or [] if e.kind == "reset_completed"]

    today = [e for e in completed if e.when and e.when.astimezone().date() == local_today]

    if not today:
        report.verdict = "no"
        # Confidence in a negative is the strongest available statement that no reset was
        # seen, which is the best a viewer can honestly say.
        report.confidence = None
        return report

    # The most confident of today's events is the one to show; when several are recorded the
    # highest-confidence announcement is the one the community treated as authoritative.
    best = max(today, key=lambda e: e.confidence)
    report.verdict = "yes"
    report.confidence = best.confidence
    report.event = best
    return report


def fetch_status(url: str = STATUS_URL, timeout: int = REQUEST_TIMEOUT_SECONDS) -> Dict[str, Any]:
    """Fetches the status payload. Raises on failure; the caller decides what to report."""
    request = urllib.request.Request(
        url,
        headers={
            # Some hosts reject the default agent.
            "User-Agent": "CodexRunway-Viewer/1.0",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def check(
    now: Optional[datetime] = None,
    url: str = STATUS_URL,
    payload: Optional[Dict[str, Any]] = None,
) -> ResetTodayReport:
    """Fetches and evaluates.

    Any failure becomes an "unknown" verdict carrying the reason, never an exception: this
    feeds a display panel, and a panel that cannot render because a network call failed is
    worse than one that says it does not know.
    """
    reference = now or datetime.now(timezone.utc)

    if payload is None:
        try:
            payload = fetch_status(url)
        except urllib.error.HTTPError as error:
            # The server answered and refused, which is a different situation from being
            # unable to reach it: the first is not fixed by retrying or by checking a network
            # connection. Reporting both as "unreachable" sent the user looking at the wrong
            # thing.
            return ResetTodayReport(verdict="unknown", problem=f"http_{error.code}")
        except urllib.error.URLError as error:
            reason = getattr(error, "reason", None)
            if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
                return ResetTodayReport(verdict="unknown", problem="timeout")
            return ResetTodayReport(verdict="unknown", problem="network_unreachable")
        except TimeoutError:
            return ResetTodayReport(verdict="unknown", problem="timeout")
        except OSError:
            return ResetTodayReport(verdict="unknown", problem="network_unreachable")
        except ValueError:
            return ResetTodayReport(verdict="unknown", problem="invalid_response")

    try:
        return evaluate(parse_status(payload), reference)
    except (TypeError, ValueError, AttributeError):
        return ResetTodayReport(verdict="unknown", problem="invalid_response")


if __name__ == "__main__":
    import sys

    result = check()
    print(json.dumps(
        {
            "verdict": result.verdict,
            "confidence_percent": result.confidence_percent,
            "problem": result.problem,
            "monitor": result.monitor_status,
            "generated_at": result.generated_at.isoformat() if result.generated_at else None,
            "event": {
                "kind": result.event.kind,
                "type": result.event.reset_type,
                "when": result.event.when.isoformat() if result.event and result.event.when else None,
                "text": result.event.text,
            } if result.event else None,
        },
        indent=2,
        ensure_ascii=False,
    ))
