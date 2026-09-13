# sah 的组合机制

> 会话作用域、动态插件、effect 是**一个机制**的三个面。
> 本文写的是已实现的机制、模块 API 与用法。EN 镜像待补。

---

## 1. 机制

**组合的单位是词法作用域的环境；作用的单位是可重放的 op。**

```
                    root        sah 自身绑定
                     ↑
当前层链 = import*  会话 / 插件的层（快照：只读、可遮蔽、不可写）
                     ↑
                    plugin*    插件的层，声明 imports / exports
                     ↑
                    local      会话自己的 define
```

- **会话拥有一个环境。** 嵌套（fork / ref）成为 import 层。
- **插件是一段程序**，跑在自己的层里；它的 exports 在**链接期**对别的插件可见。
- **能力就是绑定**——没有服务注册表，`tools` 在 Scheme 里就是一个名字。
- **作用是 op（数据）**——逆由解释器在**改变之前**从 pre-state 导出，于是可以卸载、可以检查、可以拒绝。
- **环境是 log 的视图**，什么都不存：重建 = replay，环境跟着游标走。

核心只有三样：**环境链、op 解释器、log**。工具 / hook / 命令 / provider 全部是"定义了某些绑定的插件"。

---

## 2. 模块

### 2.1 `src/core/env.ss` — 词法环境链

```scheme
(env KIND LABEL PARENT CHEZ-ENV CACHE)
;;   KIND   root | session | plugin
;;   LABEL  这一层是谁（'root，或会话/插件的名字）—— 诊断与报错用
;;   CACHE  #f | stale | (SYMBOLS . MEMBERSHIP-TABLE)   惰性失效，见下
```

| 函数 | 行为 |
|---|---|
| `(env-root)` | 根层。**就是** `(interaction-environment)`：boot 把 sah 源码求值进它，所以下面每一层都看得见 sah 自身的绑定 |
| `(env-layer PARENT KIND LABEL)` | 新建一个**可变**子层（`copy-environment`）。层只能这样产生 |
| `(env-kind e)` `(env-label e)` `(env-parent e)` `(env-chez e)` `(env-depth e)` | 访问器 |
| `(env-has? e NAME)` | 这个名字在这一层链上可见吗（哈希表查，O(1)） |
| `(env-symbols e)` | 可见的名字，已排序 |
| `(env-defined e)` | **这一层相对父层新增的名字**（= 这一层的 exports），已排序。不需要记录任何东西 |
| `(env-origin e NAME)` | 这个名字**由哪一层**定义；找不到返回 `#f` |
| `(env-inherited? e NAME)` | 定义在**祖先层**（不是本层）吗 |
| `(env-eval e FORM)` | 求值（会改动这一层时用它） |
| `(env-value e NAME)` | 读一个值（不触碰缓存） |
| `(env-ref e NAME)` | 值，或 `'absent`——**`#f` 与"不存在"必须可区分**，否则逆无法还原一个原本不存在的名字 |
| `(env-define! e NAME VALUE)` | 把**运行时对象**绑进这一层（闭包也行，见 §5） |
| `(env-try-form! e FORM)` | 按命名规则处理一个 `define` / `define-syntax` / `set!`。→ `(values STATUS MESSAGE)`，STATUS 为 `ok` / `shadowed` / `error` / `skip`。**全函数：失败返回 `error` 而不抛** |
| `(env-replay! e SOURCES)` | 依次重放一组源码字符串。→ 计数与诊断的 alist（见下） |

`env-replay!` 返回：

```scheme
((replayed . 3) (skipped . 2) (failed . 2)
 (notices . (...))            ; 遮蔽报告
 (skipped-forms . (...))      ; 没有重放的形
 (failures . (...)))          ; 失败的原因
```

### 2.2 `src/core/plugin.ss` — 插件

