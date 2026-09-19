# sah Plugin 设计与开发

> 日期：2026-09-18

本文是 plugin package 作者的接口规范。运行时事务语义见
[CORDIS-KERNEL.md](CORDIS-KERNEL.md)，入门示例见 [EXTENDING.md](EXTENDING.md)。

## 1. 包结构

每个 package 是自包含目录：

```text
my-plugin/
  plugin.ss
  DESCRIPTION.md
  lib/
  vendor/
```

入口固定为 `plugin.ss`。代码、prompt、动态库定位逻辑和第三方源码应放在 package
目录内。package 不应依赖仓库中与自己无关的相对路径。

发现顺序：

```text
<cwd>/.sah/plugins/<name>/plugin.ss
~/.sah/plugins/<name>/plugin.ss
<sah-install>/plugins/<name>/plugin.ss
```

同名 package 只加载优先级最高的一份。

## 2. 定义 Plugin

```scheme
(plugin hello
  "Adds a greeting tool."
  (imports)
  (exports greeting)
  (op-define 'greeting "hello")
  (op-register-tool
   'hello
   "Return a greeting."
   (schema '((name "string" "Name")))
   (lambda (args)
     (string-append greeting " " (assq-ref args 'name)))))
```

`plugin` 只声明：

- 名称；
- 可选描述；
- 依赖 plugin；
- 对依赖者公开的 binding；
- 一组 op form。

body form 在 plugin scope 中求值，结果必须是 op datum。

## 3. Scope 与依赖

`imports` 按名字链接已经定义的 plugin。依赖的 export 通过只读词法 facade 进入当前
scope；未导出的 binding 不可见。

`op-define` 在当前 plugin scope 建立 binding：

```scheme
(plugin settings
  (imports)
  (exports endpoint)
  (op-define 'endpoint "service-v1"))
```

不要用进程全局变量在 plugin 之间传递状态。共享值通过 export/import，动态能力通过
Runtime capability。

## 4. 注册动态能力

### Tool

```scheme
(op-register-tool NAME DESCRIPTION PARAMETERS HANDLER)
```

handler 接收解析后的参数 alist，返回字符串或可格式化值。

### Hook

```scheme
(op-register-hook STAGE PROCEDURE)
```

stage、参数和返回协议由 `core/runtime.ss` 的 `hook-specs` 定义。hook 同步执行，应保持
短小；耗时工作放进 tool。

### Command

```scheme
(op-register-command NAME DESCRIPTION HANDLER)
```

handler 接收命令余下的文本，返回真值表示已经处理。

### Renderer 与 Widget

```scheme
(op-register-renderer TARGET KEY PROCEDURE)
(op-register-widget PLACEMENT KEY PROCEDURE)
```

renderer 返回逻辑行列表或 `#f`。失败时显示层记录诊断并回退内置 renderer。

### Session Bootstrap

```scheme
(op-register-session-bootstrap KEY FORMS)
```

`FORMS` 是 Scheme datum 列表。它们进入每个 session 的独立 `eval` scope，并在 scope
重建时先于 journal form 求值。

## 5. 自定义 Op

package 可在定义 plugin 前注册 handler：

```scheme
(op-register-handler!
 'op-register-cache
 'registry
 requires
 prepare
 apply
 rollback
 show)
```

签名：

```scheme
(requires op rt scope owner)
(prepare op rt scope owner)
(apply op rt scope owner prepared)
(rollback op rt scope owner prepared handle)
(show op)
```

约束：

1. `prepare` 只验证并收集材料；
2. `apply` 返回精确 handle；
3. `rollback` 只撤销该 handle；
4. 不能可靠撤销的作用不声明为可卸载 op；
5. handler 名称在 Runtime 中必须唯一。

## 6. 生命周期

package 被发现后，其 plugin 默认挂载。运行时入口：

```text
/plugins
/plugin inspect NAME
/plugin mount NAME
/plugin dispose NAME
/plugin restart NAME
/reload
```

模型侧 `plugin` tool 使用同一套操作。

dispose 会先处理依赖目标的 active plugin。restart 会恢复操作前 active 的 dependent
closure。影响 session bootstrap 的变更会重建当前 `eval` scope；journal 无法重放时，
变更被拒绝并恢复原 plugin 集合。

## 7. 设计检查

一个 package 完成前应确认：

- 目录脱离源码树其他位置仍然完整；
- 所有依赖都写在 `imports`；
- 所有跨 plugin binding 都写在 `exports`；
- 每个外部作用都有 prepare、handle 和 rollback；
- dispose 后没有残留 capability；
- restart 后依赖闭包状态正确；
- session bootstrap 可与已有 journal 重放；
- package 加载失败不会留下定义或 op handler；
- 本机凭据、代理和调试配置不在 package 中。
