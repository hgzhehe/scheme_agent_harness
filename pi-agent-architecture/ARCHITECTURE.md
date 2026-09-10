# Pi 完整架构说明

> 对象：`@earendil-works/pi-coding-agent` v0.84.3
> 上游：monorepo `github.com/earendil-works/pi-mono`，包目录 `packages/coding-agent`
> 本文是综合 `docs/` 官方文档整理出的架构总览，细节以 `docs/` 内各篇为准。

---

## 1. 定位与设计哲学

Pi 是一个**极简终端编码 harness（coding harness）**，不是一个大而全的 IDE agent。

- **核心小，能力外置**：核心只提供 `read` / `write` / `edit` / `bash` 四个默认工具与 agent 循环；其余能力通过扩展、Skills、Prompt 模板、主题、Packages 添加。
- **不内置常见“重”功能**（官方明确立场）：
  - No MCP —— 用带 README 的 CLI 工具（Skills），或写扩展加 MCP。
  - No sub-agents —— 用 tmux 起多个 pi，或写扩展。
  - No permission popups —— 用容器 / 自己写确认扩展。
  - No plan mode —— 写计划到文件，或写扩展。
  - No built-in to-dos —— 用 TODO.md，或写扩展。
  - No background bash —— 用 tmux。
- **四种运行形态**：interactive（TUI）、print/JSON、RPC（进程集成）、SDK（嵌入 Node 应用）。
- **一切以事件流为核心**：agent 的每一步（turn、message delta、tool 执行、压缩、重试）都通过事件暴露，TUI/RPC/JSON/SDK 都是同一事件流的不同消费者。

---

## 2. 包分层（monorepo 架构）

`pi-mono` 按职责拆包，`pi-coding-agent` 位于最上层做集成：

```
┌──────────────────────────────────────────────────────────────┐
│ @earendil-works/pi-coding-agent   ← CLI / TUI / RPC / SDK      │
│   模式层 modes/  +  核心编排 core/  +  内置工具 core/tools/     │
├──────────────────────────────────────────────────────────────┤
│ @earendil-works/pi-client         ← 客户端 / RPC client        │
│ @earendil-works/pi-protocol       ← 线协议类型                 │
├──────────────────────────────────────────────────────────────┤
│ @earendil-works/pi-agent-core     ← Agent 循环、消息类型、事件  │
│ @earendil-works/pi-tui            ← 终端 UI 组件系统           │
├──────────────────────────────────────────────────────────────┤
│ @earendil-works/pi-ai             ← LLM provider 抽象 + 模型   │
│    （另有 telemetry 包）                                       │
└──────────────────────────────────────────────────────────────┘
```

| 包 | 职责 |
|----|------|
| `pi-ai` | 各 provider API 抽象、消息/`Usage`/`StopReason` 基础类型、`getModel`、`ModelRuntime` 的底层凭证存储（`CredentialStore`） |
| `pi-agent-core` | `Agent` 类、agent 循环、`AgentMessage` 联合类型、`AgentEvent` |
| `pi-tui` | `Component` / `Focusable` 接口、`Text`/`Box`/`Container`/`Markdown`/`Image`/`Editor`/`Input`、overlay、主题、渲染 |
| `pi-protocol` / `pi-client` | 线协议与客户端，供 RPC / 远程使用 |
| `pi-coding-agent` | 会话、资源加载、压缩、扩展运行时、内置工具、四种模式、包管理 |

本机实际只安装了顶层 `pi-coding-agent`（其余作为依赖解析），源码入口导出见 `docs/sdk.md` 的 *Exports* 一节。

`pi-coding-agent` 内部 `dist/` 目录结构（即模块划分）：

```
dist/
├── cli.js / rpc-entry.js       入口
├── config.js                  路径/资源解析（getPackageDir 等）
├── migrations.js              会话格式迁移
├── package-manager-cli.js     包管理命令
├── core/                      ★ 核心编排
│   ├── agent-session.js       AgentSession：单会话生命周期
│   ├── agent-session-runtime.js  AgentSessionRuntime：会话替换
│   ├── agent-session-services.js cwd 绑定服务装配
│   ├── session-manager.js     JSONL 会话树持久化
│   ├── messages.js            扩展消息类型
│   ├── compaction/            compaction.ts / branch-summarization.ts / utils.ts
│   ├── tools/                 read/bash/edit/write/grep/find/ls/powershell
│   ├── extensions/            扩展宿主与类型
│   ├── export-html/           会话导出 HTML
│   └── …（auth-storage、event-bus、defaults、diagnostics…）
├── modes/
│   ├── interactive/           InteractiveMode（TUI）
│   ├── rpc/                    runRpcMode
│   └── json-event.js           runPrintMode / JSON 事件流
├── extensions/                内置扩展（含 llama）
├── server/ client/ utils/
└── bundle/                    打包产物（CLI 二进制入口）
```

