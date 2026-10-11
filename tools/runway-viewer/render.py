"""Renders the collected data as one self-contained HTML file.

No CDN and no external assets: the file has to open from a local path with no network,
which is also what keeps a local usage viewer from quietly becoming a page that phones
home. Everything — styles, script, data — is inlined.

The layout is built around one observation: the accounts are not equally interesting.
Exactly one of them is in use, and at most a few need attention; the rest are a list. A page
that gives all twelve the same six-line card buries the two that matter in three thousand
pixels of identical rows, so the active account gets a full card and the others get a line.

Colours and thresholds are the macOS app's own, so the two do not disagree about what "low
quota" looks like.
"""

from __future__ import annotations

import html
import json
import os
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from accounts import Account, load_accounts, load_config_summary
from quota_estimate import AccountEstimate, load_estimates as load_quota_estimates
import quota_estimate
from reset_today import ResetTodayReport, check as check_reset
from sessions import iter_session_files, load_sessions, summarise

# Health colour per threshold, matching QuotaHealth in the macOS build.
HEALTH_COLOURS = {
    "green": "#32d74b",
    "yellow": "#ffd60a",
    "red": "#ff453a",
    "unknown": "#8e8e93",
}


# ---------------------------------------------------------------------------- formatting


def _fmt_tokens(value: int) -> str:
    """Compact token counts: 1.2M rather than 1234567."""
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}K"
    return str(value)


def _fmt_reset(when: Optional[datetime], now: datetime) -> Optional[str]:
    """A short "resets in …" string, or None when the time is unknown or past."""
    if when is None:
        return None
    remaining = when - now
    if remaining <= timedelta(0):
        return "即将重置"
    days = remaining.days
    hours = remaining.seconds // 3600
    minutes = (remaining.seconds % 3600) // 60
    if days > 0:
        return f"{days} 天 {hours} 小时后重置"
    if hours > 0:
        return f"{hours} 小时 {minutes} 分后重置"
    return f"{minutes} 分钟后重置"


def _fmt_expiry(when: Optional[datetime], now: datetime) -> Optional[str]:
    """Expiry text, shown only inside a fortnight.

    A date a month out is information; showing it on every card is how a real warning stops
    being noticed.
    """
    if when is None:
        return None
    remaining = when - now
    if remaining <= timedelta(0):
        return "订阅已到期"
    if remaining > timedelta(days=14):
        return None
    days = remaining.days
    hours = remaining.seconds // 3600
    return f"{days} 天 {hours} 小时后到期" if days > 0 else f"{max(1, hours)} 小时后到期"


def _esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


# ---------------------------------------------------------------------------- quota


def _quota_rows(windows, now: datetime, compact: bool = False) -> str:
    """One line per window: label, remaining, a bar, and when it resets.

    The bar is omitted at full remaining. Eight bars all reading 100% carry no information and
    push the one bar that does matter off the screen; the number alone says it in less space.
    """
    rows = []
    for window in windows:
        colour = HEALTH_COLOURS.get(window.health, HEALTH_COLOURS["unknown"])
        reset = _fmt_reset(window.resets_at, now)
        remaining = window.remaining_percent

        if remaining >= 100 and not compact:
            bar = ""
        else:
            bar = (
                f'<div class="bar"><div class="bar-fill" '
                f'style="width:{remaining}%;background:{colour}"></div></div>'
            )

        note = f'<span class="q-note">{_esc(reset)}</span>' if reset else ""
        rows.append(
            f'<div class="q-row">'
            f'<span class="q-label">{_esc(window.label)}</span>'
            f'<span class="q-value" style="color:{colour}">{remaining}%</span>'
            f"</div>{bar}{note}"
        )

    return f'<div class="quota">{"".join(rows)}</div>'


