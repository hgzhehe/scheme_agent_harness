# sah 组合与扩展机制

> 日期：2026-09-18
> 本文只说明 extension/plugin API 的使用。Cordis 内核的不变量、当前完成度与唯一
> 实施 gap 见 [CORDIS-KERNEL.md](CORDIS-KERNEL.md)；整个 sah 的底层语义见
> [CORE-MECHANISMS.md](CORE-MECHANISMS.md)。

## 1. 三层扩展方式

sah 支持：

1. 普通 extension：文件 load 时调用 `register-tool!`、`register-hook!` 等；
2. plugin program：声明 imports/exports，返回一组可 prepare/rollback 的 op；
3. plugin package：含 `plugin.ss` 的完整目录，加载时自注册 plugin program。

普通 extension 适合本机调试和简单能力。plugin program 是需要组合、卸载和事务保证时的
正式机制。plugin package 只负责发现与分发，不新增第二套生命周期。

发现目录：

```text
<cwd>/.sah/plugins/<name>/plugin.ss
~/.sah/plugins/<name>/plugin.ss
<sah-install>/plugins/<name>/plugin.ss
~/.sah/extensions/*.ss
<cwd>/.sah/extensions/*.ss
```

同名 package 按项目、全局、安装目录的顺序取第一个。plugin package 的目录路径是
owner；extension 的文件路径是 owner。加载失败或 reload 时，该 owner 的动态定义会
被清理。

## 2. 普通 extension

```scheme
(register-tool!
 'hello
 "Return a greeting."
 (schema '((name "string" "Name")))
 (lambda (args)
   (string-append "hello " (assq-ref args 'name))))

(register-hook!
 'before-agent-start
 (lambda (text session config)
   (cons 'inject "Project extension loaded.")))
```

同名工具或命令会遮蔽旧定义。extension 被清理后，旧定义重新出现。

普通 extension 的顶层任意副作用不受 sah 管理。只有通过 runtime registration API
产生的能力能按 owner 自动清理。

## 3. Plugin program

```scheme
(plugin project-facts
  (imports)
  (exports codename)
  (op-define 'codename "PINEAPPLE")
  (op-register-tool
   'codename
   "Return the project codename."
   (schema '())
   (lambda (args) codename))
  (op-register-hook
   'before-agent-start
   (lambda (text session config)
     (cons 'inject "Use the project codename when relevant."))))
```

含义：

- `imports` 是 plugin dependency；
- `exports` 是唯一对 dependents 可见的 binding facade；
- body form 在 plugin local scope 中求值；
- 每个 body form 必须得到一个已注册的 op datum；
- scope op 在 link 阶段建立词法定义；
- registry op 在完整 prepare 后统一 commit。

resource loader 先加载 plugin packages，再加载 extensions，随后调用 mount-all。

## 4. Import 与 export

```scheme
(plugin base
  (imports)
  (exports port)
  (op-define 'port 8080)
  (op-define 'secret "private"))

(plugin consumer
  (imports base)
  (exports endpoint)
  (op-define 'endpoint
             (string-append "localhost:"
                            (number->string port))))
```

`consumer` 能看到 `port`，看不到 `secret`。

规则：

- missing dependency：link error；
- dependency cycle：link error；
- 两个 import 导出同名 binding：link error；
- 声明 export 但本层没有定义：link error；
- 对 imported binding 执行 `set!`：scope error；
- 本层 `define` 同名 binding：允许显式遮蔽。

## 5. 内置 op

### `op-define`

```scheme
(op-define 'name value)
```

在 plugin local scope 中定义 binding。undo kind 是 `scope`，dispose 时丢弃整个 scope。

### `op-register-tool`

```scheme
(op-register-tool name description schema handler)
```

注册 runtime tool。frame 记录 owner，dispose 时只移除该 owner 的那一层定义。

### `op-register-hook`

```scheme
(op-register-hook stage handler)
```

注册 hook，handle 是 hook token。

### `op-register-command`

```scheme
(op-register-command name description handler)
```

注册 slash command。

### `op-register-renderer`

```scheme
(op-register-renderer target key
  (lambda (value format width)
    ...))
```

`target` 是 `message`、`entry`、`event` 或 `widget`。renderer 返回逻辑行列表；返回
`#f` 时继续使用内置 renderer。异常会记录并回退，不会中断 agent。

同一 `target/key` 的后注册定义遮蔽旧定义。dispose 当前 plugin 后，旧 renderer
重新可见。

### `op-register-widget`

```scheme
(op-register-widget 'footer 'build-status
  (lambda (context format width)
    (list "build: clean")))
```

