# New API 额度与用量接口调研

> **目标**：让 CodexRunway 面板显示 New API（AI 中转网关）账号的**剩余额度**与**用量统计**。
> **调研对象**：用户自建站点 `ai.apizn.com`（API 智纽，New API `v1.0.0-rc.34-apizn.20260914.27-stream-probes`）。
> **方法**：对目标站点只读实测 + 上游 `QuantumNous/new-api` 源码 + 官方 API 文档三方交叉验证。

## 0. 结论速览

| 问题 | 结论 | 依据 |
| --- | --- | --- |
| 只用 `sk-` key 能否查额度/用量？ | **能**（`/v1/dashboard/billing/*`） | 实测 200 |
| New API 原生 `/api/user/self` 能用吗？ | **不能**，401 | 实测 |
| `total_usage` 单位？ | **$0.01（美分）** | **源码** `amount * 100` |
| `hard_limit_usd` 是什么？ | 额度上限（美元）；**该 key 为「无上限」哨兵** | **源码** `token.UnlimitedQuota` 分支 |
| 能算「剩余百分比」吗？ | **不能**（未设限额） | 源码 + 实测 |
| 能拿分时段用量吗？ | **不能**，日期参数被忽略 | 实测 |
| 用量统计可行吗？ | **能**，走本地会话日志 | 实测日志结构 |

---

## 0.5 「登录拿余额」的可行性与方案对比

**问题**：给 newapi 账号加一个登录入口，登录后是否就能读到余额？

**答案**：能，但**登录必须产出的是「系统访问令牌」（PAT）**，而不是网页 session。原因与依据如下。

### 0.5.1 三套凭据的边界（源码 + 实测）

| 凭据 | 获取方式 | 可访问 | 实测 |
| --- | --- | --- | --- |
| **API Key** (`sk-...`) | 已在用 | `/v1/*`（含 billing 两个端点） | ✅ 200 |
| **系统访问令牌**（PAT / AccessToken） | 网页「个人设置 → 系统访问令牌」生成 | **`/api/*` 全部 dashboard 端点** | 见 §0.5.2 |
| **网页 session** | 登录后 cookie | `/api/*`（浏览器会话） | — |

用 sk- key 访问 `/api/*` 实测全部 401：

```
[401] /api/user/self            → {"code":"AUTH_UNAUTHORIZED", ...}
[401] /api/user/token/status    → {"code":"AUTH_UNAUTHORIZED", ...}
[401] /api/user/self/groups     → {"code":"AUTH_UNAUTHORIZED", ...}
```

而 `/api/status`、`/api/pricing` **完全公开**（无凭据 200）。

### 0.5.2 PAT 能读到什么（源码：`controller/user.go` `buildSelfUserData`）

`GET /api/user/self` 需要的凭据由中间件 `UserAuth` → `classifyDashboardCredential` 判定，其**明确接受 PAT**：

```go
// middleware/auth.go
patUser, err := model.ValidateAccessToken(raw)      // 校验 PAT
if err != nil { return ..., dashboardCredentialPAT, err }
...
return user, service.AuthIdentity{UserID: user.Id, ...}, dashboardCredentialPAT, nil
```

返回字段（`buildSelfUserData`，节选关键项）：

| 字段 | 含义 |
| --- | --- |
| **`quota`** | **剩余额度** ← 用户想要的「余额」 |
| **`used_quota`** | 已用额度 |
| **`request_count`** | 请求次数 |
| `group` | 分组（影响倍率） |
| `aff_quota` / `aff_history_quota` | 邀请返利额度 |
| `username` / `display_name` / `email` / `role` / `status` | 身份信息 |

→ **有了 PAT 就能拿到真正的「剩余额度」**，这比 §1.2 的 billing 端点（只能给出「无上限」哨兵）信息量大得多。

### 0.5.3 PAT 不能纯程序化获取