---

## 3. 进程与运行模式

| 模式 | 入口 | 说明 |
|------|------|------|
| interactive（默认） | `pi` | 全屏 TUI：header / messages / editor / footer；slash 命令、`@` 文件引用、图片、外部编辑器 |
| print | `pi -p "…"` | 单次输出后退出；`--mode json` 输出结构化事件流 |
| RPC | `pi --mode rpc` | stdin/stdout 上的严格 JSONL 协议，供跨语言进程集成 |
| SDK | `import …` | 同进程 Node 嵌入，直接用 `AgentSession` |

**stdio 约定**

- RPC：**严格 LF (`\n`) 分帧**。客户端只能按 `\n` 切分；不要用 Node `readline`（它还会在 `U+2028/U+2029` 处断行，而这些字符合法出现在 JSON 字符串里）。
- JSON 模式：每行一个 JSON，首行为 session header，随后按序输出事件。`message_update` 是 **delta-only**（省略累计 `message` 与 `partial`），保持流大小线性。

三条路径共享同一套 `createAgentSessionRuntime()` + `AgentSession`，因此行为一致（`docs/sdk.md` 的 *Run Modes*）。

---

## 4. 核心对象模型

```
createAgentSessionRuntime(factory, {cwd, agentDir, sessionManager})
        │  可替换活跃会话：newSession / switchSession / fork / importFromJsonl
        ▼
  AgentSessionRuntime
        │  .session（替换后会变，需重新订阅事件）
        ▼
  AgentSession  ──持有──►  Agent (pi-agent-core)
        │                     ├─ state.messages: AgentMessage[]
        │                     ├─ state.model / thinkingLevel / systemPrompt
        │                     ├─ state.tools: AgentTool[]
        │                     └─ state.streamingMessage / errorMessage
        ├─ subscribe(listener) → unsubscribe   （事件流）
        ├─ prompt / steer / followUp
        ├─ setModel / setThinkingLevel / cycle*
        ├─ navigateTree / compact / abortCompaction / abort / dispose
        └─ bindExtensions(...)   （会话替换后需重新绑定）
```

### 4.1 `createAgentSession()` vs `createAgentSessionRuntime()`

- **`createAgentSession()`**：创建一个 `AgentSession`。通过 `ResourceLoader` 提供 extensions/skills/prompts/themes/context。返回 `{ session, extensionsResult, modelFallbackMessage? }`。
- **`AgentSessionRuntime`**：需要**替换活跃会话并重建与 cwd 绑定的运行时状态**时使用（`/new`、`/resume`、`/fork`、`/clone`、import）。这是内置 interactive/print/rpc 模式实际使用的层。
  - `runtime.session` 在替换后变化 → **必须重新订阅**、**重新 `bindExtensions`**。
  - 创建诊断在 `runtime.diagnostics`；失败则抛异常，由调用方处理。

工厂模式：`createAgentSessionServices({cwd})` 装配 cwd 绑定服务 → `createAgentSessionFromServices({services, sessionManager, sessionStartEvent})`。

### 4.2 消息模型

基础消息（`pi-ai`）：

```typescript
UserMessage      { role:"user",      content: string | (TextContent|ImageContent)[], timestamp }
AssistantMessage { role:"assistant", content: (TextContent|ThinkingContent|ToolCall)[], api, provider,
                   model, usage, stopReason, errorMessage?, timestamp }
ToolResultMessage{ role:"toolResult", toolCallId, toolName, content, details?, usage?, isError, timestamp }
```

扩展消息（`pi-coding-agent`）：

```typescript
BashExecutionMessage    { role:"bashExecution",  command, output, exitCode, cancelled, truncated,
                          fullOutputPath?, excludeFromContext?, timestamp }
CustomMessage           { role:"custom",         customType, content, display, details?, timestamp }
BranchSummaryMessage    { role:"branchSummary",  summary, fromId, timestamp }
CompactionSummaryMessage{ role:"compactionSummary", summary, tokensBefore, timestamp }
```

