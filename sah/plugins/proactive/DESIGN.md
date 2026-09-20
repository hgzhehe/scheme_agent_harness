# proactive

sah 的主动性（pro-activeness）基底：让 agent 按时间或按事件自行发起动作。

```
sah/plugins/proactive/plugin.ss      1072 行
tests/proactive-check.ss               49 项
```

---

## 1. 主动性及其两个硬问题

### 1.1 现状

Agent 的经典刻画里，主动性（pro-activeness）与反应性（reactivity）、自主性并列：
一个理性 agent 既要对环境变化作出反应，也要朝目标主动迈步。而当代 agent 框架
绝大多数只实现了反应性——一个 ReAct 式循环，等待输入，产出动作。

主动性在实践中被**外置**：cron 起一个进程，平台定时器发一条 webhook，运维脚本
定期把一段 prompt 灌进 CLI。外置方案有一个根本缺陷：**被唤醒的 agent 与被使用的
agent 不是同一个运行实例**。它拿不到上一次的会话历史，拿不到正在求值的词法作用域，
拿不到已注册的工具与能力。它只能从零开始，或靠外部拼装上下文。

次好的做法是**心跳回合**：定时向 agent 灌一条无内容的唤醒消息，让它自检。
这保留了运行实例，但代价是每次都烧一个完整回合，且唤醒内容与"要做的事"无关。

第三种是**自我排程**：agent 通过一个工具给自己安排未来任务。它保留了运行实例，
也让"要做的事"由 agent 自己决定。缺的只是基底——把"何时触发"这件事做成一个
可注册、可列举、可取消的一等对象。这就是本插件提供的东西。

在进程内实现主动性，才是让"未来的自己给现在的自己留张便条"成立的唯一方式。

### 1.2 两个硬问题

**单写者会话。** agent 回合不是纯函数：它向会话追加消息、可能触发上下文压缩、
可能改变词法作用域。两个回合并发写同一份日志会交错损坏上下文。因此主动性
**不能抢占**正在进行的回合，只能排队——即**反压**（backpressure），而非抢占式调度。
这条约束贯穿整个调度设计。

**无人值守的回合要可控。** 自主回合没有人在旁边看着：它烧 token，可能跑偏，可能失败。
因此每一次自主动作必须是**可枚举、可取消、可审计**的。这解释了为什么任务模型是
"显式注册的一等对象"，而不是"随手起一个线程跑一段代码"。

---

## 2. 实现基底：续延作为调度原语

不带续延的语言实现协程式调度，必须把计算的状态**显式物化**：状态机、生成器
（编译器改写为状态机）、`async/await`（改写为 CPS + 框架的调度器）。计算被暂停的
那一刻，"剩下要做什么"必须由程序员写成数据。

有完整续延则不需要。**续延本身就是"剩下要做什么"**，捕获它就等于捕获计算状态。
于是调度器退化为一个**续延队列**：

```
挂起 = 捕获自己的续延，入队；然后调用一个外层续延，把栈交还给循环
恢复 = 调用队列里那个续延，栈帧被装回，从挂起处继续
```

Chez 的 `call/cc` 提供完整续延，两个方向都成立，且开销小。这是本插件选择
Scheme 作为实现语言的直接理由——不是"用上了 call/cc"这个说法本身，
而是**协程式调度在这里不需要任何状态物化**。

两个必须点明的性质：

**续延捕获的是"控制上下文"，其范围由捕获点所在的构造决定。** 在 `for-each`
内部捕获，捕获到的是"本循环剩余的全部迭代"，因为 `for-each` 不界定捕获范围
（它不是 delimited control 的界定符）。这一点在本插件里不是一个边角注意，
而是**调度纪律的强制约束**，见 §4.4。

**完整续延是多次可调用的（multi-shot）。** 同一个续延可以被恢复任意多次，
每次重新进入同一段控制上下文。这既是灵活性（可以重放、可以回溯），
也是危险（恢复一个已经"逻辑上走完"的续延会重放副作用）。本插件的挂起
本质上是 one-shot 用法，但不能依赖这一点，所以用结构上的约束来保证正确性。

作为对照：Haynes/Hieb/Friedman 的 **engine** 用续延实现时间片抢占，
`amb`/回溯用它实现非确定性。本插件的调度器是这些构造的一个**协作式、单线程**的
简化版本：不做抢占，只在回调显式让出时切换。

---

## 3. 设计

