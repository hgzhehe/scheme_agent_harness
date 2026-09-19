# sah 核心机制设计

> 状态：规范性设计
> 日期：2026-09-18
> 适用版本：当前实现

## 1. 当前内核

sah 是一个以 Scheme datum 为共同语言的 agent harness：

- 会话历史是 datum；
- agent 控制状态和 continuation 是 datum；
- plugin program、effect plan 和 rollback frame 是 datum；
- message、tool call、event 与外部 JSON 投影仍从同一组 datum 产生。

当前内核由三种机制共同构成：

1. pi agent 的小内核：provider、tool、session、resource、frontend 各自保持薄边界；
2. Cordis 的动态组合：动态作用必须有 owner、安装证据和撤销路径；
3. defunctionalized CPS：控制状态与下一步不藏在宿主调用栈和闭包中。

它们已经通过 Scheme 的 datum、词法环境和显式解释器汇合为 sah 自己的运行模型，不是
等待补齐的参考框架。核心执行形状是：

```text
input
  -> pure machine state
  -> effect request
  -> effect interpreter
  -> effect result
  -> data continuation
  -> next state
```

## 2. 唯一总原则

> 一个事实只能有一个可变所有者。

这条规则决定整个结构：

| 事实 | 唯一所有者 |
|---|---|
| 当前配置、活动会话、动态能力、插件槽、资源 | Runtime |
| 已提交历史、cursor、会话词法状态 | Session |
| 一次 agent run 尚未完成的控制 | Machine datum |
| 一次插件激活的撤销证据 | PluginSlot.frames |
| editor、selector、瞬时流式文本 | TUI app |

event 不是状态仓库，parameter 不是第二份状态，frontend 也不能复制核心对象。

## 3. 五个正交对象

### Runtime

进程内唯一可变根，回答“这个 sah 实例现在拥有什么”。

### Session

已经提交的事实集合，回答“这条会话路径发生过什么”。

### Machine

纯控制 datum，回答“这次运行下一步要请求什么 effect”。

### PluginSlot

一个插件在 Runtime 中的完整事实，回答“定义、状态、scope 与撤销证据是什么”。

### Renderer

canonical datum 到显示或协议投影的纯边界，回答“同一个事实如何被不同前端观察”。

这些对象不能互相代替：

- transcript 不能充当 continuation；
- event 不能充当 durable journal；
- plugin dependency graph 不能充当 Scheme 环境 parent chain；
- UI status 不能充当 agent state；
- rollback frame 不能承诺撤销插件没有声明的外部副作用。

## 4. Runtime

Runtime 的当前形状是：

```scheme
(runtime
  cwd
  config
  session
  session-started?
  root-scope
  session-root-scope
  capability-cells
  plugins
  resources
  chat-override
  next-token)
```

### 4.1 两种 root scope

`root-scope` 服务 plugin package。它能看到 sah 的 package API 和 `op-*` 构造子。

`session-root-scope` 服务会话 `eval`。它基于 Chez Scheme 环境，但不自动暴露 sah
内部绑定。

这是语义隔离，不是安全沙箱。会话 Scheme 仍以当前用户权限运行。

### 4.2 Parameter 的边界

`current-runtime` 与 `current-owner` 只在 plugin package、tool handler 等动态边界使用。
核心调用显式传递 `rt`。

`current-session` 不保存独立值，而是从 `current-runtime` 读取活动 Session，因此不会
与 Runtime.session 发生漂移。

## 5. Capability

所有动态能力只有一种底层表示：

```scheme
(cap TOKEN OWNER KIND KEY VALUE)
```

底层操作只有：

```scheme
(runtime-add-capability! rt owner kind key value)
(runtime-capability rt kind key)
(runtime-capabilities rt kind)
(runtime-remove-capability! rt token)
(runtime-remove-owner! rt owner)
```

tool、command、hook、subscriber、input handler、op handler、renderer 和 widget 都只是
这个表之上的领域 API，不拥有自己的 registry。

### 5.1 遮蔽

同 kind、同 key 的新 cell 遮蔽旧 cell。删除 owner 或 token 后，下面的定义自然重新
出现：

```text
plugin/read
core/read
```

因此 plugin 覆盖内置工具后即使加载失败，核心工具仍能恢复，不需要 registry snapshot。

### 5.2 Owner 清理

package load failure、session stop、plugin rollback 和 reload 使用同一种删除语义。
系统不再按 capability kind 分别维护 cleanup 代码。