def _balance_block(account: Account) -> str:
    """A relay account's prepaid balance.

    Drawn separately from the quota windows, because a relay has a balance rather than a
    rate-limit window and one rendered as the other would be a plausible-looking bar that
    means nothing.
    """
    if account.remaining_usd is None:
        return '<div class="q-note dim">尚无余额数据</div>'

    used = account.used_usd or 0.0
    total = account.remaining_usd + used
    fraction = 0 if total <= 0 else max(0.0, min(100.0, account.remaining_usd / total * 100))
    colour = (
        HEALTH_COLOURS["green"] if fraction >= 50
        else HEALTH_COLOURS["yellow"] if fraction >= 20
        else HEALTH_COLOURS["red"]
    )
    requests = f" · {account.request_count:,} 次请求" if account.request_count else ""

    return (
        f'<div class="quota"><div class="q-row">'
        f'<span class="q-label">余额</span>'
        f'<span class="q-value" style="color:{colour}">${account.remaining_usd:,.2f}</span>'
        f"</div>"
        f'<div class="bar"><div class="bar-fill" style="width:{fraction:.1f}%;'
        f'background:{colour}"></div></div>'
        f'<span class="q-note">已用 ${used:,.2f}{requests}</span></div>'
    )


def _estimate_line(estimate: Optional[AccountEstimate], account: Account) -> str:
    """The allowance estimate, labelled for how much it can be trusted.

    The figure is an extrapolation, and a badly-conditioned one: at a low sample point,
    dividing by a whole-number percentage amplifies its rounding. One account's completed
    cycle gave 70M credits where its 2%-sampled cycle gave 9.8 billion. Showing the number
    without saying which of those it is would be presenting arithmetic as measurement.
    """
    if estimate is None or estimate.best is None:
        if account.is_api_key:
            return ""
        reason = (
            "本周期尚无用量" if (account.windows and account.windows[0].used_percent == 0)
            else "缺少采样"
        )
        return f'<span class="est-none">{_esc(reason)}，暂无法推算</span>'

    best = estimate.best
    figure = quota_estimate.format_credits(best.estimated_credits)
    cycle = best.cycle_start.isoformat() if best.cycle_start else "—"

    if best.is_complete:
        note, tone = f"整周期 {cycle}", "est-solid"
    elif best.is_reliable:
        note, tone = f"采样 {best.used_percent}% · {cycle}", "est-soft"
    else:
        note, tone = f"仅采样 {best.used_percent}% · 偏差可能很大", "est-weak"

    return (
        f'<span class="est {tone}">推算 <strong>{figure}</strong>'
        f'<span class="est-note">{_esc(note)}</span></span>'
    )


# ---------------------------------------------------------------------------- accounts


def _active_card(account: Account, now: datetime, estimate: Optional[AccountEstimate]) -> str:
    """The account in use, given the room the others do not get."""
    badges = ['<span class="badge badge-active">当前</span>']
    if account.plan and not (account.is_api_key and (account.plan or "").lower() == "api"):
        badges.append(f'<span class="badge badge-plan">{_esc(account.plan.title())}</span>')
    if account.is_api_key:
        badges.append('<span class="badge">中转</span>')

    expiry = _fmt_expiry(account.subscription_expires_at, now)
    expiry_html = f'<div class="expiry">{_esc(expiry)}</div>' if expiry else ""

    meta = []
    if account.email and account.email != account.title:
        meta.append(f'<span>{_esc(account.email)}</span>')
    if account.workspace_name:
        meta.append(f'<span>{_esc(account.workspace_name)}</span>')

    body = _balance_block(account) if account.is_api_key else _quota_rows(account.windows, now)
    ident = f'<div class="card-meta">{" · ".join(meta)}</div>' if meta else ""

    return f"""
    <article class="card card-active">
      <div class="card-head">
        <div class="card-title">{_esc(account.title)}</div>
        <div class="badges">{''.join(badges)}</div>
      </div>
      {ident}
      {expiry_html}
      {body}
      {_estimate_line(estimate, account)}
    </article>"""