### 3.1 机制而非策略

> 本插件只回答**「何时触发」**，不回答**「触发什么」**。

插件不含自驱循环，不含"目标未达成就再来一轮"的逻辑，不规定 agent 该关注什么。
到点后做什么由载荷的**内容**决定，而内容由模型、用户或会话代码给出。

这使自主性可控：任何一次自主动作都是某个人显式排下的，因此可枚举、可审计、可撤销。
模型通过工具给自己排活，于是"agent 决定未来何时关注什么"成立，而决定权始终在模型手里。

### 3.2 任务模型

一个任务 = 一个**触发器** + 一份**载荷**。

| 触发器 | 语义 |
|---|---|
| `every ms` | 周期，首次在 `ms` 后 |
| `after ms` | 一次性，触发后自回收 |

| 载荷 | 触发时 | 产生回合 |
|---|---|---|
| `prompt` | 文本作为一次全新的 agent 回合投递 | ✅ |
| `note` | 往会话日志追加一行，模型下一回合可见 | ❌ |
| `callback` | 一个 Scheme 闭包，在调度线程上执行 | ❌ |

`note` 与 `prompt` 的区别是本质性的：前者是**对模型的输入**而不消耗一次推理，
后者消耗一整回合。巡检类任务用 `note` 记录观察，用 `prompt` 触发处置。

**重名即替换**——agent 修订自己的计划时，这正是想要的语义。

### 3.3 反压

§1.2 的单写者约束，落实为三条规则：

- 运行时有回合在跑（`running > 0`）时，`prompt` 与 `note` **排队**，不写会话
- 若检测到**非自己**发起的回合（用户敲了回车），取消自己那次自主运行让路
- 回合结束、`running` 归零时，投递队列

代价是「触发时刻」与「看见时刻」可能相差很远：一个正在跑的长回合会推迟所有主动投递。
这是正确性的代价，不是缺陷。`prompt` 载荷在**独立线程**上投递，因为 agent 回合
会阻塞到模型返回。

### 3.4 可逆性

每个注册项（hook、tool、command、renderer、事件订阅、会话作用域注入）都是
pin 在插件 owner 上的 sah capability。`plugin dispose` 即全部回滚。
调度线程在下一拍发现自己的插件槽位不再活跃，自行退出。

结果：插件不留后台资源。没有任务、没有挂起、没有排队时，线程不存在
（报告里显示 `scheduler not needed`）。

---

## 4. 核心机制

### 4.1 回卷点

调度循环**顶端**捕获一个续延，称为**回卷点**（rewind point）：

```scheme
(call/cc (lambda (k) (state-rewind-set! st k) 'boot))
(loop ...)
```

挂起协议由两个续延构成：

```
1. call/cc 捕获「回调剩余部分」的续延 k
2. 把 k 连同数据存进队列
3. 调用回卷点 ────► 当前栈被丢弃，线程交还循环
```

恢复时调用 `k`，回调的栈帧被装回，**从挂起处继续**而非重跑。

回卷点永不返回，这一点被用来消除一个本会存在的歧义：

```scheme
(let ((reply (call/cc (lambda (k) <入队 k> (rewind 'park)))))
  reply)
```

唯一能到达 `call/cc` 返回值的路径，就是有人调用 `k`。因此**不存在**
"我是首次进入还是被恢复"的判断，从而也不可能判断错——即使恢复方向 `k` 传入一个
过程对象。完整续延在这里换来的是**判断的消失**，而不只是语法的便利。

### 4.2 两类挂起

| 原语 | 恢复者 | 语义 |
|---|---|---|
| `(proactive-pause! ms)` | 时钟 | 定时器：ms 后恢复自己 |
| `(proactive-handoff! ch v)` | 订阅者 | 交接：把「值 + 续延」交给别人 |

两者共用同一套机件（捕获、入队、回卷、恢复），区别只在**谁**持有续延。
`pause!` 把续延交给时钟，`handoff!` 把它交给一个频道。

### 4.3 续延作为消息

交接让**调用栈本身成为消息**。生产者挂起后，它的续延——剩余函数体、局部变量、
待返回的栈帧——作为普通数据流经队列。订阅者以 `(handler value k)` 收到它，
可在**自己的栈内部**续跑生产者的栈：

```scheme
(define (consumer value k)
  ...                        ; 消费者自身的计算
  (k (list 'verified value)) ; 从这里进入生产者的栈
  ...)                       ; 生产者的 (handoff ...) 现在返回这个 reply
```

