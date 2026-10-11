[English](./README.md) · 简体中文 · [繁體中文](./README_ZH_HANT.md) · [한국어](./README_KO.md) · [日本語](./README_JA.md) · [Русский](./README_RU.md) · [Français](./README_FR.md)

<p align="center">
  <img src="Resources/AppIcon.png" alt="CodexRunway logo" width="128" height="128">
</p>

# CodexRunway

你的 Codex 还可以跑多久？

CodexRunway 是一个原生 macOS 状态栏应用，帮你在菜单栏查看 Codex 额度，并提供 Codex 的今日是否重置、reset credits、API 等价成本与本机会话能力，以及 Codex 的多账号管理。

## 亮点

- 菜单栏查看 Codex 剩余额度。
- 查看 5 小时、每周和附加额度窗口。
- 查看今日速率限制是否已重置（数据来自 [www.codexrunway.com](https://www.codexrunway.com)），并可跳转到相关公开动态。
- 设置中可开关「今日是否重置」栏目，并单独配置其刷新间隔（默认开启、每 5 分钟）。
- 管理多个 Codex 账号：浏览器登录、导入本机 `auth.json`、粘贴 token / JSON（含 `/auth/session`）、导入文件或 API Key。
- 确认后安全切号，原子写回 `~/.codex/auth.json`，可选立即重启 Codex，使 CLI / IDE 同步。
- 显示当前账号、订阅类型与到期信息。
- 用官方周占用率和每日 Credits 推算本周额度，并与历史推算对比，便于发现是否被下调；设置中可开关，默认开启。
- 查看 reset credits 数量、状态和到期时间。
- 查看 API 等价成本与 token 用量：今日、本周期、上周期、本月或自定义范围；设置可改主弹窗默认范围。
- 主弹窗配额下方显示本年 token 用量图表（热力图 / 折线图 / 柱状图，每日 / 每周 / 累计），设置中可切换样式或关闭；默认热力图。
- 本机会话增量索引，加速成本扫描。
- 查看最近 Codex 会话、项目、状态和用量摘要。
- 修复本机会话索引。
- 支持浅色、深色、跟随系统，以及 English、简体中文、繁體中文、한국어、日本語、Русский、Français 界面。
- 提供 macOS 14+ 桌面组件：额度总览、Token 趋势、关键指标和今日重置。

## 截图

<p align="center">
  <img src="docs/images/1.webp" alt="CodexRunway 配额概览" width="260">
  <img src="docs/images/2.webp" alt="CodexRunway 重置次数详情" width="260">
  <img src="docs/images/3.webp" alt="CodexRunway API 等价成本" width="260">
  <img src="docs/images/4.webp" alt="CodexRunway 设置页面" width="260">
  <img src="docs/images/5.webp" alt="CodexRunway 多账号" width="260">
</p>

## 安装

### 手动安装

用 `Scripts/package-app.sh` 本地构建 DMG，打开与你的 Mac 匹配的安装包：

- Apple Silicon：`CodexRunway-macos-arm64.dmg`
- Intel：`CodexRunway-macos-x86_64.dmg`

打开 DMG 后把 `CodexRunway.app` 拖入 `Applications`，也可以手动解压同架构的 ZIP。

安装版首次启动时默认请求开启开机自启，可在 **控制面板 → 通用 → 开机自启** 中关闭或开启；若 macOS 要求批准，点击 **打开登录项设置** 后允许该应用；后续启动会尊重系统设置中的更改，命令行和开发运行不会注册登录项

### macOS 安全阻挡

当前 Release 是 ad-hoc signed，未 notarized。首次打开如果提示“无法验证开发者”或“未经安全验证”，请右键点击 `CodexRunway.app`，选择“打开”，或在“系统设置 > 隐私与安全性”中点击“仍要打开”。

如果提示“CodexRunway.app 已损坏，无法打开。您应该将它移到废纸篓”，通常是下载隔离属性导致的。把 app 放入 `Applications` 后运行：

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

然后再次打开应用。

## 使用前提

- macOS 12+
- 推荐已安装并使用过 Codex
- 可通过本机 `~/.codex/auth.json` 导入，或在应用内添加账号（浏览器登录、粘贴凭据、导入文件等）

## 本地运行

```bash
swift run CodexRunway
```

在 macOS 14+，该命令会自动构建并注册独立的 `CodexRunway Dev` 应用和 Widget 扩展，然后启动它；开发应用位于 `.build/codex-runway-widget-dev/CodexRunway-dev.app`，可直接从系统组件库添加。启动前请先退出其他正在运行的 CodexRunway 实例。若只需运行未打包的命令行进程，可设置 `CODEX_RUNWAY_DISABLE_DEV_APP=1`。

自检命令：

```bash
swift run CodexRunway --self-check
```

自检只读取本地状态，不请求网络；它会输出脱敏的 Codex 诊断、凭据状态和账号身份。任何 token 或 API Key 都不会打印。

## 桌面组件

桌面组件要求 macOS 14+。从包含此修复的版本起，正式 Release 和本地开发构建都会包含 Widget 扩展。组件展示 Codex 数据。升级后，macOS 会从应用包的 `Contents/PlugIns` 注册正式版组件。

`swift run CodexRunway` 使用独立的 `swift-dev` 标识，不会覆盖现有安装。也可使用 `.dev` 标识手动生成带组件的应用：

```bash
INCLUDE_WIDGET=1 \
RUNWAY_BUNDLE_ID=com.github.codex-runway.dev \
RUNWAY_APP_GROUP_ID=group.com.github.codex-runway.dev \
RUNWAY_WIDGET_STORAGE_MODE=local \
bash Scripts/package-app.sh
```

生成的应用位于 `dist/CodexRunway.app`。包含此修复的正式 Release 和本地 ad-hoc 构建默认从 `~/.codex-runway/widget-snapshot.json` 读取权限为 `0600` 的版本化派生快照；已注册 App Group 的 Developer ID 构建可改用 `RUNWAY_WIDGET_STORAGE_MODE=app-group`。快照不含邮箱、账号 ID、token、认证 JSON 或外部事件原文。后续仍可接入 Developer ID、App Group 注册与公证。

## 网络代理

在 **控制面板 → 通用 → 网络** 中选择 **跟随系统**、**HTTP 代理** 或 **SOCKS5 代理**，自定义代理支持用户名和密码认证；设置覆盖 Codex 请求，以及公开状态与价格源；浏览器登录页面与已经运行的外部 CLI 进程沿用各自的网络设置，不修改系统代理

修改须点击 **保存代理设置** 后生效；**测试连接** 用当前草稿检查网络连通性，不发送账号凭据，也不保存草稿；代理凭据保存在 macOS 钥匙串，与非密钥设置分开存放；配置损坏、凭据不可用或自定义代理失败时不会自动直连，请修复设置或主动改回 **跟随系统**

## 隐私

- token 从本机 `~/.codex/auth.json` 读取；多账号凭据仅保存在 `~/.codex-runway/accounts/<id>/auth.json`（目录 `0700`、文件 `0600`）。账号索引 `index.json` 不含 token。
- 用户主动切号时，才会将选中凭据原子写回 `~/.codex/auth.json`，以便 Codex CLI / IDE 同步使用。
- 刷新非当前托管账号 token 时只更新账号库副本，不写官方 `auth.json`；刷新当前账号时同步官方 auth 与副本。
- 无效或 mock 凭据不会写回官方 `~/.codex/auth.json`。
- access token、refresh token、id token、API key 不会写入日志、README、issue 模板或自检输出。
- API 等价成本默认来自本机会话 JSONL 日志，并在 `~/.codex-runway/` 下维护本地增量索引等派生数据；不上传会话内容。
- 订阅额度推算只把派生的 Credits 合计与占用率写入 `~/.codex-runway/quota-estimate-history.json`，不含 token 或密钥。
- API 等价成本的在线用量只在本地没有可用 token 数据时作为补全。Token 图表的“官方统计（多端）”来自当前账号的官方资料统计，可能延迟或后续修订；“本机日志（全部本机会话）”扫描本机现有会话，历史记录可能跨账号。按日数据使用 UTC 日期，以便两边使用同一日界。两者口径不同，不能视为包含关系或直接相减。
- 会话修复只处理 `~/.codex/session_index.jsonl`，写入前会创建备份，不删除会话文件。
- 「今日是否重置」只下载公开状态源，不附带 Codex 账号、token 或本机会话内容。
- 桌面组件快照存储仅保存额度、余额、派生成本、Token 日序列和重置状态等非密钥数据；主应用是唯一写入者，组件只读。

## 数据来源

- **今日是否重置**：数据来源于 [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json)，非官方且仅供参考，可能延迟或暂时不可用。
- **配额 / reset credits / 订阅额度推算 / Token 用量官方统计 / 部分在线用量**：在你已登录的前提下，通过本机凭据访问官方 ChatGPT / Codex 后端接口；官方 Token 统计仅对应当前账号，并显示服务端统计截至日期。订阅额度推算非正式：用周占用率和每日 Credits 外推本周额度（1000 Credits ≈ $40，版本 `credits-usd-2026-08-26`）。
- **Token 用量本机日志 / API 等价成本 / 最近会话**：默认基于本机 `~/.codex` 会话日志与本地索引计算。本机历史日志没有可靠的账号归属，因此可能包含多个账号的数据。

## 开发与贡献

```bash
swift test
swift build
swift build -c release
```

贡献说明见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

## 社区支持

- [LinuxDO](https://linux.do/)

## 许可证

本项目遵循仓库中的 [LICENSE](LICENSE)。