```scheme
(plugin  NAME IMPORTS EXPORTS BODY-FORMS)          ; 定义（= library 的形状）
(mount   NAME STATE ENV PAIRS FRAMES)              ; 一次挂载的状态
;;        STATE: defined | linking | linked | mounted
(frame   OP FORM PRE HANDLE KIND)                  ; 撤销日志的一条
```

| 函数 | 行为 |
|---|---|
| `(plugin NAME (imports I …) (exports E …) BODY …)` | 源形。把插件登记为 `defined` |
| `(plugin-mount! NAME)` | 链接（若需要）然后执行 effect op，逐条记 frame。**会先挂载它的 imports**（`import` 会 invoke 库） |
| `(plugin-dispose! NAME)` | 逆序执行 frame 链（跳过层 op），然后丢掉这一层。**先级联卸载依赖它的插件** |
| `(plugin-list)` | `((NAME . STATE) …)` |
| `(plugin-requirements NAME)` | 声明的 imports |
| `(plugin-exports NAME)` | 声明了**且这一层确实定义过**的 exports |
| `(plugin-env NAME)` | 插件自己的层 |
| `(plugin-frames NAME)` | 撤销日志，**一行一条，派生** |
| `(plugin-frame-data NAME)` | 同一条日志的完整版（含源形、pre-state、handle） |
| `(plugin-mount-all!)` `(plugin-dispose-all!)` | 加载器与 `/reload` 用的批量操作 |
| `(op-kinds)` | 已登记的 op 构造子，已排序 |
| `(op-requires OP ENV)` `(op-pre OP ENV)` `(op-do OP ENV)` `(op-undo OP ENV PRE HANDLE)` | op 的四张分派表 |
| `(op-show OP)` | op 的可读行，**派生**：kind 去掉 `op-` 前缀 + 位置 1 上的标识符 |
| `(frame-show F)` `(frame-detail F)` | 一条 frame 的行 / 完整视图 |
| `(value-show V)` | 有界的值渲染 |

### 2.3 三张注册表新增的逆操作

`register-*!` 原本只有"加"，没有"减"；插件的 op 需要逆，所以补齐：

| 函数 | 位置 |
|---|---|
| `(unregister-tool! NAME)` | `src/tools/registry.ss` |
| `(unregister-hook! CELL)` | `src/core/hooks.ss`（`register-hook!` 现在返回它创建的那个 cell，hook 没有名字可作键） |
| `(unregister-command! NAME)` | `src/extend/commands.ss` |

---

## 3. 用法

### 3.1 写一个插件

放在 `~/.sah/extensions/*.ss`（全局）或 `<cwd>/.sah/extensions/*.ss`（项目）。启动时读入即挂载。

```scheme
;; ~/.sah/extensions/project-facts.ss
(plugin project-facts
  (imports)                       ; 没有依赖
  (exports codename)              ; 别的插件可以 import 它
  (op-define 'codename "PINEAPPLE")
  (op-register-tool 'codename
                    "Return the project codename."
                    (schema '())
                    (lambda (args) codename))          ; 直接用本层/导入的名字
  (op-register-hook 'before-agent-start
                    (lambda (text session config) '(inject . "FACTS"))))
```

**插件体是数据**，在插件自己那一层里求值：导入的名字**直接写**（上例的 `codename`），不需要任何前缀或 `ctx` 参数。`syntax-rules` 是卫生的，所以这也只能是数据——宏引入的变量不会是 body 里写的那个变量。

写不出东西时先定义它：

```scheme
(plugin my-tools
  (imports core)                  ; 用别的插件的 exports
  (exports)
  (op-define 'read-toml (lambda (path) (parse-toml (read-file path))))
  (op-register-tool 'toml "Read a TOML file." (schema '((path "string" "File")))
                    (lambda (args) (read-toml (assq-ref args 'path)))))
```

### 3.2 装载、查看、卸载