生产者不重启：它从停下的地方继续，带着消费者的回复。注意控制流的形状——
生产者的剩余部分在消费者的动态范围内执行，两者的栈在那一刻是嵌套的。

在无续延的语言里，这件事要靠显式状态对象模拟：把"生产者算到哪了"编码成数据，
消费者读取并推进它。本插件不需要那层编码。

### 4.4 捕获范围与调度纪律

§2 提到的性质在这里变成一条硬约束。

`for-each` 内的续延捕获了**剩余迭代**，因为 `for-each` 不界定捕获范围。
直接后果（已验证）：

```scheme
(for-each (lambda (x) ... (call/cc (lambda (k) (set! saved k))) ...) '(a b c))
;; 之后调用 (saved 'resume)：
body calls: (a b c b c)
```

由此得到**调度纪律**：

> 一个 pass 只做一件事，且「触发」必须是该 pass 的最后一步。

若一个 pass 取出整个到期列表再 `for-each` 触发，那么其中会挂起的那个回调，
其续延里**带着排在它后面的任务**；恢复时那些任务会被再触发一次——
在定时器语义下这是一次真实的重复触发。

把触发放在 pass 最后，挂起回调的续延里就只剩"回到循环"，没有待办。
这是本插件里`call/cc` 影响算法形状而非仅影响实现的唯一一处，也是最容易做错的一处。

---

## 5. 算法

### 5.1 调度循环

```
scheduler(rt, st):
    REWIND ← call/cc(k => st.rewind ← k; boot)

    loop:
        if st.stop ∨ ¬plugin_alive(rt) ∨ idle(st):
            teardown(st); return                 # 无事自退

        if st.suspended:                         # 用户 /proactive pause
            sleep_slice(next_wait(st))
        else:
            # 一个 pass 一个动作；触发/派发是 pass 的最后一步
            if resume_one(rt, st):               # 到期的挂起续延
                ⊥                                # 只会跳进被挂起的栈
            elif dispatch_one_event(rt, st):     # 事件队列非空
                ⊥                                # 可能经续延跳进生产者栈
            else:
                job ← claim_due(st)              # 至多一个；加锁推进或移除
                if job: run_job(rt, st, job)     # 可能挂起 → 回卷
                else:
                    kick(rt, st)                 # 投递排队中的 prompt/note
                    sleep_slice(next_wait(st))

next_wait(st):
    if st.events ≠ ∅: return 0                   # 队列里有活，不睡过去
    D ← {job.due} ∪ {resume.due}
    if D = ∅: return 500                         # 上限，使 dispose 能被及时察觉
    return max(0, min(500, min(D) − now))
```

`⊥` 表示"本 pass 到此为止"：调用续延把控制流交给别的栈，当前 pass 被放弃。
调度线程按需启动：挂上第一个任务时创建，空闲时自行退出。

### 5.2 挂起

```
pause(ms):
    st ← current_state()                         # 调度线程的本地身份
    reply ← call/cc(k =>                         # k = 回调的剩余部分
                lock: enqueue_resume(st, now+ms, k)
                st.rewind(park))                 # 永不返回 → 栈被丢弃
    return reply                                 # 仅在有人调用 k 时到达
```

### 5.3 交接

```
handoff(channel, value):
    st ← current_state()
    reply ← call/cc(k =>
                lock: enqueue_event(st, channel, value, k)
                st.rewind(handoff))              # 永不返回
    return reply
```

### 5.4 派发

```
dispatch_one_event(rt, st):
    event ← lock: pop_front(st.events)           # FIFO
    if event = ∅: return #f
    (channel, value, k) ← event
    emit(proactive-event, channel, k ? handoff : signal)
    handler ← lock: lookup(st.handlers, channel)
    if handler = ∅:
        journal_note("event CH 到达但无监听者")    # 带续延的事件不能静默挂死
        return #t
    guard: handler(value, k)                     # 可能 (k reply) → 续跑生产者
    return #t
```

`k = #f` 表示**纯事件**（`proactive-signal!`，无生产者等待）；
`k` 是续延表示**交接**。订阅者由此可以区分两种来源。

### 5.5 不变量

