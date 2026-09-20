# proactive 插件 —— 现状与示例记录

> 快照时间：2026-09-20 · 作者：sah 内的 coding agent
> 插件位置：`sah/plugins/proactive/`（经 `~/.sah/plugins/proactive` 软链接被安装态 sah 发现）

---

## 1. 一句话现状

**可用、已挂载、经过实机验证。** 插件能在没有用户输入的情况下按时间或按事件自主触发工作，
包括把 `call/cc` 捕获的**调用栈本身当消息传给另一个任务、由后者续跑**。

两侧测试：插件自测 **34 项全过**；内核套件 **152 项全过**。

需要如实说明的两点：

- 内核套件那 152 项是在**事件队列那次改动之前**跑的。那次改动只碰 `plugins/proactive/plugin.ss`，
  没有触及内核代码，但**没有在改动之后重跑过**（最后一次重跑被你中断了）。
- `proactive-check.ss` 的 34 项是改动之后跑的，全过。

---

## 2. 交付物

| 文件 | 行数 | 说明 |
|---|---:|---|
| `plugins/proactive/plugin.ss` | 1065 | 全部实现 |
| `plugins/proactive/README.md` | 86 | 设计/用法文档 |
| `plugins/proactive/DESCRIPTION.md` | 1 | 包描述（`/plugins`、`plugin list` 里显示的那行） |
| `plugins/proactive/proactive.scm.example` | 22 | 会话启动时自动挂任务的配置示例 |
| `tests/proactive-check.ss` | 355 | 插件行为测试（离线，provider 被 stub） |
| `src/core/plugin.ss` | — | **改动**：修掉内核 `op-register-handler!` 的遮蔽 bug |
| `tests/run-tests.ss` | — | **改动**：新增 `custom ops` 段 7 项回归测试；内置包计数 3→4 |

安装态：`~/.sah/plugins/proactive` → 指向仓库目录的软链接（`rm` 即卸载）。

当前挂载列表（重启后确认）：

```
legacy-smoke  mounted   ← 另一个 agent 加的
minikanren    mounted
proactive     mounted   ← 本插件
scheme-match  mounted
z3            mounted
```

---

## 3. 插件能力

### 3.1 一个 job = 定时器 + 三种载荷之一

| 载荷 | 触发时发生什么 |
|---|---|
| `prompt` | 文本作为**一次全新的 agent 回合**投递，无需任何用户输入 |
| `note` | 往 journal 追加一行，模型下一回合能看到（不产生回合） |
| `callback` | 一个普通 Scheme 闭包，在插件的调度线程上执行 |

`every` 重复，`after` 一次性（触发后自回收）。**重名即替换**，这正是 agent 修订自己计划时想要的。

### 3.2 三个使用面

- **工具 `proactive`** —— 模型可以给自己排活
- **命令 `/proactive`** —— 人在提示行排活
- **会话作用域函数** —— `proactive-every!` / `proactive-after!` / `proactive-note!` /
  `proactive-jobs` / `proactive-fire!` / `proactive-cancel!` / `proactive-clear!` /
  `proactive-on!` / `proactive-off!` / `proactive-signal!`
  （经 `interaction-environment` 桥到内核，`eval` 里直接写代码排活）

### 3.3 事件队列（本次新增）

```
(proactive-on! channel handler)        安装消费者，订阅一个频道
(proactive-signal! channel value)      发一个纯事件（无生产者等待）
(proactive-handoff! channel value)     在回调内挂起自己，把「值 + 续延」发上频道
```

- 消费者签名：`(handler value continuation)`
- 消费者调用 `(continuation reply)` 即**从消费者自己的栈内部续跑生产者的栈**
- 同一个频道一个 handler，重复注册即替换

### 3.4 运行时 API（回调内部可用）

```
(proactive-pause! ms)      挂起当前回调，ms 后从此处继续（定时器语义）
(proactive-handoff! ch v)  挂起并把续延交给别人（事件语义）
(proactive-abort! reason)  放弃回调剩余部分
(proactive-running-state)  当前调度器状态，或 #f
```

配置：`~/.sah/proactive.scm` 或 `<workspace>/.sah/proactive.scm`，形如
`(every "name" ms "text")` / `(after ms "text")` / `(note ms "text")`。

---

## 4. 三个示例的现状

### 示例 1 —— 自主开腔（`prompt` 载荷）

**做了什么**：挂一个 10 秒的一次性 prompt 任务，内容是「只回复 helloworld」。

```scheme
(proactive-after! "helloworld" 10000
  "Reply with exactly this one line and nothing else: helloworld")
```

