"""Reads CodexRunway's own data files.

Only the standard library. The files are JSON on disk and shared with the macOS build,
so nothing here rewrites them — this is a read-only viewer.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def default_app_home() -> str:
    return os.path.join(os.path.expanduser("~"), ".codex-runway")


def default_codex_home() -> str:
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


@dataclass
class QuotaWindow:
    """One rate-limit window, as the index cached it."""

    label: str
    used_percent: int
    window_minutes: Optional[int]
    resets_at: Optional[datetime]

    @property
    def remaining_percent(self) -> int:
        return max(0, 100 - min(100, max(0, self.used_percent)))

    @property
    def health(self) -> str:
        """Matches the macOS thresholds: remaining >= 50 green, >= 20 yellow, else red."""
        remaining = self.remaining_percent
        if remaining >= 50:
            return "green"
        if remaining >= 20:
            return "yellow"
        return "red"


@dataclass
class Account:
    id: str
    title: str
    subtitle: Optional[str] = None
    plan: Optional[str] = None
    email: Optional[str] = None
    user_id: Optional[str] = None
    workspace_id: Optional[str] = None
    workspace_name: Optional[str] = None
    auth_mode: Optional[str] = None
    requires_reauth: bool = False
    subscription_expires_at: Optional[datetime] = None
    quota_updated_at: Optional[datetime] = None
    windows: List[QuotaWindow] = field(default_factory=list)
    relay_base_url: Optional[str] = None

    #: A New API relay's balance, when the index cached one. Deliberately separate from the
    #: quota windows: a relay has a prepaid balance, not a rate-limit window, and drawing one
    #: as the other would show a plausible-looking bar that means nothing.
    remaining_usd: Optional[float] = None
    used_usd: Optional[float] = None
    request_count: Optional[int] = None
    token_name: Optional[str] = None

    #: The user's stored position, used only to order the list.
    sort_index: int = 0

    #: Whether Codex is currently using this account, taken from the index's
    #: `activeAccountId`. A plain field rather than a property because the index is the only
    #: place that knows, so there is nothing to derive it from.
    is_active: bool = False

    @property
    def is_api_key(self) -> bool:
        # Guarded like `_is_api_key`: `auth_mode` is copied straight off disk, so it is only a
        # string when the index said so.
        return isinstance(self.auth_mode, str) and self.auth_mode.lower() == "apikey"

    @property
    def worst_health(self) -> str:
        order = {"red": 0, "yellow": 1, "green": 2}
        if not self.windows:
            return "unknown"
        return min((w.health for w in self.windows), key=lambda h: order.get(h, 3))


def _is_api_key(entry: Dict[str, Any]) -> bool:
    """Whether this entry authenticates with a relay API key rather than a subscription.

    The value is compared as a string only when it actually is one: a malformed index can
    hold a list or number here, and `.lower()` on those raises out of `load_accounts`,
    leaving the viewer with no accounts at all instead of one unusual row.
    """
    mode = entry.get("authMode")
    return isinstance(mode, str) and mode.lower() == "apikey"


def _optional_float(value: Any) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _optional_int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_dict(value: Any) -> Dict[str, Any]:
    """Narrows a decoded JSON value to a dict, for the same reason `_optional_int` exists.

    Every branch below reaches into the index through `.get`. The file is written by another
    process while this one reads it, so a shape that is not a dict is a realistic input, and
    an `AttributeError` from it would discard every account rather than the one bad field.
    """
    return value if isinstance(value, dict) else {}


def _parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _window_label(minutes: Optional[int]) -> str:
    """Names a window by its length, not by position.

    The API is not contractually ordered, so reading "the first window is the five-hour one"
    once reported a weekly window as five hours.
    """
    if minutes == 300:
        return "5 小时"
    if minutes == 10080:
        return "每周"
    if minutes is None:
        return "配额"
    return f"{minutes} 分钟"


def _windows_from_quota(quota: Dict[str, Any]) -> List[QuotaWindow]:
    windows: List[QuotaWindow] = []

    def add(used: Any, minutes: Any, resets: Any) -> None:
        if used is None:
            return
        try:
            used_int = int(used)
        except (TypeError, ValueError):
            return
        try:
            minutes_int = int(minutes) if minutes is not None else None
        except (TypeError, ValueError):
            minutes_int = None
        windows.append(
            QuotaWindow(
                label=_window_label(minutes_int),
                used_percent=used_int,
                window_minutes=minutes_int,
                resets_at=_parse_time(resets),
            )
        )

    primary = (quota.get("primaryUsedPercent"), quota.get("primaryWindowMinutes"), quota.get("primaryResetsAt"))
    secondary = (quota.get("secondaryUsedPercent"), quota.get("secondaryWindowMinutes"), quota.get("secondaryResetsAt"))

    # Shorter window first: it resets sooner and is what a user checks first.
    a_minutes = primary[1] or 0
    b_minutes = secondary[1] or 0
    if a_minutes and b_minutes and a_minutes > b_minutes:
        add(*secondary)
        add(*primary)
    else:
        add(*primary)
        add(*secondary)

    return windows


def load_accounts(app_home: Optional[str] = None) -> List[Account]:
    """Reads the account index.

    Returns an empty list when the index is missing or unreadable: a viewer that refuses to
    open because one file is malformed is less useful than one that shows what it can.
    """
    home = app_home or default_app_home()
    index_path = os.path.join(home, "accounts", "index.json")
    if not os.path.isfile(index_path):
        return []

    try:
        with open(index_path, errors="ignore") as handle:
            root = json.load(handle)
    except (OSError, ValueError):
        return []

    # A valid JSON document of the wrong shape (a bare list, `null`, a string) is not an
    # index. Treated as empty rather than raising, matching the missing-index case above: a
    # viewer that opens and says "no accounts" is more useful than one that will not open.
    if not isinstance(root, dict):
        return []

    active_id = root.get("activeAccountId")
    accounts: List[Account] = []
    for entry in root.get("accounts") or []:
        if not isinstance(entry, dict):
            continue
        account_id = entry.get("id")
        if not account_id:
            continue

        quota = _as_dict(entry.get("cachedQuota"))
        newapi = _as_dict(quota.get("newAPI"))
        email = entry.get("email")
        accounts.append(
            Account(
                id=account_id,
                title=entry.get("alias") or entry.get("displayName") or email or account_id,
                subtitle=entry.get("username"),
                plan=entry.get("planType") or quota.get("plan"),
                email=email,
                user_id=entry.get("userId"),
                # A ChatGPT workspace id exists only for a subscription account. For a relay
                # account this field holds the relay row's own id, and labelling it "workspace"
                # told the user something that was not true.
                workspace_id=None if _is_api_key(entry) else entry.get("accountId"),
                workspace_name=entry.get("workspaceName"),
                auth_mode=entry.get("authMode"),
                requires_reauth=bool(entry.get("requiresReauth")),
                subscription_expires_at=_parse_time(entry.get("subscriptionExpiresAt")),
                quota_updated_at=_parse_time(quota.get("updatedAt")),
                windows=[] if _is_api_key(entry) else _windows_from_quota(quota),
                relay_base_url=entry.get("relayBaseURL"),
                # `or 0` used to run before `int()`, so `int("nope")` still raised for a
                # non-numeric string. `_optional_int` absorbs that and the entry sorts to 0.
                sort_index=_optional_int(entry.get("sortIndex")) or 0,
                remaining_usd=_optional_float(newapi.get("remainingUSD")),
                used_usd=_optional_float(newapi.get("keyUsedUSD")),
                request_count=_optional_int(newapi.get("requestCount")),
                token_name=newapi.get("tokenName"),
                is_active=(entry.get("id") == active_id),
            )
        )

    # The active account is pinned first, then the user's own sortIndex. Reproduces the macOS
    # ordering, which is a user-visible contract: the account in use is always at the top. The
    # stored index is used as-is rather than being rewritten from the enumeration, so reading
    # the file cannot silently change the order a user chose.
    accounts.sort(key=lambda a: (not a.is_active, a.sort_index))
    return accounts


def load_config_summary(codex_home: Optional[str] = None) -> Dict[str, Any]:
    """The selected provider and its address, read from config.toml.

    Parsed by hand rather than with a TOML library, because the standard library has none in
    Python 3.9 and this needs exactly two values. Anything not understood is ignored.
    """
    home = codex_home or default_codex_home()
    path = os.path.join(home, "config.toml")
    result: Dict[str, Any] = {"path": path, "exists": os.path.isfile(path), "selected": None, "providers": {}}
    if not result["exists"]:
        return result

    try:
        with open(path, errors="ignore") as handle:
            text = handle.read()
    except OSError:
        return result

    section: Optional[str] = None
    for raw in text.splitlines():
        line = _strip_comment(raw).strip()
        if not line:
            continue
        if line.startswith("["):
            section = line.strip("[]").strip()
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        if section is None and key == "model_provider":
            result["selected"] = value or None
        elif section and section.startswith("model_providers.") and key == "base_url":
            name = section.split(".", 1)[1]
            value = _strip_userinfo(value)
            # A multi-line value that was not understood leaves an empty string behind.
            # Reporting "" as an address is worse than reporting nothing: it looks like a
            # real reading and would be shown in place of the provider's actual URL.
            if value:
                result["providers"][name] = value

    return result


def _strip_comment(line: str) -> str:
    """Drops a trailing comment, ignoring a `#` inside a quoted value.

    A model provider's address can legitimately contain `#` — a fragment in a URL, for
    instance — and a naive `split("#")` would truncate it, silently turning a valid address
    into a shorter one that still looks plausible.
    """
    in_single = in_double = escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and in_double:
            escaped = True
        elif char == '"' and not in_single:
            in_double = not in_double
        elif char == "'" and not in_double:
            in_single = not in_single
        elif char == "#" and not in_single and not in_double:
            return line[:index]
    return line


def _strip_userinfo(url: str) -> str:
    """Removes `user:password@` from a provider URL before it can reach the output.

    This module promises that no credential reaches what it returns, and it reads a file
    that other tools also write. A relay or proxy address is exactly the kind of value that
    gets a key embedded in it (`https://user:sk-...@relay.example/v1`), so the userinfo
    section is dropped rather than displayed. The host and path are unaffected, which is
    what the panel actually shows.
    """
    scheme, sep, rest = url.partition("://")
    if not sep or "@" not in rest:
        return url
    host = rest.rsplit("@", 1)[1]
    return f"{scheme}://{host}"


def active_account_id(app_home: Optional[str] = None) -> Optional[str]:
    home = app_home or default_app_home()
    index_path = os.path.join(home, "accounts", "index.json")
    try:
        with open(index_path, errors="ignore") as handle:
            root = json.load(handle)
    except (OSError, ValueError):
        return None
    # Only a string is an id. Returning a list or a number here would compare unequal to
    # every account id, silently reporting "no active account" instead of the stored one.
    if not isinstance(root, dict):
        return None
    active = root.get("activeAccountId")
    return active if isinstance(active, str) and active else None
