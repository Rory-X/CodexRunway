# Codex 额度窗口触发探针 — 一手调研报告

调研问题：能否仿照 Codex Desktop，用一个存储的 OAuth 凭证、发一个**最小请求**，来「启动」额度窗口计时？

结论先行：**5 小时窗口可以，且本次已做受控实验直接证明；周窗口存疑（证据冲突，见 §1.3）。**
读接口不启动计时，必须发一次**真实推理**（或验证 WebSocket `generate:false` 这条候选零推理路径）。

调研日期：2026-09-28。样本：本机 `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/archived_sessions/**`
共 **689 个 rollout、10,901 条带 `rate_limits` 的观测**，外加对 6 个托管账号的真实 HTTP 实验。
上游源码基线：`openai/codex` @ `1cc7e2361237ce7244430ee1d581c77f95c57ac8`（2026-09-28）。

---

## TL;DR / 答案

| 问题 | 答案 | 证据强度 |
|---|---|---|
| 5h 窗口是滚动窗口吗？ | **不是**。它是「窗口内首个请求」开启后**固定 5 小时**的窗口，`resets_at` 一旦设定就不再滑动 | **受控实测**（同账号 A/B） |
| `resets_at` 何时被设定？ | **首个推理请求到达时**，设为 `该时刻 + 18000s` | **受控实测** |
| 空闲账号的窗口会「等请求才启动」吗？ | **会**。空闲时 `reset_after_seconds == limit_window_seconds == 18000`；一旦发请求，`reset_at` 被钉住并开始倒计时 | **受控实测** |
| 最小触发请求是什么？ | `POST https://chatgpt.com/backend-api/codex/responses`，body 里放一句 `"ok"`。等价 CLI：`codex exec --ephemeral -m <廉价模型> "ok"` | **实测通过** |
| 有更便宜的 ping 吗？ | 读接口**不触发**（已证）。WS `generate:false` prewarm 是**候选零推理路径**：能拿到额度数据，但**是否启动窗口未验证** | 部分 |
| 响应头里有窗口状态吗？ | **有**，完整 `x-codex-*` 家族见 §3，但只在**推理端点**返回，读接口不返回 | **实测抓包** |
| 社区有先例吗？ | **有，且已落地**。至少两个独立项目在做同一件事，机制与本报告一致 | 源码级 |

**可行性判定：可行。** 但探针必须是「一次真实推理」，不是 ping；且必须用
`reset_after_seconds >= limit_window_seconds` 判断「无活动窗口」，**不能用 `used_percent == 0`**。

---

## 1. 窗口机制

### 1.1 受控实验：读接口不启动，推理启动

对同一账号（`oauth-4f8dc043cb2f3bdc`，plus）连续操作，只改一个变量：

```
### PHASE 1: 两次只读轮询，间隔 30s（对照组）
[read#1] used=0%  reset_after=18000  win=18000  reset_at=1790582766  reset_at-now=18000  ACTIVE=False
[read#2] used=0%  reset_after=18000  win=18000  reset_at=1790582797  reset_at-now=18000  ACTIVE=False
         ↑ reset_at 两次都「等于当下+18000」，即尚未钉住 —— 无窗口

### PHASE 2: 一次最小推理请求
  POST /backend-api/codex/responses -> 200

### PHASE 3: 推理后的只读轮询
[after+10s] used=0%  reset_after=17990  reset_at=1790582799  reset_at-now=17989  ACTIVE=False
[after+20s] used=0%  reset_after=17979  reset_at=1790582799  reset_at-now=17978  ACTIVE=False
[after+30s] used=0%  reset_after=17968  reset_at=1790582799  reset_at-now=17967  ACTIVE=True
[after+40s] used=0%  reset_after=17957  reset_at=1790582799  reset_at-now=17956  ACTIVE=True
         ↑ reset_at 被**钉死在 1790582799**，reset_after 开始递减 —— 窗口已启动
```

关键读法：**窗口未启动时 `reset_at` 是浮动值**（= 现在 + 全窗长，每次读都变）；
**启动后变成常量**，`reset_after` 单调递减。
这个「浮动 → 钉死」的转变，是本报告判定窗口启动的核心信号，比 `used_percent` 可靠得多。

