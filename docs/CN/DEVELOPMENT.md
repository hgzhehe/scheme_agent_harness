# sah 系统开发文档

> 日期：2026-09-14
> 机制规范见 [CORE-MECHANISMS.md](CORE-MECHANISMS.md)，剩余工作见
> [GAP-IMPLEMENTATION.md](GAP-IMPLEMENTATION.md)。

## 1. 开发原则

sah 的目标是保持一个能被完整理解的小内核。新增代码应优先维护以下性质：

- 数据形状集中；
- runtime ownership 显式；
- machine 控制与 effect 执行分开；
- session journal append-only；
- plugin effect 可 prepare、apply、rollback；
- scope 可由当前 journal path 重建；
- mode 只处理交互；
- 测试围绕架构不变量，而不是内部实现行数。

不要通过新增 process-global list、隐藏 snapshot、匿名 disposer 链或新的递归 agent loop
绕开现有机制。

## 2. 源码边界

| 路径 | 职责 |
|---|---|
| `src/vendor/` | vendored dependency |
| `src/fp/` | measured persistent vector |
| `src/util/` | 字符串、路径、JSON、平台和小工具 |
| `src/core/data.ss` | canonical message 与 entry datum |
| `src/core/scope.ss` | runtime/plugin/session lexical scope |
| `src/core/runtime.ss` | runtime record、events、hooks |
| `src/core/capability.ss` | tools、commands、input handlers、owner cleanup |
| `src/core/plugin.ss` | plugin graph、op algebra、mount/dispose transaction |
| `src/core/render.ss` | canonical projection、renderer、widget、导出格式 |
| `src/core/config.ss` | config 和 system prompt |
| `src/core/transport.ss` | curl transport |
| `src/extend/` | extension、skill、prompt 和 builtin commands |
| `src/ai/` | provider codec 与 dispatch |
| `src/session/manager.ss` | SexprL persistence、恢复、repair、会话元数据 |
| `src/session/host.ss` | active session 生命周期和所有 mode 共用的控制入口 |
| `src/session/` 其余文件 | log、discovery、pi format |
| `src/tools/` | 内置工具 datum |
| `src/agent/machine.ss` | 纯控制状态转换 |
| `src/agent/agent.ss` | effect interpreter 与 driver |
| `src/agent/` 其余文件 | context、compaction、branch |
| `src/tui/` | terminal adapter、editor、selector/component |
| `src/modes/` | CLI、TUI、REPL、print、JSONL RPC、one-shot |
| `src/main.ss` | bootstrap 与生命周期 |

`manifest.ss` 是 source、tests、bench 和 build 共用的唯一源码列表。新增文件时先确定它
位于哪一层，再把它放到首次引用之前。

## 3. Bootstrap 规则

源码加载阶段只允许：

- 定义 record、函数、syntax；
- 构造纯 tool datum；
- 定义常量。

源码加载阶段不允许注册工具、hook、command、plugin mount 或 event subscriber。

runtime 初始化统一写在 bootstrap：

```scheme
(define rt (runtime-new raw-config))
(install-core-op-handlers! rt)
(install-core-tools! rt)
(install-resource-input-handlers! rt)
```

随后 finalize config、加载动态资源、创建 session 和 `session-host`。mode 不得直接关闭、
替换或重放 session；这些操作全部通过 host。

## 4. Runtime API 约定

核心函数接受显式 `rt`：

```scheme
(run-agent rt session config prompt)
(llm-chat rt config messages tools)
(session-load rt path)
(runtime-call-tool rt session name args)
(runtime-mount-plugin! rt name)
(runtime-restart-plugin! rt name)
(session-host-switch! host next reason)
(session-host-run-agent! host prompt)
```

扩展边界可以使用：

```scheme
(current-runtime)
(current-session)
(current-owner)
```

不要在核心函数内部为了省参数而读取 parameter。parameter 的目的只是让加载的 Scheme
扩展和 tool handler 获得边界上下文。

## 5. 新增内置工具

工具文件只定义 datum：