`GET|POST /api/user/self/token` 生成 PAT，但其实现要求「安全验证」：

```go
// controller/access_token.go
func GenerateAccessToken(c *gin.Context) {
    if middleware.RequireSecurityProof(c, service.VerificationOperation{
        Scope: service.VerificationScopeAccessTokenGenerate,
    }) == nil { return }          // ← 必须通过安全验证（需交互）
    ...
    key, err := common.GenerateRandomKey(29 + common.GetRandomInt(4))
    common.ApiUpdateUserAccessToken(id, key)
    c.JSON(200, gin.H{"success": true, "data": key})
}
```

要点：
- 生成需通过 `RequireSecurityProof`，**不是纯 API 调用可得**
- 生成会**覆盖旧 token**（`UpdateUserAccessToken` 而非追加），即 PAT 是「每用户唯一、可再生」
- 另有 `DELETE /api/user/self/token` 可吊销

`POST /api/user/login` 登录路由**存在**，但带 `TurnstileCheck()` 人机验证，且返回的是 session cookie；从 session 再换 PAT 仍需过 `RequireSecurityProof`。

### 0.5.4 三种实现路线对比

| 路线 | 用户操作 | 能拿到「余额」 | 复杂度 | 稳定性风险 |
| --- | --- | --- | --- | --- |
| **A. 只读 sk- key**（现状可做） | 无需额外操作 | ❌ 只能拿「已用」（且无上限时无百分比） | 低 | 低 |
| **B. 引导用户填 PAT**（推荐） | 去网页「个人设置 → 系统访问令牌」复制一段填写 | ✅ `quota` + `used_quota` + `request_count` | 中 | 低（PAT 长期有效，除非用户重新生成） |
| **C. 应用内嵌登录窗口** | 在 app 内输入账号密码/走 OAuth | ✅（换到 PAT 后） | **高** | **高**：需处理 Turnstile 人机验证、2FA、OAuth（GitHub/LinuxDO/Passkey）、密码加密（`PasswordLoginEncryptionEnabled`），任一环节变更即失效 |

**建议选 B**：
- 拿到的是**最完整的额度信息**（含真正的剩余额度）
- 避开 Turnstile / 2FA / OAuth 的脆弱耦合
- 用户操作成本仅「复制一段 token」
- 凭据应存进 Keychain（复用现有 `ProxyCredentialStore` 的模式），**不落明文**

**C 的风险**：本站在 `/api/status` 中显示 `passkey_login = true`、`github_oauth = true`、`linuxdo_oauth = true`、`password_login_enabled = true` —— 登录方式多且可能被管理员调整，内嵌登录的实现与维护成本远高于收益。

### 0.5.5 实测验证（用真实 PAT 跑通）

已用用户提供的 PAT 实测，**全部假设得到验证**：

```
GET /api/user/self   Authorization: Bearer <PAT>   → 200
  id=68  username=qianjh  display_name=Rory  role=1  status=1  group=default
  quota      = 954,911        ← 剩余额度
  used_quota = 31,545,089     ← 已用额度
  request_count = 1,317
  aff_quota = 0  aff_history_quota = 0
```

**单位换算得到确证**：`quota + used_quota = 32,500,000`，÷ `quota_per_unit`(500000) = **恰好 $65.0000**（整数）→ 换算比正确，且该账号总额度为 $65（充值额）。

**三个口径的用量对比（重要发现）**：

| 口径 | quota | 折美元 |
| --- | --- | --- |
| **用户级** `used_quota`（PAT `/api/user/self`） | 31,545,089 | **$63.09** |
| 各 token `used_quota` 合计（PAT `/api/token/`） | 31,478,066 | $62.96 |
| **单个 token** `ccodex` | 30,873,193 | **$61.75** |
| sk- key 的 `billing/usage` ×100 | 30,927,626 | $61.86 |

**sk- key 与 token 的对应关系已确认**：