内容块：`TextContent` / `ImageContent(data base64, mimeType)` / `ThinkingContent` / `ToolCall(id,name,arguments)`。
`Usage = { input, output, cacheRead, cacheWrite, totalTokens, cost{…} }`。
`StopReason`：`stop | length | toolUse | error | aborted`（`pending` 仅存在于流式中间态，绝不落盘）。

### 4.3 事件流

`AgentEvent`（核心）+ `AgentSessionEvent`（会话层，含 queue/compaction/retry）：

```
agent_start / agent_end
turn_start / turn_end { message, toolResults }
message_start / message_update / message_end
tool_execution_start / tool_execution_update / tool_execution_end
queue_update { steering, followUp }
compaction_start / compaction_end
auto_retry_start / auto_retry_end
summarization_retry_scheduled / _attempt_start / _finished
agent_settled   ← 无 retry/compaction/follow-up 剩余（“真正结束”）
```

`message_update` 携带 `assistantMessageEvent`：`text_delta` / `thinking_delta` / `toolcall_start` … 用 `contentIndex` + `delta` 组装实时内容。

### 4.4 消息队列语义

- **steering**：在当前 assistant turn 的工具调用执行完后投递。
- **follow-up**：等 agent 全部工作完成后才投递。
- 交互模式：`Enter` = steering，`Alt+Enter` = follow-up，`Escape` 中止并把队列还原到编辑器。
- 设置：`steeringMode` / `followUpMode` = `one-at-a-time`（默认，等响应）| `all`。
- SDK：流式中调用 `prompt()` 必须给 `streamingBehavior`，否则报错；或直接用 `steer()` / `followUp()`。`preflightResult(bool)` 在 `prompt()` resolve 前触发一次，表示是否被接受。

---

## 5. 会话持久化与上下文构建

### 5.1 存储

- 位置：`~/.pi/agent/sessions/--<cwd 路径，/ 换成 ->--/<timestamp>_<uuid>.jsonl`
- 格式：JSONL，每行一个 entry，首行是 `session` header（无 `id/parentId`）。
- 版本：v1 线性 → v2 树（`id`/`parentId`）→ v3 把 `hookMessage` role 改名为 `custom`。加载时自动迁移到 v3。

### 5.2 Entry 类型

| type | 作用 | 是否进 LLM 上下文 |
|------|------|:----:|
| `session` | header（version/id/timestamp/cwd/parentSession?） | – |
| `message` | `AgentMessage` | ✅ |
| `model_change` | 记录模型切换 | – |
| `thinking_level_change` | 记录思考级别变化 | – |
| `compaction` | 摘要（`summary`, `tokensBefore`, `firstKeptEntryId`/`retainedTail`, `usage`, `details`） | ✅（作为 summary） |
| `branch_summary` | 分支切换时对旧分支的摘要（`fromId`） | ✅ |
| `custom` | 扩展状态持久化（`customType`, `data`） | ❌ |
| `custom_message` | 扩展注入、参与上下文的特殊消息 | ✅ |
| `label` | 书签/标记（`targetId`, `label`） | ❌ |
| `session_info` | 会话显示名（`/name`） | ❌ |

所有 entry 继承 `SessionEntryBase { type, id(8位hex), parentId|null, timestamp(ISO) }`。

### 5.3 树结构与上下文重建

entry 通过 `parentId` 构成树，**树内分支不产生新文件**；“leaf” 是当前位置。

- `buildContextEntries()`：从 leaf 回走到 root，按 compaction 规则裁剪（见 §6）。
- `buildSessionContext()`：在 entry 列表上产出给 LLM 的 message 列表 + 当前 model/thinking level。
  - `message` → 原样；`compaction` → `compactionSummary`(+`retainedTail`)；`branch_summary` → `branchSummary`；`custom_message` → `CustomMessage`；`custom` → 不产出。

### 5.4 SessionManager API（要点）

- 创建：`create(cwd)` / `open(path)` / `continueRecent(cwd)` / `inMemory()` / `forkFrom(...)`
- 列表：`list(cwd)` / `listAll()`
- 追加：`appendMessage` / `appendModelChange` / `appendThinkingLevelChange` / `appendCompaction` / `appendCustomEntry` / `appendCustomMessageEntry` / `appendSessionInfo` / `appendLabelChange`
- 树：`getLeafId/getLeafEntry/getEntry/getBranch/getTree/getChildren/getLabel/branch/resetLeaf/branchWithSummary/createBranchedSession`
- 信息：`buildContextEntries/buildSessionContext/getHeader/getSessionName/getCwd/getSessionDir/getSessionId/getSessionFile/isPersisted`

---

## 6. 压缩（Compaction）与分支摘要

