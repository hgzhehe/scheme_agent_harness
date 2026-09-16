# sah 的 Scheme 式 Cordis 内核

> 状态：规范性设计与实施契约
> 日期：2026-09-16
> 适用版本：`main` init baseline

## 1. 本文只管什么

本文只定义 sah 的动态组合内核：

- extension 注册的能力归谁所有；
- plugin 如何声明依赖、安装作用和撤销作用；
- reload 如何替换整组动态资源；
- 后续实现到什么位置必须停止。

本文不重复：

- agent machine、session、journal：见
  [CORE-MECHANISMS.md](CORE-MECHANISMS.md)；
- extension、plugin 的使用方法：见
  [DESIGN-COMPOSITION.md](DESIGN-COMPOSITION.md)；
- sah 其他子系统的未完成工作：见
  [GAP-IMPLEMENTATION.md](GAP-IMPLEMENTATION.md)。

## 2. 唯一不变量

> 动态作用必须有 owner、安装证据和撤销路径。

三个词分别对应：

```text
owner       谁引入了这个作用
evidence    实际安装了什么
undo        如何只撤销这一次安装
```

如果一个作用不能回答这三个问题，它不是受管理的 plugin effect。它可以作为普通
Scheme 代码执行，但不能声称支持可靠 reload 或 dispose。

## 3. Scheme 表示

Cordis 的 Context、Service 和 Effect 在 sah 中不保留原 API，而被压成四种对象。

### 3.1 Capability

所有动态能力使用一种 cell：

```scheme
(cap TOKEN OWNER KIND KEY VALUE)
```

tool、command、hook、subscriber、input handler、op handler、renderer 和 widget 都只是
该 cell 的领域接口，不拥有独立 registry。

同 `KIND/KEY` 的新 cell 遮蔽旧 cell。删除新 cell 后，旧定义自然恢复，不保存 registry
snapshot。

### 3.2 PluginSlot

一个 plugin 名字只有一个运行时事实：

```scheme
(plugin-slot OWNER DEFINITION STATE SCOPE OPS FRAMES)
```

definition、状态、词法 scope 和撤销证据不分散到第二张表。

### 3.3 Op 与 Frame

plugin body 产生 op datum。op handler 定义：

```scheme
(op-handler UNDO-KIND REQUIRES PREPARE APPLY ROLLBACK SHOW)
```

成功 apply 后只留下最小撤销证据：

```scheme
(frame OP PREPARED HANDLE)
```

registry op 的 handle 通常就是 capability token。词法定义的撤销不是模拟 unbind，而是
丢弃整个未发布或已卸载的 plugin scope。

### 3.4 Scope

dependency graph 只决定链接顺序；Scheme environment 承担名字可见性：

```text
runtime root
  -> imported export facade
  -> plugin local scope
```

依赖只暴露声明的 exports。private binding 不泄漏，imported binding 不允许被 `set!`。
export 不是全局 service locator，而是显式词法 facade。

## 4. 当前已经闭合

### 4.1 Owner 清理

extension 文件的绝对路径是 owner。文件加载失败时，它已经注册的 capability、op handler
和 plugin definition 都会被移除。

plugin effect 使用自己的 frame 精确撤销，不靠“恢复一份旧 registry”。

实现：

- `sah/src/core/runtime.ss`
- `sah/src/core/capability.ss`
- `sah/src/extend/loader.ss`

### 4.2 单次 Mount 事务

一次 mount 的真实顺序是：

```text
解析 dependency closure
  -> 建立全部 scope
  -> prepare 全部 external effect
  -> 按依赖顺序 apply
  -> 发布 PluginSlot
```

prepare 失败时不执行任何 apply。apply 失败时，已执行的 frame 严格逆序 rollback。

rollback 再失败时，残余 frame 写回 PluginSlot，状态为 `transaction-failed`；后续 dispose
可以继续清理。系统不会把未清理的作用标成成功。

### 4.3 Dispose 与 Restart

dispose 先卸载 active dependents，再撤销目标 plugin。

restart 记录原 active dependent closure，卸载后按依赖顺序重新 mount，避免 dependent
继续引用旧 scope。

### 4.4 能力范围

当前受管理的 plugin effect 已覆盖：

- tool；
- hook；
- command；
- renderer；
- widget；
- extension 自定义的 op handler。

新增同类能力时，应继续落到 capability cell 和 op/frame，不新增专用 registry。

### 4.5 验证

当前离线测试为 `96 passed, 0 failed`。其中直接覆盖：

- owner 删除后恢复被遮蔽能力；
- extension 加载失败后的完整清理；
- dependency export facade；
- 全计划 prepare 先于 apply；
- apply 失败后的逆序 rollback；
- rollback 失败后的残余 frame 重试；
- renderer/widget 的 mount 与 dispose；
- dependency restart 恢复 dependents。

