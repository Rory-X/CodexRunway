"""Reads the subscription allowance estimate.

The macOS app samples, once per billing cycle, how many credits a plan appears to grant:
it records how many credits have been used and what percentage of the plan that
represents, then extrapolates. The result is an estimate, and this module keeps it
labelled as one — a figure derived from two rounded inputs must not be shown with the
confidence of a measured value.

Only reading happens here. The file is shared with the macOS build, so nothing is
rewritten and nothing is normalised on disk.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Any, Dict, List, Optional


def default_history_path(app_home: Optional[str] = None) -> str:
    home = app_home or os.path.join(os.path.expanduser("~"), ".codex-runway")
    return os.path.join(home, "quota-estimate-history.json")


@dataclass
class EstimateSample:
    """One recorded estimate for one billing cycle."""

    cycle_start: Optional[date]
    estimated_credits: Optional[float]
    used_credits: Optional[float]
    used_percent: Optional[int]
    recorded_at: Optional[datetime]

    @property
    def is_reliable(self) -> bool:
        """Whether this estimate was derived from enough of the cycle to be worth showing.

        The figure is an extrapolation: credits used, divided by the fraction of the cycle
        they represent. At a low fraction that division amplifies whatever rounding went
        into the percentage. A cycle sampled at 2% produced 9.8 billion credits where the
        same account's completed cycle produced 70 million — a factor of 140, from the same
        arithmetic on a smaller sample.

        The threshold is 25%: below it the extrapolation is dominated by the rounding of
        `usedPercent`, which is a whole number, so a reading of 2% means the true figure is
        anywhere from roughly 1.5% to 2.5% — a swing of a third in the divisor.
        """
        return self.used_percent is not None and self.used_percent >= 25

    @property
    def is_complete(self) -> bool:
        """Whether the cycle reached 100%, which is when the estimate is most reliable.

        A cycle sampled at 34% has been extrapolated from a third of the data, so its figure
        is far softer than one that ran to completion.
        """
        return self.used_percent is not None and self.used_percent >= 100


@dataclass
class AccountEstimate:
    account_id: str
    samples: List[EstimateSample]

    @property
    def latest(self) -> Optional[EstimateSample]:
        if not self.samples:
            return None
        return max(self.samples, key=lambda s: s.recorded_at or datetime.min.replace(tzinfo=timezone.utc))

    @property
    def reliable(self) -> List[EstimateSample]:
        return [s for s in self.samples if s.is_reliable]

    @property
    def best(self) -> Optional[EstimateSample]:
        """The sample to headline: the most complete cycle, then the most recent.

        Preferring a completed cycle over a newer partial one is deliberate. A cycle that
        ran to 100% gives a figure derived from the whole allowance, while a fresh cycle
        sampled early can be off by an order of magnitude — and it would be the one shown
        first if recency alone decided.
        """
        if not self.samples:
            return None

        # Preferred in order: a completed cycle, then any reliable sample, then anything at
        # all. Falling back rather than hiding the row keeps an account from looking as
        # though it has no data when it merely has none worth trusting.
        for pool in (
            [s for s in self.samples if s.is_complete],
            self.reliable,
            self.samples,
        ):
            if pool:
                return max(
                    pool,
                    key=lambda s: s.recorded_at or datetime.min.replace(tzinfo=timezone.utc),
                )

        return None

    @property
    def best_is_trustworthy(self) -> bool:
        """Whether the headline figure was derived from most of a cycle."""
        best = self.best
        return best is not None and best.is_reliable


def _parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _parse_date(value: Any) -> Optional[date]:
    if not isinstance(value, str) or len(value) < 10:
        return None
    try:
        return date.fromisoformat(value[:10])
    except ValueError:
        return None


def _float(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _int(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _history_key(entry: Dict[str, Any]) -> Optional[str]:
    """The key this account's history is filed under.

    Two shapes occur, and both must be produced: an API-key account is filed as
    `id:<accountId>`, while a subscription account is filed as
    `oauth:user:<userId>|account:<accountId>`. A viewer that only looked for one spelling
    would silently show no estimate for half the accounts.
    """
    account_id = entry.get("id")
    if not account_id:
        return None

    if (entry.get("authMode") or "").lower() == "apikey":
        return f"id:{account_id}"

    user_id = entry.get("userId")
    workspace = entry.get("accountId")
    if user_id and workspace:
        return f"oauth:user:{user_id}|account:{workspace}"
    return f"id:{account_id}"


def load_estimates(
    app_home: Optional[str] = None,
    index: Optional[Dict[str, Any]] = None,
) -> Dict[str, AccountEstimate]:
    """Estimates keyed by the account id they belong to.

    Keyed by account id rather than by the history's own key, so a caller holding an
    account does not have to reconstruct the storage format to look one up.
    """
    path = default_history_path(app_home)
    if not os.path.isfile(path):
        return {}

    try:
        with open(path, errors="ignore") as handle:
            root = json.load(handle)
    except (OSError, ValueError):
        return {}

    if not isinstance(root, dict):
        return {}
    history = root.get("accounts")
    if not isinstance(history, dict):
        return {}

    # The index supplies the id the history is filed under; without it there is no way to
    # map a key back to an account, so an absent index means no estimates rather than a
    # guess.
    if index is None:
        index_path = os.path.join(app_home or os.path.join(os.path.expanduser("~"), ".codex-runway"), "accounts", "index.json")
        try:
            with open(index_path, errors="ignore") as handle:
                index = json.load(handle)
        except (OSError, ValueError):
            return {}

    if not isinstance(index, dict):
        return {}

    by_key: Dict[str, str] = {}
    for entry in index.get("accounts") or []:
        if not isinstance(entry, dict):
            continue
        key = _history_key(entry)
        if key and entry.get("id"):
            by_key[key] = entry["id"]

    result: Dict[str, AccountEstimate] = {}
    for key, raw_samples in history.items():
        account_id = by_key.get(key)
        if account_id is None or not isinstance(raw_samples, list):
            continue

        samples: List[EstimateSample] = []
        for raw in raw_samples:
            if not isinstance(raw, dict):
                continue
            samples.append(
                EstimateSample(
                    cycle_start=_parse_date(raw.get("cycleStartDate")),
                    estimated_credits=_float(raw.get("estimatedCredits")),
                    used_credits=_float(raw.get("usedCredits")),
                    used_percent=_int(raw.get("usedPercent")),
                    recorded_at=_parse_time(raw.get("recordedAt")),
                )
            )

        if samples:
            result[account_id] = AccountEstimate(account_id=account_id, samples=samples)

    return result


def format_credits(value: Optional[float]) -> str:
    """A compact credit figure.

    Credits are not currency, so they are not shown with a currency symbol; the macOS app
    converts them to USD only where it has a rate to convert with.
    """
    if value is None:
        return "—"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}K"
    return f"{value:.0f}"


if __name__ == "__main__":
    import json as _json

    estimates = load_estimates()
    print(_json.dumps(
        {
            account_id: {
                "samples": len(est.samples),
                "best_credits": est.best.estimated_credits if est.best else None,
                "best_used_percent": est.best.used_percent if est.best else None,
                "latest_credits": est.latest.estimated_credits if est.latest else None,
            }
            for account_id, est in estimates.items()
        },
        indent=2,
    ))