两种摘要机制共用结构化摘要格式，并对文件操作做**累积跟踪**。摘要请求使用独立的 routing session ID，且在 provider 支持时**禁用 prompt-cache 写入**（一次性 prompt）。

| 机制 | 触发 | 目的 |
|------|------|------|
| Compaction | 上下文超阈值 或 `/compact` | 摘要旧消息释放上下文 |
| Branch summarization | `/tree` 导航 | 切分支时保留被放弃分支的上下文 |

### 6.1 Compaction 触发与流程

触发条件：`contextTokens > contextWindow - reserveTokens`（默认 `reserveTokens=16384`，可配）。

流程：
1. 从最新消息往回累积 token，直到达到 `keepRecentTokens`（默认 20k）→ 得到 cut point；
2. 收集“上一个保留边界（或会话起点）→ cut point”之间的消息；
3. 调 LLM 生成结构化摘要（若已有上一次摘要，作为迭代上下文传入）；
4. 追加 `CompactionEntry`（`summary` + `firstKeptEntryId`，新版还会写自包含的 `retainedTail`）；
5. 重建本次请求上下文 = `system + summary + firstKeptEntryId 起保留的消息`。

**重复压缩**：新摘要的起算点是上一次的 kept 边界，而非 compaction entry 本身；`tokensBefore` 会按重建后的真实上下文重算。

**Split turn**：当单个 turn 超过 `keepRecentTokens`，cut 落在 turn 中间的 assistant 消息，此时生成两份摘要（history + turn prefix）再合并。

**合法 cut point**：user / assistant / bashExecution / custom 消息。**绝不切在 tool result**（必须与其 tool call 同处）。

### 6.2 分支摘要

`/tree` 切换分支时：找最深公共祖先 → 回走旧 leaf 收集 entry → 按 token 预算（新的优先）准备 → LLM 摘要 → 在新位置追加 `BranchSummaryEntry(fromId)`。

### 6.3 摘要格式与文件跟踪

结构化摘要段落：Goal / Constraints & Preferences / Progress(Done, In Progress, Blocked) / Key Decisions / Next Steps / Critical Context。
文件跟踪从“被摘要消息里的 tool call”+“既往 compaction/branch summary 的 `details`”累积，因此跨多次压缩/嵌套分支都能保留读改文件全史。默认 `details = { readFiles, modifiedFiles }`，扩展可自定义。

扩展可通过 `session_before_compact` / `session_before_tree` 取消或自定义摘要，失败走 `session_compact_failed`。

---

## 7. 资源加载与配置

### 7.1 目录

- **全局**：`~/.pi/agent/`（可用 `PI_CODING_AGENT_DIR` 覆盖）
  `extensions/`、`skills/`、`prompts/`、`themes/`、`AGENTS.md`、`settings.json`、`models.json`、`auth.json`、`sessions/`、`trust.json`、`models-store.json`、`git/`、`npm/`
- **项目**：`<cwd>/.pi/`（`extensions/ skills/ prompts/ themes/ settings.json SYSTEM.md`）
- **项目祖先**：`.agents/skills/`（从 cwd 向上，直到 git 仓库根或文件系统根）
- **全局技能补充**：`~/.agents/skills/`

`cwd` 影响项目资源发现、上下文文件遍历、会话目录命名、工具路径解析；`agentDir` 影响全局资源。传入自定义 `ResourceLoader` 后二者不再控制资源发现。

### 7.2 `DefaultResourceLoader`

统一发现并暴露 `getExtensions()` / `getSkills()` / `getPrompts()` / `getThemes()` / `getAgentsFiles()`。支持覆盖钩子：`systemPromptOverride`、`skillsOverride`、`promptsOverride`、`agentsFilesOverride`、`additionalExtensionPaths`、`extensionFactories`、`eventBus`。改完调用 `await loader.reload()`。

### 7.3 上下文文件与系统提示

- 加载 `AGENTS.md`（或 `CLAUDE.md`）：全局 → 向上各级父目录 → 当前目录，全部**拼接**；若某目录有 `AGENTS.override.md`，该目录改用 override。
- 系统提示：`.pi/SYSTEM.md`（项目）或 `~/.pi/agent/SYSTEM.md`（全局）**替换**默认；`APPEND_SYSTEM.md` **追加**。
- CLI：`--no-context-files/-nc` 关闭上下文文件；`--system-prompt` / `--append-system-prompt`。

### 7.4 Settings

两处合并：全局 `~/.pi/agent/settings.json` → 项目 `<cwd>/.pi/settings.json`（项目覆盖全局，嵌套对象按键合并）。