def _compact_row(account: Account, now: datetime, estimate: Optional[AccountEstimate]) -> str:
    """One line for an account that is neither in use nor in trouble.

    Two things only: what it is, and how much is left. Everything else — user id, workspace,
    the full reset schedule — is the same on every row and is what made the page unreadable.
    """
    plan = (account.plan or "").title() or ("中转" if account.is_api_key else "")
    plan_html = f'<span class="badge badge-plan">{_esc(plan)}</span>' if plan else ""

    if account.is_api_key:
        if account.remaining_usd is not None:
            tone = "green" if account.remaining_usd > 0 else "red"
            right = (
                f'<span class="row-value" style="color:{HEALTH_COLOURS[tone]}">'
                f"${account.remaining_usd:,.2f}</span>"
            )
        else:
            right = '<span class="row-value dim">—</span>'
    elif account.windows:
        # The worst window decides the colour: a row exists to be scanned, and averaging two
        # windows into one number hides the one that is about to run out.
        worst = min(account.windows, key=lambda w: w.remaining_percent)
        colour = HEALTH_COLOURS.get(worst.health, HEALTH_COLOURS["unknown"])
        reset = _fmt_reset(worst.resets_at, now) or ""
        right = (
            f'<span class="row-value" style="color:{colour}">{worst.remaining_percent}%</span>'
            f'<span class="row-sub">{_esc(reset)}</span>'
        )
    else:
        right = '<span class="row-value dim">—</span>'

    est = estimate.best if estimate else None
    est_html = ""
    if est is not None and est.estimated_credits is not None:
        tone = "est-solid" if est.is_complete else ("est-soft" if est.is_reliable else "est-weak")
        est_html = (
            f'<span class="row-est {tone}">{quota_estimate.format_credits(est.estimated_credits)}</span>'
        )

    return f"""
      <div class="row">
        <div class="row-main">
          <span class="row-title">{_esc(account.title)}</span>
          {plan_html}
          {est_html}
        </div>
        <div class="row-right">{right}</div>
      </div>"""


def _attention_card(account: Account) -> str:
    """An account that needs the user to do something. Kept out of the list on purpose."""
    return f"""
    <article class="card card-warn">
      <div class="card-head">
        <div class="card-title">{_esc(account.title)}</div>
        <div class="badges"><span class="badge badge-warn">需重新授权</span></div>
      </div>
      <div class="card-meta">登录授权已失效，重新登录后恢复。</div>
    </article>"""


def _accounts_section(
    accounts: List[Account],
    estimates: Dict[str, AccountEstimate],
    now: datetime,
) -> str:
    active = [a for a in accounts if a.is_active]
    attention = [a for a in accounts if a.needs_attention and not a.is_active]
    subscription = [
        a for a in accounts
        if not a.is_active and not a.needs_attention and not a.is_api_key
    ]
    relay = [
        a for a in accounts
        if not a.is_active and not a.needs_attention and a.is_api_key
    ]

    parts: List[str] = []

    for account in active:
        parts.append(_active_card(account, now, estimates.get(account.id)))

    for account in attention:
        parts.append(_attention_card(account))

    if subscription:
        rows = "".join(_compact_row(a, now, estimates.get(a.id)) for a in subscription)
        parts.append(
            f'<h3 class="group">订阅账号 <span class="group-count">{len(subscription)}</span></h3>'
            f'<div class="list">{rows}</div>'
        )

    if relay:
        rows = "".join(_compact_row(a, now, estimates.get(a.id)) for a in relay)
        parts.append(
            f'<h3 class="group">中转账号 <span class="group-count">{len(relay)}</span></h3>'
            f'<div class="list">{rows}</div>'
        )

    if not parts:
        parts.append('<p class="empty">还没有账号。添加后会显示在这里。</p>')

    return "".join(parts)


# ---------------------------------------------------------------------------- usage