```scheme
(define inspect-tool
  (make-tool-datum
   'inspect
   "Inspect something."
   (schema '((path "string" "Target path")))
   (lambda (args)
     ...)))
```

然后：

1. 在 `manifest.ss` 加载该文件；
2. 在 `install-core-tools!` 的列表中加入 datum；
3. 增加 handler 契约测试；
4. 确认 generated system prompt 会列出它；
5. 确认工具返回 string，异常由 `runtime-call-tool` 转为 error result。

需要 session 或 runtime 时使用 `require-session` / `require-runtime`。不要给工具建立
自己的全局状态。

## 6. 新增 hook stage

先在 `hook-specs` 声明：

```scheme
(stage kind failure-policy)
```

`kind` 应明确是：

- `effect`；
- `transform`；
- `guard`；
- `veto`。

失败策略只选 `fail-open` 或 `fail-closed`。然后使用统一的：

```scheme
runtime-invoke-hook
runtime-run-transform
runtime-run-hook-effects
runtime-veto-reason
```

不要在调用点单独写一套 guard 和默认值。

## 7. 新增 plugin op

### 7.1 构造子

```scheme
(define (op-register-index name handler)
  (list 'op-register-index name handler))
```

### 7.2 Handler

扩展侧 API：

```scheme
(op-register-handler!
 'op-register-index
 'registry
 requires
 prepare
 apply
 rollback
 optional-show)
```

所有函数都接收显式上下文：

```scheme
(requires op rt scope owner)
(prepare op rt scope owner)
(apply op rt scope owner prepared)
(rollback op rt scope owner prepared handle)
```

要求：

- `prepare` 不产生外部 effect；
- rollback 所需信息在 apply 前取得；
- `apply` 成功后返回足够的 handle；
- `rollback` 可重复调用时应尽量保持幂等；
- op kind 在一个 runtime 中唯一，重复注册直接失败；
- handler 由 extension owner 持有，reload 时清理。

### 7.3 Undo kind

- `scope`：effect 只改变新建 plugin scope，撤销方式是丢弃 scope；
- `registry`：effect 改变 runtime registry，必须提供 rollback。

如果 effect 无法给出可信 rollback，不应伪装成可卸载 plugin op。可以保留为明确的
host escape hatch，并在文档中写清不可撤销。

## 8. Session 与 eval

新增 entry kind 时必须同步检查：

1. `core/data.ss` 的 canonical shape；
2. `entry-*` accessor；
3. `entry->context-messages`；
4. token measure；
5. `session/log.ss` append constructor；
6. `session/manager.ss` migration 和 retarget；
7. `session/pi-format.ss`；
8. branch、fork、compaction；
9. tests。

会改变 lexical state 的 eval form 必须通过：

```scheme
(session-eval-form! rt session form)
```

不要先直接 `scope-eval` 再自行追加日志。这个 helper 保证失败时从 durable path 重建
scope。

移动 cursor 必须通过：

```scheme
(session-branch! rt session entry-id)
(session-branch-summary! rt session target from summary)
```

它们会同步重建 lexical scope。

从文件恢复时有两种不同失败：

- 最后一行是不完整 datum：恢复完整前缀，session 标记为 recovered/read-only；
- 中间行或完整行语法损坏：拒绝加载，不能当成正常 EOF。

read-only recovered session 必须先调用 `session-repair!`。repair 先保存原文件字节备份，
再重写完整 journal，成功后才恢复可写。不要在读取路径中静默修复用户文件。

## 9. Renderer、Widget 与前端

新增格式或显示行为时，优先扩展 `core/render.ss`，不要在 mode 中复制 message/event
分支。注册入口：

```scheme
(register-message-renderer! 'assistant renderer)
(register-entry-renderer! 'message renderer)
(register-event-renderer! 'tool-start renderer)
(register-widget! 'footer 'build-status widget)
```

renderer 接收 canonical datum、format 和 width 等上下文，返回字符串或行。它必须：

- 不修改 session、runtime 或 config；
- 输出宽度受调用方约束；
- 对不认识的 datum 返回 `#f`，让内置 renderer 接管；
- 允许失败回退，不能依赖异常控制核心流程。

