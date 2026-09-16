# sah 系统开发手册

> 日期：2026-09-16
> 本文只描述如何修改当前实现，不重复核心设计，也不保存旧 API 的迁移说明。
> 核心不变量见 [CORE-MECHANISMS.md](CORE-MECHANISMS.md)，动态组合见
> [CORDIS-KERNEL.md](CORDIS-KERNEL.md)。

## 1. 修改纪律

开始编码前先回答三个问题：

1. 这个事实由谁拥有？
2. 它是 durable fact、纯控制 datum、动态 capability，还是 UI 瞬时状态？
3. 新实现接管后，哪段旧 representation 会被删除？

如果答案需要“两个地方都更新”，设计还没有完成。

禁止用以下方式完成重构：

- 保留旧 API 的 adapter；
- 新建 `v2` manager 与旧 manager 并存；
- 用 snapshot 修补重复 registry；
- 为每种 capability 再写一套 owner cleanup；
- mode 自行拼 agent 或 session 生命周期；
- 只移动文件，不重建责任边界。

## 2. 源码地图

| 路径 | 责任 |
|---|---|
| `core/data.ss` | canonical message、call、entry |
| `core/runtime.ss` | Runtime、capability cells、event、hook |
| `core/capability.ss` | tool、command、input 领域 API |
| `core/scope.ss` | Scheme scope 与 import facade |
| `core/plugin.ss` | plugin program、link、transaction、dispose |
| `render/` | text、JSON、dispatch、session export |
| `session/log.ss` | 不可变 journal tree |
| `session/manager.ss` | persistence、recovery、scope replay |
| `session/control.ss` | Runtime 的活动会话生命周期 |
| `agent/machine.ss` | 纯 defunctionalized CPS control |
| `agent/agent.ss` | effect interpreter 与 driver |
| `agent/context.ss` | provider context projection |
| `agent/compaction.ss` | compaction policy 与 summary |
| `extend/` | extension、skills、prompts、commands |
| `tools/` | 内置 tool datum |
| `tui/` | terminal、editor、selector |
| `modes/` | TUI、REPL、print、RPC |
| `main.ss` | bootstrap 与最终清理 |

`manifest.ss` 是唯一源码清单。新增文件必须放在首次运行时调用之前。

## 3. Bootstrap

源码加载阶段只允许定义 record、函数、syntax、常量和纯 datum。

显式安装顺序：

```scheme
(define rt (runtime-new cwd raw-config))
(install-core-op-handlers! rt)
(install-core-tools! rt)
(install-resource-input-handlers! rt)
(runtime-config-set!
 rt (finalize-config rt raw-config cwd))
```

之后加载资源、创建 Session、写入 Runtime，再启动：

```scheme
(runtime-session-set! rt session)
(runtime-start-session! rt 'initial #f)
```

退出时：

```scheme
(runtime-stop-session! rt 'exit #f)
(runtime-dispose-all-plugins! rt)
```

## 4. Runtime API

核心调用显式传递 `rt`：

```scheme
(runtime-call-tool rt name args)
(runtime-active-tools rt)
(runtime-process-input rt text)
(runtime-submit! rt text)
(run-agent! rt prompt)
(runtime-mount-plugin! rt name)
(runtime-switch-session! rt session reason)
```

extension/tool 边界可以使用：

```scheme
(require-runtime)
(require-session)
(current-owner)
```

不要在核心函数里为了省参数读取 parameter。

## 5. 新增 Capability

先判断现有 kind 能否表达。大多数扩展能力应落在：

```text
tool command input-handler hook subscriber op-handler renderer
```

底层注册：

```scheme
(runtime-add-capability! rt owner kind key value)
```

注册返回 token。精确撤销使用 token：

```scheme
(runtime-remove-capability! rt token)
```

整个扩展、会话或动态层撤销使用：

```scheme
(runtime-remove-owner! rt owner)
```

不要新增 kind-specific cleanup。

## 6. 新增 Tool

工具文件只定义 datum：

```scheme
(define inspect-tool
  (make-tool-datum
   'inspect
   "Inspect one value."
   (schema '((name "string" "Value name")))
   (lambda (args)
     ...)))
```

然后：

1. 在 `manifest.ss` 加载工具文件；
2. 加入 `install-core-tools!`；
3. handler 返回 string 或可被 `format` 的值；
4. 需要上下文时使用 `require-runtime` / `require-session`；
5. 增加成功、参数失败和 handler 异常测试。

工具不得建立自己的 process-global session 或 config。

## 7. 新增 Hook Stage

先在 `core/runtime.ss` 的 `hook-specs` 定义：

```scheme
(STAGE KIND FAILURE-POLICY)
```

`KIND`：

- `effect`
- `transform`
- `guard`
- `veto`

`FAILURE-POLICY`：

- `fail-open`
- `fail-closed`

调用点使用统一函数：

```scheme
runtime-invoke-hook
runtime-run-transform
runtime-run-hook-effects
runtime-veto-reason
```

不要在调用点自建 guard policy。

## 8. 新增 Plugin Op

构造子只产生 datum：

```scheme
(define (op-register-index name handler)
  (list 'op-register-index name handler))
```

handler：

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

函数签名：

```scheme
(requires op rt scope owner)
(prepare op rt scope owner)
(apply op rt scope owner prepared)
(rollback op rt scope owner prepared handle)
```