## 6. Session 与 Journal

Session 只拥有已提交事实：

```scheme
(session id cwd file log port created model parent scope health recovery)
```

内存日志是不可变树：

```scheme
(slog persistent-vector cursor linear?)
```

entry 的 ID 是 vector 位置，parent 指向父 entry。移动 cursor 会选择另一条 root-to-leaf
路径，但不会删除旧分支。

### 6.1 Cursor 是唯一视角

cursor 同时决定：

1. 发送给模型的 message path；
2. 当前可见的 compaction checkpoint；
3. 当前 model/provider/thinking metadata；
4. 会话 Scheme scope 的 replay path。

这样不会出现“聊天回到了旧分支，但 Scheme 定义仍来自新分支”的双重现实。

### 6.2 Durable eval

改变词法状态的成功表单会写为 `scope-form`：

```scheme
define
define-syntax
set!
include
include-ci
import
```

如果宏表单实际产生新 binding，也会被识别为 durable form。

durable eval 的不变量是：

```text
scope evaluation succeeds
  and journal append succeeds
  or the scope is rebuilt from the durable path
```

因此 journal 写失败不会留下只存在于内存的定义。

### 6.3 损坏恢复

SexprL 文件以完整换行 datum 为恢复边界：

- 最后一行被中断：恢复完整前缀，标记为 recovered/read-only；
- 中间行损坏或完整坏行：拒绝加载；
- `/repair` 先保留原字节备份，再写完整 journal；
- repair 成功前禁止继续 append。

## 7. Session Control

Runtime 直接拥有唯一活动 Session。没有额外的 session host record。

统一生命周期入口：

```scheme
(runtime-start-session! rt reason previous-file)
(runtime-stop-session! rt reason target-file)
(runtime-switch-session! rt next reason)
(runtime-new-session! rt)
(runtime-resume-session! rt path)
(runtime-fork-session! rt entry-id)
(runtime-clone-session! rt)
```

switch 的固定顺序是：

```text
session-before-switch veto
  -> shutdown/end hooks
  -> session-end event
  -> remove old session owner
  -> close old journal
  -> replace Runtime.session
  -> project model/thinking into Runtime.config
  -> session-start event/hooks
  -> install session commands
```

TUI、RPC、REPL 和 slash command 不得自行拼装这条流程。

## 8. Defunctionalized CPS Machine

Machine 只含稳定数据：

```scheme
(start PROMPT LIMIT)
(turn STEP LIMIT)
(request STEP LIMIT RETRIED?)
(force-compact STEP LIMIT)
(commit STEP LIMIT REPLY)
(tools STEP LIMIT CALLS)
(await EFFECT CONTINUATION)
(done REPLY)
(failed REASON)
```

它不包含 Runtime、Session、config、port 或 procedure。

纯函数：

```scheme
(machine-step state)
(machine-resume continuation effect-result)
```

continuation 当前有：

```scheme
(next STATE)
(provider STEP LIMIT RETRIED?)
(committed STEP LIMIT REPLY)
```

### 8.1 Effect interpreter

`agent/agent.ss` 解释以下 effect：

```scheme
(effect begin PROMPT)
(effect auto-compact STEP)
(effect provider STEP)
(effect force-compact)
(effect commit-reply STEP REPLY)
(effect execute-tool CALL)
```

provider、tool、hook、journal 和 event 都只在 interpreter 中发生。

### 8.2 Driver

唯一 agent 入口是：

```scheme
(run-agent! rt prompt)
```

唯一输入入口是：

```scheme
(runtime-submit! rt input)
```

所有 mode 只提交输入。它们不再组合 `process-input` 和 `run-agent`。

agent 成功或失败都通过同一个 finalizer 发射：

```scheme
agent-failed? -> agent-end -> agent-settled
```

### 8.3 Context overflow

overflow 是显式控制转换：

```text
provider error(context-overflow)
  -> force-compact
  -> request(retried? = true)
  -> reply or failed
```

是否已经重试是 machine datum 的一部分，不藏在异常处理闭包中。

## 9. Plugin

Plugin 把 Cordis 式动态组合压成 Scheme datum。一个名字只对应一个 Runtime slot：

```scheme
(plugin-slot OWNER DEFINITION STATE SCOPE FRAMES)
```

它的核心保证只有三条：

1. imports/exports 通过显式词法 facade 链接；
2. 全部 effect 先 prepare，再按依赖顺序 apply；
3. 失败时逆序 rollback，清理失败则保留 residual frame。