plugin 中使用 `op-register-renderer` / `op-register-widget`，让注册动作进入 frame 和
rollback。普通 extension 可直接调用注册 API，由 extension owner 清理。

TUI 组件只处理局部交互状态。提交 prompt、执行 slash command、切换 session、修改
model/thinking 都调用 `session-host`。RPC 也遵循相同规则，stdout 只写 JSONL；调试输出
写 stderr。

## 10. 修改 agent 控制

控制决策写在 `agent/machine.ss`，effect 写在 `agent/agent.ss`。

新增步骤时：

1. 增加 machine phase；
2. 定义 effect datum；
3. 定义 continuation tag；
4. 在 `machine-resume` 处理 success/error；
5. 在 interpreter 实现 effect；
6. 测试 transition datum；
7. 测试成功、失败和 lifecycle event。

不要在 `machine-transition` 或 `machine-resume` 中执行 IO。也不要在 interpreter 中
复制控制分支，控制选择应回到 machine。

## 11. Provider 开发

provider adapter 负责：

- config 到 request；
- canonical message/tool 到协议 JSON；
- response/stream 到 canonical assistant message；
- provider continuation data 的保存和重放；
- delta event。

provider adapter 不负责：

- session append；
- tool execution；
- agent step；
- compaction policy；
- UI rendering。

网络错误应保留足够诊断。context overflow 必须能被 `context-overflow?` 归类，让 machine
决定一次 compact-and-retry。

## 12. Extension loader 与 reload

每个 extension 文件的 owner 是其绝对路径。加载失败时必须删除该 owner 的：

- tool；
- command；
- hook；
- input handler；
- op handler；
- plugin definition 和 mount；
- renderer 和 widget。

reload 顺序：

```text
dispose plugins
  -> clear non-core capabilities and op handlers
  -> clear skills/prompts/extensions
  -> reload
  -> mount
  -> refresh generated system prompt
  -> register session commands again
```

本机 provider、代理、密钥和调试配置不得写入 tracked 源码或示例配置。

## 13. 测试策略

运行：

```bash
cd sah
scheme --script tests/run-tests.ss
```

当前测试集中验证以下契约：

- codec 与 canonical datum；
- persistent vector 与 journal tree；
- runtime 隔离；
- owner shadow/unshadow；
- hook failure policy；
- session scope replay 和 branch；
- durable eval 原子性；
- session 尾部恢复、只读保护与 repair 备份；
- session host start/stop/switch 和 model/thinking 恢复；
- machine effect/kont 与失败生命周期；
- context overflow retry；
- plugin export facade；
- prepare-before-commit；
- commit rollback；
- rollback failure residual state；
- renderer/widget owner cleanup、失败回退和 dependency restart；
- plain/Markdown/HTML/JSON projection；
- editor、selector、小终端 layout、Windows 控制台就绪保护和主屏 scrollback；
- provider reasoning delta 到 TUI 临时显示区的事件链；
- extension load cleanup；
- source manifest。

当前离线套件有 89 个契约测试。测试数量不是目标；每个测试都应对应一个跨模块不变量
或已经发生过的故障。

## 14. 构建

```powershell
$env:SAH_RUNTIME_EXE='C:\path\to\scheme.exe'
scheme --script build.scm
```

产物位于 `sah/dist/`。Windows bundle 包含：

- `sah.exe`；
- `sah.boot`；
- Chez runtime 需要的本地 DLL。

build 会执行：

```text
dist/sah.exe --usage
```

作为 smoke check。

构建脚本会把源码定义装入 interaction environment，供 plugin program 使用。session
`eval` 使用独立的 Chez root，不依赖该环境。

## 15. 提交前检查

```bash
scheme --script tests/run-tests.ss
scheme --script sah.ss --usage
scheme --script build.scm
```

另外检查：

- 没有被删除的旧模块引用；
- 没有新增 process-global registry；
- 没有 proxy、token、API key 或本机绝对配置进入 diff；
- generated build 文件是否应被忽略；
- 文档描述的是当前实现，不把目标能力写成已完成。