`SettingsManager`：`create(cwd?, agentDir?)` / `inMemory(settings?)`；getter/setter 同步操作内存，setter 异步入队持久化；需要 durability 边界用 `await flush()`；错误用 `drainErrors()` 自行上报（不自动打印）。

主要分组（详见 `docs/settings.md`）：Model & Thinking、UI & Display、Telemetry、Network、Warnings、Compaction、Branch Summary、Retry、Message Delivery（`steeringMode`/`followUpMode`/`transport`）、Terminal & Images、Shell、Tools、Sessions、Model Cycling、Markdown、Resources、`defaultProjectTrust`、`packages`/`extensions` 来源、`npmCommand` 等。

### 7.5 项目信任（Project Trust）

- “需要信任”的项目资源：`.pi/settings.json`、`.pi/{extensions,skills,prompts,themes}`、`.pi/SYSTEM.md`/`APPEND_SYSTEM.md`、祖先的 `.agents/skills`。空 `.pi` 目录不算。
- 决策来源优先级：最接近的已保存决策（`~/.pi/agent/trust.json`，按规范化目录）→ `defaultProjectTrust`（`ask`(默认)/`always`/`never`）。
- **信任解析前**只加载：上下文文件、用户/全局扩展、CLI `-e` 扩展（让它们能处理 `project_trust` 事件）。项目本地扩展、项目包内扩展、项目 settings 在信任后才加载。
- 非交互模式（`-p` / `--mode json` / `--mode rpc`）不弹信任框，按 `defaultProjectTrust` 处理；可用 `-a/--approve`、`-na/--no-approve` 单次覆盖。
- `/trust` 仅写 `trust.json`，**不重载当前会话**，需重启生效。

### 7.6 Pi Packages

- 安装到 `~/.pi/agent/git/`（git）或 `~/.pi/agent/npm/`（npm）；`-l` 装项目本地（`.pi/git`、`.pi/npm`）。
- 来源：`npm:`、`git:`、`https://`、`ssh://`、本地路径；支持 `@版本/标签/commit`（pinned 包不会被 `pi update --extensions/--all` 升级）。
- 清单：`package.json` 的 `pi` 键声明 `extensions/skills/prompts/themes`；无清单则按约定目录自动发现。
- git 包默认 `npm install --omit=dev`，故运行时依赖必须放 `dependencies`。
- 安全：Packages 有完整系统权限，安装前审查源码。

---

## 8. 扩展机制（Extensions）

扩展是 TypeScript 模块（经 [jiti](https://github.com/unjs/jiti) 免编译加载），默认导出工厂函数，可同步或异步（异步工厂会被 `await`，用于启动前拉取远程模型等；之后才触发 `session_start` / `resources_discover` / 刷新 `registerProvider`）。

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_e, ctx) => ctx.ui.notify("loaded!", "info"));
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash" && event.input.command?.includes("rm -rf")) {
      if (!(await ctx.ui.confirm("Dangerous!", "Allow rm -rf?")))
        return { block: true, reason: "Blocked by user" };
    }
  });
  pi.registerTool({ name:"greet", label:"Greet", description:"…",
    parameters: Type.Object({ name: Type.String() }),
    async execute(id, params, signal, onUpdate, ctx) {
      return { content: [{ type:"text", text:`Hello, ${params.name}!` }], details:{} };
    }});
  pi.registerCommand("hello", { description:"Say hello",
    handler: async (args, ctx) => ctx.ui.notify(`Hello ${args||"world"}!`, "info") });
}
```

**位置**（可 `/reload` 热重载）：`~/.pi/agent/extensions/*.ts`、`~/.pi/agent/extensions/*/index.ts`、`.pi/extensions/...`；settings 里 `extensions: [...]` 追加路径。快速测试用 `pi -e ./path.ts`。

**可用导入**：`@earendil-works/pi-coding-agent`（类型）、`typebox`（schema）、`@earendil-works/pi-ai`（`StringEnum` 等）、`@earendil-works/pi-tui`（UI 组件）、Node 内置模块、npm 依赖（在扩展目录 `npm install`）。

**长生命周期资源**：不要在工厂里启动进程/socket/watcher/timer（工厂可能在不启动会话的调用中执行）。延迟到 `session_start` 或真正需要时启动，并用幂等的 `session_shutdown` 清理。

### 8.1 事件生命周期（关键路径）

```
pi start
 ├─ project_trust（仅用户/全局与 CLI -e 扩展）
 ├─ session_start {reason:"startup"}
 └─ resources_discover {reason:"startup"}
