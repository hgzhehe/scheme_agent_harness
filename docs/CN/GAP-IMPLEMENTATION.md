# sah 当前 gap 与实施路线

> 快照日期：2026-09-14
> 本文从当前可用版本继续向前，只列尚未闭合的工程问题。

## 1. 当前基线

当前版本已经形成一条可实际使用的主路径：

- runtime 独占 tool、command、hook、event、plugin、renderer 和 widget registry；
- agent loop 是 defunctionalized machine，effect 与 continuation 都是 datum；
- provider、tool、hook 和 journal IO 只由 effect interpreter 执行；
- session host 统一 start、stop、switch、new、resume、fork、clone 和 run；
- model、provider、thinking level 作为当前 session path 的 durable metadata；
- SexprL journal 支持树形分支、session-local scope replay、尾部截断恢复和显式 repair；
- plugin 支持 dependency/export facade、全图 prepare、事务 mount、逆序 rollback、
  residual retry、dispose 和 dependent-aware restart；
- plugin 与 extension 都能注册 renderer 和 TUI widget，并由 owner 自动清理；
- TUI 已具备流式 transcript、多行 editor、history、session/tree selector、状态行和
  plugin widget placement；
- plain、ANSI、Markdown、HTML、JSON 使用同一 canonical projection；
- JSONL RPC 支持 prompt、command、state、session 切换、fork、模型设置和导出；
- source、test、build 共用 manifest，Windows standalone bundle 已通过真实 provider
  冒烟。

这些能力属于基线，不再以“未来目标”描述。

## 2. P0：Durable machine checkpoint

### 现状

machine、effect、kont 已经显式数据化，但 continuation 仍携带进程内 session/config
对象，也没有写入 journal。当前只能恢复已提交历史，不能恢复正在等待的控制状态。

### 实施

1. machine 中只保存稳定 session id、config revision 和 path cursor；
2. 给每个 effect 分配 operation id 和 retry class；
3. journal 增加 `machine-checkpoint`、`effect-started`、`effect-committed`；
4. provider read-only effect 与可能产生副作用的 tool effect 使用不同恢复策略；
5. 启动时解释最后一个未完成 checkpoint，而不是猜测是否重试；
6. 在每个 await/commit 边界加入 crash fault injection。

### 验收

- 任意 checkpoint 前后退出都得到确定恢复结果；
- 非幂等 tool 不会因模糊重试重复执行；
- 恢复后的 step、cursor、context 和不中断执行一致。

## 3. P0：取消、会话写纪律与异步前端

### 现状

TUI 和 RPC 已经建立，但 provider/tool interpreter 仍同步。一个 runtime 也没有正式的
session writer lease。

### 实施

- effect interpreter 接受 cancellation token；
- transport 能终止 curl 进程和未读完的 stream；
- machine 增加 `cancelled` terminal state；
- `agent-end` / `agent-settled` 在 success、failure、cancel 三条路径都恰好一次；
- 每个 session file 只有一个 writer lease，或 append 前做 revision compare；
- RPC 增加 request id、cancel 和异步 event envelope；
- TUI 的 Esc/Ctrl-C 先取消当前 run，再决定是否退出进程。

### 验收

- provider、shell 和 tool batch 都能取消；
- cancel 后没有悬挂 process/port，也没有半条 journal datum；
- RPC 可在流式 prompt 期间发送 cancel；
- 同一 session 的两个 writer 不会静默覆盖或交错。

## 4. P1：结构化 tool contract

### 现状

schema 会发送给模型，但本地没有统一 validation；tool result 仍主要是
`(values string error?)`，大输出和副作用策略没有统一表示。

### 实施

- 在 `runtime-call-tool` 前验证项目使用到的 JSON Schema 子集；
- tool result 改为 tagged datum，区分 success、invalid-arguments、blocked、
  execution-error 和 cancelled；
- 大输出落 artifact store，消息只持有摘要和 reference；
- shell/write/edit 声明 effect class、cwd policy 和 approval policy；
- renderer 与 RPC 对所有 result kind 提供稳定 projection。

### 验收

- 不合法参数不会进入 handler；
- provider、journal、TUI、JSON 对错误种类理解一致；
- 大结果不会无界占用 context 或 RPC 单行。

## 5. P1：Provider continuation state 独立

OpenAI Responses 的 opaque output 目前借存在 usage alist 的 `responses-output` 中。
token accounting 与 provider continuation state 应分离。

建议把 assistant message 演进为带显式 metadata 的兼容形状，或新增 tagged metadata
entry，并同步：

