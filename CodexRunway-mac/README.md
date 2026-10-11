English · [简体中文](./README_ZH.md) · [繁體中文](./README_ZH_HANT.md) · [한국어](./README_KO.md) · [日本語](./README_JA.md) · [Русский](./README_RU.md) · [Français](./README_FR.md)

<p align="center">
  <img src="Resources/AppIcon.png" alt="CodexRunway logo" width="128" height="128">
</p>

# CodexRunway

How much longer can your Codex keep running?

CodexRunway is a native macOS menu bar app for checking Codex quota. It also provides Codex reset-today status, reset credits, API-equivalent cost, and local sessions, along with multi-account management for Codex.

## Highlights

- Check remaining Codex quota from the menu bar.
- View 5-hour, weekly, and additional quota windows.
- See whether Codex rate limits have reset today (data from [www.codexrunway.com](https://www.codexrunway.com)), with a link to the related public post.
- Toggle the “reset today?” section in settings and configure its own refresh interval (on by default, every 5 minutes).
- Manage multiple Codex accounts: browser sign-in, import local `auth.json`, paste token/JSON (including `/auth/session`), import files, or add an API key.
- Switch accounts safely after confirmation by atomically writing `~/.codex/auth.json`, with an optional Codex restart so CLI / IDE stay in sync.
- Show the current account, subscription tier, and expiration.
- Estimate this week’s Codex allowance from official weekly usage percent and daily Credits, compare it with previous weeks to spot quota cuts, and toggle the module in settings (on by default).
- View reset credit count, status, and expiration time.
- View API-equivalent cost and token usage for today, the current cycle, the previous cycle, this month, or a custom range; the default range is configurable in settings.
- Show a year-to-date token usage chart under quota on the main panel (heatmap / line / bar; daily / weekly / cumulative); style is switchable in the panel and settings, heatmap by default; can be turned off.
- Use a local incremental session index for faster cost scans.
- View recent Codex sessions, projects, status, and usage summaries.
- Repair the local session index.
- Support light, dark, system appearance, and English, 简体中文, 繁體中文, 한국어, 日本語, Русский, Français.
- Offer macOS 14+ desktop widgets for quota overview, token trend, a key metric, and reset-today status.

## Screenshots

<p align="center">
  <img src="docs/images/1.webp" alt="CodexRunway quota overview" width="260">
  <img src="docs/images/2.webp" alt="CodexRunway reset credits details" width="260">
  <img src="docs/images/3.webp" alt="CodexRunway API-equivalent cost" width="260">
  <img src="docs/images/4.webp" alt="CodexRunway setting page" width="260">
  <img src="docs/images/5.webp" alt="CodexRunway multi-account" width="260">
</p>

## Installation

### Manual installation

Build the DMG locally with `Scripts/package-app.sh`:

- Apple Silicon: `CodexRunway-macos-arm64.dmg`
- Intel: `CodexRunway-macos-x86_64.dmg`

Open the DMG and drag `CodexRunway.app` into `Applications`, or unpack the ZIP built for the same architecture.

On its first launch, the installed app requests launch at login by default; you can turn it off or on in **Control Panel → General → Launch at login**. If macOS requires approval, use **Open Login Items Settings** to allow it. Later launches respect changes made in System Settings; command-line and development runs do not register login items.

### macOS Security Blocks

Current releases are ad-hoc signed and not notarized. If macOS says the developer cannot be verified or the app was not checked for malicious software, right-click `CodexRunway.app` and choose Open, or go to System Settings > Privacy & Security and click Open Anyway.

If macOS says `CodexRunway.app` is damaged and should be moved to the Trash, it is usually the download quarantine attribute. After placing the app in `Applications`, run:

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

Then open the app again.

## Requirements

- macOS 12+
- Codex installed and used on this Mac is recommended
- Import from local `~/.codex/auth.json`, or add accounts in the app (browser sign-in, paste credentials, import files, and more)

## Run Locally

```bash
swift run CodexRunway
```

On macOS 14+, this command automatically builds and registers a separate `CodexRunway Dev` app and Widget extension, then launches it. The development app lives at `.build/codex-runway-widget-dev/CodexRunway-dev.app` and can be added directly from the system widget gallery. Quit any other running CodexRunway instance first. Set `CODEX_RUNWAY_DISABLE_DEV_APP=1` only when you want the raw unpackaged command-line process without widgets.

Self-check:

```bash
swift run CodexRunway --self-check
```

The self-check reads local state only and makes no network request. It prints redacted Codex diagnostics, credential status, and account identity. Tokens and API keys are never printed.

## Desktop Widgets

Desktop widgets require macOS 14 or later. Starting with a release that contains this fix, public releases and local development builds both include the Widget extension. Each widget shows Codex data. After upgrading, macOS registers the production widget from the app's `Contents/PlugIns` directory.

`swift run CodexRunway` uses separate `swift-dev` identifiers and does not replace an existing installation. You can also package a widget-enabled app manually with `.dev` identifiers:

```bash
INCLUDE_WIDGET=1 \
RUNWAY_BUNDLE_ID=com.github.codex-runway.dev \
RUNWAY_APP_GROUP_ID=group.com.github.codex-runway.dev \
RUNWAY_WIDGET_STORAGE_MODE=local \
bash Scripts/package-app.sh
```

The app is written to `dist/CodexRunway.app`. Public releases containing this fix and local ad-hoc builds use the read-only versioned derived snapshot at `~/.codex-runway/widget-snapshot.json` with `0600` permissions. A Developer ID build with a registered App Group can instead set `RUNWAY_WIDGET_STORAGE_MODE=app-group`. The snapshot contains no email, account ID, token, auth JSON, or raw external event text. Developer ID signing, App Group registration, and notarization remain available as future distribution work.

## Network proxy

In **Control Panel → General → Network**, choose **Follow System**, **HTTP Proxy**, or **SOCKS5 Proxy**; custom proxies support username and password authentication. The setting covers Codex requests and the public status and pricing feeds. Browser sign-in pages and already-running external CLI processes keep their own network settings; the system proxy is not changed.

Changes apply only after **Save Proxy Settings**. **Test Connection** checks network reachability with the current draft, without sending account credentials or saving the draft. Proxy credentials are stored in the macOS Keychain, separately from non-secret preferences. Invalid configuration, unavailable credentials, or a failed custom proxy do not trigger a direct connection; fix the settings or explicitly switch back to **Follow System**.

## Privacy

- Tokens are read from local `~/.codex/auth.json`; multi-account credentials are stored only under `~/.codex-runway/accounts/<id>/auth.json` (directory mode `0700`, file mode `0600`). The account index `index.json` never contains tokens.
- Official `~/.codex/auth.json` is overwritten only when you confirm an account switch (atomic write), so Codex CLI / IDE stay in sync.
- Refreshing a non-active managed account updates only its library copy, not official `auth.json`. Refreshing the active account keeps the official auth file and the library copy in sync.
- Invalid or mock credentials are never written back to official `~/.codex/auth.json`.
- Access tokens, refresh tokens, ID tokens, and API keys must not be written to logs, README files, issue templates, or self-check output.
- API-equivalent cost is computed from local session JSONL logs by default, with derived data such as a local incremental index under `~/.codex-runway/`. Session contents are not uploaded.
- Weekly quota estimates store only derived Credits totals and percents in `~/.codex-runway/quota-estimate-history.json`. No tokens or keys.
- Online usage supplements API-equivalent cost only when local token data is unavailable. The chart’s “Official stats (all devices)” series comes from current-account profile statistics and may lag or be revised; “Local logs (all sessions)” scans the sessions present on this Mac and historical entries may span accounts. Daily values in this comparison use UTC dates so both sources share the same day boundary. The two series are not a subset relationship and should not be subtracted.
- Session repair only touches `~/.codex/session_index.jsonl`, creates a backup before writing, and never deletes session files.
- “Reset today?” only downloads the public status feed. It sends no Codex account, token, or local session content.
- Widget snapshot storage contains only non-secret derived quota, balance, cost, daily-token, and reset-status data. The main app is the sole writer; widgets are read-only.

## Data sources

- **Reset today?**: Data comes from [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json). Unofficial and advisory only; may be delayed or temporarily unavailable.
- **Quota / reset credits / quota estimate / official token usage / some online usage**: When signed in, requests use your local credentials against official ChatGPT / Codex backend APIs. Official token usage belongs to the current account and shows the backend statistics date. Quota estimate is unofficial: weekly allowance is extrapolated from weekly used percent and daily Credits (1000 Credits ≈ $40, version `credits-usd-2026-08-26`).
- **Local-log token usage / API-equivalent cost / recent sessions**: Computed by default from local `~/.codex` session logs and the local index. Historical local logs have no reliable account attribution, so they may include multiple accounts.

## Development and Contribution

```bash
swift test
swift build
swift build -c release
```

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for contribution notes.

## Community

- [LinuxDO](https://linux.do/)

## License

This project follows the repository [LICENSE](LICENSE).
