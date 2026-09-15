# sah 整体迁移重构契约

> 日期：2026-09-15
> 基线：`14005ef`
> 分支：`rewrite/low-entropy-core`

## 1. 目标

这次工作不是继续整理现有实现，而是保留已经验证的行为，从数据模型开始重新建立
sah。

旧源码只承担两种作用：

1. 提供可运行的行为样本；
2. 暴露必须删除的重复状态和重复调用链。

不复制旧模块，不建立 `v2` 兼容层，不让新旧 representation 同时存在。一个行为被新
实现接管后，旧实现必须在同一个变更中删除。

## 2. 当前可检查事实

基线有 50 个 Scheme 源文件和 96 个离线契约测试。第一批核心簇为：

| 文件 | 行数 |
|---|---:|
| `core/runtime.ss` | 194 |
| `core/capability.ss` | 363 |
| `core/plugin.ss` | 723 |
| `session/host.ss` | 204 |
| `agent/machine.ss` | 128 |
| `agent/agent.ss` | 200 |
| 合计 | 1812 |

这一簇当前存在三类重复事实：

1. Runtime 为 tool、command、hook、input handler、subscriber、op handler 和 renderer
   分别保存列表，并分别实现注册、查找、owner 清理和 dynamic clear。
2. 当前配置同时保存在 Runtime 和 session host；更新时必须手工同步。
3. 活动会话同时由 session host、`current-session` 和 agent machine 携带。

这三个问题不通过补 helper 解决，而通过删除 representation 解决。

## 3. 最终状态所有权

### Runtime

Runtime 是进程内唯一可变根，只拥有：

```scheme
(runtime
  cwd
  config
  session
  session-started?
  root-scope
  session-root-scope
  capabilities
  plugins
  resources
  chat-override
  next-token)
```

- `config` 只有这一份；
- `session` 是唯一活动会话引用；
- `capabilities` 是唯一动态能力表；
- plugin definition、mount state 和 rollback frame 位于同一个 plugin slot；
- skills、prompts 和已加载 extension 路径位于一个 resource map。

`current-runtime` 与 `current-owner` 只服务扩展边界。`current-session` 不再保存独立
事实；需要时从当前 Runtime 取得活动会话。

### Session

Session 只拥有已经提交的会话事实：

```scheme
(session id cwd file log port created model parent scope health recovery)
```

- `log` 是 append-only entry tree；
- cursor 同时决定模型上下文与 Scheme scope；
- model、provider、thinking 的当前值从活动路径投影；
- session 不拥有 agent continuation 或 UI 状态。

### Machine

Machine 是纯 defunctionalized CPS datum：

```scheme
(turn STEP LIMIT)
(request STEP LIMIT RETRIED?)
(commit STEP LIMIT REPLY)
(tools STEP LIMIT REPLY CALLS)
(await EFFECT KONT)
(done REPLY)
(failed REASON)
```

Machine 不包含 Runtime、Session、config、port、procedure 或 UI 对象。

```scheme
(machine-step state)                 -> state | await | done | failed
(machine-resume continuation result) -> state | done | failed
```

### Driver

Driver 解释 effect。它不是新的状态容器。

```scheme
(runtime-submit! rt input)
(run-agent! rt prompt)
```

所有 mode 只调用 `runtime-submit!`。agent lifecycle 的结束事件只有一个发射位置。

### TUI

TUI 只保存 editor、selector、瞬时 stream/reasoning 文本和一次前台运行句柄。它不复制
session、config、plugin 或 agent machine 状态。

## 4. Capability 统一表示

所有动态能力使用一种 cell：

```scheme
(cap TOKEN OWNER KIND KEY VALUE)
```

唯一底层操作是：

```scheme
(runtime-add-capability! rt owner kind key value)
(runtime-capability rt kind key)
(runtime-capabilities rt kind)
(runtime-remove-capability! rt token)
(runtime-remove-owner! rt owner)
```