- journal migration；
- context projection；
- compaction；
- pi import/export；
- provider adapter；
- JSON/HTML export。

切换 provider 时必须明确旧 continuation state 是丢弃、保留但不发送，还是经 adapter
迁移，不能由某个 codec 隐式决定。

## 6. P1：Plugin activation 与原子 reload

### 已有

单次 dependency closure mount 已经全量 prepare；失败会 rollback；dispose/restart 会
处理 active dependents；owner cleanup 覆盖 registry、renderer 和 widget。

### 剩余

- dependency activation 没有 reference-counted lease；
- plugin definition owner 与 mount request owner 尚未分开；
- 多个 extension 文件的 reload 不是一个整体事务；
- frame 没有 stable id、timestamp 和可选 journal projection；
- mounted plugin 的 op handler algebra 不能热替换。

### 实施

1. mount request 记录 root、request owner 和 dependency reason；
2. dependency 使用 activation lease，只有最后一个 lease 释放后才 dispose；
3. 把全部 extension/plugin 读入 candidate runtime；
4. candidate 完成 link、prepare 和验证后原子替换 active dynamic layer；
5. 旧 layer 在新 layer 生效后逆序 dispose；
6. reload 失败继续使用完整旧 layer。

## 7. P1：项目 trust 与 capability policy

项目 `.sah/extensions` 和 session `eval` 都以当前用户权限执行。词法隔离不是安全沙箱。

需要：

- canonical cwd trust store；
- global resource 与 project resource 分阶段加载；
- 非交互模式的明确默认 trust policy；
- 未信任项目不可注册或执行 effect capability；
- shell/write/edit 的路径、命令和网络 policy；
- TUI、REPL 与 RPC 共用同一个 policy decision protocol。

这项工作应早于 package manager 或公开分发生态。

## 8. P2：TUI 与 RPC 产品化

当前 TUI 是可工作的第一版 engine，不是 pi TUI API 的完整复刻。后续应围绕真实工作流
演进：

- overlay/modal component 与焦点栈；
- 统一 keymap、theme token 和 resize event；
- tool detail 折叠、diff/artifact viewer；
- transcript virtualization，避免超长 session 全量重绘；
- plugin component 生命周期，而不只是 placement widget；
- versioned RPC envelope、request id、增量 event 和 capability discovery；
- PTY 驱动的 Windows/POSIX 终端回归。

前端仍不得直接修改 session internals；新增交互先扩展 host/runtime protocol。

## 9. P2：验证深化

当前 89 个离线契约测试覆盖主要不变量。下一阶段增加：

- journal tree property test；
- branch/scope model-based test；
- plugin transaction 和 candidate reload fault matrix；
- provider stream fixtures；
- crash checkpoint recovery；
- cancellation race；
- PTY TUI snapshot 与 resize/Unicode 输入；
- Windows/POSIX build matrix。

重点 fault point：

```text
after scope eval / before journal flush
after each plugin apply / rollback
after staged session write / backup rename
before provider result commit
after tool effect / before tool-result append
during cancellation and session switch
```

## 10. 推荐实施顺序

| 顺序 | 工作 | 形成的能力 |
|---|---|---|
| 1 | durable checkpoint + effect id | defunctionalized CPS 跨进程恢复 |
| 2 | cancellation + writer lease | 可中断且不会破坏会话 |
| 3 | structured tool result/schema/policy | 稳定 effect 边界 |
| 4 | provider continuation state 独立 | 清晰的跨 provider resume |
| 5 | activation lease + candidate reload | 真正原子的动态组合 |
| 6 | project trust | 可以放心扩大扩展面 |
| 7 | async RPC + advanced TUI | 在稳定协议上完善交互 |
| 8 | property/fault/build matrix | 把故障恢复变成持续保证 |

## 11. 收束标准

下一阶段不以“功能数量”判断完成，而以四条硬标准收束：

1. 一个普通编码任务能在 TUI、print 和 RPC 中走完同一条 runtime 路径；
2. session 能切换、分支、恢复、repair，并且任何失败都不伪造持久事实；
3. plugin 能安装、卸载、重启和 reload，失败后仍有可解释状态；
4. 所有新增能力都落在 machine、effect、journal、scope、capability 或 renderer 这几个
   既有语义中心，不另建平行框架。

目标不是复制 pi 或 DSH 的表面 API，而是保留 pi 的小内核、Cordis 的动态组合精神，
再用 Scheme datum 和显式解释器把控制、历史、作用与界面统一起来。