因此，Cordis 的核心不变量已经实现。后续工作不是继续增加插件概念。

## 5. 有意停止的地方

以下内容不是当前 gap：

- 把 provider、session、machine、frontend 全部改成 plugin；
- 通用反应式 service graph；
- activation lease 或依赖引用计数；
- optional dependency、late binding；
- plugin package manager；
- 异步 hook/event framework；
- 通用配置树；
- 任意 Scheme 副作用自动回滚。

只有出现当前语义无法表达的真实用例，才重新打开其中一项。不得以“更像 Cordis”为理由
扩张内核。

普通 extension 保留为本机定制和调试入口。它的任意顶层副作用不受 sah 管理；需要可靠
卸载的作用必须写成 plugin op。这是边界，不再为普通 extension 伪造事务保证。

## 6. 唯一内核 Gap：原子 Reload

### 6.1 当前故障

当前 `reload-resources!` 先执行：

```text
dispose old plugins
  -> remove old extension owners
  -> load new files
  -> mount new plugins
```

如果新 extension、link、prepare 或 apply 失败，旧动态层已经被破坏。单次 plugin mount
有事务，但整批 reload 没有事务。

这是真 gap，因为它直接违反唯一不变量：一次“替换动态层”的安装失败后，没有恢复原层。

### 6.2 目标行为

```text
active layer 保持可用
  -> 建立 candidate layer
  -> 加载全部 extension
  -> link 全部 plugin
  -> prepare 全部 effect
  -> 尝试 candidate activation
  -> 成功：一次发布 candidate，再清理 old
  -> 失败：撤销 candidate，active layer 不变
```

原子保证只覆盖 runtime 管理的 capability、plugin、resource 和声明过 rollback 的 op。
自定义 op 未声明的外部副作用不在保证内。

### 6.3 实施边界

本次实现只允许修改：

- `core/runtime.ss`：承载 candidate/active 动态层的最小边界；
- `core/plugin.ss`：分离 plan、activation、publish；
- `extend/loader.ss`：从破坏式 reload 改为 candidate reload；
- `tests/run-tests.ss`：增加 fault matrix。

不修改 agent、session、provider、render 或 TUI 语义。它们只能观察 reload 成功或失败。

### 6.4 实施顺序

1. 先写一个失败测试：新 extension 加载失败后，旧工具仍可调用。
2. 找出 candidate 所需的最小数据，不先创建通用 manager。
3. 让 plugin transaction 能在未发布状态完成 link、prepare 和 activation。
4. 让 extension 注册写入 candidate，而不是 active layer。
5. 成功时只保留一个发布点。
6. 删除旧的“先 dispose 再 load”路径，不保留兼容实现。
7. 补齐 link、prepare、apply、rollback 四个失败点。

### 6.5 验收

必须同时满足：

- extension 读取或求值失败：旧层不变；
- dependency/link 失败：旧层不变；
- prepare 失败：apply 次数为零，旧层不变；
- apply 失败：candidate 完整 rollback，旧层不变；
- reload 成功：已删除的旧 extension 确实消失；
- reload 成功：新能力只安装一次；
- session command、event subscriber 和 active session 不被替换；
- 失败状态可由返回值或 event 观察，不只打印日志；
- 旧 reload 路径被删除；
- 全部既有测试继续通过。

满足这些条件后，Cordis 内核开发结束。

## 7. 系统收尾：Project Trust

项目 `.sah/extensions` 当前会以用户权限直接执行。最小修复只做加载门控：

- 用户级 extension 继续加载；
- 项目级 extension 先检查 canonical cwd 的 trust 决定；
- 非交互模式必须有确定的 allow/deny 策略；
- TUI、REPL、print、RPC 共用同一个决定。

本阶段不同时建设 sandbox、权限 DSL 或 package manager。

## 8. 开发纪律

修改动态组合内核时只问四个问题：

1. 这个作用的 owner 是什么？
2. 安装成功后留下的最小 handle 是什么？
3. rollback 是否只撤销本次安装？
4. 失败后哪个对象保存真实状态？

新增能力时：

```text
能用 capability cell 表达
  -> 写领域 wrapper
需要 plugin 管理
  -> 增加 op handler
不能可信撤销
  -> 明确标为 unmanaged，不伪装成 plugin effect
```

禁止：

- 新建第二套 registry；
- 为 reload 保存全局 snapshot；
- 同时保留新旧 reload 路径；
- 为未来可能性增加 activation manager、service proxy 或 package abstraction；
- 用日志代替失败状态；
- 在纯重构中净增加结构。

## 9. 收口条件

下面两项完成后，这条路线关闭：

1. 原子 candidate reload；
2. 最小 project trust；

之后新增插件能力必须由具体用户场景驱动，不能继续以“补齐 Cordis”为长期路线。