| # | 不变量 | 违反的后果 |
|---|---|---|
| I1 | 一个 pass 一个动作，触发/派发是最后一步 | 续延带回待办，恢复时重复触发（§4.4） |
| I2 | 回卷点是挂起的唯一出口 | 栈泄漏，控制流分叉 |
| I3 | handlers / jobs 是**注册**，不是线程状态 | 线程退出时静默遗忘监听器 |
| I4 | 同时至多一个 agent 回合在写会话 | 会话历史交错损坏（§3.3） |

I3 值得单独说明：调度线程空闲退出时会重置**线程状态**（thread / rewind / stop? /
delivering? / expecting?），但**不**触碰 jobs、events、handlers——后者是控制面注册，
清掉它们会让刚注册的监听器在调度器恰好无事可做时被遗忘，而"注册后立刻无事可做"
正是启动后的第一瞬间。

---

## 6. 接口

### 6.1 三个使用面

**工具 `proactive`**（模型自我排程）
```json
{"action": "after", "name": "verify", "interval_ms": 5000,
 "prompt": "check whether the build passed and fix it if not"}
```

**命令 `/proactive`**（人排程）
```
/proactive after verify 5000 check the build
/proactive list
/proactive cancel verify
```

**会话作用域函数**（会话代码排程）
```scheme
(proactive-every! name ms text)      (proactive-after! name ms text)
(proactive-note! name text)          (proactive-jobs)
(proactive-fire! name)               (proactive-cancel! name)
(proactive-clear!)                   (proactive-control action ...)
(proactive-on! channel handler)      (proactive-off! channel)
(proactive-signal! channel value)
```

### 6.2 回调内部 API

```scheme
(proactive-pause! ms)        挂起自己，ms 后从此处继续
(proactive-handoff! ch v)    挂起自己，把「值 + 续延」交给订阅者
(proactive-abort! reason)    放弃回调剩余部分
(proactive-running-state)    当前调度器状态，或 #f
```

前两个只在调度线程上的回调内有效；在别的线程调用得到明确错误，而非未定义行为。

### 6.3 配置

`~/.sah/proactive.scm` 或 `<workspace>/.sah/proactive.scm`，在 `session-start` 时装载：

```scheme
(every "build-watch" 300000 "run the build; if it is red, fix it")
(every 600000 "check whether anything I was told to do is still open")
(after 5000 "summarize the open threads in this session")
(note 3600000 "checkpoint: an hour has gone by")
```

每个 form 是 `(kind ms text)` 或 `(kind name ms text)`。

---

## 7. 示例

三个示例各验证模型的一个不同性质。

### 7.1 自主发起回合

```scheme
(proactive-after! "helloworld" 10000
  "Reply with exactly this one line and nothing else: helloworld")
```

十秒后会话日志出现 `[proactive:helloworld] ...`，agent 自发产出回复 `helloworld`，
全程无用户输入。

**验证的性质**：定时器 → 自主回合的最小链路。同时暴露反压的存在——
触发时若有回合在跑，prompt 排队，「触发时刻」与「看见时刻」可以相差很远。

### 7.2 跨时刻共享会话状态

| 时刻 | 任务 |
|---|---|
| +10s | `eval` 出一个值 → 存进会话变量 → 写文件 A |
| +20s | `eval` **读那个变量** → 写文件 B → 写日志 |

两份载荷都是 `callback`，不经过 agent。

**结果**：A = B。日志证据把顺序钉死：

```
840: (scope-form    839 838 1789867068110 (define p523-secret (random 1000000)))
841: (custom-message 840 839 1789867078148 "[proactive:secret] ... 730407")
```

两条相隔 10038ms，**中间没有任何 agent 消息**——两个定时器确实各自独立触发；
若被合并进同一轮，中间必然夹着消息条目。另外，`scope-form` 里存的是
**未求值的形式**而非值，所以那个数字直到任务 2 自己交出它之前，不存在于磁盘任何位置。

**验证的性质**：两个回调在不同时刻、调度线程上向同一个会话作用域 `eval`，
变量在两次触发间存活。这是主动性真正区别于"外置 cron"的地方：它共享运行实例的状态。

### 7.3 跨任务的调用栈交接

```scheme
(define (job1)
  (proactive-pause! 10000)                       ; 睡十秒
  (let ((payload ...))
    <写会话变量 + 文件 A>
    (let ((reply (proactive-handoff! 'handoff-1 (list 'done payload))))
      <job1 从自己的栈继续，带着 job2 的回复>)))

(define (job2 value k)                           ; 事件驱动消费者，无定时器
  (let ((from-var <eval 读会话变量>))
    <写文件 B>
    (k (list 'verified from-var))))              ; 从 job2 的栈内部续跑 job1
```