**结果**：10 秒后 journal 出现 `[proactive:helloworld] Reply with exactly...`，
紧接着 agent 自己产出回复 **`helloworld`** —— 没有任何用户输入。

**现状**：✅ 通过。证明了「定时器 → 自主回合」这条最核心的链路。
**注意**：投递要等运行时空闲。如果触发时正有回合在跑，prompt 会排队，
所以从「触发」到「看见」可能隔很久（这次就隔了我整轮思考的时间）。

### 示例 2 —— 两个定时器 + session 变量交接（`callback` 载荷）

**做了什么**（全程 `callback`，不经过 agent，所以我无法中途看到值）：

| 时刻 | 任务 |
|---|---|
| +10s | `eval` 出随机数 → 存进 session 变量 `p523-secret` → 写文件 A |
| +20s | `eval` **读那个变量** → 写文件 B → 写 journal |

**结果**：A = B = `730407`。

**journal 证据**（条目 ID 与时间戳把顺序钉死）：

```
840: (scope-form 839 838 1789867068110 (define p523-secret (random 1000000)))
841: (custom-message 840 839 1789867078148 "[proactive:secret] ... 730407")
```

- 两条相隔 **10038ms**，且**中间没有任何 agent 消息** → 两个定时器确实各自独立触发
- `scope-form` 里存的是 `(random 1000000)` 这个**未求值的形式**，不是值 →
  磁盘上从头到尾没有那个数字，直到 job2 自己把它交出来

文件 mtime 印证：`09:17:48.131` → `09:17:58.147`，差 **10.016 秒**。

**现状**：✅ 机制通过（跨线程 eval 同一 session scope、变量在两次触发间存活、
callback 里做文件 I/O 和写 journal 都正常）。
**⚠️ 但有水分**：那个「随机数」其实**不是随机的**——见 §6.1。A = B 仍然成立，
但换成「每次跑都不一样的值」这个更强的断言就**不成立**。

### 示例 3 —— 事件队列 + 续延交接（本次重点）

**做了什么**：

```scheme
(define (job1)
  (proactive-pause! 10000)                 ; 睡 10 秒
  (let ((payload (random 1000000)))
    <写 session 变量 + 文件 A>
    (let ((reply (proactive-handoff! 'handoff-1 (list 'done payload))))
      <job1 从自己的栈里继续，拿着 job2 的回复>)))

(define (job2 value k)                     ; 事件驱动消费者：没有定时器
  (let ((from-var <eval 读 session 变量>))
    <写文件 B>
    (k (list 'verified from-var))))        ; ← 从 job2 的栈内部续跑 job1
```

**结果 trajectory**（`/tmp/p523-handoff-trace.txt`）：

```
(job1-sleeping-10s                        ← job1 触发，开始睡
 job1-awake                               ← 定时器把它唤醒
 (job1-hands-off 730407)                  ← 数据发往 变量/文件/事件
 (job2-received (done 730407))            ← 事件队列把「值 + 续延」递给 job2
 (job2-read-session-var 730407)           ← job2 eval 出 session 变量
 (job2-continuing-job1 730407)            ← job2 调用 k
 (job1-continued-with (verified 730407))) ← job1 从自己的栈里继续
```

**顺序是决定性的**：`job1-continued-with` 排在 `job2-continuing-job1` **之后** ——
job1 的续延是在 **job2 的调用栈内部**跑起来的。这就是「job2 利用 job1 的调用栈接续其状态」。

journal 也印证：`[proactive:handoff] job1 resumed its own stack, got (verified 730407)`。

**现状**：✅ 通过。三处数据落点（session 变量 / 文件 A & B / 事件值）都拿到同一个值，
且续跑方向正确。

---

## 5. 机制（怎么做到的）

### 5.1 `call/cc` —— 回卷点 + 两条挂起原语

调度循环顶端捕获一个续延作为**回卷点**。回调挂起时：

1. `call/cc` 捕获**回调自身**的续延（`k`）
2. 把 `k` 连同数据存进队列（定时器队列或事件队列）
3. 调用**回卷点** → 当前栈被丢弃，线程交还循环

恢复时调用 `k`，回调的栈帧被装回来，于是**从挂起处继续**而不是重跑。
实测 5000 次挂起/恢复不涨栈。

`proactive-handoff!` 里有个消除歧义的小技巧：

```scheme
(let ((reply (call/cc (lambda (k) <入队 k> (rewind 'handoff)))))
  reply)
```

`rewind` 永不返回，所以**唯一**能到达 `call/cc` 返回值的路径就是消费者调用 `k`。
不存在「我是首次进入还是被恢复」的判断，因此也不可能判断错——
即使消费者回复一个过程对象也没问题。

