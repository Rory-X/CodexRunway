"""Renders the collected data as one self-contained HTML file.

No CDN and no external assets: the file has to open from a local path with no network,
which is also what keeps a local usage viewer from quietly becoming a page that phones
home. Everything — styles, script, data — is inlined.

The layout follows the macOS app's panel: a header, a subscription-expiry notice, then one
card per account with its quota windows. Colours and thresholds are the same ones, so the
two do not disagree about what "low quota" looks like.
"""

from __future__ import annotations

import html
import json
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from accounts import Account, load_accounts, load_config_summary
from reset_today import ResetTodayReport, check as check_reset
from sessions import iter_session_files, load_sessions, summarise

# Health colour per threshold, matching QuotaHealth in the macOS build.
HEALTH_COLOURS = {
    "green": "#32d74b",
    "yellow": "#ffd60a",
    "red": "#ff453a",
    "unknown": "#8e8e93",
}


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


def _quota_bar(window, now: datetime) -> str:
    colour = HEALTH_COLOURS.get(window.health, HEALTH_COLOURS["unknown"])
    reset = _fmt_reset(window.resets_at, now)
    reset_html = f'<div class="quota-note">{_esc(reset)}</div>' if reset else ""
    return f"""
            <div class="quota">
              <div class="quota-head">
                <span class="quota-label">{_esc(window.label)}</span>
                <span class="quota-value" style="color:{colour}">{window.remaining_percent}% 剩余</span>
              </div>
              <div class="bar"><div class="bar-fill" style="width:{window.remaining_percent}%;background:{colour}"></div></div>
              {reset_html}
            </div>"""


def _account_card(account: Account, now: datetime, is_active: bool) -> str:
    badges: List[str] = []
    if is_active:
        badges.append('<span class="badge badge-active">当前</span>')
    # The stored plan for a relay account is literally "api", so adding an API badge as well
    # produced "API API".
    plan_is_api = (account.plan or "").lower() == "api"
    if account.plan and not (account.is_api_key and plan_is_api):
        badges.append(f'<span class="badge badge-plan">{_esc(account.plan.title())}</span>')
    if account.is_api_key and not plan_is_api:
        badges.append('<span class="badge">API</span>')
    if account.requires_reauth:
        badges.append('<span class="badge badge-warn">需重新授权</span>')

    identity: List[str] = []
    if account.user_id:
        identity.append(f'<div class="meta"><span>用户 ID</span><code>{_esc(account.user_id)}</code></div>')
    if account.workspace_id or account.workspace_name:
        ws = account.workspace_name or account.workspace_id
        if account.workspace_name and account.workspace_id:
            ws = f"{account.workspace_name} · {account.workspace_id}"
        identity.append(f'<div class="meta"><span>工作区</span><code>{_esc(ws)}</code></div>')
    if account.email and account.email != account.title:
        identity.append(f'<div class="meta"><span>邮箱</span><code>{_esc(account.email)}</code></div>')
    if account.relay_base_url:
        identity.append(f'<div class="meta"><span>中转</span><code>{_esc(account.relay_base_url)}</code></div>')

    expiry = _fmt_expiry(account.subscription_expires_at, now)
    expiry_html = f'<div class="expiry">{_esc(expiry)}</div>' if expiry else ""

    bars = "".join(_quota_bar(w, now) for w in account.windows)

    if account.is_api_key:
        # A relay account has a prepaid balance rather than a rate-limit window. Showing a
        # percentage bar here would be inventing a quota it does not have.
        if account.remaining_usd is not None:
            used = account.used_usd or 0.0
            total = account.remaining_usd + used
            fraction = 0 if total <= 0 else max(0.0, min(100.0, account.remaining_usd / total * 100))
            colour = HEALTH_COLOURS["green"] if fraction >= 50 else (
                HEALTH_COLOURS["yellow"] if fraction >= 20 else HEALTH_COLOURS["red"]
            )
            requests = f" · {account.request_count:,} 次请求" if account.request_count else ""
            bars = f"""
            <div class="quota">
              <div class="quota-head">
                <span class="quota-label">余额</span>
                <span class="quota-value" style="color:{colour}">${account.remaining_usd:,.2f}</span>
              </div>
              <div class="bar"><div class="bar-fill" style="width:{fraction:.1f}%;background:{colour}"></div></div>
              <div class="quota-note">已用 ${used:,.2f}{requests}</div>
            </div>"""
        else:
            bars = '<div class="no-quota">尚无余额数据</div>'

    elif not bars:
        bars = '<div class="no-quota">尚无配额数据</div>' 

    return f"""
      <article class="card{' active' if is_active else ''}">
        <header class="card-head">
          <div class="card-title">{_esc(account.title)}</div>
          <div class="badges">{''.join(badges)}</div>
        </header>
        {expiry_html}
        <div class="identity">{''.join(identity)}</div>
        {bars}
      </article>"""