user prompt
 ├─（先检查扩展命令，命中则绕过）
 ├─ input（可拦截/改写/处理）
 ├─（skill/template 展开）
 ├─ before_agent_start（注入消息、改系统提示）
 ├─ agent_start
 ├─ message_start / message_update / message_end
 │   turn 循环（LLM 调工具时重复）：
 │     turn_start → context(可改消息) → before_provider_headers → before_provider_request
 │       → after_provider_response → [tool_execution_start → tool_call(可 block)
 │         → tool_execution_update → tool_result(可改) → tool_execution_end] → turn_end
 ├─ agent_end
 └─ agent_settled
会话更替:
 /new|/resume → session_before_switch(可取消) → session_shutdown → session_start → resources_discover
 /fork|/clone → session_before_fork(可取消) → session_shutdown → session_start → resources_discover
 /name → session_info_changed
 /compact|auto → session_before_compact(可取消/自定义) → session_compact | session_compact_failed
 /tree → session_before_tree(可取消/自定义) → session_tree
 /model|Ctrl+P → thinking_level_select(若级别被改/钳制) → model_select
 exit(Ctrl+C/Ctrl+D/SIGHUP/SIGTERM) → session_shutdown
```

### 8.2 `ExtensionContext`（`ctx`）

- `ctx.ui`：`notify / confirm / input / select / custom()`、`setStatus`、`setWidget`、`setFooter`、`setHeader`、编辑器替换等。
- `ctx.mode`（interactive/print/rpc/json）、`ctx.hasUI`、`ctx.cwd`。
- `ctx.isProjectTrusted()`、`ctx.sessionManager`、`ctx.modelRegistry` / `ctx.model` / `ctx.thinkingLevel` / `ctx.scopedModels`。
- `ctx.signal`、`ctx.isIdle()` / `ctx.abort()` / `ctx.hasPendingMessages()`、`ctx.shutdown()`。
- `ctx.getContextUsage()`、`ctx.compact()`、`ctx.getSystemPrompt()`。

`ExtensionCommandContext` 额外提供：`getSystemPromptOptions` / `waitForIdle` / `newSession` / `fork` / `navigateTree` / `switchSession` / `reload`（会话替换有专门生命周期与注意事项）。

### 8.3 `ExtensionAPI` 方法

`on`、`registerTool`、`sendMessage`、`sendUserMessage`、`appendEntry`、`setSessionName`/`getSessionName`、`setLabel`、`registerCommand`/`getCommands`、`registerMessageRenderer`、`registerMarkdownTransformer`、`registerEntryRenderer`、`registerShortcut`、`registerFlag`、`exec`、`getActiveTools`/`getAllTools`/`setActiveTools`、`registerProvider`/`unregisterProvider`、`events`（扩展间事件总线，`createEventBus()` 可外部接入）。

### 8.4 TUI 组件系统（`pi-tui`）

```typescript
interface Component {
  render(width: number): string[];   // 每行不得超过 width
  handleInput?(data: string): void;
  wantsKeyRelease?: boolean;         // Kitty 协议按键释放
  invalidate(): void;                // 主题变化时清缓存
}
```

- **Focusable**：文本光标组件实现 `focused`，在渲染输出中放 `CURSOR_MARKER`（零宽 APC），TUI 据此摆放硬件光标以支持 IME；容器需把 `focused` 透传给内嵌 `Input`/`Editor`，否则中日韩输入法候选框位置错误。
- 使用：扩展/自定义工具里 `ctx.ui.custom((tui, theme, keybindings, done) => new MyComponent(...))`；`{ overlay: true }` 做浮层。
- 内置：`Text` / `Box` / `Container` / `Spacer` / `Markdown` / `Image` / `Editor` / `Input`。
- 每行渲染末尾由 TUI 追加 SGR/OSC8 reset，样式不跨行；多行着色需逐行重贴或用 `wrapTextWithAnsi()`。
- 常见模式：选择对话框、异步带取消加载、设置开关、持久状态指示、editor 上下 widget、自定义 footer、自定义 editor（如 vim 模式）。

---

## 9. 工具层

- 内置工具名：`read`、`bash`、`powershell`（Windows）、`edit`、`write`、`grep`、`find`、`ls`。
- **默认启用**：`read`、`bash`、`edit`、`write`。
- 工具工厂导出：`createCodingTools`、`createReadOnlyTools`、`createReadTool/createBashTool/createPowerShellTool/createEditTool/createWriteTool/createGrepTool/createFindTool/createLsTool`。
- `edit` 返回 `details.diff`（TUI 显示）与 `details.patch`（标准 unified patch，供 SDK 消费者）。
- 自定义工具：`defineTool({...})`（参数用 `typebox` schema）或扩展里 `pi.registerTool()`；`customTools: [...]` 与扩展注册工具合并。用 `tools` allowlist 时须把自定义工具名也列进去。
- 工具裁剪：`--tools/-t`（allowlist）、`--exclude-tools/-xt`、`--no-builtin-tools/-nbt`、`--no-tools/-nt`；SDK 侧 `tools` / `excludeTools` / `noTools:"all"|"builtin"`。
- bash/powershell 工具执行时注入会话语境环境变量：`PI_SESSION_ID`、`PI_SESSION_FILE`、`PI_PROVIDER`、`PI_MODEL`、`PI_REASONING_LEVEL`（自定义工具可 opt-out，见 `docs/environment-variables.md`）。
- 其他进程级环境变量：`AI_AGENT=pi`、`PI_CODING_AGENT=true`、`PI_CODING_AGENT_DIR`、`PI_CODING_AGENT_SESSION_DIR`、`PI_PACKAGE_DIR`、`PI_OFFLINE`、`PI_SKIP_VERSION_CHECK`、`PI_TELEMETRY`、`PI_CACHE_RETENTION`、`VISUAL`/`EDITOR`。

---

## 10. 模型与 Provider 层

### 10.1 `ModelRuntime`

实现 pi-ai 的 `Models` 并持有凭证存储。

- 创建：`await ModelRuntime.create({ allowModelNetwork?, modelRefreshTimeoutMs?, authPath?, modelsPath?, credentials?, modelsStorePath?, modelsStore?, signal? })`。
- 远程目录会持久化（默认 `~/.pi/agent/models-store.json`），后续 runtime 可离线恢复；网络刷新按 provider 节流（约 4 小时一次），`refresh({allowNetwork:true, force:true, signal})` 可强制。`PI_OFFLINE` 禁用模型网络。
- 凭证解析优先级：runtime override（`setRuntimeApiKey`，不落盘）→ `auth.json`（API key / OAuth）→ 环境变量 → 回退 resolver（`models.json` 的自定义 key）。
- `login/logout/setRuntimeApiKey/removeRuntimeApiKey` 在本地快照一致后 resolve（不等远程目录新鲜度）；若凭证已提交但本地同步失败，抛 `CredentialSynchronizationError`（含 `providerId/operation/credential/cause`）。
- `refresh()` 启动新 provider generation，不会被旧的卡住，旧 generation 不会回写。
- `ModelRegistry` 是给扩展用的同步兼容 facade。解析 CLI 模型字符串用 `resolveCliModel()` / `resolveModelScopeWithDiagnostics()`。

### 10.2 模型选择回退顺序

未指定模型时：① 从会话恢复（续接时）→ ② settings 默认 → ③ 第一个可用模型。若会话模型无法恢复，`createAgentSession` 返回 `modelFallbackMessage`。

### 10.3 自定义模型（`~/.pi/agent/models.json`）

按 provider 配置 `baseUrl` / `api` / `apiKey` / `models[]`；支持 API：OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google 等。可设 `compat.supportsDeveloperRole` / `supportsReasoningEffort`（面向 Ollama/vLLM/SGLang 等）。支持覆盖内置 provider、per-model 覆盖、`thinkingLevelMap`、采样参数、自定义 headers。文件每次打开 `/model` 时重载，无需重启。

### 10.4 自定义 Provider（扩展）

- `pi.registerProvider(id, {baseUrl, apiKey, api, models[]})`；可覆盖内置或注册新的，也可 `unregisterProvider`。
- 支持 OAuth 流程（`OAuthLoginCallbacks` / `OAuthCredentials`）。
- 可实现**自定义流式 API**：定义 `stream` 模式与事件类型（content blocks、tool calls、usage/cost、上下文溢出错误）。
- 配置参考与 model 定义参考见 `docs/custom-provider.md`。

### 10.5 内置 provider

订阅类：Anthropic Claude Pro/Max、OpenAI ChatGPT Plus/Pro(Codex)、GitHub Copilot（另含 xAI、OpenRouter、Radius）。API key 类覆盖 Anthropic/OpenAI/Azure/DeepSeek/NVIDIA NIM/Google Gemini/Vertex/Bedrock/Mistral/Groq/Cerebras/Cloudflare/xAI/OpenRouter/Vercel AI Gateway/ZAI/OpenCode/HuggingFace/Fireworks/Together/Baseten/Kimi/MiniMax/小米 MiMo 等。另支持 llama.cpp router（`/login llama.cpp` + `/llama` + `/model`）。

---

## 11. 安全模型

- Pi 是**本地 agent**，以启动它的用户权限运行，把用户可写文件都视为同一本地信任边界。
- **项目信任只是输入加载门**：防止仓库在你批准前悄悄改 pi 的 settings / extensions。它**不是沙箱**，也不限制模型批准后让工具做什么。
- **无内建沙箱**（有意为之）：内建工具能读写文件、跑 shell；扩展同权限。真正的隔离必须来自 OS/容器/VM。
- 处理不受信任仓库、无人值守自动化：把整个 pi 放进容器/VM/micro-VM/受策略约束的沙箱，只挂载必要路径，避免挂 `~/.pi/agent`（除非确实需要宿主会话/凭证），用最小/短期凭证，必要时断网，回传前审查 diff。
- 只读挂载或复制进出沙箱以获得更强写保护；R/W bind-mount 仍可能改宿主文件。
- `containerization.md` 给出三种模式：整进程进容器 / 宿主 pi 把工具执行路由进 Gondolin micro-VM / OpenShell。

---

## 12. 集成方式对比

| 方式 | 场景 | 要点 |
|------|------|------|
| **SDK** | 同进程 Node 嵌入、要类型安全、直接访问 agent state | `createAgentSession` / `createAgentSessionRuntime`；`session.subscribe` 事件流；`runPrintMode` / `runRpcMode` / `InteractiveMode` 可复用内置模式 |
| **RPC** | 跨语言、进程隔离、语言无关客户端 | `pi --mode rpc`；严格 LF JSONL；命令带可选 `id` 做请求/响应关联；`type:"response"` 表示成功/失败；事件异步流；含扩展 UI 协议（stdout 请求 / stdin 响应） |
| **JSON 模式** | 结构化事件消费 | `pi --mode json`；`JsonAgentSessionEvent`；delta-only 的 `message_update` |
| **CLI** | 人机交互 / 脚本 | 四种模式 + 包管理 + 资源/工具/会话/模型选项（见 `README.upstream.md` CLI Reference） |

---

## 13. 关键设计取舍（总结）

1. **事件流为单一事实源**：TUI 只是事件流的一个渲染器，RPC/JSON/SDK 复用同一 `AgentSession`。
2. **会话即树，分支不改文件**：`id/parentId` + leaf 指针，`/tree` 原地导航；压缩/分支摘要作为可分叉路径上的“检查点 entry”。
3. **上下文是重建出来的**：`buildContextEntries → buildSessionContext`，压缩 entry 可自包含（`retainedTail`），因此旧会话（仅 `firstKeptEntryId`）也能加载。
4. **资源发现与信任解耦**：信任解析前只加载“安全来源”，扩展自身可通过 `project_trust` 事件参与决策。
5. **扩展优先**：核心不内建 MCP/子 agent/权限弹窗/plan mode；这些全部由扩展/Packages 承载。
6. **模型层可插拔**：内置 provider + `models.json` + 扩展 `registerProvider`（含自定义流式 API 与 OAuth）三层覆盖。
7. **无内建沙箱 + 项目信任**：明确边界，把真正隔离交给 OS/容器。

---

## 14. 相关文档索引（本合集内）

- 上手：`docs/quickstart.md`、`docs/usage.md`、`docs/providers.md`
- 资源与配置：`docs/settings.md`、`docs/environment-variables.md`、`docs/keybindings.md`、`docs/themes.md`
- 会话：`docs/sessions.md`、`docs/session-format.md`、`docs/compaction.md`
- 扩展：`docs/extensions.md`、`docs/skills.md`、`docs/prompt-templates.md`、`docs/packages.md`、`docs/tui.md`
- 模型：`docs/models.md`、`docs/custom-provider.md`、`docs/llama-cpp.md`
- 集成：`docs/sdk.md`、`docs/rpc.md`、`docs/json.md`
- 安全/部署：`docs/security.md`、`docs/containerization.md`
- 平台：`docs/windows.md`、`docs/termux.md`、`docs/tmux.md`、`docs/terminal-setup.md`、`docs/shell-aliases.md`
- 开发：`docs/development.md`、`meta/package.json`、`meta/CHANGELOG.md`
- 示例：`examples/extensions/`、`examples/sdk/`