### 5.2 时间

Chez 没有定时器设施，且这个构建里 **`thread-sleep!` 没有绑定**。时钟就是：

```scheme
(fork-thread ...) + (sleep (make-time 'time-duration ns s)) + (now-ms) 做 deadline
```

外加 100ms 切片，让 `dispose` 能被及时察觉。TUI 本来就是这么驱动 agent 的，这里沿用同一形状。

### 5.3 线程与调度

- 一个 runtime 一个调度线程，**按需启动、无事自退**（不留后台线程）
- **一个 pass 只做一件事**，且触发/派发是该 pass 的**最后一步**
  （这样回调挂起时，其续延里除了「回到循环」没有别的待办）
- 队列用 `make-mutex` + `with-mutex` 保护（沿用 TUI 事件队列的做法）
- prompt 载荷在**自己的线程**上投递（agent 回合会阻塞到模型返回）

### 5.4 与用户协作

订阅 `agent-start` / `agent-end` 事件：有回合在跑时主动任务排队；
若检测到是**别人**（用户敲回车）开始了回合，取消自己那次自主运行让路。

### 5.5 可逆性

hook / tool / command / renderer / 事件订阅 / session-bootstrap 全部是
pin 在该包 owner 上的 sah capability，`plugin dispose` 即全部消失。

---

## 6. 发现的问题、修复，以及坑

### 6.1 ⚠️ `random` 未播种时是确定性的，且**每个线程各自从头开始**

这是本次最大的「坑」，直接让示例 2 和 3 的「随机数」失去意义：

```
全新进程，主线程第 1 次 (random 1000000)  = 730407
全新线程 a，第 1 次                       = 730407
全新线程 b，第 1 次                       = 730407
```

Chez 的 `random` 默认种子固定；每次 `fork-thread` 出来的新线程似乎从同一个默认状态开始，
所以**每个线程的第一次抽取都是 730407**。回调跑在调度线程上，于是每次演示都是 730407。

**影响**：
- 「A = B」仍然有效（证明 job2 读到的是 job1 存的同一个值）
- 「值不可预测 / 每次不同」**不成立**——这些演示换成 `(random 1000000)` 会得到完全相同的输出

**正确做法**：要不可预测的值，得显式播种（时间/熵），例如
`(seed-random! (now-ms))` 或从 `/dev/urandom` 读。

### 6.2 内核 bug：`op-register-handler!` 的形参 `apply` 遮蔽了 Chez 的 `apply`

`src/core/plugin.ss`：

```scheme
(define (op-register-handler! kind undo requires prepare apply rollback . show)
  (apply runtime-register-op-handler! ...))   ; ← apply 是形参，不是 Chez 的 apply
```

后果：这个 API **永远无法注册 op handler**，而是拿 10 个参数去调用你传入的 apply handler：

```
Exception: incorrect number of arguments 10 to #<procedure ...>
```

即**任何第三方插件都无法注册自定义 op**。我的插件最初是靠直接调
`runtime-register-op-handler!` 绕过的。

**已修**：两处形参改名 `apply` → `apply-op`，并在 `tests/run-tests.ss` 增加
`custom ops` 段 7 项回归测试（注册落地 / `op-show` / prepare-apply-rollback 往返 /
rollback 拿到 handle / 拒绝重复注册 / 包能挂载并显示 effect / dispose 能回滚）。

**顺带发现**：原有那条 `failed plugin package load removes every owned definition`
测试**是蒙对的**——它的 apply handler 是 `(lambda args #t)`，所以被遮蔽的那次调用
恰好「成功」了。修好后它才真正在测「包加载失败能清理干净」。

同类隐患（未改，因为不是活 bug）：`src/agent/agent.ss` 的
`tool-result-transform` 形参 `error?` 遮蔽 `error`；但该函数体没调用 `error`。

### 6.3 插件 bug：`teardown` 把 handler 表清空了

`proactive-on!` 会启动调度线程；线程立刻发现无事可做 → teardown → **清掉 handler 表**。
结果：**刚注册的监听器立刻被静默遗忘**，事件派发时找不到 handler。

**已修**：teardown 只重置**线程状态**（thread / rewind / stop? / delivering? / expecting?）。
jobs、events、handlers 是**注册**（控制面），不是线程状态，不该被清。

### 6.4 调度器形状改动（防御性，**未证实**）

我把调度器从「一个 pass 取整个 due 列表再 `for-each` 触发」改成
「一个 pass 只触发一个任务，且触发放在 pass 最后一步」。