def _reset_card(report: Optional[ResetTodayReport], now: datetime) -> str:
    """The "did it reset today?" card.

    Three states, drawn differently on purpose. "Unknown" must not look like "no": a user
    deciding whether to keep working needs to distinguish "no reset happened" from "this
    could not be checked", and collapsing the two would answer a question the data did not.
    """
    if report is None:
        report = ResetTodayReport(verdict="unknown", problem="not_checked")

    event = report.event

    if report.verdict == "yes":
        accent, headline = "#32d74b", "是"
        scope = "全局重置" if event and event.is_global else "重置"

        parts = [f"监测到今天已有完成的 <strong>{scope}</strong>"]
        if report.confidence_percent is not None:
            parts.append(f"置信度约 <strong>{report.confidence_percent}%</strong>")
        if event and event.when:
            # The moment is stated outright rather than reusing the countdown wording, which
            # produced "the reset time was resetting soon".
            parts.append("发生于 " + event.when.astimezone().strftime("%m-%d %H:%M"))
        body = "，".join(parts) + "。"

    elif report.verdict == "no":
        accent, headline = "#8e8e93", "否"
        body = "今天还没有监测到完成的额度重置。"

    else:
        accent, headline = "#ff9f0a", "未知"
        body = UNKNOWN_RESET_REASONS.get(
            report.problem or "", "暂时无法确认今天是否重置。"
        )

    quote = (
        f'<div class="reset-quote">{_esc(event.text)}</div>'
        if event and event.text
        else ""
    )
    checked = (
        f'<div class="reset-meta">最近检查 '
        f'{report.last_check_at.astimezone().strftime("%H:%M:%S")}</div>'
        if report.last_check_at
        else ""
    )
    badge = (
        f'<div class="reset-badge" style="background:{accent}22;color:{accent}">'
        f'置信度 {report.confidence_percent}%</div>'
        if report.confidence_percent is not None
        else ""
    )

    return f"""
      <div class="card reset-card" style="border-color:{accent}33">
        <div class="reset-head">
          <div>
            <div class="reset-label">今日是否重置</div>
            <div class="reset-verdict" style="color:{accent}">{headline}</div>
          </div>
          {badge}
        </div>
        <div class="reset-body">{body}</div>
        {quote}
        {checked}
      </div>"""


#: Why the verdict is unknown, in the user's terms. Mapped from the code carried on
#: ResetTodayReport so the wording lives with the view rather than the fetch logic.
UNKNOWN_RESET_REASONS = {
    "not_checked": "还没有检查状态服务。",
    "http_403": "状态服务拒绝了请求，无法确认今天是否重置。",
    "http_404": "状态服务地址已变更，无法确认今天是否重置。",
    "timeout": "状态服务响应超时，无法确认今天是否重置。",
    "network_unreachable": "无法连接状态服务，可能是网络问题。",
    "invalid_response": "状态服务返回了无法解析的内容。",
    "unsupported_schema": "状态服务使用了更新的格式，本视图暂不支持。",
    "monitor_not_ok": "上游监测当前状态异常，暂时无法判断。",
}