token 列表（PAT 可见 4 个，均 `unlimited_quota=true`）：

| id | name | key 前缀（打码显示） | used_quota |
| --- | --- | --- | --- |
| 24 | **ccodex** | `KOEf**********KPnf` | 30,873,193 |
| 191 | kunkun | `et7W**********93hP` | 567,154 |
| 234 | cc | `bfTV**********wtnf` | 19,370 |
| 231 | gemini | `y9lQ**********d8x3` | 18,349 |

应用持有的 sk- key 前缀为 `sk-KOEfR...`，**精确匹配 `ccodex`**。

→ **结论修正**：sk- key 的 billing 端点返回的是**该 token 自身的用量**，**不是**用户维度。此处此前推测有误，已由实测纠正。

→ 差额 $1.34 = 其余 3 个 token 的用量（`cc` + `gemini` + `kunkun` ≈ 604,873 quota ≈ $1.21，加上零星差异）。

**因此两种展示口径可选**：

| 口径 | 数据源 | 含义 |
| --- | --- | --- |
| **Token 级**（与账号一一对应） | sk- key → `billing/usage` | 该 key 自己的消费 |
| **用户级**（全部 key 合计） | PAT → `/api/user/self` | 你在这个站点的总消费 |

→ 卡片上宜**同时展示**，或明确标注口径，避免用户误解。

### 0.5.6 降级策略（重要）

PAT 与 sk- key 是**两套独立凭据**，应支持「只填 sk- key」的降级路径：

| 已提供 | 显示内容 |
| --- | --- |
| sk- key + PAT | 剩余额度、已用额度、请求次数（**完整**） |
| 仅 sk- key | 仅「已用金额」（§1.3）；无上限时不显示百分比 |
| 都没有 | 现有提示「API 账号不显示 ChatGPT 额度进度条」 |

---

## 1. 额度与用量接口

### 1.1 认证

实测：**只需 `Authorization: Bearer sk-...`**。官方文档示例带 `New-Api-User` 头，但本站点实测**加不加结果完全相同**，故可省略。

sk- key **不能**访问 `/api/*` 原生端点：

```
GET /api/user/self   Authorization: Bearer sk-...  →  401
  {"code":"AUTH_UNAUTHORIZED","message":"Unauthorized, invalid access token","success":false}
```

### 1.2 额度上限

```
GET {baseURL}/v1/dashboard/billing/subscription
Authorization: Bearer sk-...
```

实测响应：

```json
{
  "object": "billing_subscription",
  "has_payment_method": true,
  "soft_limit_usd": 100000000,
  "hard_limit_usd": 100000000,
  "system_hard_limit_usd": 100000000,
  "access_until": 0
}
```

**源码解读**（`controller/billing.go` `GetSubscription`）：

```go
quota := remainQuota + usedQuota          // 总额度 = 剩余 + 已用
amount := float64(quota)
switch operation_setting.GetQuotaDisplayType() {
case operation_setting.QuotaDisplayTypeCNY:
    amount = amount / common.QuotaPerUnit * operation_setting.USDExchangeRate
case operation_setting.QuotaDisplayTypeTokens:
    // tokens 保持原值
default:                                   // USD（本站即此分支）
    amount = amount / common.QuotaPerUnit
}
if token != nil && token.UnlimitedQuota {
    amount = 100000000                     // ← 无上限哨兵
}
```

→ 字段语义是**美元额度**，且**该 key 被标记为无上限**，所以三个 limit 都是哨兵值。
→ **无法计算「剩余额度」或百分比**，只能显示「已用」。

### 1.3 已用额度

```
GET {baseURL}/v1/dashboard/billing/usage
Authorization: Bearer sk-...
```

实测响应：

```json
{"object": "list", "total_usage": 6174.6386}
```

**源码解读**（`controller/billing.go` `GetUsage`）：