def _heatmap(daily: Dict[str, int], now: datetime, weeks: int = 19) -> str:
    """A calendar heatmap of daily token use, columns being weeks.

    Intensity is a square-root scale rather than linear. Usage here spans three orders of
    magnitude — a quiet day against a heavy one — and on a linear scale every ordinary day
    would be an indistinguishable speck next to the single largest one, which is exactly the
    pattern a reader is looking for.

    Days with no data are drawn as empty cells rather than omitted, so the shape of the
    calendar stays readable and a gap is visibly a gap.
    """
    today = now.astimezone().date()
    start = today - timedelta(days=today.weekday() + (weeks - 1) * 7)
    peak = max(daily.values()) if daily else 0

    columns: List[str] = []
    for week in range(weeks):
        cells: List[str] = []
        for weekday in range(7):
            day = start + timedelta(days=week * 7 + weekday)
            if day > today:
                cells.append('<div class="hm-cell hm-void"></div>')
                continue
            value = daily.get(day.isoformat(), 0)
            level = 0 if peak == 0 or value == 0 else max(1, round((value / peak) ** 0.5 * 4))
            title = f"{day.isoformat()}：{value:,} tokens"
            cells.append(f'<div class="hm-cell hm-{level}" title="{_esc(title)}"></div>')
        columns.append(f'<div class="hm-col">{"".join(cells)}</div>')

    months: List[str] = []
    seen = None
    for week in range(weeks):
        day = start + timedelta(days=week * 7)
        if day.month != seen:
            seen = day.month
            months.append(f'<span class="hm-month">{day.month} 月</span>')
        else:
            months.append('<span class="hm-month"></span>')

    return (
        '<div class="hm-wrap"><div class="hm-grid">'
        + "".join(columns)
        + '</div><div class="hm-months">'
        + "".join(months)
        + '</div><div class="hm-legend"><span>少</span>'
        + "".join(f'<div class="hm-cell hm-{level}"></div>' for level in range(5))
        + "<span>多</span></div></div>"
    )


def _weekly_bars(daily: Dict[str, int]) -> str:
    weeks: Dict[date, int] = {}
    for key, value in daily.items():
        try:
            day = date.fromisoformat(key)
        except ValueError:
            continue
        monday = day - timedelta(days=day.weekday())
        weeks[monday] = weeks.get(monday, 0) + value

    ordered = sorted(weeks.items())[-16:]
    if not ordered:
        return '<p class="empty">没有周数据。</p>'

    peak = max(v for _, v in ordered)
    return "".join(
        f'<div class="wk-row"><span class="wk-label">{monday.isoformat()[5:]}</span>'
        f'<div class="wk-track"><div class="wk-fill" style="width:'
        f'{(0 if peak == 0 else value / peak * 100):.1f}%"></div></div>'
        f'<span class="wk-value">{_fmt_tokens(value)}</span></div>'
        for monday, value in ordered
    )


def _cumulative(daily: Dict[str, int]) -> str:
    ordered = sorted((date.fromisoformat(k), v) for k, v in daily.items() if v >= 0)
    if len(ordered) < 2:
        return '<p class="empty">数据不足，无法绘制累计曲线。</p>'

    running = 0
    points = []
    for day, value in ordered:
        running += value
        points.append((day, running))

    peak = points[-1][1] or 1
    coords = " ".join(
        f"{index / (len(points) - 1) * 100:.2f},{100 - total / peak * 96:.2f}"
        for index, (_, total) in enumerate(points)
    )
    return (
        '<svg class="cum" viewBox="0 0 100 100" preserveAspectRatio="none">'
        f'<polyline points="{coords}" fill="none" stroke="var(--accent)" '
        'stroke-width="0.8" vector-effect="non-scaling-stroke" /></svg>'
        f'<div class="cum-axis"><span>{points[0][0].isoformat()}</span>'
        f"<span>{_fmt_tokens(peak)} tokens</span>"
        f"<span>{points[-1][0].isoformat()}</span></div>"
    )


def _usage_views(daily: Dict[str, int], now: datetime) -> str:
    """Daily heatmap, weekly bars and a cumulative line, as three switchable panels.

    Switching happens in the browser with no script: each view is rendered up front and a
    radio group chooses which is visible. That keeps the file a single static document, which
    is the whole point of it being a file.
    """
    return f"""
    <div class="views">
      <input type="radio" name="usage-view" id="view-day" checked>
      <input type="radio" name="usage-view" id="view-week">
      <input type="radio" name="usage-view" id="view-cum">
      <div class="view-tabs">
        <label for="view-day">每日</label>
        <label for="view-week">每周</label>
        <label for="view-cum">累计</label>
      </div>
      <div class="view view-day">{_heatmap(daily, now)}</div>
      <div class="view view-week">{_weekly_bars(daily)}</div>
      <div class="view view-cum">{_cumulative(daily)}</div>
    </div>"""


