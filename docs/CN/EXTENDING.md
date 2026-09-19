# 定制 sah

> 日期：2026-09-18

sah 有三个文件化定制面：

| 机制 | 用途 | 位置 |
|---|---|---|
| **plugin package** | 增加工具、hook、命令、renderer、widget 或 session Scheme 能力 | 安装目录、`~/.sah/plugins/<名称>/`、`<项目>/.sah/plugins/<名称>/` |
| **skill** | 按需加载的 Markdown 指令 | `~/.sah/skills/<名称>/SKILL.md`、`<项目>/.sah/skills/...` |
| **prompt template** | 变成 `/命令` 的 Markdown 模板 | `~/.sah/prompts/<名称>.md`、`<项目>/.sah/prompts/<名称>.md` |

## Plugin package

一个插件包是包含 `plugin.ss` 的完整目录：

```text
hello/
  plugin.ss
  DESCRIPTION.md
  ...
```

sah 按以下优先级发现包：

```text
<cwd>/.sah/plugins/<name>/plugin.ss
~/.sah/plugins/<name>/plugin.ss
<sah-install>/plugins/<name>/plugin.ss
```

同名目录只加载优先级最高的一份。包目录是 owner；加载失败时，该包已经声明的 plugin
和自定义 op handler 会被清理。

最小插件：

```scheme
(plugin hello
  "Adds a greeting tool."
  (imports)
  (exports)
  (op-register-tool
   'hello
   "Return a greeting."
   (schema '((name "string" "Name")))
   (lambda (args)
     (string-append "hello " (assq-ref args 'name)))))
```

`plugin` body 中每个 form 都必须返回一个 op datum。启动时 sah 先发现包，再按依赖顺序
挂载其中定义的 plugin。

### Import 与 export

```scheme
(plugin base
  (imports)
  (exports port)
  (op-define 'port 8080)
  (op-define 'secret "private"))

(plugin consumer
  (imports base)
  (exports endpoint)
  (op-define
   'endpoint
   (string-append "localhost:" (number->string port))))
```

`consumer` 只能看到 `base` 显式导出的 `port`。缺失依赖、循环依赖、重复导入名称和未定义
export 都会使挂载失败。

### 内置 op

| op | 作用 |
|---|---|
| `op-define` | 在 plugin local scope 定义 binding |
| `op-register-tool` | 注册模型工具 |
| `op-register-hook` | 注册运行时 hook |
| `op-register-command` | 注册 slash command |
| `op-register-renderer` | 注册 message、entry、event 或 widget renderer |
| `op-register-widget` | 注册 TUI widget |
| `op-register-session-bootstrap` | 向 session `eval` 环境加入 Scheme forms |

示例：

```scheme
(plugin project-policy
  "Adds a shell guard and a status command."
  (imports)
  (exports)
  (op-register-hook
   'tool-call
   (lambda (name args)
     (and (eq? name 'shell)
          (string-contains?
           "rm -rf /"
           (or (assq-ref args 'command) ""))
          '(block . "refusing destructive command"))))
  (op-register-command
   'policy
   "Show the active project policy."
   (lambda (args)
     (printf "project policy is active~%")
     #f)))
```

### Hook 点

| hook | 参数 | 可返回 |
|---|---|---|
| `session-start` | `session config` | 忽略 |
| `session-before-switch` | `current next reason` | `'(cancel . WHY)` |
| `session-shutdown` | `session reason target-file` | 忽略 |
| `before-agent-start` | `text session config` | `'(prompt . TEXT)`、`'(inject . TEXT)`、`#f` |
| `input` | `text` | `'handled`、`'(transform TEXT)`、`#f` |
| `before-request` | `messages config` | 替换后的消息列表 |
| `before-provider-request` | `payload config` | 替换后的请求 datum |
| `tool-call` | `name args` | `'(block . REASON)`、`'(args . NEW-ARGS)`、`#f` |
| `tool-result` | `name args out is-error` | `(list NEW-OUT NEW-IS-ERROR)` |
| `after-reply` | `reply config` | 替换后的回应 |
| `before-compact` | `reason instructions` | `'(cancel . WHY)`、`'(instructions . TEXT)` |
| `before-fork` | `session target` | `'(cancel . WHY)` |
| `before-tree` | `session target` | `'(cancel . WHY)` |
| `session-end` | `session` | 忽略 |

guard/veto hook 失败时 fail-closed；普通 transform/effect hook 失败时 fail-open。具体策略由
`hook-specs` 定义。

### Renderer 与 widget

```scheme
(plugin visual-status
  (imports)
  (exports)
  (op-register-renderer
   'message 'assistant
   (lambda (message format width)
     (and (eq? format 'plain)
          (list (string-append "assistant> "
                               (assistant-text message))))))
  (op-register-widget
   'footer 'project-status
   (lambda (context format width)
     (list "project: ready"))))
```

renderer 返回逻辑行列表；返回 `#f` 时使用内置 renderer。异常会记录并回退。widget
placement 支持 `header`、`above-editor`、`below-editor` 和 `footer`。

### Session Scheme 能力

`op-register-session-bootstrap` 把 forms 加入每个 session 的隔离 `eval` 环境。挂载、卸载
或重启插件后，当前 session 会从有效 bootstrap 和 journal 重建 scope。

预装的 `scheme-match`、`minikanren` 和 `z3` 都使用这个 op；核心不认识这些名称。

### 自定义 op

包的 `plugin.ss` 可以在定义 plugin 前注册新的 op kind：

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

`prepare` 不能产生外部作用；`apply` 返回撤销所需的 handle；`rollback` 只撤销本次安装。
无法可靠撤销的作用不应伪装成 plugin op。

### 生命周期

用户和模型使用同一套入口：

```text
/plugins
/plugin inspect NAME
/plugin mount NAME
/plugin dispose NAME
/plugin restart NAME
```

模型使用 `plugin` 工具执行相同操作。plugin 集合改变后，当前 session 的 eval scope 会
重建；若 journal 依赖被卸载的 Scheme 能力，操作会被拒绝并恢复原集合。

`/reload` 重新发现 plugin packages、skills 和 prompt templates，然后重建 system prompt
与当前 eval scope。更新 chez-z3 这类已被 Chez import 的 R6RS library 后应重启进程。

## Skill

```markdown
---
name: scheme-review
description: 审查 Scheme 代码的风格、正确性与 Chez 陷阱。
---
审查当前目录的 Scheme 代码。
```

只有 `name`、`description` 和路径进入 system prompt；正文由模型在需要时用 `read`
读取。用户可以用 `/skill:scheme-review [参数]` 强制加载。

## Prompt template

```markdown
---
description: 审查暂存改动
argument-hint: "[关注点]"
---
审查 `git diff --cached`。额外关注：${1:-无}。
```

文件名就是命令名。参数支持 `$1`…`$9`、`$@`、`$ARGUMENTS` 和 `${N:-默认值}`。

## 安全边界

- plugin package 与 session `eval` 都以当前用户权限执行，不是安全沙箱。
- 只加载可信项目中的 `.sah/plugins`。
- hook 是同步的；长时间工作应放进 tool。
- 本机 provider、代理 URL、API key 和调试配置不得进入仓库。