在另一账号（`oauth-6717c4953043f34f`）独立复现同一条时间线；并用一个被服务端拒绝的请求
（HTTP 400，见 §2.2）作额外对照：**被拒绝的请求不启动窗口**。

### 1.2 5h 窗口的长期统计（10,901 条观测）

按 `(window_minutes, resets_at)` 归并为 **56 个 5h 窗口锚点**
（`resets_at` 有 ±5s 抖动，必须按**分钟取整**归并，否则同一窗口虚增成多个）：

| 指标 | 值 |
|---|---|
| 首次被观测时「窗口几乎全满」= 该请求刚开启它 | **52 / 56 = 93%** |
| 首次被观测时窗口已在运行中 | 4 / 56 |
| 单窗口内 `resets_at` 原始抖动 | ≤ 数秒（同一锚点内**不滑动**） |

会话内表现：某锚点在 **12.78 小时**连续观测跨度内 `reset_at` 恒定不变，确认窗口一旦开启
就不随每次请求滑动 —— 即**不是滚动窗口**。
（注：`codex-rs/protocol/src/protocol.rs:2395` 的字段注释写作 "Rolling window duration"，
但那只是上游对 `window_minutes` 的措辞，**与实测行为不符**；实测为非滚动。）

### 1.3 周窗口：证据冲突，**未定论**（重要）

必须明确标注为**存疑**，因为手头证据自相矛盾：

**支持「周窗口也由活动开启」（我的数据）：**

- 27 个周窗口锚点中 **19 个**首次被观测时是「全新」的（`reset_at - first_obs ≈ 604800s`，
  中位 elapsed = **0.01 小时**；16 个 elapsed ≤ 0.5h）。若是固定周期窗口，不该有如此高比例的
  「正好在首个请求时归零」。

**支持「周窗口独立于请求」（我的数据）：**

- 8 / 27 个周窗口首次被观测时已在运行（elapsed 达 8.57h、21.13h）。
- 周窗口锚点间隔混乱：同一账号先后出现 0.08d / 0.52d / 1.14d / 1.28d / 69.96d 等间隔，
  **远非 7 天周期** —— 这一点本身就否证了「固定周期」说法。

**社区一手证据（非官方，但有可复核数据）：**