dispose 先处理 active dependents，restart 恢复原 active closure。详细 op/frame 与
生命周期语义见 [CORDIS-KERNEL.md](CORDIS-KERNEL.md)。

## 10. Plugin Package 与 Resource

plugin package 的 owner 是包目录。加载失败时：

```text
dispose owned plugin slots
  -> remove every capability with this owner
  -> do not publish package path
```

sah 按项目、全局、安装目录的优先级发现 `<name>/plugin.ss`，包通过
`plugin-define!` 自注册；核心不登记 package 名称。

plugin dirs/packages、skills、prompts 使用 Runtime.resources 的同一资源表，
不各自建立可变字段。项目级资源优先于用户级和安装目录资源。它们当前仍以本机用户
权限执行；project trust 是已知边界。

## 11. Renderer 与 Frontend

渲染层分成四个责任：

| 模块 | 责任 |
|---|---|
| `render/text.ss` | display width、ANSI、plain/Markdown/HTML 文本 |
| `render/json.ss` | message、entry、event 的稳定结构化投影 |
| `render/dispatch.ss` | renderer capability、失败回退、event sink |
| `render/session.ss` | 整体会话文档与导出 |

JSON 是协议投影，不允许显示插件改写。plain、ANSI、Markdown、HTML 可以被 renderer
capability 覆盖。

renderer 失败只写诊断并回退内置实现，不能打断 agent 或改变 journal。

### 11.1 TUI

TUI 只保存：

- editor；
- selector；
- stream/reasoning 瞬时文本；
- status 与 notice；
- terminal adapter 和 event subscription。

它使用一个 `tui-frame` 组装布局：

```scheme
(tui-frame app width)         ; 保留原生 terminal scrollback
(tui-frame app width height)  ; 有界视口
```

Windows Terminal 使用主屏而不是 alternate screen，因而保留滚动条和原生鼠标选择。
鼠标滚轮输入被解码但不会调用不可靠的 stdin readiness 路径。

agent interpreter 仍按 Machine effect 顺序同步推进；TUI 只把这次运行放到后台线程。
局部 `run-control` 承担取消位和当前外部进程的取消函数，Ctrl+C 可终止 provider/shell
子进程，忙碌期间提交的输入按 FIFO 在当前运行收束后继续。它不进入 Runtime、Session
或 Machine datum。

### 11.2 RPC

RPC 与其他 mode 使用同一个 Runtime：

```text
prompt command get_state new_session resume fork
set_model set_thinking export shutdown
```

stdout 只写 JSONL envelope，诊断写 stderr。当前协议是串行的。

## 12. Bootstrap

加载源码只定义值，不安装动态能力。

启动顺序：

```text
parse config
  -> runtime-new
  -> install core op handlers/tools/input handlers
  -> finalize config
  -> discover plugin packages
  -> mount plugins, then discover skills/prompts
  -> create or load session
  -> Runtime.session := session
  -> runtime-start-session!
  -> run selected mode
  -> runtime-stop-session!
  -> dispose plugins
```

`manifest.ss` 是 source、tests、bench 和 build 共用的唯一加载顺序。

## 13. 核心不变量

1. 一个进程实例只有一个 Runtime。
2. 一个 Runtime 只有一个 capability list。
3. 当前 config 和 active session 只保存在 Runtime。
4. Session journal 只记录已经提交的事实。
5. cursor 同时决定 context、metadata 与 Scheme scope。
6. Machine 是纯 datum，不持有运行时对象或 procedure。
7. mode 只通过 `runtime-submit!` 提交输入。
8. agent 生命周期只有一个 finalizer。
9. 一个 plugin 名字只有一个 PluginSlot。
10. plugin effect 在完整 prepare 后才开始 apply。
11. rollback 失败必须保留 residual frame。
12. JSON projection 是稳定协议，不是主题系统。
13. TUI 不复制 Session、config 或 Machine。
14. 旧 representation 被替代时必须在同一变更中删除。

## 14. 非目标

当前内核不声称：

- Scheme eval 是安全沙箱；
- 任意外部 plugin effect 都可回滚；
- 进程崩溃后能恢复未完成 continuation；
- provider/tool 调用可异步取消；
- RPC 支持并发 steering；
- 多进程可同时写同一 session。

这些限制写入 gap 文档，不能通过兼容层、第二状态表或 UI 拼装掩盖。