这是 widget target 的便捷形式。placement 当前支持 `header`、`above-editor`、
`below-editor` 和 `footer`。widget 与其他 registry op 一样进入 transaction frame。

### `op-register-session-bootstrap`

```scheme
(op-register-session-bootstrap 'language-key forms)
```

把一组 Scheme form 注册为 session language bootstrap。mount、dispose 或 restart 后，
当前 session 的 eval scope 会从 bootstrap 与 journal 一起重建。`scheme-match`、
`minikanren` 和 `z3` 都通过这个 op 提供语言能力。

## 6. 自定义 op

```scheme
(define (op-register-cache name value)
  (list 'op-register-cache name value))

(op-register-handler!
 'op-register-cache
 'registry

 ;; requires
 (lambda (op rt scope owner)
   #f)

 ;; prepare
 (lambda (op rt scope owner)
   (lookup-old-cache-value (cadr op)))

 ;; apply
 (lambda (op rt scope owner prepared)
   (install-cache-value! (cadr op) (caddr op))
   (cadr op))

 ;; rollback
 (lambda (op rt scope owner prepared handle)
   (restore-cache-value! handle prepared))

 ;; optional show
 (lambda (op)
   (format "register-cache ~a" (cadr op))))
```

`prepare` 必须在不改变外部状态的情况下收集 inverse 所需信息。整个 dependency subgraph
的所有 op 都 prepare 成功后，apply 才开始。

自定义 op kind 在 runtime 中必须唯一。extension unload 会删除其拥有的 handler。

## 7. Mount 与失败

```scheme
(plugin-mount! 'project-facts)
(plugin-list)
(plugin-frames 'project-facts)
(plugin-restart! 'project-facts)
(plugin-dispose! 'project-facts)
```

正常状态：

```text
defined -> linking -> linked -> committing -> mounted
mounted -> disposing -> defined
```

失败状态：

```text
transaction-failed
dispose-failed
```

这两个状态都保留未清理 frame。再次调用 `plugin-dispose!` 会继续尝试。

mount 期间的 `plugin-op` 和 `plugin-mount` event 会缓冲到整个事务提交之后。观察者不会
看到最终回滚掉的半成品安装。

restart 会先 dispose 目标以及当前 active dependents，再恢复原 active closure。这样
dependency 更新不会留下仍标记为 mounted、却引用旧 scope/frame 的 dependent。

## 8. Hook 约定

常用返回形状：

```scheme
;; before-agent-start
(cons 'prompt "replacement")
(cons 'inject "additional user context")

;; input
'handled
(list 'transform "new input")

;; tool-call
(cons 'block "reason")
(cons 'args new-args)

;; tool-result
(list new-output new-error?)

;; veto hooks
(cons 'cancel "reason")
```

guard/veto hook 的异常按 fail-closed 处理；普通 transform/effect hook 按 fail-open 处理。
具体策略以 `hook-specs` 为准。

## 9. Reload

`/reload`：

1. dispose mounted plugins；
2. 清理旧 plugin package 与 extension owner；
3. 清空 plugin package、extension、skills 与 prompts 资源记录；
4. 重新发现并 load plugin packages；
5. 重新 load extension files；
6. mount plugin programs；
7. 重新发现 skills/prompts；
8. 刷新 generated system prompt；
9. 从 plugin bootstrap 与当前 journal 重建 session eval scope。

一个 package 或 extension load 失败时，该 owner 已经注册的工具、hook、command、
input handler、op handler、renderer、widget 和 plugin definition 都会被删除，其他
资源继续加载。

运行时也可以用：

```text
/plugins
/plugin inspect NAME
/plugin mount NAME
/plugin dispose NAME
/plugin restart NAME
```

这些命令是调试和运维入口，不改变 plugin transaction 的底层语义。

## 10. Session eval 与 plugin scope

两者使用不同 root：

- plugin scope 可以看到 sah extension DSL；
- session eval scope 只从 Chez Scheme language root 开始。

session 中的 durable definition 会进入 journal：

```scheme
(scope-form ID PARENT TS (define answer 42))
```

它不会发送给模型。branch 时只重放当前 path，因此不同会话分支可以有不同的 Scheme
binding state。

## 11. 安全边界

plugin package、extension 和 eval 都以当前用户权限执行。当前没有 project trust 或
OS sandbox。

因此：

- 不加载不可信的项目 plugin package 或 extension；
- 不把 secret 写进 tracked extension；
- 不在仓库提交本机代理和 provider 凭据；
- 对 shell/write/edit 的额外限制应实现为 capability policy，而不是依赖 prompt。