```scheme
(plugin-mount! 'project-facts)        ; 或：放进 extensions/ 由启动/`/reload` 挂载

(plugin-list)          ; ((project-facts . mounted))
(plugin-frames 'project-facts)
;; => ("register-hook before-agent-start"
;;     "register-tool codename"
;;     "define codename")

(plugin-frame-data 'project-facts)    ; 完整视图
;; => (("register-tool codename"
;;      (form . "(op-register-tool (quote codename) \"Return the project codename.\" (schema (quote (...))) (lambda (args) codename))")
;;      (pre . #f) (handle . codename) (undo . registry))
;;     …)

(plugin-dispose! 'project-facts)      ; 逆序撤销它自己的作用，然后丢掉它的层
```

REPL 里有 `/reload`：它先 `plugin-dispose-all!`（每个插件撤自己的），再重读扩展文件。

### 3.3 附加载（agent 侧）

插件是 datum，所以 `eval` 就是入口，不需要新工具：

```scheme
(eval '(plugin-mount! '(plugin tmp (imports) (exports)
                         (op-register-tool 'ping "Pong." (schema '()) (lambda (a) "PONG")))))
(eval '(plugin-list))            ; ((tmp . mounted))
(eval '(plugin-dispose! 'tmp))   ; 撤销，工具消失
```

### 3.4 给扩展作者：登记一种新的 op

op 集合本身是注册表，所以**谁拥有那个 effect，谁登记它的 op**。加一种能力 = 一处声明 + 四张表：

```scheme
;; 在拥有该 effect 的那一层里
(define (op-register-thing name value) (list 'op-register-thing name value))   ; 构造子 = 数据

(op-register-handler!
 'op-register-thing 'registry                                   ; UNDO-KIND: 'registry | 'layer
 (lambda (op env) #f)                                           ; REQUIRES
 (lambda (op env) (find-thing (cadr op)))                       ; PRE（在改变之前读）
 (lambda (op env) (do-register-thing (cadr op) (caddr op)) (cadr op))   ; DO → 返回 handle
 (lambda (op env pre handle) (undo-register-thing handle)))     ; UNDO
;; 第 7 个参数是可选的 (lambda (op) → 一行)，不写就用派生行
```

四张表的完备性可机械检查：`(op-kinds)` 的每一项在 `op-requires` / `op-pre` / `op-do` / `op-undo` 上都必须有分派。

---

## 4. 命名规则与不变量

| 名字定义在 | 本层 `define` | 本层 `set!` |
|---|---|---|
| 祖先层（root / import） | 允许遮蔽，**报告** | **拒绝** |
| 本层（session / plugin） | 后者胜（REPL 语义） | 允许 |
| 两个 import 同时导出 | —— **链接期报错** —— | |

```scheme
(env-try-form! rc '(set! inherited 1))   ; => error  "inherited is not writable here: it comes from a"
(env-try-form! rc '(set! unbound 1))     ; => error  "unbound is not defined here, so it cannot be set"
(env-try-form! rc '(define inherited 2)) ; => shadowed "inherited shadows the definition from a"
(env-try-form! rc '(define mine 1))      ; => ok
```

**不变量**

1. **归属是词法的**：一个定义属于哪一层由它在源码里的位置决定，与调用栈无关。判别：祖先层定义的闭包在子层被调用，返回**祖先层**的值。
2. **子不写父**：`define` / `set!` 都不回写祖先层。
3. **跨层写入被拒**：祖先层的名字不可 `set!`；未绑定的名字也不会被 `set!` 创建。
4. **遮蔽可见**：跨层 `define` 允许，但一定被报告。
5. **import 冲突是错误**，不是静默取第一个。
6. **顺序无关**：挂载/导入顺序不影响最终状态（链接期解决）。
7. **环境可从 log 重建**，且 replay 不重演世界作用。
8. **代数外的 op 被拒**，不是被忽略。
9. **逆在改变之前导出**：`op-pre` 先读，`op-do` 后做。

---

