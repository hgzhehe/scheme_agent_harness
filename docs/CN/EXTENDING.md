# 扩展与定制 sah

sah 有三个定制面，全都是普通文件：

| 面 | 是什么 | 放在哪 |
|---|---|---|
| **extension** | 注册 hook / 工具 / 命令的 Scheme 文件 | `~/.sah/extensions/*.ss`、`<项目>/.sah/extensions/*.ss` |
| **skill** | 按需加载的 markdown 指令 | `~/.sah/skills/<名称>/SKILL.md`、`<项目>/.sah/skills/...` |
| **prompt template** | 变成 `/命令` 的 markdown 文件 | `~/.sah/prompts/<名称>.md`、`<项目>/.sah/prompts/<名称>.md` |

同名时项目定义覆盖全局定义。三种都有示例放在
[`sah/examples/`](../../sah/examples/)。其中一个值得为自己装上：
[`examples/skills/sah-internals/`](../../sah/examples/skills/sah-internals/SKILL.md)
教 agent sah 自身怎么运作——把它拷到 `~/.sah/skills/`，agent 就会从运行中的系统
回答关于本 harness 的问题而不是猜，你让它扩展 sah 时它也知道该改哪个文件。

## Extension

extension 就是一个普通的 Scheme 文件。加载它等于执行它的顶层代码，里面调用
`register-hook!`、`register-tool!`、`register-command!`。没有 API 对象、没有工厂
函数、没有构建步骤、没有类型定义——因为扩展语言就是实现语言。

```scheme
;; ~/.sah/extensions/guard-destructive.ss
(register-hook! 'tool-call
  (lambda (name args)
    (and (eq? name 'shell)
         (string-contains? "rm -rf /" (or (assq-ref args 'command) ""))
         '(block . "refusing rm -rf"))))
```

写坏的 extension 不会把 agent 拖垮：加载出错会被报告并跳过，hook 抛异常也会被
报告并跳过。

### Hook 点

hook 按注册顺序执行，每个都能看到上一个的结果（中间件风格）。返回 `#f` 永远表示
“没有意见，别动它”。

| hook | 参数 | 可返回 |
|---|---|---|
| `session-start` | `session config` | 忽略（只用副作用） |
| `before-agent-start` | `text session config` | `'(prompt . TEXT)`、`'(inject . TEXT)`、`#f` |
| `input` | `text` | `'continue`、`'(transform TEXT)`、`'handled` |
| `before-request` | `messages config` | 替换后的消息列表 |
| `before-provider-request` | `payload config` | 替换后的 JSON payload |
| `tool-call` | `name args` | `'(block . REASON)` 或 `'(args . NEW-ARGS)` |
| `tool-result` | `name args out is-error` | `(list 新OUT 新IS-ERROR)` |
| `after-reply` | `reply config` | 替换后的回应 |
| `before-compact` | `reason instructions` | `'(cancel . WHY)` 或 `'(instructions . TEXT)` |
| `before-fork` | `session target` | `'(cancel . WHY)` |
| `before-tree` | `session target` | `'(cancel . WHY)` |
| `session-end` | `session` | 忽略 |

实践上要注意的几点：

- `tool-call` 的**拦截**会替换模型看到的工具结果，因此模型知道*为什么*被拒并能改道；
  它不会中止本轮。
- `tool-call` 的参数改写对后续 hook 和真正执行都可见；之后不会重新校验（与 pi 相同）。
- `before-request` 是非破坏性的上下文编辑：改变发出去的内容，但不碰会话。
- `before-agent-start` 每个用户 prompt 跑一次，时机在输入管线定稿之后：用
  `'(prompt . TEXT)` 改写它，或用 `'(inject . TEXT)` 在它前面插一条消息（项目事实、
  提醒、检索到的上下文）。它是**每 prompt** 阶段，`before-request` 是**每请求**阶段。
- `after-reply` 看到的是模型回应解码之后、落盘之前的那份数据，所以 hook 可以脱敏、
  注解或替换它。它作用于“进来”的方向；“出去”的方向是 `before-provider-request`。
- `before-fork` 与 `before-tree` 是**否决**阶段：在 fork 或移动游标之前跑，可返回
  `'(cancel . WHY)`。`--fork` 遇到否决会以非零码退出，所以脚本不会把“被拒绝”误当成
  “已 fork”。
- `before-compact` 返回的 instructions 会追加到摘要提示里，这是做领域专用检查点的
  办法。

### 工具与命令