理由是推演：会 pause 的回调会把排在它后面的任务一起捕获进续延，恢复时可能重复触发。
我为它写了回归测试 `a pausing callback does not replay jobs queued behind it`。

**但是我没能证明这个 bug 存在**——把插件回退到旧写法去跑，victim 也只触发一次，
埋点显示 `run-job` 各调用一次，没有重放。

**结论**：新形状本身是对的且更安全（续延里不留待办），性能无损失，予以保留；
但那条测试目前是**防御性**的，不是在挡一个已证实的 bug。注释里已按此说明。

### 6.5 编辑插件需要 reload

磁盘上的 `plugin.ss` 改了，**运行中的进程不会自动生效**。需要：

```scheme
(reload-resources! rt (runtime-config rt) (runtime-cwd rt))
```

或命令 `/reload`。我第一次跑交接演示时报 `variable proactive-handoff! is not bound`，
就是这个原因（不是插件坏了）。

---

## 7. 已知限制

| 限制 | 说明 |
|---|---|
| 定时器精度 | Chez 的 `fork-thread` 是**绿色线程**，Scheme 代码跑在单个 OS 线程上。agent 做 CPU 活时会推迟调度线程的 tick。实测 250ms 的定时器在负载下出现 394–576ms 的间隔（偶尔 +10~30%） |
| `(random n)` | 见 §6.1，未播种时确定性 |
| `proactive-pause!` / `handoff!` | 只在调度线程上的回调内部有效；是**协作式**让路，不是抢占 |
| 定时器不持久 | 进程重启后已挂的任务不恢复。`note` 会落 journal 所以「触发过什么」作为历史留存，但**定时器本身**不留 |
| prompt 排队 | 定时器不会抢占正在跑的回合；忙时排队，所以「触发时刻」和「看见时刻」可能差很远 |
| 无 handler 的事件 | 带续延的事件如果没人监听，会 journal 一条提示而不是静默失败（否则生产者永远挂着） |

---

## 8. 验证记录

### 自动化

```
scheme --script tests/proactive-check.ss     →  34 passed, 0 failed
scheme --script tests/run-tests.ss           →  152 passed, 0 failed   (事件队列改动之前)
```

`proactive-check.ss` 覆盖：包挂载/描述/各注册项、session 作用域 bootstrap、
定时器触发、`proactive-pause!` 挂起恢复（含执行顺序断言）、失败回调不杀调度器、
防重放回归、prompt 自主回合、note 落 journal 且不产生回合、重复任务多次触发、
取消、全部控制动作返回字符串、调度线程无事自退、dispose 回滚、重挂载可用、
配置文件加载、示例配置可解析。

### 实机（本次会话实测）

| 验证 | 结果 |
|---|---|
| 重启后加载 | ✅ 4 个插件全 mounted，proactive 挂载、描述正确 |
| 定时器在我思考时自烧 | ✅ 日志时间戳比我的 `sleep` 起点早 8.6 秒；`[pass]` 埋点可见 |
| `proactive-pause!` 从原处恢复 | ✅ trace `(done resumed start)` |
| 示例 1 自主开腔 | ✅ agent 自发产出 `helloworld` |
| 示例 2 变量交接 | ✅ A = B（但值非随机，见 §6.1） |
| 示例 3 续延交接 | ✅ 顺序证明在 job2 栈内续跑 job1 |

---

## 9. 建议的下一步

1. **重跑内核套件** —— 事件队列改动后还没跑过（改动只碰插件文件，预期 152 仍成立）
2. **给示例换个真随机源** —— 至少让示例 2/3 的「值不同」这层断言站得住
3. **补事件队列的自动化测试** —— `proactive-check.ss` 目前**没有**覆盖
   `proactive-on!` / `proactive-signal!` / `proactive-handoff!`（示例 3 只是手工验证过）。
   至少应有：signal 无续延路径、handoff 续延路径、无 handler 时的提示、off! 之后不派发、
   同一 pass 内多个事件的顺序
4. **定夺防重放那条测试** —— 要么找出能复现的场景，要么把注释/测试降级为纯防御
5. **`reload-resources!` 的健壮性** —— 我传错参数时它抛出的是内部的 `filter: ... is not
   proper list`，报错不好懂

---

## 10. 相关改动（不限于本插件）

本次会话还改动了（`git status`）：`src/core/plugin.ss`（§6.2）、`tests/run-tests.ss`（§6.2）。
另外 `transport.ss` / `tui.ss` / `shell.ss` / `terminal.ss` / `platform.ss` /
`scope.ss` / `loader.ss` / `manager.ss` / `docs/CN/CORE-MECHANISMS.md` 的改动
**不是本次插件工作产生的**（另一个 agent 的工作）。
