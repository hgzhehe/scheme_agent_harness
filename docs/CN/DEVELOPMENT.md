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
| `src/core/config.ss` | config 和 system prompt |
| `src/core/transport.ss` | curl transport |
| `src/extend/` | extension、skill、prompt 和 builtin commands |
| `src/ai/` | provider codec 与 dispatch |
| `src/session/` | log、persistence、discovery、pi format |
| `src/tools/` | 内置工具 datum |
| `src/agent/machine.ss` | 纯控制状态转换 |
| `src/agent/agent.ss` | effect interpreter 与 driver |
| `src/agent/` 其余文件 | context、compaction、branch |
| `src/modes/` | CLI、REPL、print、one-shot |
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

随后 finalize config、加载动态资源、创建 session。

## 4. Runtime API 约定

核心函数接受显式 `rt`：

```scheme
(run-agent rt session config prompt)
(llm-chat rt config messages tools)
(session-load rt path)
(runtime-call-tool rt session name args)
(runtime-mount-plugin! rt name)
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

## 9. 修改 agent 控制

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

## 10. Provider 开发

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

## 11. Extension loader 与 reload

每个 extension 文件的 owner 是其绝对路径。加载失败时必须删除该 owner 的：

- tool；
- command；
- hook；
- input handler；
- op handler；
- plugin definition 和 mount。

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

## 12. 测试策略

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
- machine effect/kont 与失败生命周期；
- context overflow retry；
- plugin export facade；
- prepare-before-commit；
- commit rollback；
- rollback failure residual state；
- extension load cleanup；
- source manifest。

测试数量不是目标。每个测试都应对应一个跨模块不变量或已经发生过的故障。

## 13. 构建

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

## 14. 提交前检查

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