硬规则：

1. `prepare` 不产生外部作用；
2. rollback 所需信息必须在 apply 前取得；
3. `apply` 返回足够的 handle；
4. registry op 优先直接返回 capability token；
5. scope op 使用 `scope` undo kind；
6. 无法可信撤销的作用不得伪装成可卸载 op。

## 9. 修改 Machine

控制决策只写在 `agent/machine.ss`。

新增控制步骤时：

1. 增加纯 state datum；
2. 从 `machine-step` 返回 effect 与数据 continuation；
3. 在 `machine-resume` 处理 effect result；
4. 在 `agent/agent.ss` 实现 effect；
5. 测试 state、effect、continuation、success、failure；
6. 确认 lifecycle finalizer 仍只有一个。

Machine 中禁止放：

- Runtime 或 Session；
- config alist；
- port；
- procedure；
- TUI object。

## 10. 修改 Session

新增 entry kind 时同步检查：

1. `core/data.ss` shape/accessor/token measure；
2. `session/log.ss` constructor 与 path projection；
3. `session/manager.ss` migration、retarget、recovery；
4. `agent/context.ss`；
5. compaction 与 branch；
6. `session/pi-format.ss`；
7. `render/json.ss` 与文本渲染；
8. tests。

改变 lexical state 的表单必须通过：

```scheme
(session-eval-form! rt session form)
```

移动 cursor 必须通过：

```scheme
(session-branch! rt session id)
(session-branch-summary! rt session target from summary)
```

不要直接改 log cursor 后忘记重建 scope。

## 11. 修改 Session Lifecycle

所有活动会话操作都在 `session/control.ss`。

mode 和 command 只能调用：

```scheme
runtime-new-session!
runtime-resume-session!
runtime-fork-session!
runtime-clone-session!
runtime-set-model!
runtime-set-thinking!
```

不要直接 close 当前 Session 后替换 Runtime.session。必须保留 veto、hook、owner cleanup、
metadata projection 和 start event 的完整顺序。

## 12. Provider

provider adapter 负责：

- config 到 request；
- canonical message/tool 到协议 JSON；
- response/stream 到 canonical assistant message；
- usage 与 provider continuation data；
- delta event。

provider 不负责：

- journal append；
- tool execution；
- agent step；
- compaction policy；
- TUI rendering。

context overflow 异常必须能被 `context-overflow?` 分类，由 Machine 决定一次 compact/retry。

## 13. Renderer

修改位置：

| 需求 | 文件 |
|---|---|
| display width、ANSI、plain/Markdown/HTML | `render/text.ss` |
| stable JSON shape | `render/json.ss` |
| plugin renderer、widget、event sink | `render/dispatch.ss` |
| whole-session export | `render/session.ss` |

注册入口：

```scheme
(register-message-renderer! role proc)
(register-entry-renderer! kind proc)
(register-event-renderer! kind proc)
(register-widget! placement key proc)
```

renderer 必须纯观察，失败时允许回退。JSON 是协议投影；不要把主题逻辑放进 JSON。

## 14. TUI

TUI 局部状态可以 mutable，但不得复制核心事实。

布局只通过：

```scheme
(tui-frame app width)
(tui-frame app width height)
```

新增交互时：

1. key decoding 留在 `tui/terminal.ss`；
2. editor 行为留在 `tui/editor.ss`；
3. selector 行为留在 `tui/selector.ss`；
4. Runtime/session 操作留在核心 protocol；
5. TUI 只解释 key 并调用 protocol。

不要重新引入通用 component framework，除非至少两个独立组件确实共享生命周期协议。

## 15. Extension Reload

每个 extension 文件 owner 是规范化绝对路径。

加载失败：

```text
remove owned plugin slots
  -> remove owner capabilities
  -> report stderr
```

reload 不保存 registry baseline，也不按 kind 重置。删除动态 owner 后，被遮蔽的核心
capability 自动恢复。

当前整批 reload 仍是破坏式替换。原子 candidate reload 的实现边界和验收只在
[CORDIS-KERNEL.md](CORDIS-KERNEL.md) 中维护，本节不另建路线。

本机 provider、代理 URL、API key 和调试配置禁止进入 tracked 文件。

## 16. 测试与构建

离线契约测试：

```powershell
C:\chezscheme\ta6nt\bin\ta6nt\scheme.exe --script sah\tests\run-tests.ss
```

当前基线为 96 个测试。每个测试应对应跨模块不变量或真实故障，不以数量代替设计。

构建：

```powershell
$env:SAH_RUNTIME_EXE='C:\path\to\scheme.exe'
scheme --script sah\build.scm
```

Windows 上旧 `dist/sah.exe` 仍在运行时，可把验证产物写到独立目录：

```powershell
$env:SAH_DIST_DIR='C:\path\to\sah\build\dist-check'
scheme --script sah\build.scm
```

提交前：

```text
tests 96/96
source usage smoke
standalone build smoke
git diff --check
no old representation references
no local proxy/token/config in diff
```

## 17. 重构验收

纯重构必须同时满足：

- 行为测试不退化；
- 旧 representation 实际删除；
- mutable owner 数量不增加；
- 没有 adapter 或第二状态表；
- 源码规模不以测试或文档为借口膨胀；
- 新边界能用一句话说明；
- 文档只描述当前实现。
