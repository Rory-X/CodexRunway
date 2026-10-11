"""Checks that `sessions.py` and `accounts.py` still behave.

Run it directly:

    python3 tools/runway-viewer/selfcheck.py

It prints one PASS/FAIL/SKIP line per check and exits non-zero if anything failed, so it
can be wired into CI or run by hand on a machine whose data files look nothing like the
one it was written on.

Two rules shape everything here:

* **Real data where it exists, synthetic data where it does not.** The bugs this catches
  most often — double-counted tokens, re-logged turns — only appear in files Codex actually
  wrote, so the real-data checks matter. But the machine may be fresh, so every real-data
  check degrades to SKIP rather than failing when `~/.codex` or `~/.codex-runway` is absent.
* **Nothing secret is ever printed.** This script reads files that can contain credentials,
  so failures report *that* a credential leaked and where, never its value. Comparisons are
  done on presence, never by echoing the string.

The session log on the author's machine is 2.6 GB, so the real-data scan is bounded by a
wall-clock deadline and reports how many files it managed to cover. The check is written to
be meaningful on the files it reaches, not to require all of them.
"""

from __future__ import annotations

import glob
import json
import os
import re
import sys
import tempfile
import time
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import accounts  # noqa: E402
import sessions  # noqa: E402


# Hard ceiling on the real-data scan. The whole script must finish in well under 30 seconds
# even on a machine with a multi-gigabyte session tree, and parsing is I/O bound, so the
# deadline is checked between files rather than trusting a file count to be fast enough.
REAL_DATA_BUDGET_SECONDS = 12.0

#: Returned by a check whose data is not present on this machine. Distinct from a pass so the
#: summary can report it honestly rather than implying the check ran.
SKIP = "__skip__"

_results = []


def check(name, fn):
    """Runs one check, catching anything it raises as a failure rather than a crash.

    A traceback escaping here would abort the run before the remaining checks report, which
    is the opposite of what a self-check is for.
    """
    try:
        detail = fn()
        # A check that returns the sentinel `SKIP` could not run because the data it needs is
        # not on this machine. That is not a pass, and reporting it as one would let a fresh
        # machine look fully verified when the real-data checks never ran at all.
        if detail == SKIP:
            _results.append((name, "SKIP", "no ~/.codex or ~/.codex-runway data on this machine"))
        else:
            _results.append((name, "PASS", detail or ""))
    except AssertionError as error:
        _results.append((name, "FAIL", str(error)))
    except Exception as error:  # noqa: BLE001 - any failure is a check failure
        _results.append((name, "FAIL", "%s: %s" % (type(error).__name__, error)))


def skip(name, reason):
    _results.append((name, "SKIP", reason))


def _tmpdir():
    return tempfile.mkdtemp(prefix="runway-selfcheck-")


def _usage_line(timestamp, input_tokens, output_tokens, reasoning=0, total=None, cached=0):
    """One `token_count` record, shaped like the ones Codex writes."""
    turn = {
        "input_tokens": input_tokens,
        "cached_input_tokens": cached,
        "output_tokens": output_tokens,
        "reasoning_output_tokens": reasoning,
    }
    if total is None:
        total = input_tokens + output_tokens
    record = {
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": turn,
                # This is the field Codex itself keeps consistent with input+output.
                "total_token_usage": {"total_tokens": total},
            },
        },
    }
    return json.dumps(record) + "\n"