tool、command、hook、subscriber、input handler、op handler、renderer 和 widget 的公开
API 可以保留，但只能是对这五个操作的领域入口，不能再拥有各自的 registry。

owner 清理必须是一遍过滤。extension 加载失败、plugin dispose、session switch 和
reload 不再分别枚举能力种类。

## 5. Plugin 最小模型

一个 plugin 名字只对应一个 slot：

```scheme
(plugin-slot OWNER DEFINITION STATE SCOPE OPS FRAMES)
```

保留的语义：

- imports/exports facade；
- dependency cycle 与 export conflict 检查；
- 完整 effect plan 先 prepare；
- dependency order apply；
- 严格逆序 rollback；
- rollback 失败保留 residual frames；
- dispose 先处理 active dependents；
- restart 恢复原 active closure。

删除的结构：

- 独立的 plugin list 与 mount alist；
- mount snapshot 与第二份 plugin definition 映射；
- 每种 registry op 自己查找旧 cell 的 prepared 数据；
- frame 中不参与恢复或撤销的 source/status 字段；
- owner cleanup 对 plugin、op handler、renderer 和 capability 的多次遍历。

registry op 的撤销证据就是 capability token。scope op 的撤销就是丢弃未发布的 plugin
scope。

## 6. Session 生命周期

删除 `session-host` record。对应操作直接改变 Runtime 的唯一活动会话：

```scheme
(runtime-start-session! rt reason previous-file)
(runtime-stop-session! rt reason target-file)
(runtime-switch-session! rt next reason)
(runtime-new-session! rt)
(runtime-resume-session! rt path)
(runtime-fork-session! rt entry-id)
```

切换顺序保持：

```text
veto
  -> stop hooks/event
  -> remove old session owner
  -> close journal
  -> replace runtime session
  -> project model/thinking into runtime config
  -> start hooks/event
  -> install session commands
```

任何 mode、command 或 TUI 不得自行实现其中一部分。

## 7. 迁移顺序

1. 用统一 capability cell 重写 Runtime，迁移 event、hook、tool、command、input 和
   renderer；删除全部分类型 registry 字段。
2. 重写 plugin slot 与 transaction；删除旧 plugin/mount/op-handler 表。
3. 把活动 session 和 config 收回 Runtime；删除 session host record。
4. 重写 machine 与 driver；建立唯一 `runtime-submit!`。
5. 迁移 main、command、print、repl、RPC 和 TUI 到 Runtime。
6. 重写 render/TUI 热点，只保留 canonical projection 与一种 frame 构造路径。
7. 接入取消和 steering；运行句柄必须局部于一次 agent run。
8. 删除剩余旧名字、旧文档和失效测试。

每一步都在同一变更内完成“新行为接管 + 旧 representation 删除”，不提交过渡适配器。

## 8. 拒收条件

任一条件成立，本轮重构作废：

- 纯重构阶段源码净增加；
- 为迁移新增 adapter、manager、facade 或第二套状态机；
- 同一事实仍有两个 mutable owner；
- owner cleanup 仍按 capability kind 分支；
- mode 仍组合 `process-input` 与 `run-agent`；
- lifecycle end 仍有多个发射位置；
- Machine 携带 Session、Runtime、config 或 procedure；
- plugin definition 与 mount state 仍需跨两张表同步；
- 新实现只能靠保留旧实现才能通过测试。

## 9. 验收

结构验收：

- 一个 Runtime；
- 一个 capability list；
- 一个 active session 字段；
- 一个 submit 入口；
- 一个 agent finalizer；
- 一个 plugin slot 表示；
- 零兼容层。

行为验收：

- 基线 96 个测试全部通过；
- session new/resume/fork/branch/scope replay/repair 保持；
- plugin mount/dispose/restart/failure recovery 保持；
- print/repl/RPC/TUI 走同一提交入口；
- eval、tool rendering、reasoning rendering 和 Windows terminal 回归保持；
- 最终 standalone build 通过。

这次迁移以“旧结构实际消失”为完成条件，不以新设计文档、测试数量或解释完整度代替
源码收敛。
