# sah 当前 Gap 与实施路线

> 快照日期：2026-09-15
> 基线：Runtime/Session/Machine/Plugin/Render 整体迁移后的可运行版本

## 1. 当前已经闭合

- Runtime 是唯一可变根；
- config 与 active session 只有一份；
- capability 使用统一 `(cap token owner kind key value)`；
- extension/session/plugin cleanup 使用统一 owner 删除；
- Session host record 已删除；
- input 只有 `runtime-submit!` 一个入口；
- Machine 是不携带 Runtime/Session/procedure 的 defunctionalized CPS datum；
- agent success/failure 只有一个 finalizer；
- 一个 plugin 名字只有一个 PluginSlot；
- plugin mount 先完整 prepare，再 apply，失败保留 residual frames；
- render 已拆成 text、JSON、dispatch、session export；
- TUI 只有一个 frame 构造路径；
- Windows Terminal 保留原生 scrollback 和鼠标选择；
- 96 个离线契约测试通过。

以下工作才是 gap。不能把目标能力写成当前能力。

## 2. P0：可取消的 Run

### 问题

provider、tool batch 和 compaction 仍由同步 driver 执行。TUI 在一次 run 期间不能可靠地
接收 Ctrl-C、steering 或 follow-up。

### 目标模型

一次运行拥有局部句柄：

```scheme
(run ID STATE CANCEL QUEUE WORKER)
```

它属于一次 `run-agent!` 调用或 frontend controller，不进入 Runtime 的长期全局状态，
也不复制 Machine。

Machine 增加：

```scheme
(cancelled REASON)
```

effect interpreter 在 effect 边界检查 cancellation token。

### 实施顺序

1. transport 返回可关闭的请求 handle；
2. shell tool 暴露可终止 process handle；
3. driver 接受 cancellation token；
4. success/failure/cancel 共用同一 finalizer；
5. TUI worker 与 input loop 分离；
6. Ctrl-C 优先取消 active run；
7. steering queue 在下一个明确 machine boundary 注入；
8. RPC 增加 request id、event 与 cancel。

### 禁止

- 不在 Runtime 增加第二份 agent state；
- 不用 UI status 猜测是否正在运行；
- 不用异步线程直接写 Session；
- 不捕获任意宿主 continuation 充当 durable checkpoint。

## 3. P0：Session Writer Lease

### 问题

当前单进程写入可靠，但多个进程可以打开同一 session file。

### 实施

- 打开持久 Session 时取得 writer lease；
- lease 记录 session id、pid、start time 和 revision；
- append 前校验 revision；
- stale lease 只能通过显式 repair/recover 流程接管；
- memory session 不使用 lease。

### 验收

- 两个 writer 不会静默交错；
- 进程崩溃后可识别 stale lease；
- repair 保留原文件与 lease 诊断。

## 4. P0：Durable Machine Checkpoint

### 问题

Machine 已经数据化，但尚未写入 journal。进程恢复只能恢复已提交事实，不能恢复未完成
effect。

### 实施

新增 durable datum：

```scheme
(machine-checkpoint RUN-ID STATE)
(effect-started RUN-ID EFFECT-ID CLASS)
(effect-committed RUN-ID EFFECT-ID RESULT)
```

恢复策略必须按 effect class 区分：

- provider read-only 请求可显式重试；
- 幂等读工具可重试；
- write/edit/shell 等外部作用不能在结果未知时自动重放。

### 验收

- 每个 await/commit 边界可做 crash injection；
- 恢复后的 cursor、step 与不中断执行一致；
- 非幂等工具不会因模糊重试执行两次。

## 5. P1：结构化 Tool Result

### 问题

本地 schema 尚未统一验证，tool result 仍主要是 `(values string error?)`。

### 目标

```scheme
(tool-result ok value metadata)
(tool-result invalid-arguments details)
(tool-result blocked reason)
(tool-result execution-error reason)
(tool-result cancelled reason)
```

### 实施