轨迹：

```
(job1-sleeping-10s                        ← job1 触发，开始睡
 job1-awake                               ← 时钟把它唤醒
 (job1-hands-off 730407)                  ← 数据发往 变量 / 文件 / 事件
 (job2-received (done 730407))            ← 队列把「值 + 续延」递给 job2
 (job2-read-session-var 730407)           ← job2 eval 出会话变量
 (job2-continuing-job1 730407)            ← job2 调用 k
 (job1-continued-with (verified 730407))) ← job1 从自己的栈里继续
```

顺序是断言本身：`job1-continued-with` 排在 `job2-continuing-job1` **之后**——
job1 的续延在 **job2 的调用栈内部**执行。

**验证的性质**：一个任务的续延可以作为数据交给另一个任务，后者在其自身栈内
恢复前者。这是 §4.3 的直接演示，也是外置方案无法表达的能力。

---

## 8. 限制

| 限制 | 成因 |
|---|---|
| **非硬实时** | `fork-thread` 是绿色线程：Scheme 代码跑在单个 OS 线程上，agent 做 CPU 活会推迟调度线程的 tick。250ms 定时器在负载下实测 394–576ms 间隔 |
| **无定时器原语** | 该 Chez 构建未绑定 `thread-sleep!`。时钟由 `fork-thread` + `sleep` + deadline 轮询实现 |
| **续延不可序列化** | 挂起只存在于内存。因此**不支持"任务写盘、重启后接着跑"**——这是完整续延换来实现简洁的固有代价，不是可修补的遗漏 |
| **定时器不持久** | 进程退出后已注册任务消失。已触发的事实（`note` 落的日志行）作为历史留存，定时器本身不留 |
| **反压即延迟** | 不抢占回合（I4 的代价）：忙时排队，「触发」与「看见」可能相差很远 |
| **平面结构** | 无依赖图 / 工作流。"A 完成才做 B" 需靠事件频道手工连线 |
| **仅两类触发器** | 时钟与事件。没有谓词监视（"当文件变化时"）；可用 `every` 轮询自行实现 |
| **单消费者** | 一个频道一个 handler。发布订阅需要更完整的路由 |
| **无权限层** | 没有"哪些任务允许调用哪些工具"的约束 |
| **`(random n)` 注记** | 该 Chez 未播种的 `random` 是确定性的，且每个 `fork-thread` 出来的线程各自从同一默认状态开始，故回调内首次抽取恒为同一值。示例 7.2 / 7.3 的「A = B」不受影响，但"值不可预测"不成立；要不可预测须显式播种 |

---

## 9. 位置

现有三个内置插件（`match` / `minikanren` / `z3`）都是**纯被动**的：
往会话作用域注入语法，然后等待被使用。`proactive` 是仓库里第一个**主动方**，
也是第一个注册 hook / tool / command / renderer / **自定义 op** 的包。

与相邻机制的取舍：

| 目标 | 机制 | 为什么不用本插件 |
|---|---|---|
| 每次回合前改提示词 | `before-agent-start` hook | 同步变换，无时钟需求 |
| 拦住某次工具调用 | `tool-call` hook | 同上 |
| 会话开始做点事 | `session-start` hook | 本插件**内部**用它装载配置 |
| 观察 / 记录 agent 行为 | `runtime-subscribe!` | 只读旁路 |
| 语言扩展（语法、求解器） | `op-register-session-bootstrap` | 被动的语法注入 |
| **时间 / 事件触发的自主动作** | **本插件** | — |

### 文件

| 文件 | 说明 |
|---|---|
| `plugin.ss` | 实现（1072 行） |
| `DESCRIPTION.md` | 包描述 |
| `README.md` | 使用向简版 |
| `proactive.scm.example` | 启动自动排活的配置示例 |
| `tests/proactive-check.ss` | 49 项离线行为测试 |
| `tests/run-tests.ss` | 内核套件；`custom ops` 段（7 项）覆盖本插件依赖的自定义 op 机制 |
| `src/core/plugin.ss` | 内核改动：`op-register-handler!` 形参 `apply` 遮蔽 Chez 的 `apply`，致该 API 无法注册自定义 op；已改名 `apply-op` 并补测试 |