# ---------------------------------------------------------------------------- reset card


UNKNOWN_RESET_REASONS = {
    "not_checked": "还没有检查状态服务。",
    "http_403": "状态服务拒绝了请求。",
    "http_404": "状态服务地址已变更。",
    "timeout": "状态服务响应超时。",
    "network_unreachable": "无法连接状态服务。",
    "invalid_response": "状态服务返回了无法解析的内容。",
    "unsupported_schema": "状态服务使用了更新的格式。",
    "monitor_not_ok": "上游监测当前状态异常。",
}


def _reset_card(report: Optional[ResetTodayReport], now: datetime) -> str:
    """The "did it reset today?" answer, as one compact strip.

    Three states, drawn differently on purpose. "Unknown" must not look like "no": a user
    deciding whether to keep working needs to distinguish "no reset happened" from "this could
    not be checked", and collapsing the two would answer a question the data did not.
    """
    if report is None:
        report = ResetTodayReport(verdict="unknown", problem="not_checked")

    event = report.event

    if report.verdict == "yes":
        accent, verdict = "#32d74b", "是"
        scope = "全局重置" if event and event.is_global else "重置"
        parts = [f"今天已有完成的 <strong>{scope}</strong>"]
        if report.confidence_percent is not None:
            parts.append(f"置信度 <strong>{report.confidence_percent}%</strong>")
        if event and event.when:
            parts.append("发生于 " + event.when.astimezone().strftime("%H:%M"))
        detail = "，".join(parts) + "。"
    elif report.verdict == "no":
        accent, verdict = "#8e8e93", "否"
        detail = "今天还没有监测到完成的额度重置。"
    else:
        accent, verdict = "#ff9f0a", "未知"
        detail = UNKNOWN_RESET_REASONS.get(report.problem or "", "暂时无法确认。")
        if detail.endswith("。"):
            detail = detail[:-1] + "，无法确认今天是否重置。"

    quote = (
        f'<div class="reset-quote">{_esc(event.text)}</div>'
        if event and event.text else ""
    )
    checked = (
        f'<span class="reset-when">检查于 '
        f'{report.last_check_at.astimezone().strftime("%H:%M:%S")}</span>'
        if report.last_check_at else ""
    )

    return f"""
    <div class="reset" style="--reset-accent:{accent}">
      <div class="reset-verdict">{verdict}</div>
      <div class="reset-body">
        <div class="reset-detail">{detail}</div>
        {quote}
        {checked}
      </div>
    </div>"""


# ---------------------------------------------------------------------------- page


def build_html(
    accounts: Optional[List[Account]] = None,
    usage: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    reset: Optional[ResetTodayReport] = None,
    estimates: Optional[Dict[str, AccountEstimate]] = None,
    now: Optional[datetime] = None,
) -> str:
    """Builds the page.

    Every input is a parameter so the renderer can be exercised without touching the real data
    directories.
    """
    reference = now or datetime.now(timezone.utc)
    accounts = accounts if accounts is not None else load_accounts()
    usage = usage if usage is not None else summarise(
        load_sessions(iter_session_files()), reference
    )
    config = config if config is not None else load_config_summary()
    if estimates is None:
        estimates = load_quota_estimates()

    if reset is None:
        reset = check_reset(reference)

    daily = {k: int(v) for k, v in (usage.get("daily") or {}).items()}
    provider = config.get("selected") or "(未设置)"
    provider_address = (config.get("providers") or {}).get(config.get("selected") or "", "")

    return f"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CodexRunway</title>