- [openai/codex#36313](https://github.com/openai/codex/issues/36313)：作者在**一周内**观测到
  **9 个不同周窗口锚点**，每个都恰好等于「某次活动时刻 + 7 天」（精确到分钟），结论是
  周窗口被重算为 `now + 7d`，而非锚定计费周期起点。
- [openai/codex#35952](https://github.com/openai/codex/issues/35952)：用户写下
  *"I understand how these works: starts at the first message received from me"*，
  并报告 reset 日期在使用中被推后。

**我的判定：周窗口很可能同样由活动驱动，但机制是「重算为 now+7d」，与 5h 窗口的「钉死 5h」
语义不同。我没有对「关闭态周窗口 → 发请求 → 开启」做受控实验**，因为调研期间没有任何账号
处于周窗口关闭态。**不要据此写实现逻辑。**

---

## 2. 最小触发请求

### 2.1 最小可行 HTTP 请求（实测通过）

```http
POST https://chatgpt.com/backend-api/codex/responses HTTP/1.1
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
Content-Type: application/json
Accept: text/event-stream
Originator: codex_cli_rs
User-Agent: codex_cli_rs/<version>

{"model":"gpt-5.6-luna",
 "instructions":"You are a helpful assistant.",
 "input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]}],
 "stream":true,
 "store":false}
```

响应为 SSE（`text/event-stream`）：首事件 `response.created`，末事件 `response.completed`。
`originator` / `User-Agent` 取自 Codex 自身请求构造；服务端接受 `codex_cli_rs/0.153.4`。

### 2.2 明确的负面结果（全部实测）

| 尝试 | 结果 | 含义 |
|---|---|---|
| `GET /backend-api/wham/usage` | 200，但**不启动窗口** | 没有零成本 ping |
| `HEAD /backend-api/codex/responses` | **405 Method Not Allowed** | 无 header-only 探测 |
| `OPTIONS /backend-api/codex/responses` | **400 Bad Request** | 同上 |
| body 带 `max_output_tokens` | **400 `{"detail":"Unsupported parameter: max_output_tokens"}`**，且**不启动窗口** | 该参数被拒 |
| 裸 WebSocket 握手（不发帧） | 连接可建立，但**不返回任何额度数据** | 握手本身不带状态 |

### 2.3 WebSocket prewarm：候选零推理路径（**半验证**）

源码里有一条明确「不是推理请求」的路径：

> `codex-rs/core/src/client.rs:19-20`：
> "WebSocket prewarm is a v2-only `response.create` with `generate=false`; it waits for completion"
> `codex-rs/core/src/client.rs:1900`：`// `generate=false` prewarm is connection setup, not an inference request.`

实测向 `wss://chatgpt.com/backend-api/codex/responses` 发送：

```json
{"type":"response.create","model":"gpt-5.6-luna","instructions":"...","input":[...],
 "tools":[],"tool_choice":"auto","parallel_tool_calls":true,
 "store":false,"stream":true,"generate":false}
```

收到（**无需推理**即返回额度数据）：

```
MSG1 {"type":"codex.rate_limits","plan_type":"plus","rate_limits":{
       "allowed":true,"limit_reached":false,
       "primary":{"used_percent":1,"window_minutes":300,"reset_after_seconds":17261,"reset_at":1790582385},
       "secondary":{"used_percent":0,"window_minutes":10080,"reset_after_seconds":557218,"reset_at":1791122343}}, ...}
MSG3 {"type":"response.created", ... "generate":false, "status":"in_progress" ...}
MSG6 {"type":"response.completed", ... "generate":false, "status":"completed" ...}
```

**已证**：`generate:false` 能拿到完整额度数据、服务端标记为 non-generate、耗时 <1s。
**未证**：它是否**启动**窗口。当时 6 个账号的 5h 窗口**全部处于活动态**，没有干净样本。
**若成立，这就是成本≈0 的探针** —— 建议实现前优先实测这条。

---

## 3. 推理响应头里的窗口状态（实测抓包）

任务假设的头名基本正确，实测**确认全部存在**。下面是 `POST /backend-api/codex/responses`
返回的完整 `x-codex-*` 家族（某 plus 账号，`used_percent=1%`、窗口活动态）：

```
x-codex-active-limit                         = premium
x-codex-plan-type                            = plus
x-codex-primary-used-percent                 = 1
x-codex-secondary-used-percent               = 0
x-codex-primary-window-minutes               = 300
x-codex-secondary-window-minutes             = 10080
x-codex-primary-over-secondary-limit-percent = 0
x-codex-primary-reset-after-seconds          = 17770
x-codex-secondary-reset-after-seconds        = 557727
x-codex-primary-reset-at                     = 1790582385
x-codex-secondary-reset-at                   = 1791122343
x-codex-credits-has-credits                  = True
x-codex-credits-balance                      = 584.1412170000
x-codex-credits-unlimited                    = False
x-codex-turn-state                           = gAAAAAB...
x-models-etag                                = W/"9fd094b7..."
x-oai-request-id                             = ad432680-...
```

**重要细节**：Codex 自己的解析器只读 **`-reset-at`（绝对时间戳）**，不读 `-reset-after-seconds`。
见 `codex-rs/codex-api/src/rate_limits.rs:68-80`（构造 `{prefix}-primary-reset-at`）与测试
`codex-rs/core/tests/suite/client.rs:3384-3388`。
`-reset-after-seconds` 是服务端额外送的**相对剩余秒数**，对本探针反而更有用（见 §6.1）。

### 3.1 哪三个端点返回额度

| 端点 | 返回形式 | 说明 |
|---|---|---|
| `POST /backend-api/codex/responses`（SSE） | **响应头** `x-codex-*` | 实测确认 |
| `wss://.../codex/responses`（WebSocket） | **事件帧** `{"type":"codex.rate_limits", ...}` | 实测确认；解析见 `codex-rs/codex-api/src/endpoint/responses_websocket.rs:774` |
| `GET /backend-api/wham/usage` | **JSON body** | 只读，无 `x-codex-*` 头（实测仅 `content-type`、`x-openai-proxy-wasm`） |

SSE 路径的头解析入口：`codex-rs/codex-api/src/sse/responses.rs:43`
`let rate_limit_snapshots = parse_all_rate_limits(&stream_response.headers);`

### 3.2 路径对照（源码）

`codex-rs/backend-client/src/client/rate_limit_resets.rs:124-139`：

```rust
fn rate_limit_status_url(&self) -> String {
    match self.path_style {
        PathStyle::CodexApi   => format!("{}/api/codex/usage", self.base_url),
        PathStyle::ChatGptApi => format!("{}/wham/usage",   self.base_url),
    }
}
```

`PathStyle` 由 base URL 是否含 `/backend-api` 决定（`client.rs:149-154`）。
即 `https://chatgpt.com/backend-api` + `/wham/usage` = 本报告与 CodexRunway 使用的端点。

---

## 4. 社区先例

**存在，且至少两个是直接解决同一问题的完整实现。**

### 4.1 `almeidasrenato/ai-reset-runner`（机制与本文一致，**源码级**）

macOS 菜单栏应用，自述目标就是 *"auto-starts your Claude Code and Codex 5-hour usage window"*。

README 明确写出机制：

> "A window does not start on a schedule. It starts with **your first message**, and it resets
> 5 hours later."

其 `Sources/AIResetRunner/Pinger.swift` 的实际触发命令：

```swift
["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
 "-C", Shell.workdir.path, "-m", model,          // 默认 gpt-5.6-luna
 "-c", "model_provider=openai",                   // 绕过代理，确保打到订阅窗口
 "-c", "model_reasoning_effort=low", "ok"]
```

`Sources/AIResetRunner/Scheduler.swift` 的「无窗口」判据与本文**完全一致**，注释点破关键陷阱：

```swift
// Not "usage == 0": a window opened a minute ago also reads 0%.
guard reading.session.isIdle(now: now.addingTimeInterval(-resetGrace)) else { return .skip(...) }
```

其触发前置条件（可借鉴）：读数新鲜度 < 5 分钟、周额度 < 100%、**距上次触发 ≥ 4h50m**（落盘）、
触发后 **45 秒复查**确认窗口真的开了、`--ephemeral` + 专用空目录 + 事后删除残留 rollout。

### 4.2 `shnksi/optimize-ai-limits`（同思路，launchd 调度）

自述 *"Sends a minimal keep-alive prompt ('Reply with exactly OK.') right after each reset,
so your next window starts immediately"*。数据源就是 `~/.codex/sessions/**/*.jsonl` 的
`token_count` → `rate_limits.primary.resets_at`；`src/parsers.mjs` 用 `resets_at` 判定窗口，
与本文一致。触发命令 `codex exec "Reply with exactly OK."`。

### 4.3 其他

- `lidge-jun/opencodex` PR #6056 *"start opted-in idle quota windows before first reset"*（closed）
- `WSL043/dsh-codex-subscription` PR #50 *"retry Codex turns after quota reset"*（closed，目标略不同）
- `headroomlabs-ai/headroom` 的 `codex_rate_limits.py` 记录**两代 schema**：旧的在响应头、
  新的在独立端点，并称 *"Current Codex ... no longer emits those headers on the `/responses`
  handshake or stream"*。

> ⚠️ 关于最后这条：**我的实测与 headroom 的说法相反** —— 2026-09-28 的 `POST /codex/responses`
> **确实返回完整 `x-codex-*` 头**（§3）。headroom 的描述可能只针对 WebSocket 传输路径，
> 或已过时。**以实测为准。**

---

## 5. 合规与账号风险（事实陈述）

- OpenAI 官方文档（`learn.chatgpt.com` Codex 手册）的 "usage limits" 章节只说明额度按
  **5 小时周期估算**、并指向 `https://chatgpt.com/codex/settings/usage` 查看限额，
  **未定义窗口何时开始**。即：**「首请求启动窗口」不是官方成文行为**，而是从客户端遥测与
  社区观测归纳出的实际行为。
- 官方公开文本中**没有**针对「用官方客户端发消息来启动窗口」的明文禁止条款。手册里出现的
  "Circumvention: Do not bypass API restrictions, rate limits, or access controls imposed by the
  third party" 处于 **Plugins 开发者政策**语境（针对第三方插件绕过他人 API 限制），不直接覆盖本场景。
- **事实性风险点**（不构成合规结论）：
  1. 探针会**消耗真实额度**（一次推理），最坏情况下把用户从「无窗口」推进到「5h 窗口中」。
  2. 探针使用**存储的 OAuth 凭证**而非用户当场交互 —— 自动化程度更高。
  3. 若实现多账号轮转「错峰」刷新窗口，属脚本化、非人工节奏使用。
- 本报告不做合规定性。用户若要求，可另做专项评估。

---

## 6. 轻量探针的工程建议

### 6.1 判定「窗口是否已启动」——唯一可靠信号

```
无活动窗口  ⟺  reset_after_seconds >= limit_window_seconds - 容差
```

实测支持（§1.1）。**绝对不要用 `used_percent == 0`** —— 刚开启的窗口同样是 0%。

`/wham/usage` 返回 `reset_after_seconds`；Codex 响应头里 `x-codex-primary-reset-after-seconds`
**也存在**（§3），所以两条路径都能判定。

**CodexRunway 现有缺口**：`Sources/CodexRunwayCore/Decoding.swift` 的 `WindowResponse`
目前只解出 `used_percent` / `reset_at` / `limit_window_seconds`，**缺 `reset_after_seconds`**。
虽然也可用 `reset_at` 推算（`reset_at - now >= window` ⇒ 无窗口），但直接解该字段更稳。

> 注意 `reset_after_seconds` 与 `reset_at` 之间有 ±5s 量级抖动，**容差至少 30s**。

### 6.2 (a) 启动窗口的最小成本路径

按优先级从低到高：

1. **【待验证，若成立则成本≈0】** WebSocket `generate:false` prewarm（§2.3）：
   一条帧、无推理、可拿到 `codex.rate_limits`。**实现前必须先实测它是否启动窗口。**
2. **【已验证可用】** `codex exec` 最小推理：
   ```
   codex exec --ephemeral --skip-git-repo-check -s read-only \
     -C <专用空目录> -m <最廉价模型> -c model_reasoning_effort=low "ok"
   ```
   用 `--ephemeral` 避免污染会话历史；专用空目录便于事后清理残留 rollout。
3. 直接 `POST /backend-api/codex/responses`（§2.1）—— 最轻，但需自己处理 SSE 与凭证。

成本量级：一次最小推理仍携带完整 system prompt，**不是零成本**。

### 6.3 (b) 确认窗口已启动

**不要**读响应头就断言。建议：

1. 触发后等待 **15–45 秒**，再 `GET /wham/usage`；
2. 断言 `reset_after_seconds < limit_window_seconds - 容差`（容差 ≥ 30s，抵消时钟偏差）;
3. 更稳：连续两次读，确认 `reset_at` **已钉住**（两次读数相同）而 `reset_after_seconds` 递减。

### 6.4 探针的幂等性（实测）

在窗口**已活动**时再发一次推理请求，**不会**推后 `reset_at`：

```
BEFORE: primary reset_at=1790582668  weekly reset_at=1791122450
【窗口内再发一次请求】
AFTER : primary reset_at=1790582668  weekly reset_at=1791122450   ← 均未移动
```

含义：探针在窗口活动态是**无副作用**的（除那一次推理的 token 消耗）。
这让「先探再决定」在正确性上安全 —— **但仍应加冷却期**（社区用 4h50m）避免白烧额度。

### 6.5 Token 刷新（实现必需）

存储的 `access_token` 会过期。刷新流程（源码确认）：

```
POST https://auth.openai.com/oauth/token
Content-Type: application/json
{"grant_type":"refresh_token",
 "client_id":"app_EMoamEEZ73f0CkXaXp7hrann",
 "refresh_token":"<refresh_token>"}
```

- 端点：`codex-rs/login/src/auth/manager.rs:212`
  `const REFRESH_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";`
- client_id：`codex-rs/login/src/auth/manager.rs:1717`
  `pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";`
- 参数构造：`codex-rs/login/src/oauth/client.rs:80-89`（`grant_type=refresh_token`）
- 结果回写 `access_token` / `refresh_token` / `id_token` 并更新 `last_refresh`：
  `manager.rs:1595-1605`（`persist_tokens`）

注意 AGENTS.md 隐私约束：刷新**非当前**托管账号时只写账号库副本，不得写官方 `~/.codex/auth.json`。

### 6.6 触发前置条件（照抄社区实践，降低风险）

1. 读数必须**新鲜**（< 5 分钟），陈旧数据绝不触发；
2. 重置判据显示**无活动窗口**（不是 `used_percent == 0`）；
3. 周额度 < 100%；
4. 距上次触发 ≥ 冷却期（社区用 **4h50m**，落盘持久化，含手动触发）；
5. 在专用空目录执行、`--ephemeral`、并清理可能残留的 rollout 文件；
6. 探测失败时按 429 指数退避。

---

## 7. 信心与缺口

### 已由一手证据验证 ✅

| 结论 | 证据 |
|---|---|
| 5h 窗口由首个推理请求开启，之后固定 5h 不滑动 | **同账号受控 A/B 实验**（§1.1）+ 10,901 条遥测（56 锚点，93% 首见即全新） |
| 空闲时 `reset_at` 浮动（= now+全窗长），启动后钉死 | 受控实验直接观测到「浮动 → 钉死」转变 |
| 只读 `GET /wham/usage` **不**启动窗口 | 受控实验 Phase 1（两次读均 18000/18000） |
| 被服务端拒绝的请求（400）**不**启动窗口 | 实测（`max_output_tokens` 400，窗口仍关闭） |
| 窗口活动态下重复请求**不**推后 `reset_at` | 实测（§6.4） |
| 完整 `x-codex-*` 头家族存在且逐个确认 | **实测抓包**（§3，逐字段） |
| 这些头由 `/codex/responses` 返回，`/wham/usage` 不返回 | 实测（两处响应头对比） |
| WS `generate:false` 能返回 `codex.rate_limits` 且非生成 | 实测（§2.3） |
| `HEAD` / `OPTIONS` 返回 405 / 400 | 实测 |
| OAuth 刷新端点 / client_id / 参数 | **源码**（含精确文件行号） |
| 上游解析器只读 `-reset-at` 不读 `-reset-after-seconds` | **源码**：`codex-api/src/rate_limits.rs:68-80` + 测试 `core/tests/suite/client.rs:3384-3388` |
| 社区先例存在且机制一致 | **源码级**阅读（两个独立项目） |

### 未验证 / 存疑 ⚠️

1. **周窗口是否可被触发 —— 证据冲突，未定论。** 我的数据既显示 19/27 锚点「首见即全新」，
   也显示 8/27 已在运行、锚点间隔混乱（0.08d–69.96d，非 7 天周期）。社区 issue
   #36313 / #35952 支持「重算为 now+7d」。**未做受控实验**（调研期间无关闭态周窗口可用）。
   **不要据此写实现。**
2. **`generate:false` prewarm 是否启动 5h 窗口 —— 未验证。** 这是最有价值的待验证项，
   可能把探针成本压到 ≈0。代码路径可跑通，但 6 个账号窗口全部处于活动态，无干净样本。
3. **「首请求启动窗口」不是官方成文行为。** 官方手册未定义窗口起点；若服务端改变语义，
   探针会静默失效。
4. **窗口启动延迟的确切分布未测量** —— 观测到钉住发生在 10–30 秒内，但无法给出可靠
   P50/P95。
5. **仅覆盖 `plus` / `team` 订阅账号。** API key 账号（`~/.codex-runway/accounts/api-*`）
   未测试 `/wham/usage` 是否返回 `rate_limit`。
6. **多 limit family 未测。** 源码支持 `x-codex-bengalfox-*` 等多额度族
   （`rate_limits.rs:263-268`），本报告只覆盖默认 `x-codex-*`。

### ⚠️ 关于本文件本身的冲突提示

写本文件时发现**同一路径已被另一个并发进程写入过一份内容不同的报告**（mtime 10:59 → 11:16）。
本报告覆盖了它，原内容备份于 `/tmp/codexresearch/sibling_report_BACKUP.md`。

**两份报告存在事实冲突**，需上层裁决：

| 议题 | 备份版本的说法 | 本报告（有受控实验） |
|---|---|---|
| 周窗口是否由请求开启 | 「**不**由请求开启（固定周期）」 | **存疑，未定论**；我数据中 19/27 首见即全新、锚点间隔非 7 天，与「固定周期」直接矛盾 |
| `x-codex-*` 头 | 引 headroom 称「已弃用、不再返回」 | **实测确认仍在返回**（`/codex/responses`） |
| `generate:false` prewarm | 未提及 | 实测可拿到额度数据；**是否启动窗口待验证** |

**建议以本报告的实测结论为准**，因为彼版对应议题均为二手引用，其中一条已被我的抓包直接推翻。

---

## 8. 来源

### 一手：上游源码（`openai/codex` @ `1cc7e2361237ce7244430ee1d581c77f95c57ac8`）

permalink 前缀：`https://github.com/openai/codex/blob/1cc7e2361237ce7244430ee1d581c77f95c57ac8/`

- `codex-rs/codex-api/src/rate_limits.rs` — 头解析（`parse_rate_limit_for_limit` :57；窗口字段构造 :68-80；多额度族 :263-268）
- `codex-rs/codex-api/src/sse/responses.rs:43` — SSE 响应头 → 额度快照
- `codex-rs/codex-api/src/endpoint/responses_websocket.rs:774` — WS `codex.rate_limits` 事件解析
- `codex-rs/codex-api/src/endpoint/responses_websocket.rs:987` — `generate: Some(false)` prewarm 帧
- `codex-rs/core/src/client.rs:17-25, 1900, 1981` — prewarm 语义注释（"not an inference request"）
- `codex-rs/backend-client/src/client/rate_limit_resets.rs:124-139` — `/wham/usage`、`/api/codex/usage` 路径构造
- `codex-rs/codex-backend-openapi-models/src/models/rate_limit_window_snapshot.rs` — `reset_after_seconds` / `limit_window_seconds` / `reset_at` / `used_percent`
- `codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_details.rs` — `primary_window` / `secondary_window`
- `codex-rs/protocol/src/protocol.rs:2349-2401` — `RateLimitSnapshot` / `RateLimitWindow`
- `codex-rs/login/src/auth/manager.rs:212, 1717, 1595-1605` — OAuth refresh URL / client_id / persist_tokens
- `codex-rs/login/src/oauth/client.rs:80-89` — `grant_type=refresh_token` 参数
- `codex-rs/core/tests/suite/client.rs:3384-3388` — 精确头名测试
- `codex-rs/tui/src/app/rate_limit_refresh.rs`、`codex-rs/tui/src/app_event.rs:216-232` — TUI 侧额度刷新来源枚举

### 一手：官方文档

- [Codex 手册（learn.chatgpt.com/docs/codex-manual.md）](https://learn.chatgpt.com/docs/codex-manual.md) — 额度章节（"local messages per five-hour period"）、usage dashboard、credits 费率；**未定义窗口起点**
- [Codex 文档索引（llms.txt）](https://learn.chatgpt.com/llms.txt)
- [Paid weekly Work and Codex rate limit resets](https://help.openai.com/zh-hans-cn/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets) — 抓取被 403 拦截，**未能读取正文**
- [How banked Codex resets work](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work) — 同上，403

### 一手：社区先例源码

- [almeidasrenato/ai-reset-runner](https://github.com/almeidasrenato/ai-reset-runner) — `Sources/AIResetRunner/Pinger.swift`、`Scheduler.swift`、`Usage.swift`
- [shnksi/optimize-ai-limits](https://github.com/shnksi/optimize-ai-limits) — `src/parsers.mjs`、README
- [headroomlabs-ai/headroom `codex_rate_limits.py`](https://github.com/headroomlabs-ai/headroom/blob/2f2950a6/headroom/subscription/codex_rate_limits.py)

### 社区议题（二手，含可复核数据）

- [openai/codex#36313](https://github.com/openai/codex/issues/36313) — 一周内 9 个周窗口锚点，每个 = 活动时刻 + 7d
- [openai/codex#35952](https://github.com/openai/codex/issues/35952) — 用户自述「窗口在首条消息开始」
- [openai/codex#32607](https://github.com/openai/codex/issues/32607) — 重置后首读即为 79% 的边界情形
- [lidge-jun/opencodex#6056](https://github.com/lidge-jun/opencodex/pull/6056)、[WSL043/dsh-codex-subscription#50](https://github.com/WSL043/dsh-codex-subscription/pull/50)

### 本机实测数据

- `~/.codex/sessions/**/rollout-*.jsonl` + `~/.codex/archived_sessions/**`：689 文件 / 10,901 条额度观测 / 56 个 5h 锚点 / 27 个周锚点
- 真实 `GET https://chatgpt.com/backend-api/wham/usage`（只读）
- 真实 `POST https://chatgpt.com/backend-api/codex/responses`（SSE）与 `wss://`（WebSocket `generate:false`）
- `codex-cli 0.153.4`（`~/.local/bin/codex`）、`codex exec --help`
- 6 个托管账号（`~/.codex-runway/accounts/*/auth.json`）的窗口状态抽样


---

## 10. 用户核实后的补充实验（2026-09-28 下午）

### 目标澄清

用户澄清真实诉求**不是**「额度耗尽时触发」，而是：

> **在 5h 计时窗口结束后，及时开启一个新的 5h 窗口。**

这个区别很重要：耗尽（used=100%）只是「窗口结束」的一种成因；窗口也可能是
**自然到期**（到 resets_at 时刻归零）。

### 窗口结束的两种形态（实测）

从单个会话 `rollout-2026-09-23T15-45-48-…jsonl`（650 条观测）抓到三次真实结束：

| 形态 | 窗口结束前 | 新窗口首读 | 新窗口起点距离首读 |
|---|---|---|---|
| **自然到期** | 08:00:02 `used=69%` `reset距=-0.04分` | 08:00:18 `used=0%` `reset距=299.73分` | **0.27 分** |
| **额度用满** | 09:41:31 `used=100%` `reset距=71.59分` | 09:42:44 `used=0%` `reset距=299.87分` | **0.13 分** |
| 额度用满 | 08:49:14 `used=100%` `reset距=250.79分` | 08:50:25 `used=0%` `reset距=122.70分` | 177 分（受跨账号数据污染，存疑） |

**关键结论**：两种形态下，新窗口都**由紧随其后的那次请求开启**——首读距离
窗口起点仅 **0.1–0.3 分钟**。这正是探针要对准的时刻。

### `model_provider` 路由加固（子代理指出的漏洞，已验证并修复）

子代理指出：探针命令若不带 provider 覆盖，CLI 会从 `~/.codex/config.toml` 解析
provider——而这个文件**正是本应用在切号时会改写的**。一旦用户切到中转账号，
触发请求会打到中转，**中转没有订阅窗口可开**，探针会静默失败。

**已实测验证**：加上 `-c model_provider="openai"` 后，请求确实打到官方后端，
返回官方额度提示（`You've hit your usage limit … try again at 3:52 PM`）。
该 flag 合法且必要，现已固化进探针。

### 真实「等待重置」样本

当前账号 `extu@vsdev.site` 正处于目标状态：

```
used = 100%
resetAfter = 15982s ≈ 4.44h
官方 CLI 提示：try again at 3:52 PM (CST) = 07:52 UTC
推算：03:26 UTC + 4.44h ≈ 07:52 UTC  ✅ 与官方提示完全吻合
```

这是「窗口结束 → 开启新窗口」链路最干净的真实验证机会。

### 仍未净验证

**探针在窗口结束的那一刻触发，是否真能开启新窗口**——需要等 `extu` 的窗口在
07:52 UTC 结束。本报告的 §8 记录的历史数据（首读距起点 0.1–0.3 分）已构成强
间接证据，但未做受控实验。