def _sparkline(daily: Dict[str, int], days: int, now: datetime) -> str:
    """A small bar chart of the last N days.

    Day keys come from the parser as local dates, and the window is built the same way, so a
    gap in the data shows as a gap rather than shifting every bar.
    """
    today = now.astimezone().date()
    window = [today - timedelta(days=offset) for offset in range(days - 1, -1, -1)]
    values = [daily.get(day.isoformat(), 0) for day in window]
    peak = max(values) if values else 0

    bars = []
    for day, value in zip(window, values):
        height = 0 if peak == 0 else max(2, round(value / peak * 100))
        title = f"{day.isoformat()}：{value:,} tokens"
        bars.append(
            f'<div class="spark-bar" style="height:{height}%" title="{_esc(title)}"></div>'
        )

    return f'<div class="spark">{"".join(bars)}</div>'


def build_html(
    accounts: Optional[List[Account]] = None,
    usage: Optional[Dict[str, Any]] = None,
    config: Optional[Dict[str, Any]] = None,
    reset: Optional[ResetTodayReport] = None,
    now: Optional[datetime] = None,
) -> str:
    """Builds the page.

    Every input is a parameter so the renderer can be exercised without touching the real
    data directories.
    """
    reference = now or datetime.now(timezone.utc)
    accounts = accounts if accounts is not None else load_accounts()
    usage = usage if usage is not None else summarise(
        load_sessions(iter_session_files()), reference
    )
    config = config if config is not None else load_config_summary()

    active_id = next((a.id for a in accounts if getattr(a, "is_active", False)), None)

    cards = "".join(
        _account_card(a, reference, is_active=(a.id == active_id))
        for a in accounts
    )
    if not cards:
        cards = '<p class="empty">还没有账号。添加后会显示在这里。</p>'

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
    --panel: #1e1e22; --raised: rgba(255,255,255,0.065); --sunken: rgba(255,255,255,0.045);
    --hairline: rgba(255,255,255,0.10); --text: #f2f2f5;
    --text-2: rgba(235,235,240,0.60); --text-3: rgba(235,235,240,0.40);
    --accent: #0a84ff;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 28px 20px 48px; background: var(--panel); color: var(--text);
    font: 13px/1.5 -apple-system, "SF Pro Text", "PingFang SC", sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  .wrap {{ max-width: 720px; margin: 0 auto; }}
  h1 {{ font-size: 17px; margin: 0 0 4px; display: flex; align-items: center; gap: 8px; }}
  h1::before {{
    content: ""; width: 10px; height: 10px; border-radius: 50%; background: var(--accent);
  }}
  .sub {{ color: var(--text-3); font-size: 11.5px; margin-bottom: 22px; }}
  h2 {{
    font-size: 11px; text-transform: uppercase; letter-spacing: .06em;
    color: var(--text-3); margin: 26px 0 10px; font-weight: 600;
  }}

  .stats {{ display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }}
  .stat {{
    background: var(--raised); border: 1px solid var(--hairline);
    border-radius: 10px; padding: 12px 14px;
  }}
  .stat-label {{ font-size: 10.5px; color: var(--text-3); margin-bottom: 5px; }}
  .stat-value {{ font-size: 19px; font-weight: 600; letter-spacing: -.01em; }}

  .card {{
    background: var(--raised); border: 1px solid var(--hairline); border-radius: 10px;
    padding: 13px 15px; margin-bottom: 9px;
  }}
  .card.active {{ border-color: rgba(10,132,255,.45); background: rgba(10,132,255,.07); }}
  .card-head {{ display: flex; justify-content: space-between; align-items: center; gap: 10px; flex-wrap: wrap; }}
  .card-title {{ font-size: 14px; font-weight: 600; word-break: break-all; }}
  .badges {{ display: flex; gap: 5px; flex-wrap: wrap; }}
  .badge {{
    font-size: 10px; font-weight: 600; padding: 2px 7px; border-radius: 5px;
    background: rgba(255,255,255,.10); color: var(--text-2);
  }}
  .badge-active {{ background: rgba(50,215,75,.18); color: #32d74b; }}
  .badge-plan {{ background: rgba(76,159,255,.18); color: #4c9fff; }}
  .badge-warn {{ background: rgba(255,159,10,.18); color: #ff9f0a; }}

  .expiry {{
    display: inline-block; margin-top: 8px; padding: 3px 8px; border-radius: 5px;
    font-size: 11px; background: rgba(255,159,10,.15); color: #ff9f0a;
  }}
  .identity {{ margin-top: 8px; display: grid; gap: 3px; }}
  .meta {{ display: flex; gap: 8px; font-size: 11px; align-items: baseline; }}
  .meta > span {{ color: var(--text-3); flex: none; min-width: 44px; }}
  .meta code {{
    color: var(--text-2); font-size: 11px; font-family: ui-monospace, "SF Mono", monospace;
    word-break: break-all;
  }}

  .quota {{ margin-top: 10px; }}
  .quota-head {{ display: flex; justify-content: space-between; font-size: 11px; margin-bottom: 4px; }}
  .quota-label {{ color: var(--text-2); }}
  .quota-value {{ font-weight: 600; }}
  .bar {{ height: 5px; border-radius: 3px; background: var(--sunken); overflow: hidden; }}
  .bar-fill {{ height: 100%; border-radius: 3px; }}
  .no-quota {{ margin-top: 8px; font-size: 11px; color: var(--text-3); }}
  .quota-note {{ margin-top: 3px; font-size: 10.5px; color: var(--text-3); }}

  .spark {{ display: flex; align-items: flex-end; gap: 2px; height: 90px; margin-top: 6px; }}
  .spark-bar {{ flex: 1; background: var(--accent); border-radius: 2px; min-height: 2px; opacity: .85; }}
  .spark-bar:hover {{ opacity: 1; }}

  .reset-card {{ padding: 15px 16px; }}
  .reset-head {{ display: flex; justify-content: space-between; align-items: flex-start; }}
  .reset-label {{ font-size: 11px; color: var(--text-3); margin-bottom: 4px; }}
  .reset-verdict {{ font-size: 26px; font-weight: 700; line-height: 1.1; }}
  .reset-badge {{ font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 6px; }}
  .reset-body {{ margin-top: 10px; font-size: 12px; color: var(--text-2); line-height: 1.65; }}
  .reset-body strong {{ color: var(--text); }}
  .reset-quote {{
    margin-top: 10px; padding: 8px 10px; border-left: 2px solid var(--hairline);
    background: var(--sunken); border-radius: 0 5px 5px 0;
    font-size: 11.5px; color: var(--text-2);
  }}
  .reset-meta {{ margin-top: 8px; font-size: 10.5px; color: var(--text-3); }}

  .empty {{ color: var(--text-3); font-size: 12px; }}
  footer {{ margin-top: 32px; color: var(--text-3); font-size: 11px; }}
</style>
</head>
<body>
<div class="wrap">
  <h1>CodexRunway</h1>
  <div class="sub">
    读取 {usage.get('session_count', 0):,} 个会话 · {usage.get('day_count', 0)} 天记录
    · 数据截至 {_esc(usage.get('last_day') or '—')}
  </div>

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

  <h2>近 30 天用量</h2>
  {_sparkline(daily, 30, reference)}

  <h2>账号（{len(accounts)}）</h2>
  {cards}

  <h2>当前配置</h2>
  <div class="card">
    <div class="meta"><span>provider</span><code>{_esc(provider)}</code></div>
    {f'<div class="meta"><span>地址</span><code>{_esc(provider_address)}</code></div>' if provider_address else ''}
    <div class="meta"><span>文件</span><code>{_esc(config.get('path', ''))}</code></div>
  </div>

  <footer>
    只读视图，不会修改任何文件。生成于 {reference.astimezone().strftime('%Y-%m-%d %H:%M:%S')}。
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