<style>
  :root {{
    --panel: #17171a; --raised: rgba(255,255,255,0.055);
    --sunken: rgba(255,255,255,0.035); --hover: rgba(255,255,255,0.075);
    --hairline: rgba(255,255,255,0.085); --text: #f4f4f7;
    --text-2: rgba(238,238,244,0.58); --text-3: rgba(238,238,244,0.34);
    --accent: #0a84ff;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 32px 20px 56px; background: var(--panel); color: var(--text);
    font: 13px/1.55 -apple-system, "SF Pro Text", "PingFang SC", sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .wrap {{ max-width: 680px; margin: 0 auto; }}

  header {{ display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 22px; }}
  h1 {{ font-size: 15px; margin: 0; display: flex; align-items: center; gap: 8px; font-weight: 600; }}
  h1::before {{ content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); }}
  .source {{ font-size: 11px; color: var(--text-3); }}

  h2 {{
    font-size: 11px; text-transform: uppercase; letter-spacing: .07em;
    color: var(--text-3); margin: 30px 0 10px; font-weight: 600;
  }}
  h2:first-of-type {{ margin-top: 0; }}

  /* Stats: one row, no boxes around each — a hairline grid reads as data, cards read as clutter. */
  .stats {{ display: flex; border: 1px solid var(--hairline); border-radius: 10px; overflow: hidden; }}
  .stat {{ flex: 1; padding: 13px 15px; background: var(--raised); }}
  .stat + .stat {{ border-left: 1px solid var(--hairline); }}
  .stat-label {{ font-size: 10.5px; color: var(--text-3); margin-bottom: 3px; }}
  .stat-value {{ font-size: 20px; font-weight: 600; letter-spacing: -.02em; }}

  /* Reset strip */
  .reset {{
    display: flex; gap: 14px; align-items: flex-start; padding: 13px 15px;
    border: 1px solid var(--hairline); border-left: 2px solid var(--reset-accent);
    border-radius: 8px; background: var(--raised);
  }}
  .reset-verdict {{ font-size: 24px; font-weight: 700; color: var(--reset-accent); line-height: 1.15; flex: none; }}
  .reset-body {{ min-width: 0; }}
  .reset-detail {{ font-size: 12.5px; color: var(--text-2); }}
  .reset-detail strong {{ color: var(--text); }}
  .reset-quote {{
    margin-top: 7px; padding: 6px 9px; border-left: 2px solid var(--hairline);
    background: var(--sunken); border-radius: 0 4px 4px 0;
    font-size: 11.5px; color: var(--text-3); font-style: italic;
  }}
  .reset-when {{ display: block; margin-top: 6px; font-size: 10.5px; color: var(--text-3); }}

  /* Usage views */
  .views > input[type="radio"] {{ position: absolute; opacity: 0; pointer-events: none; }}
  .view-tabs {{ display: flex; gap: 3px; margin-bottom: 13px; }}
  .view-tabs label {{
    font-size: 11px; padding: 4px 11px; border-radius: 5px; cursor: pointer;
    color: var(--text-2); background: var(--sunken); user-select: none;
  }}
  .view-tabs label:hover {{ background: var(--hover); }}
  #view-day:checked ~ .view-tabs label[for="view-day"],
  #view-week:checked ~ .view-tabs label[for="view-week"],
  #view-cum:checked ~ .view-tabs label[for="view-cum"] {{ background: var(--accent); color: #fff; font-weight: 600; }}
  .view {{ display: none; }}
  #view-day:checked ~ .view-day,
  #view-week:checked ~ .view-week,
  #view-cum:checked ~ .view-cum {{ display: block; }}

  /* Heatmap fills the width: the cells grow with the container rather than clustering left. */
  .hm-grid {{ display: flex; gap: 4px; align-items: stretch; }}
  .hm-col {{ display: flex; flex-direction: column; gap: 4px; flex: 1; }}
  .hm-cell {{ width: 100%; aspect-ratio: 1; border-radius: 3px; }}
  .hm-void {{ background: transparent; }}
  .hm-0 {{ background: var(--sunken); }}
  .hm-1 {{ background: rgba(10,132,255,.28); }}
  .hm-2 {{ background: rgba(10,132,255,.52); }}
  .hm-3 {{ background: rgba(10,132,255,.76); }}
  .hm-4 {{ background: var(--accent); }}
  .hm-months {{ display: flex; gap: 4px; margin-top: 7px; }}
  .hm-month {{ flex: 1; font-size: 10px; color: var(--text-3); white-space: nowrap; overflow: visible; }}
  .hm-legend {{ display: flex; align-items: center; gap: 5px; margin-top: 12px; font-size: 10px; color: var(--text-3); }}
  .hm-legend .hm-cell {{ width: 11px; aspect-ratio: 1; flex: none; }}

  .wk-row {{ display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }}
  .wk-label {{ font-size: 10.5px; color: var(--text-3); width: 40px; flex: none; font-variant-numeric: tabular-nums; }}
  .wk-track {{ flex: 1; height: 8px; background: var(--sunken); border-radius: 4px; overflow: hidden; }}
  .wk-fill {{ height: 100%; background: var(--accent); border-radius: 4px; }}
  .wk-value {{ font-size: 10.5px; color: var(--text-2); width: 52px; text-align: right; flex: none; font-variant-numeric: tabular-nums; }}

  .cum {{ width: 100%; height: 130px; display: block; }}
  .cum-axis {{ display: flex; justify-content: space-between; font-size: 10px; color: var(--text-3); margin-top: 5px; }}

  /* Accounts */
  .card {{
    border: 1px solid var(--hairline); border-radius: 10px;
    padding: 14px 16px; margin-bottom: 10px; background: var(--raised);
  }}
  .card-active {{ border-color: rgba(10,132,255,.42); background: rgba(10,132,255,.055); }}
  .card-warn {{ border-color: rgba(255,159,10,.35); background: rgba(255,159,10,.05); }}
  .card-head {{ display: flex; justify-content: space-between; align-items: center; gap: 10px; flex-wrap: wrap; }}
  .card-title {{ font-size: 14.5px; font-weight: 600; word-break: break-all; }}
  .card-meta {{ font-size: 11px; color: var(--text-3); margin-top: 3px; word-break: break-all; }}
  .badges {{ display: flex; gap: 5px; flex-wrap: wrap; flex: none; }}
  .badge {{ font-size: 10px; font-weight: 600; padding: 2px 7px; border-radius: 4px; background: rgba(255,255,255,.09); color: var(--text-2); }}
  .badge-active {{ background: rgba(50,215,75,.16); color: #32d74b; }}
  .badge-plan {{ background: rgba(76,159,255,.16); color: #4c9fff; }}
  .badge-warn {{ background: rgba(255,159,10,.16); color: #ff9f0a; }}

  .expiry {{ display: inline-block; margin-top: 8px; padding: 3px 8px; border-radius: 4px; font-size: 11px; background: rgba(255,159,10,.13); color: #ff9f0a; }}

  .quota {{ margin-top: 11px; }}
  .q-row {{ display: flex; justify-content: space-between; align-items: baseline; font-size: 11.5px; }}
  .q-label {{ color: var(--text-2); }}
  .q-value {{ font-weight: 600; font-variant-numeric: tabular-nums; }}
  .q-note {{ display: block; font-size: 10.5px; color: var(--text-3); margin-top: 3px; }}
  .q-note.dim {{ margin-top: 8px; }}
  .bar {{ height: 5px; border-radius: 3px; background: var(--sunken); overflow: hidden; margin-top: 4px; }}
  .bar-fill {{ height: 100%; border-radius: 3px; }}

  .est {{ display: inline-flex; align-items: baseline; gap: 5px; margin-top: 10px; padding-top: 9px; border-top: 1px solid var(--hairline); width: 100%; font-size: 11px; color: var(--text-3); }}
  .est strong {{ font-size: 12.5px; font-weight: 600; color: var(--text-2); }}
  .est-note {{ font-size: 10.5px; color: var(--text-3); }}
  .est-weak strong, .est-weak .est-note {{ color: #ff9f0a; }}
  .est-none {{ display: inline-block; margin-top: 10px; padding-top: 9px; border-top: 1px solid var(--hairline); width: 100%; font-size: 10.5px; color: var(--text-3); font-style: italic; }}

  .group {{ font-size: 10.5px; color: var(--text-3); margin: 20px 0 7px; font-weight: 600; text-transform: none; letter-spacing: 0; }}
  .group-count {{ color: var(--text-3); font-weight: 400; }}
  .list {{ border: 1px solid var(--hairline); border-radius: 9px; overflow: hidden; background: var(--raised); }}
  .row {{ display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 13px; }}
  .row + .row {{ border-top: 1px solid var(--hairline); }}
  .row-main {{ display: flex; align-items: center; gap: 8px; min-width: 0; }}
  .row-title {{ font-size: 12.5px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
  .row-est {{ font-size: 10.5px; color: var(--text-3); font-variant-numeric: tabular-nums; flex: none; }}
  .row-est.est-weak {{ color: #ff9f0a; }}
  .row-right {{ text-align: right; flex: none; }}
  .row-value {{ font-size: 12.5px; font-weight: 600; font-variant-numeric: tabular-nums; }}
  .row-value.dim {{ color: var(--text-3); font-weight: 400; }}
  .row-sub {{ display: block; font-size: 10px; color: var(--text-3); margin-top: 1px; }}

  .config {{ border: 1px solid var(--hairline); border-radius: 9px; background: var(--raised); padding: 12px 14px; }}
  .cfg-row {{ display: flex; gap: 10px; font-size: 11.5px; padding: 3px 0; }}
  .cfg-key {{ color: var(--text-3); width: 68px; flex: none; }}
  .cfg-val {{ color: var(--text-2); word-break: break-all; font-family: ui-monospace, "SF Mono", monospace; font-size: 11px; }}

  .empty {{ color: var(--text-3); font-size: 12px; }}
  footer {{ margin-top: 36px; color: var(--text-3); font-size: 10.5px; line-height: 1.7; }}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>CodexRunway</h1>
    <span class="source">{usage.get('session_count', 0):,} 个会话 · {usage.get('day_count', 0)} 天记录</span>
  </header>

  <div class="stats">
    <div class="stat"><div class="stat-label">今日 Token</div>
      <div class="stat-value">{_fmt_tokens(int(usage.get('today_tokens') or 0))}</div></div>
    <div class="stat"><div class="stat-label">近 7 天</div>
      <div class="stat-value">{_fmt_tokens(int(usage.get('week_tokens') or 0))}</div></div>
    <div class="stat"><div class="stat-label">累计</div>
      <div class="stat-value">{_fmt_tokens(int(usage.get('total_tokens') or 0))}</div></div>
  </div>

  <h2>今日是否重置</h2>
  {_reset_card(reset, reference)}

  <h2>Token 用量</h2>
  {_usage_views(daily, reference)}

  <h2>账号（{len(accounts)}）</h2>
  {_accounts_section(accounts, estimates, reference)}

  <h2>当前配置</h2>
  <div class="config">
    <div class="cfg-row"><span class="cfg-key">provider</span><span class="cfg-val">{_esc(provider)}</span></div>
    {f'<div class="cfg-row"><span class="cfg-key">地址</span><span class="cfg-val">{_esc(provider_address)}</span></div>' if provider_address else ''}
    <div class="cfg-row"><span class="cfg-key">文件</span><span class="cfg-val">{_esc(config.get('path', ''))}</span></div>
  </div>

  <footer>
    只读视图，不会修改任何文件。<br>
    生成于 {reference.astimezone().strftime('%Y-%m-%d %H:%M:%S')}。
  </footer>
</div>
</body>
</html>
"""


def write_report(destination: Optional[str] = None, now: Optional[datetime] = None) -> str:
    """Builds the page and writes it, returning the path."""
    target = destination or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "runway-report.html"
    )
    reference = now or datetime.now(timezone.utc)
    # A failure to reach the status service must not stop the report from being written: the
    # local data is still worth showing, and the card explains what could not be checked.
    document = build_html(reset=check_reset(reference), now=reference)
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(document)
    return target


if __name__ == "__main__":
    path = write_report()
    print(path)
    print(f"{os.path.getsize(path):,} bytes")