```scheme
(register-tool! 'ls "列目录。"
  (schema '((path "string" "要列的目录")))
  (lambda (args) (string-join (sort-strings (directory-list (or (assq-ref args 'path) "."))) "\n")))

(register-command! 'tools "列出所有已注册工具。"
  (lambda (args) (for-each ... (all-tools)) #f))
```

命令 handler 返回 `#f`（只做副作用）、字符串（用它替代用户输入发给 agent）、或
`'handled`。

与内置命令（`/compact`、`/context`、`/tree`、`/help`）重名时，内置的那一方胜出。

## Skill

```markdown
---
name: scheme-review
description: 审查 Scheme 代码的风格、正确性与 Chez 陷阱。审查 .ss/.scm 时使用。
---
审查当前目录的 Scheme 代码。
...
```

- 只有 `name` 和 `description` 进 system prompt（作为 `<skills>` 块）；正文由模型
  在需要时用 `read` 读取。这就是渐进披露：五十个 skill 只花五十行摘要的代价。
- 用户可以用 `/skill:scheme-review [参数]` 强制加载；参数会以 `User: ...` 追加。
- 没有非空 `description` 的文件不会被加载。

## Prompt template

```markdown
---
description: 审查暂存的改动
argument-hint: "[关注点]"
---
审查 `git diff --cached`。额外关注：${1:-无}。
```

文件名就是命令名（`review-diff.md` → `/review-diff`）。参数支持 `$1`…`$9`、
`$@` / `$ARGUMENTS`、`${N:-默认值}`。`description` 缺省时取第一行非空文本。

## 与 pi 的对比

pi 的扩展系统更大，是因为它的扩展是 TypeScript 模块：需要加载器（jiti）、schema 库
（typebox）、异步工厂函数、带类型的事件收窄、约 30 种事件、TUI 组件 API，以及包
管理器。sah 用大约 120 行拿到同一套核心机制——具名 hook 点、`#f` 表示“没意见”、
从扩展文件注册工具与命令——因为 Scheme 扩展本身就可以是 Scheme。

有意留下的差距，按“多可能造成影响”排序：

1. **没有项目信任机制。** pi 先加载全局扩展，等信任解析完才加载项目扩展；sah 无条件
   都加载。所以项目扩展和你自己的文件权限一样大——只在你会运行其代码的仓库里跑 sah。
2. **没有主题 / TUI 组件。** 没有 TUI 可主题化；模式层是行式 REPL。
3. **没有包管理。** 扩展就是文件；没有 registry、没有版本锁定、没有 `pi install`。
4. **只有同步。** 阻塞的 hook 会阻塞 agent。pi 的 handler 可以是异步的；如果你需要在
   hook 里访问网络，请保持短小，或把工作放进工具里。

## 调试

- `/help` 列出实际被发现到的命令、模板与技能。
- `/tools`（或 `(all-tools)`）列出已注册工具，包含扩展注册的。
- 启动时会打印 `[sah] extensions: ...`，列出加载成功的每个扩展文件。
- 抛异常的 hook 会打印 `[sah] hook NAME failed: ...` 然后跳过——所以轮次中间出现
  堆栈，通常是扩展的问题，不是 sah 的。
- 一切都在启动时加载。`/reload` 会在运行中的会话里重新读取所有扩展文件、重新发现
  skills 与模板，所以改扩展不用重启。它会先把注册表恢复到内置状态，因此被删掉的
  扩展（以及它注册的 hook）会真正消失。

## 内置命令与输入管线

命令由 `main` 为所有模式注册，所以在 print 模式下也能用：

```bash
sah "/context"          # 下一次请求会带什么
```

内置命令有 `/compact`、`/context`、`/tree`、`/label`、`/name`、`/fork`、
`/reload`、`/help`。同名的扩展
命令会输给内置的（内置在扩展之后注册，而最后注册的同名命令胜出）。

一条用户消息会依次经过几个阶段，每个阶段查自己的注册表：

1. **命令** —— `(register-command! 名称 描述 处理器)`；处理器返回 `#f`（只做副作用）、
   字符串（用它替代发给 agent 的内容）或 `'handled`。
2. **input hook** —— `(register-hook! 'input …)`；返回 `#f`、`'(transform TEXT)` 或
   `'handled`。
3. **已注册的输入 handler** —— `(register-input-handler! (lambda (name args) …))`，
   用来认领你自己的 `/名称`。`/skill:NAME` 和 `/template` 就是其中两个，这也是管线
   不需要知道技能和模板是什么的原因。

没有任何阶段认领的内容，就作为普通文本发给 agent。