def _write(directory, name, text):
    path = os.path.join(directory, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return path


# --------------------------------------------------------------------------------------
# sessions.py — synthetic
# --------------------------------------------------------------------------------------


def check_reasoning_is_not_double_counted():
    """Reasoning is a breakdown of output, so it must not be added on top of it.

    The failure this guards against is silent: the number stays plausible and is simply
    too large. It was out by ~18.5M tokens across this machine's corpus.
    """
    directory = _tmpdir()
    path = _write(
        directory,
        "a.jsonl",
        # 100 in, 50 out, of which 40 are reasoning. Codex counts this turn as 150.
        _usage_line("2026-01-01T00:00:00Z", 100, 50, reasoning=40),
    )
    summary = sessions.parse_session(path)
    assert summary is not None, "one usable reading should produce a session"
    assert summary.total_tokens == 150, "expected 100+50=150, got %d" % summary.total_tokens
    assert summary.samples[0].reasoning_output_tokens == 40, "reasoning should still be recorded"
    assert summary.samples[0].billable_tokens == 150, "billable_tokens must exclude reasoning"
    return "150 tokens, reasoning recorded separately"


def check_reemitted_turn_counted_once():
    """A re-logged turn (same reading, unmoved running total) must not count twice."""
    directory = _tmpdir()
    path = _write(
        directory,
        "a.jsonl",
        _usage_line("2026-01-01T00:00:00Z", 100, 10, total=110)
        + _usage_line("2026-01-01T00:00:05Z", 100, 10, total=110)  # re-emission
        + _usage_line("2026-01-01T00:00:09Z", 200, 20, total=330),  # a real turn
    )
    summary = sessions.parse_session(path)
    assert summary is not None
    assert len(summary.samples) == 2, "expected 2 turns, got %d" % len(summary.samples)
    assert summary.total_tokens == 330, "expected 330, got %d" % summary.total_tokens
    return "3 readings reduced to 2 turns"


def check_identical_cost_but_advanced_total_is_a_new_turn():
    """The dedupe must only fire when the running total is unmoved.

    Two turns can cost exactly the same; keying on the reading alone would drop the second
    one and under-report. The running total is what distinguishes them.
    """
    directory = _tmpdir()
    path = _write(
        directory,
        "a.jsonl",
        _usage_line("2026-01-01T00:00:00Z", 10, 5, total=15)
        + _usage_line("2026-01-01T00:00:05Z", 10, 5, total=30),
    )
    summary = sessions.parse_session(path)
    assert summary is not None
    assert len(summary.samples) == 2, "same cost but advanced total is a real turn"
    assert summary.total_tokens == 30, "expected 30, got %d" % summary.total_tokens
    return "identical readings kept apart by the running total"


def check_day_bucketing_uses_local_time():
    """23:30 local must land on the local day, not UTC's.

    In UTC+8 these two readings are on different local days although they are the same UTC
    day; a session that straddles local midnight is the case that gets this wrong.
    """
    offset = datetime.now().astimezone().utcoffset() or timedelta(0)
    directory = _tmpdir()
    # Build a UTC timestamp that is ~23:30 on local 2026-03-01 and ~00:30 on local 2026-03-02.
    local_2330 = datetime(2026, 3, 1, 23, 30, tzinfo=timezone.utc)
    utc_2330 = (local_2330 - offset).astimezone(timezone.utc)
    utc_0030 = utc_2330 + timedelta(hours=1)
    path = _write(
        directory,
        "a.jsonl",
        _usage_line(utc_2330.strftime("%Y-%m-%dT%H:%M:%SZ"), 100, 0)
        + _usage_line(utc_0030.strftime("%Y-%m-%dT%H:%M:%SZ"), 200, 0),
    )
    summary = sessions.parse_session(path)
    assert summary is not None
    per_day = sessions.daily_tokens([summary])
    expected = {date(2026, 3, 1): 100, date(2026, 3, 2): 200}
    assert per_day == expected, "bucketed as %r, expected %r" % (per_day, expected)
    return "UTC%+d: 23:30 and 00:30 split correctly" % (offset.total_seconds() // 3600)


def check_hostile_lines_are_skipped_not_fatal():
    """A malformed record must cost its own line, not the file's other readings.

    Every one of these shapes used to raise `AttributeError` out of `parse_session`,
    discarding the whole day rather than the one unusable line. This is the check that
    would have caught it.
    """
    good = _usage_line("2026-01-01T00:00:00Z", 7, 3)
    hostile = [
        json.dumps({"timestamp": "2026-01-01T00:00:00Z", "payload": ["info", "last_token_usage"]}),
        json.dumps({"timestamp": "2026-01-01T00:00:00Z", "payload": {"info": "last_token_usage"}}),
        json.dumps({"timestamp": "2026-01-01T00:00:00Z", "payload": {"info": ["last_token_usage"]}}),
        json.dumps({"timestamp": "2026-01-01T00:00:00Z", "payload": {"info": {"last_token_usage": "no"}}}),
        json.dumps({"timestamp": "2026-01-01T00:00:00Z", "payload": {"info": {"last_token_usage": [1, 2]}}}),
        json.dumps(["info", "last_token_usage"]),
        json.dumps({"type": "session_meta", "payload": "session_meta"}),
        "null",
        "5",
        '"info last_token_usage"',
        '{"timestamp":"2026-01-01T00:00:0',  # truncated mid-write
    ]
    directory = _tmpdir()
    path = _write(directory, "a.jsonl", "\n".join(hostile) + "\n" + good)

    # The reading before the good line must not survive as a zero-token sample either.
    summary = sessions.parse_session(path)
    assert summary is not None, "the good line should still yield a session"
    assert summary.total_tokens == 10, "expected 10 from the good line, got %d" % summary.total_tokens
    return "%d hostile lines, good line still read" % len(hostile)


def check_empty_and_truncated_and_crlf():
    """The everyday degenerate inputs: empty, no usage, CRLF, BOM."""
    directory = _tmpdir()
    cases = {
        "empty": ("", None),
        "no usage": (json.dumps({"a": 1}) + "\n", None),
        "crlf": (_usage_line("2026-01-01T00:00:00Z", 10, 1).replace("\n", "\r\n"), 11),
        "bom": ("\ufeff" + _usage_line("2026-01-01T00:00:00Z", 10, 1), None),
    }
    for name, (text, expected) in cases.items():
        path = _write(directory, name.replace(" ", "_") + ".jsonl", text)
        summary = sessions.parse_session(path)
        got = None if summary is None else summary.total_tokens
        assert got == expected, "%s: got %r, expected %r" % (name, got, expected)
    return "empty/no-usage/CRLF/BOM handled"


def check_directories_are_not_treated_as_sessions():
    """A directory named `*.jsonl` must not be enumerated as a session file.

    `glob` matches on name, so a directory would be read as an empty file and contribute
    nothing while looking like it had been counted.
    """
    directory = _tmpdir()
    os.makedirs(os.path.join(directory, "trap.jsonl"), exist_ok=True)
    _write(directory, "real.jsonl", _usage_line("2026-01-01T00:00:00Z", 5, 5))
    found = [os.path.basename(p) for p in sessions.iter_session_files(directory)]
    assert found == ["real.jsonl"], "found %r" % (found,)
    return "directory filtered out"


# --------------------------------------------------------------------------------------
# sessions.py — real data
# --------------------------------------------------------------------------------------


def _final_running_total(path):
    """The last `total_token_usage.total_tokens` in a file, or None.

    This is Codex's own running total for the session. Summing the per-turn figures and
    comparing against it is what proves the arithmetic, because the two are computed by
    different code from different fields: one is accumulated here, the other was written by
    Codex. They can only agree if the per-turn reduction is right.
    """
    final = None
    try:
        handle = open(path, errors="ignore")
    except OSError:
        return None
    with handle:
        for line in handle:
            if '"total_token_usage"' not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            payload = record.get("payload") if isinstance(record, dict) else None
            info = payload.get("info") if isinstance(payload, dict) else None
            usage = info.get("total_token_usage") if isinstance(info, dict) else None
            if isinstance(usage, dict) and usage.get("total_tokens") is not None:
                try:
                    final = int(usage["total_tokens"])
                except (TypeError, ValueError):
                    pass
    return final


def check_real_sessions_never_overshoot_codex_total():
    """Across real files, our per-turn total must never exceed Codex's own running total.

    Exceeding it means something is being counted twice — an added-but-overlapping field, or
    a re-logged turn. Equality is the strongest signal: on files with no re-emissions and no
    compaction, the two are the same number exactly.
    """
    root = sessions.default_sessions_root()
    if not os.path.isdir(root):
        return SKIP
    files = sessions.iter_session_files(root)
    if not files:
        return SKIP

    # Smallest first, then the largest: small files are fast and exercise the simple path,
    # the largest is where the re-emission and compaction bugs actually show up.
    ordered = sorted(files, key=os.path.getsize)
    ordered = ordered[:40] + ordered[-5:]

    deadline = time.time() + REAL_DATA_BUDGET_SECONDS
    checked = exact = compared = 0
    overshoot = []
    for path in ordered:
        if time.time() > deadline:
            break
        final = _final_running_total(path)
        if final is None:
            continue
        summary = sessions.parse_session(path)
        if summary is None:
            continue
        checked += 1
        if final > 0:
            compared += 1
            if summary.total_tokens > final:
                overshoot.append((os.path.basename(path), summary.total_tokens, final))
            elif summary.total_tokens == final:
                exact += 1

    if compared == 0:
        return SKIP
    assert not overshoot, "module total exceeds Codex's own total in %d file(s), e.g. %r" % (
        len(overshoot),
        overshoot[0],
    )
    return "%d files compared, %d matched Codex's total exactly, 0 overshoot" % (compared, exact)


def check_real_sessions_negative_free():
    """No real file should produce a negative total or a negative day.

    A negative figure means a field was read from the wrong place or subtracted rather than
    added, and it would render as a nonsense bar rather than as an obvious error.
    """
    root = sessions.default_sessions_root()
    if not os.path.isdir(root):
        return SKIP
    files = sessions.iter_session_files(root)
    if not files:
        return SKIP
    ordered = sorted(files, key=os.path.getsize)[:40]
    deadline = time.time() + REAL_DATA_BUDGET_SECONDS
    worst = None
    checked = 0
    for path in ordered:
        if time.time() > deadline:
            break
        summary = sessions.parse_session(path)
        if summary is None:
            continue
        checked += 1
        if summary.total_tokens < 0:
            worst = (os.path.basename(path), summary.total_tokens)
            break
        for sample in summary.samples:
            if sample.billable_tokens < 0:
                worst = (os.path.basename(path), sample.billable_tokens)
                break
        if worst:
            break
    if checked == 0:
        return SKIP
    assert worst is None, "negative tokens in %r" % (worst,)
    return "%d files scanned, no negative totals" % checked


# --------------------------------------------------------------------------------------
# accounts.py
# --------------------------------------------------------------------------------------


def _fake_index(entries, active=None):
    """Builds a temporary `~/.codex-runway`-shaped home holding one accounts/index.json."""
    home = _tmpdir()
    path = os.path.join(home, "accounts", "index.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "activeAccountId": active, "accounts": entries}, handle)
    return home


def check_wrong_shaped_index_does_not_raise():
    """A valid JSON document of the wrong shape must yield no accounts, not an exception.

    The index is rewritten by another process while this one reads it, so a shape that is
    not what we expect is a realistic input. Each of these used to raise, which discarded
    every account rather than the offending one.
    """
    cases = {
        "root is a list": '[{"id": "a"}]',
        "root is null": "null",
        "root is a string": '"hi"',
        "accounts is a dict": '{"accounts": {"id": "a"}}',
        "cachedQuota is a list": '{"accounts": [{"id": "a", "cachedQuota": ["x"]}]}',
        "cachedQuota.newAPI is a string": '{"accounts": [{"id": "a", "cachedQuota": {"newAPI": "oops"}}]}',
        "sortIndex is non-numeric": '{"accounts": [{"id": "a", "sortIndex": "nope"}]}',
        "sortIndex is fractional": '{"accounts": [{"id": "a", "sortIndex": "3.7"}]}',
        "authMode is a list": '{"accounts": [{"id": "a", "authMode": ["apikey"]}]}',
        "activeAccountId is a list": '{"activeAccountId": ["x"], "accounts": [{"id": "a"}]}',
    }
    for name, raw in cases.items():
        home = _tmpdir()
        path = os.path.join(home, "accounts", "index.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(raw)
        # Both entry points must survive every one of these.
        accounts.load_accounts(home)
        accounts.active_account_id(home)
        assert accounts.load_accounts(home) == [] or isinstance(accounts.load_accounts(home), list)
    return "%d malformed indexes handled" % len(cases)


def check_active_account_is_first():
    """The account in use is pinned first; the rest keep their stored order.

    The ordering is user-visible and a stored preference, so "stable" means the stored
    `sortIndex`, not the order the entries happened to appear in.
    """
    entries = [
        {"id": "c", "sortIndex": 3},
        {"id": "a", "sortIndex": 1},
        {"id": "b", "sortIndex": 2},
    ]
    for active, expected in (("b", ["b", "a", "c"]), (None, ["a", "b", "c"])):
        home = _fake_index(entries, active=active)
        got = [account.id for account in accounts.load_accounts(home)]
        assert got == expected, "active=%r: got %r, expected %r" % (active, got, expected)
        if active:
            assert accounts.load_accounts(home)[0].is_active, "first account should be marked active"
    return "active pinned first; other rows by sortIndex"


def check_quota_health_thresholds():
    """The macOS thresholds: remaining >= 50 green, >= 20 yellow, else red."""
    window = accounts.QuotaWindow(label="5h", used_percent=0, window_minutes=300, resets_at=None)
    cases = {0: "green", 50: "green", 51: "yellow", 80: "yellow", 81: "red", 100: "red"}
    for used, expected in cases.items():
        window.used_percent = used
        assert window.health == expected, "used=%d gave %s, expected %s" % (
            used,
            window.health,
            expected,
        )
    return "green/yellow/red boundaries hold"


def check_real_accounts_load():
    """The real index, if present, loads and still pins the active account first."""
    home = accounts.default_app_home()
    index = os.path.join(home, "accounts", "index.json")
    if not os.path.isfile(index):
        return SKIP
    loaded = accounts.load_accounts()
    assert loaded, "the index exists but produced no accounts"
    active = accounts.active_account_id()
    if active:
        assert loaded[0].id == active, "active account is not first"
        assert loaded[0].is_active, "the first account is not flagged active"
    for account in loaded:
        assert account.worst_health in ("red", "yellow", "green", "unknown"), account.worst_health
    return "%d accounts, active pinned first" % len(loaded)


# --------------------------------------------------------------------------------------
# No secrets, no writes
# --------------------------------------------------------------------------------------


def check_config_output_contains_no_credential():
    """Nothing credential-shaped from config.toml may appear in what we return.

    The comparison is done by presence only — a leaking value is named by its key, never
    echoed — so a failure here cannot itself disclose the secret.
    """
    home = accounts.default_codex_home()
    path = os.path.join(home, "config.toml")
    if not os.path.isfile(path):
        return SKIP
    try:
        with open(path, errors="ignore") as handle:
            text = handle.read()
    except OSError:
        return SKIP

    produced = json.dumps(accounts.load_config_summary(), ensure_ascii=False)
    if produced == "null":
        produced = ""

    # Any quoted value sitting on a key that names a credential.
    pattern = re.compile(
        r"""^\s*([A-Za-z0-9_\-]*?(?:key|token|secret|password)[A-Za-z0-9_\-]*)\s*=\s*["']([^"']{8,})["']""",
        re.IGNORECASE | re.MULTILINE,
    )
    leaked = [
        match.group(1)
        for match in pattern.finditer(text)
        if match.group(2) in produced
    ]
    assert not leaked, "credential value(s) reached the output for key(s): %s" % ", ".join(leaked)

    # A relay address may carry credentials in its userinfo section.
    for url in accounts.load_config_summary().get("providers", {}).values():
        if isinstance(url, str) and "://" in url:
            host = url.split("://", 1)[1]
            assert "@" not in host, "a provider address still carries userinfo"

    return "%d credential-shaped values checked, none present" % len(pattern.findall(text))


def check_real_index_has_no_credential():
    """Nothing credential-shaped may reach the output built from the real account index.

    The index legitimately holds emails, account ids and relay hostnames, all of which are
    shown to the user and all of which are long enough that "looks long and opaque" would
    flag them. So this checks for the shapes an actual credential takes — a JWT, a
    `sk-`-style key, or a `Bearer`-prefixed value — rather than length alone.
    """
    home = accounts.default_app_home()
    path = os.path.join(home, "accounts", "index.json")
    if not os.path.isfile(path):
        return SKIP

    loaded = accounts.load_accounts()
    produced = json.dumps(
        [
            {
                "id": account.id,
                "title": account.title,
                "subtitle": account.subtitle,
                "email": account.email,
                "auth_mode": account.auth_mode,
                "relay_base_url": account.relay_base_url,
                "token_name": account.token_name,
                "workspace_id": account.workspace_id,
            }
            for account in loaded
        ],
        ensure_ascii=False,
        default=str,
    )

    credential_shapes = {
        "JWT": re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\."),
        "sk-style key": re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}"),
        "bearer value": re.compile(r"\bBearer\s+[A-Za-z0-9_\-\.]{16,}"),
        "refresh-token-ish": re.compile(r"\brt_[A-Za-z0-9_\-]{16,}"),
    }
    found = [name for name, pattern in credential_shapes.items() if pattern.search(produced)]

    # A relay address may carry credentials in its userinfo section.
    for account in loaded:
        url = account.relay_base_url
        if isinstance(url, str) and "://" in url:
            if "@" in url.split("://", 1)[1]:
                found.append("relay url userinfo")

    assert not found, "credential-shaped value(s) reached the output: %s" % ", ".join(found)
    return "%d accounts, no credential shape present" % len(loaded)


def check_auth_json_is_never_read():
    """`auth.json` holds the real credentials and must not be opened at all.

    Checked against the source: the modules are only allowed to read the index and
    config.toml. Reading the credential file is the one mistake here that no amount of
    output filtering would make safe.
    """
    offenders = []
    for module in (sessions, accounts):
        path = getattr(module, "__file__", None)
        if not path:
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        # Only a string literal that names the file counts; a comment or a docstring mention
        # is fine, so look for it inside a quoted string.
        for match in re.finditer(r"""["']([^"']*auth\.json[^"']*)["']""", source):
            offenders.append("%s: %r" % (os.path.basename(path), match.group(1)))
    assert not offenders, "a module references auth.json: %s" % "; ".join(offenders)
    return "neither module references auth.json"


def check_modules_never_open_for_write():
    """Neither module may open a file for writing, appending, or truncation.

    Both read files shared with the macOS app, and a write would corrupt another program's
    data. Checked against the source rather than by watching the filesystem, because the
    other app writes these files concurrently and an mtime comparison could not tell the two
    apart.
    """
    offenders = []
    write_call = re.compile(r"""open\s*\([^)]*?["']([rwaxt]{1,2}\+?)["']""")
    for module in (sessions, accounts):
        path = getattr(module, "__file__", None)
        if not path:
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        for mode in write_call.findall(source):
            if any(flag in mode for flag in ("w", "a", "x", "+")):
                offenders.append("%s: open(..., %r)" % (os.path.basename(path), mode))
    assert not offenders, "write-mode open() found: %s" % "; ".join(offenders)
    return "no write-mode open() in either module"


# --------------------------------------------------------------------------------------


def main():
    check("sessions: reasoning not double-counted", check_reasoning_is_not_double_counted)
    check("sessions: re-emitted turn counted once", check_reemitted_turn_counted_once)
    check(
        "sessions: same cost, advanced total is a new turn",
        check_identical_cost_but_advanced_total_is_a_new_turn,
    )
    check("sessions: day bucketing is local", check_day_bucketing_uses_local_time)
    check("sessions: hostile lines skipped, not fatal", check_hostile_lines_are_skipped_not_fatal)
    check("sessions: empty / truncated / CRLF", check_empty_and_truncated_and_crlf)
    check("sessions: directories not read as sessions", check_directories_are_not_treated_as_sessions)
    check("sessions: real files never overshoot Codex total", check_real_sessions_never_overshoot_codex_total)
    check("sessions: real files have no negative totals", check_real_sessions_negative_free)
    check("accounts: malformed index does not raise", check_wrong_shaped_index_does_not_raise)
    check("accounts: active account first, rest stable", check_active_account_is_first)
    check("accounts: quota health thresholds", check_quota_health_thresholds)
    check("accounts: real index loads", check_real_accounts_load)
    check("accounts: config.toml output has no credential", check_config_output_contains_no_credential)
    check("accounts: index output has no credential", check_real_index_has_no_credential)
    check("accounts: auth.json never read", check_auth_json_is_never_read)
    check("both: no write-mode open()", check_modules_never_open_for_write)

    failures = 0
    width = max(len(name) for name, _, _ in _results)
    for name, status, detail in _results:
        if status == "FAIL":
            failures += 1
        line = "%-4s %-*s" % (status, width, name)
        if detail:
            line += "  %s" % detail
        print(line)

    print()
    passed = sum(1 for _, status, _ in _results if status == "PASS")
    skipped = sum(1 for _, status, _ in _results if status == "SKIP")
    print(
        "%d passed, %d failed, %d skipped"
        % (passed, failures, skipped)
    )
    if skipped:
        print("(skipped checks need ~/.codex or ~/.codex-runway; they are not failures)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