1. 验证实际使用的 JSON Schema 子集；
2. tool handler 前统一参数检查；
3. message、event、JSON、RPC 共用 result kind；
4. 大输出进入 artifact store，context 只保存摘要与引用；
5. shell/write/edit 声明 effect class 与 policy。

## 6. P1：Provider Continuation State

OpenAI Responses 的 opaque output 当前借存在 usage alist 中。token accounting 与协议
continuation 必须分开。

需要新增明确 metadata：

```scheme
(assistant-meta usage provider-state)
```

同步修改：

- canonical message；
- journal migration；
- context projection；
- compaction；
- pi import/export；
- JSON projection；
- provider adapter。

切换 provider 时必须明确旧 state 是保留但不发送、丢弃，还是由 adapter 迁移。

## 7. P1：Plugin Activation Lease 与原子 Reload

### 当前能力

单次 dependency closure mount 已经全量 prepare，dispose/restart 会处理 dependents。

### 剩余问题

- dependency 没有 activation lease；
- definition owner 与 mount requester 尚未区分；
- 多 extension reload 不是整体事务；
- op algebra 热替换没有 candidate phase。

### 目标

```text
load candidate dynamic layer
  -> link all plugins
  -> prepare all effects
  -> validate
  -> atomically publish candidate
  -> dispose old layer
```

dependency 只有最后一个 lease 释放后才 dispose。

失败时继续使用完整旧 layer，不能得到半新半旧 Runtime。

## 8. P1：Trust 与 Policy

项目 extension 和 session eval 都以当前用户权限执行。词法隔离不是安全边界。

需要：

- canonical cwd trust store；
- user resource 与 project resource 分阶段加载；
- 非交互模式的明确默认策略；
- shell/write/edit/network capability policy；
- TUI、REPL、RPC 共用 decision protocol；
- project config 不得静默覆盖全局安全策略。

这项工作应早于公开 plugin package 生态。

## 9. P2：TUI 与 RPC

在 cancellation protocol 完成后再扩展：

- working indicator 由真实 active run 驱动；
- steering/follow-up queue；
- tool detail 折叠与 diff/artifact viewer；
- transcript virtualization；
- resize event 与统一 keymap/theme token；
- versioned RPC envelope；
- capability discovery；
- Windows/POSIX PTY 回归。

不要先建立通用 component framework。只有出现至少两个共享 focus、render、dispose
协议的真实组件后，才抽象 component lifecycle。

## 10. P2：验证

新增：

- journal tree property test；
- branch/scope model-based test；
- plugin transaction fault matrix；
- provider stream fixtures；
- cancellation race；
- writer lease 冲突；
- crash checkpoint recovery；
- PTY resize、Unicode、mouse、selection；
- Windows/POSIX build matrix。

关键 fault point：

```text
after scope eval / before journal append
after plugin prepare / each apply / each rollback
after staged session write / before replace
after tool effect / before tool-result append
before provider result commit
during cancel and session switch
```

## 11. 实施次序

| 顺序 | 工作 | 形成的保证 |
|---|---|---|
| 1 | cancellation handle + worker boundary | TUI/RPC 可中断 |
| 2 | writer lease | 单 session 单 writer |
| 3 | durable checkpoint + effect class | 崩溃恢复不重复副作用 |
| 4 | structured tool result/schema | 稳定工具边界 |
| 5 | provider metadata 独立 | 协议状态不污染 usage |
| 6 | activation lease + candidate reload | 动态层原子替换 |
| 7 | trust/policy | 项目扩展可控执行 |
| 8 | advanced TUI/RPC + fault matrix | 产品化与持续验证 |

## 12. 收束规则

每个 gap 的实现都必须满足：

1. 先定义唯一 owner 和 datum；
2. 先删除被替代 representation；
3. 不加兼容层；
4. 不建立第二状态机；
5. 不让 frontend 直接修改 Session internals；
6. 失败状态必须可观察，不能用日志假装成功；
7. 纯重构阶段源码不得净膨胀；
8. 文档只声明已经通过验收的能力。