## 5. 形状由 Chez 决定（约束 → 设计）

| Chez 事实 | 决定了什么 |
|---|---|
| `(copy-environment ENV)` 给**可变**子环境，绑定是快照 | 运行时能造词法作用域链；层是 `copy-environment` 的产物。~2 ms / 2174 绑定 |
| 库环境不可写（`invalid definition in immutable environment`） | "累积定义"只能发生在 `copy-environment` 出来的层里；`(import …)` 不能用来建会话环境 |
| **运行时对象不能裸嵌进被求值的形**（`invalid syntax`），但 `(quote ,VALUE)` 可以且保同一性 | `env-define!` 用 `(define NAME (quote VALUE))` 绑定任意对象，闭包也行 |
| **没有移除绑定的手段**（无 `unset!` / `undefine`） | 定义的逆是**丢掉整层**，所以 op 分 `'layer` / `'registry` 两类 |
| `(environment-symbols ENV)` 返回 **list**（不是 vector），~1 ms | "这一层定义了什么" = 与父层求差。缓存必须存在，且**惰性失效**（写时标脏、读时才重算） |
| `parameterize` 能绑 `print-length` / `print-level` | 渲染自动有界，长表变 `(0 1 2 3 ...)`、深嵌套变 `(a (b (c (...))))`——不需要自己写截断 |
| 打印器输出 `#<procedure f at file:line>`，但 `eval` 造的闭包无名 | 所以 frame 记**源形**：闭包以源码出现在日志里 |
| `list-set!` 未绑定 | 用 `set-car!` + `list-tail` 改记录槽位 |
| `symbol-hash` 可用 | 层缓存用哈希表做 O(1) 成员判断 |

---

## 6. 与三源的对应

| 借自 | 取的 | 它没有的 |
|---|---|---|
| **R6RS `library`** | `(import …)` 前置、`export`、命名冲突是错误、imports 不可 `set!`、库管理器：已加载可枚举、exports/requirements 可查 | **没有卸载**（Chez 里含 `unload` 的名字是空集）。装一次永不移除 |
| **Cordis** | 卸载 = per-plugin 反向撤销；注册即 effect；递归卸载；组合即数据 | 撤销日志是**不透明闭包**，看不见、diff 不了 |
| **pi** | 插件面宽（hook / tool / command）；工具的渲染属于工具自己；坏插件记录后继续 | 回退靠作者（要求写幂等的 `session_close`），无 per-extension 卸载 |
| **defunc CPS** | frame 是数据且携带中间状态 → 撤销日志可打印、可 diff、可落盘 | —— |

---

## 7. 现状

**已实现并接线**

- `src/core/env.ss`、`src/core/plugin.ss` 在 `manifest.ss` 里，编译进产物。
- 扩展文件里的 `(plugin …)` 由 `load-extensions!` 装载，`/reload` 先整体卸载再重读。
- 三张注册表有了逆操作，op 集合覆盖 `op-define` / `op-register-tool` / `op-register-hook` / `op-register-command`。
- 插件生命周期发事件：`(ev plugin-op NAME KIND LINE)`、`plugin-mount`、`plugin-undo`、`plugin-dispose`——订阅者能累积 append-only 的装卸与副作用历史。
- 现有 `register-*!` 的调用点与已写好的扩展文件**不需要改**；一个文件里的普通顶层副作用仍然是无主注册。

**未接线**

- **工具签名没有 ctx**，所以 `eval` 仍跑在 `(interaction-environment)`，不在会话环境里；会话环境嵌套（§1 的 `session` 层）尚未由 `main`/工具层建立。这是让"每个会话一个环境"生效的最后一步，也是唯一改动运行中产品 ABI 的一步。
- 插件的 frame 与事件**没有时间戳**，也**不落 session**：跨重启的历史目前不保留。
- 沙箱：目前插件一律在你自己的权限下运行（与 pi 相同）；op 准入是能力边界，不是隔离。