```go
amount := float64(quota)
switch operation_setting.GetQuotaDisplayType() {
case operation_setting.QuotaDisplayTypeCNY: ...
case operation_setting.QuotaDisplayTypeTokens: ...
default:
    amount = amount / common.QuotaPerUnit
}
usage := OpenAIUsageResponse{
    Object:     "list",
    TotalUsage: amount * 100,              // ← 乘 100
}
```

→ `total_usage` 单位是 **$0.01（美分）**，与[官方文档](https://doc.newapi.pro/en/api/fei-account-billing-panel/)「measured in $0.01 USD units」一致。

**本账号实算**：

| 值 | 换算 |
| --- | --- |
| `total_usage = 6174.6386` | **已用 $61.75** |
| `hard_limit_usd = 100000000` | 无上限哨兵 |

**日期参数被忽略**（实测三次返回完全相同）：

| 请求 | 返回 |
| --- | --- |
| 无参数 | `6174.6386` |
| `2020-01-01 ~ 2030-01-01` | `6174.6386` |
| `2026-09-16 ~ 2026-09-17`（一天） | `6174.6386` |

→ 源码中 `GetUsage` 确实**不读任何日期参数**，返回的是**累计总额**。

### 1.4 两个重要开关（影响返回内容）

源码中两处会影响结果的配置：

| 配置 | 影响 |
| --- | --- |
| `common.DisplayTokenStatEnabled` | 为 true 时返回**该 token** 的额度；否则返回**该用户**的总额度 |
| `operation_setting.GetQuotaDisplayType()` | `USD` / `CNY` / `TOKENS`，决定换算方式 |

**实现必须按运行时探测处理，不能硬编码**（见 §4）。

---

## 2. 公开端点（无需认证）

| 端点 | 用途 | 实测 |
| --- | --- | --- |
| `GET /api/status` | 版本、配额设置、功能开关 | 200 |
| `GET /api/pricing` | 模型价格表（36 个模型，含 `model_ratio`/`completion_ratio`/`cache_ratio`） | 200 |

**不存在的端点**（实测排除，避免误用）：

| 端点 | 结果 |
| --- | --- |
| `GET /v1/dashboard/billing/credit_grants` | **404** `Invalid URL` |

→ 可用端点就是 `subscription` + `usage` 两个，**没有**能返回「剩余额度」的独立端点。

`/api/status` 关键字段（本站点实测）：

```json
{
  "version": "v1.0.0-rc.34-apizn.20260914.27-stream-probes",
  "quota_per_unit": 500000,
  "quota_display_type": "USD",
  "display_in_currency": true,
  "usd_exchange_rate": 7.3,
  "system_name": "API 智纽"
}
```

响应头亦带 `x-new-api-version`，可用于版本探测。

> ⚠️ 版本号带 `apizn` 定制后缀，说明该站点**非纯上游**。虽然 `billing.go` 的逻辑与其行为一致，但**不能假定所有行为都等同上游**。

---

## 3. 限流行为（实测，实现必须处理）

连续快速请求会触发 **403 Forbidden**（一次连续探测 4 个端点后即被拒），稍后恢复。

**要求**：
- 查询间隔保守（建议 ≥60s，与现有账号额度刷新节奏一致）
- 处理 403/429，指数退避
- 额度查询失败**不得影响账号可用性**（复用现有 `lastError` 机制，只提示不阻断）

---

## 4. 实现要点

### 4.1 baseURL 从哪里来（关键缺口）

实测确认当前 `AccountStore` 的 `ManagedAccount` **没有 baseURL 字段**，且 `CodexAuth.apiKey(apiKey:baseURLHint:)` 的 `baseURLHint` 参数**被丢弃（永未使用）**——是个未实现的预留接缝。

**可靠来源**：`~/.codex/config.toml`

```toml
model_provider = "custom"

[model_providers.custom]
base_url = "https://ai.apizn.com/v1"

[model_providers.codex_local_access]
base_url = "https://ai.apizn.com/v1"
```

→ 需**新增轻量 TOML 读取**（现有代码无 TOML 解析），解析 `[model_providers.*]` 的 `base_url`。

### 4.2 单位判定（不能硬编码）

因站点可配置 `quota_display_type`，建议**运行时探测**：

1. 先读 `GET /api/status` → `quota_display_type`、`quota_per_unit`
2. `USD` → `total_usage / 100` = 美元
3. 若 `/api/status` 不可用 → 回退：拿 `total_usage` 与本地统计的 token 量做**量级合理性校验**，异常时只显示原始值并标注单位未知

### 4.3 「无上限」的呈现

`hard_limit_usd == 100000000` 时应显示为：

> 已用 **$61.75**（此 key 未设额度上限）

而**不是**进度条或百分比 —— 进度条会误导。

### 4.4 用量统计走本地

服务端拿不到分时段用量（§1.3），且限流敏感。**用量统计从本地会话日志算**。

日志结构（实测）：

```json
{"type": "token_usage_record",
 "payload": {
   "usage":              {"input_tokens":28398,"cached_input_tokens":19328,"output_tokens":184,"total_tokens":28582},
   "turn_token_usage":   { ... },
   "thread_token_usage": { ... }
 }}
```

**口径验证（重要）**：`usage` 是**单次增量**，`turn_token_usage` / `thread_token_usage` 是**累计值**。
实测单个会话：`Σ usage.total_tokens = 7,391,771` **恰好等于**最后一条的 `thread_token_usage.total_tokens`。
→ **必须累加 `usage`，不可累加后两者**（否则重复计数）。

`sessions/**/*.jsonl` 的 `session_meta` 含 `model_provider`、`cwd`、`timestamp`；`turn_context` 含 `model`。

**账号归属判据（实测发现存在归属歧义，需谨慎）**：

近 30 天按 `model_provider` 分组的 token 量：

| provider | 30 天 total_tokens |
| --- | --- |
| `custom` | 347,591,176 |
| `openai` | 110,045,616 |

按时间线看，`openai` 从 2026-09-14 才开始出现，与 `custom` 并存至今；`openai` 会话均来自 VS Code 扩展（`source=vscode`）。

`config.toml` 中 `custom` 与 `codex_local_access` **都指向**同一 newapi 地址，但**日志里不记录 base_url**，因此：

- **不能按 provider 名过滤**（名字不稳定：`custom` / `codex_local_access` / `openai` 三种都出现过）
- `provider=openai` 的会话**是否走 newapi 无法从日志直接判定** —— 若它实际直连官方，则不该计入 newapi 用量

**因此「用量统计」有两种口径，需产品决策**：

| 口径 | 含义 | 风险 |
| --- | --- | --- |
| **A. 按 provider 白名单** | 只统计 `custom` + `codex_local_access` | 可能漏掉走 newapi 但标 `openai` 的会话 |
| **B. 全部会话** | 统计所有本地会话 | 可能把官方直连的量算进 newapi，虚高 |

**建议**：先落 A（保守、不虚高），并在 UI 标注口径；后续若能确定 newapi 的 provider 名集合，再调整。

**量级校验**：服务端累计已用 $61.75，而 A 口径下 30 天约 3.48 亿 token（单模型估算 $50~$380/30天）。若 $61.75 是全部历史累计，与 A 口径量级**不矛盾**；若按 B 口径则更偏高。→ 侧面支持选 A。

现存 `UsageCostLogParser` 已能解析 `token_usage_record`，但**不区分 provider**，需扩展。

---

## 5. 待确认 / 存疑

- [ ] `DisplayTokenStatEnabled` 在目标站点的取值（影响返回「该 token 额度」还是「该用户总额度」）—— 当前 key 无上限，两种取值下都为哨兵，无法区分
- [ ] 能否免登录拿到该用户的**剩余额度**（当前 key 无上限，无法验证该路径）
- [ ] 若用户配置了真实限额，`hard_limit_usd` 的语义是否可直接当「总额度」用（源码看是 `remain + used`，应可用）
- [ ] 403 的确切触发阈值（仅观测到"连续 4 次后"，未测精确值）

---

## 6. 来源

| 结论 | 来源 |
| --- | --- |
| **`total_usage` 单位 = $0.01** | 源码 [`controller/billing.go`](https://github.com/QuantumNous/new-api/blob/main/controller/billing.go) `GetUsage`：`TotalUsage: amount * 100`；[官方文档](https://doc.newapi.pro/en/api/fei-account-billing-panel/)「measured in $0.01 USD units」 |
| **无上限哨兵 100000000** | 源码 `GetSubscription`：`if token.UnlimitedQuota { amount = 100000000 }` |
| DATE 参数无效 | 源码 `GetUsage` 不读日期参数；实测三次返回相同 |
| 端点路径与认证要求 | [官方 API 文档：Account Billing Dashboard Module](https://doc.newapi.pro/en/api/fei-account-billing-panel/) |
| `quota_per_unit=500000` 等站点配置 | 实测 `GET /api/status` |
| 端点可用性 / 401 / 限流 / 日期忽略 | 对 `https://ai.apizn.com` 的只读实测（未外传密钥） |
| 本地日志结构、增量口径、provider 分布 | 实测统计 `~/.codex/sessions` 与 `~/.codex/config.toml` |

---

# 第二部分：需求落地方案

> 以下基于用户确认的产品需求，逐项对齐代码落点。**本部分只做设计，尚未改代码。**

## 1. 需求清单

| # | 需求 | 可行性 | 关键依据 |
| --- | --- | --- | --- |
| 1 | 新增 `newapi` 账号类型 | ✅ | `ManagedAuthMode` 现仅 `oauth`/`apiKey`，扩展即可 |
| 2 | **仅 key 时**也能查该 key 用量（兜底） | ✅ | `/v1/dashboard/billing/*`，实测 200 |
| 3 | PAT 作为**可选**配置项 | ✅ | PAT 存 Keychain，缺失则降级 |
| 4 | 有 PAT 时，切换后可见完整个人额度与面板信息 | ✅ | `/api/user/self` 返回 `quota`/`used_quota`/`request_count` |
| 5 | 展示：余额、今日用量、今日 token、近 7 日 token | ✅ | PAT `/api/log/self` 按天聚合 |
| 6 | 按 key 显示用量详情（每条请求的字段列表） | ✅ | `/api/log/self` 单条含 18 个字段 |
| 7 | 状态栏只显示「今日用量 + 余额」，区别于官号进度条 | ✅ | 走现有 `.text` 样式，改 `statusText` 即可 |
| 8 | 复用现有 Token 用量面板 | ✅ | `TokenUsageHeatmapBuilder.makeSeries(dailyTokens:)` 直接可喂 |

## 2. 数据来源与降级

| 场景 | 数据源 | 可得内容 |
| --- | --- | --- |
| **仅 sk- key** | `/v1/dashboard/billing/{subscription,usage}` | 该 key 已用金额（§1.3）。无「余额」概念 |
| **sk- key + PAT** | 上述 + `/api/user/self` + `/api/log/self` | 余额、已用、请求数、每日明细、逐请求列表 |

**降级规则**：PAT 缺失时不报错，仅少显示余额与明细；key 查询失败不影响账号可用性。

## 3. 落点设计

### 3.1 账号类型与配置

- `ManagedAuthMode` 新增 `case newAPI`
- `ManagedAccount` 新增可选字段：
  - `newAPIBaseURL: String?` —— 服务地址（从 `~/.codex/config.toml` 推导或用户填写）
  - PAT **不落 `index.json`**，存 Keychain（复用 `ProxyCredentialStore` 模式，与账号 id 关联）
- `CodexAuth.apiKey(apiKey:baseURLHint:)` 中已存在但被丢弃的 `baseURLHint` 参数 —— 可正式启用

> `AGENTS.md` 要求：多账号凭据仅允许存 `~/.codex-runway/accounts/<id>/auth.json`（0700/0600）；
> PAT 是**额外凭据**，宜存 Keychain 而非 index。需同步更新该文档的隐私约定。

### 3.2 服务地址来源（`~/.codex/config.toml`）

实测用户配置：

```toml
model_provider = "custom"
[model_providers.custom]
base_url = "https://ai.apizn.com/v1"
```

需新增**轻量 TOML 读取**（现有代码无 TOML 解析），只解析 `[model_providers.*]` 段的 `base_url`。
`base_url` 带 `/v1` 后缀，调用 `/api/*` 时需去掉。

### 3.3 单位与换算（不可硬编码）

- `quota_per_unit` 从 `/api/status` 读取（本站 500000）
- `quota_display_type` 决定语义（本站 `USD`）
- `used_quota`/`quota` 为 quota 单位 → ÷`quota_per_unit` = 美元
- `/v1/dashboard/billing/usage` 的 `total_usage` 已是 `$0.01` 单位（源码 `amount * 100`）
- **两套单位不同，不可混用**

实测校准：`954911 + 31545089 = 32500000`，÷500000 = **$65.00**（整数）→ 换算正确。

### 3.4 面板呈现

| 位置 | 内容 |
| --- | --- |
| 账号卡片 | 余额 / 总额 + **已用百分比**（有 PAT 时）；仅 key 时显示已用金额 |
| 详情页 | 余额、今日用量($ + token)、近 7 日 token、逐请求列表 |
| **Token 用量面板** | **复用** `TokenUsageHeatmapBuilder.makeSeries(dailyTokens:)`，喂服务端按天聚合的 `[dayKey: tokens]` |
| 状态栏（`.text` 样式） | 「今日 $X · 余额 $Y」 |

**关于进度条**：有 PAT 时 `quota` 是真实剩余额度 → **可以**做进度条（与官方账号一致）；
仅 key 时无上限哨兵 → 不做进度条，只显示金额。这与需求 7「区别于官号进度条显示」一致。

### 3.5 热力图数据缺口（已诊断）

用户截图中 Token 用量面板几乎全空。实测诊断：

- 本地 `~/.codex/sessions` **确有数据**（如 09-10 有 1.7 亿 token）
- 但面板走的是 Codex **官方多端统计**通道，对 API Key/newapi 账号**无数据**

→ 用服务端 `/api/log/self` 聚合，可填满该面板。实测按天聚合结果：

```
2026-09-10  tokens=141,661,050  $34.12  请求=725
2026-09-12  tokens= 21,386,342  $ 9.96  请求= 72
2026-09-16  tokens= 45,456,846  $14.20  请求=225
```

## 4. 风险与约束

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| **限流 403** | 实测连续请求会被拒 | 低频（≥60s）、指数退避、失败不阻断 |
| **日志分页开销** | 1129 条需多页拉取 | 只为「详情/历史」按需拉；卡片只用聚合接口 |
| 日志仅 7 天 | 实测覆盖 7 天 | 更长趋势需本地日志补充 |
| `/api/data/self` 限 1 个月 | 实测报错 | 控制时间窗 |
| 无权限端点 | `dashboard`/`amount` 返回 403 | 不依赖 |
| PAT 明文风险 | — | 存 Keychain；提示用户可随时轮换（生成会覆盖旧值） |

## 5. 待确认

- `newapi` 账号是否与 Codex OAuth 账号**共用**「切换」语义（切换会改 `auth.json` 并重启 Codex）？
- 状态栏在 newapi 账号下，`.text` 样式的具体文案格式
- 今日用量的「今日」以服务端时区还是本地时区为准（服务端时间戳为本地时区秒值）
