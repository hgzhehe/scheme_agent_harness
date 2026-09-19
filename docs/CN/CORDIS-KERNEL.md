# sah 动态组合内核

> 状态：规范性设计
> 日期：2026-09-18

本文定义 sah plugin 的运行时语义。包格式与使用方法见
[DESIGN-COMPOSITION.md](DESIGN-COMPOSITION.md)；完整 agent 内核见
[CORE-MECHANISMS.md](CORE-MECHANISMS.md)。

## 1. 核心约束

动态作用必须同时具备：

1. 明确的 owner；
2. 安装前得到的准备结果；
3. 安装后保存的精确证据；
4. 与证据对应的撤销操作。

一个 plugin 在 Runtime 中只有一个 `PluginSlot`：

```scheme
(plugin-slot OWNER DEFINITION STATE SCOPE FRAMES)
```

它是定义、状态、词法环境和撤销证据的唯一事实源。

## 2. Package 与 Plugin

package 是磁盘上的完整目录，入口是 `plugin.ss`。package 目录的规范化绝对路径是
owner。一个 package 可以定义多个 plugin，也可以先注册自定义 op handler。

plugin definition 是纯 datum：

```scheme
(plugin NAME DESCRIPTION IMPORTS EXPORTS BODY)
```

`BODY` 保存产生 op datum 的 Scheme form。加载 package 只发布定义；实际动态作用发生在
mount。

package 加载失败时，Runtime 删除该 owner 的 plugin slot 和 capability。失败 package
不会出现在已加载资源表中。

## 3. Link

mount 先计算依赖闭包和拓扑顺序，再为每个 plugin 建立独立 scope。

import 只引入依赖显式声明且实际定义的 export。以下情况在产生外部作用前失败：

- 缺失依赖；
- import cycle；
- 多个依赖导出同名 binding；
- plugin 声明了未定义的 export；
- op 所需 binding 不存在。

依赖图只决定激活顺序。binding 可见性由词法 scope 决定，两者不是同一份状态。

## 4. Op Algebra

op handler 的形状是：

```scheme
(op-handler UNDO-KIND REQUIRES PREPARE APPLY ROLLBACK SHOW)
```

各阶段职责：

| 阶段 | 职责 |
|---|---|
| `requires` | 声明 op 需要的 scope binding |
| `prepare` | 验证输入并取得 apply/rollback 所需材料 |
| `apply` | 产生动态作用并返回 handle |
| `rollback` | 只撤销该 handle 代表的安装 |
| `show` | 生成检查与事件中的简短描述 |

`prepare` 不得产生外部作用。`apply` 之后形成 frame：

```scheme
(frame OP PREPARED HANDLE)
```

frame 是撤销的唯一依据。rollback 不依赖重新读取当前配置、磁盘或 registry。

`UNDO-KIND` 为 `scope` 的 op 在 link 阶段只修改 plugin local scope；其余 op 在事务
apply 阶段执行。

## 5. 内置 Op

内核提供：

```scheme
op-define
op-register-hook
op-register-tool
op-register-command
op-register-renderer
op-register-widget
op-register-session-bootstrap
```

registry 类 op 的 handle 是 capability token。rollback 通过 token 删除本次注册，
不会重置整个 registry，也不会删除被遮蔽的旧定义。

package 可以用 `op-register-handler!` 增加 op kind。新增 handler 必须遵守同一
prepare/apply/rollback 协议。

## 6. Mount Transaction

mount 的固定顺序：

```text
resolve dependency closure
  -> link every inactive plugin
  -> prepare every external effect
  -> apply in dependency order
  -> publish scopes, frames and mounted state
```

任一 prepare 失败时，没有外部作用已经发生。

任一 apply 失败时，Runtime 按 frame 逆序 rollback。rollback 全部成功则恢复到 mount
前状态；rollback 失败则保留剩余 frame，并把 slot 标记为
`transaction-failed`。保留证据优先于伪造成功清理。

## 7. Dispose 与 Restart

dispose 先递归处理 active dependent，再逆序撤销目标 slot 的 frames。

全部 frame 撤销后，slot 回到：

```text
state = defined
scope = #f
frames = ()
```

撤销失败时，slot 标记为 `dispose-failed`，未处理的 frames 保留，下一次 dispose
从剩余证据继续。

restart 记录目标及其 active dependent closure，执行 dispose，再按原依赖顺序 mount
原本 active 的集合。

## 8. Session Scope

`op-register-session-bootstrap` 发布一组 Scheme forms。当前 session 的 `eval` scope
由两部分重建：

```text
active plugin bootstraps
  -> current journal path 的 durable scope forms
```

mount、dispose 或 restart 后必须重建 scope。若 journal 在新 plugin 集合下无法重放，
这次变更被拒绝，Runtime 恢复之前的 active plugin 集合并再次重建。

因此 plugin 状态和 session 可用语言不会静默分叉。

## 9. Reload

`/reload` 的对象是 package、skill 和 prompt template。

当前流程：

```text
dispose active plugins
  -> remove package owners
  -> rediscover packages
  -> load definitions and op handlers
  -> mount plugins
  -> reload skills and prompts
  -> rebuild system prompt and session scope
```

单个 mount/dispose/restart 具有上述事务和恢复语义。整批 reload 是当前进程内的完整
资源替换；调用方应把 load 或 replay 错误视为 reload 失败。

## 10. 可观察性

Runtime 发射 plugin mount、op、undo、dispose、restart 和失败事件。事件用于观察，
不保存 plugin 状态。

公开检查入口：

```text
/plugins
/plugin inspect NAME
/plugin mount NAME
/plugin dispose NAME
/plugin restart NAME
```

模型使用 `plugin` tool 调用同一 Runtime 生命周期。

## 11. 信任边界

package code、tool handler、hook 和 session bootstrap 都以当前用户权限执行。sah
保证 owner、事务和进程内清理语义，不提供代码沙箱，也不承诺撤销 plugin 未声明的
任意外部副作用。

## 12. 不变量

1. 一个 plugin 名字只对应一个 Runtime slot。
2. 一个动态 capability 只存在于统一 capability list。
3. package owner 是 package 目录，不是 plugin 名字。
4. link 与 prepare 完成后才开始外部 apply。
5. 每次成功 apply 都产生一个 frame。
6. rollback 只依赖 frame 中保存的证据。
7. rollback 失败时保留 residual frame。
8. dispose 先处理 active dependent。
9. plugin 集合改变后重建 session scope。
10. event、UI 和文档都不是运行时状态源。
