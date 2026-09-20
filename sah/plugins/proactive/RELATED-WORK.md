# proactive 插件 —— 相关工作与下一步计划

> 快照时间：2026-09-20
> 作者：跑在 **pi** 里的 coding agent（不是 sah 内的那个）。`STATUS.md` 是 sah 内的 agent 写的，
> 本文是对它的外部复核 + 文献定位，**结论仍待你拍板**。
> 配套：[`STATUS.md`](STATUS.md)（现状与实机记录）· [`README.md`](README.md)（设计与用法）
>
> 分工：**STATUS 记"做了什么、测到了什么"；本文记"它在文献里是什么、下一步按什么顺序改"**，
> 并且每条建议都绑到 `plugin.ss` 的具体行。
> 引用核查状态见 §8：带链接的是本次检索核对过的；少数经典按记忆列出，已单独标注。

---

## 0. 一页地图

| 你文档里的机制 | 代码位置（`plugin.ss`） | 文献支线 | 一句话结论 |
|---|---|---|---|
| 定时器 → 自主回合（`prompt`） | `proactive-queue!` 181 · `proactive-resume-one!` 259（自己的线程 285） | 主动性 / proactivity | **机制有、gate 没有**；文献共识是"主动性是校准问题，不是能力问题" |
| `pause!` / `handoff!` 的续延交接 | `call/cc` 472（回卷点）· 736（`pause!`）· 845（`handoff!`） | one-shot continuations / 线程让出续延 | 换 `call/1cc`：更快更省，**且把"重复恢复"从静默合法变成报错** |
| 频道 + handler | `proactive-on!` 784 · `off!` 801 · `signal!` 814 · `handoff!` 826 | delimited continuations / algebraic effect handlers | 你的频道就是**一个 deep handler**；要定义"handler 被替换时，在途续延归谁" |
| durable form 重放（sah 内核，插件只是使用者） | `src/core/scope.ss` · `src/session/manager.ss` | deterministic record & replay | **all-or-nothing**：记形式不记值 = 不保证重放；先记值/种子 |
| `callback` 立即 / `prompt` 独立线程 / §6.4 的新形状 | `proactive-run-job!` 229 · 回卷点 472 | ECA 规则的 coupling mode | 正名 + 深度上限 + 环检测（现在两个都没有） |

---

## 1. 主动性：你现在是**无 gate** 的

### 现状（对应 STATUS §3.1 / §4 示例 1 / §5.4 / §7）

一个 `prompt` 载荷到点就投：`proactive-run-job!` → `proactive-queue!`（181）进 pending →
`proactive-resume-one!`（259）在**自己的线程**上投递一次完整 agent 回合。
唯一的"礼让"是 §5.4：检测到有回合在跑就排队，检测到是**用户**开始的回合就取消自己那次运行。

也就是说：**开腔的门槛 = 定时器到点**。

### 文献

2025–2026 的主动性文献基本上一致地把"到点就开腔"当作**反面教材**，并把主动性形式化成
"在不确定性下**校准过的**自主介入"：

- **Lu et al., "Proactive Agent"（ICLR 2025）** —— 收真实人类活动、让人工标注"这条预测该不该接受"、
  训 reward model，发布 **ProactiveBench（6,790 个事件）**，微调后 F1 66.47%。
  链接：[ICLR 2025 proceedings](https://proceedings.iclr.cc/paper_files/paper/2025/hash/75c37811e830bf029584b1c6fac17726-Abstract-Conference.html)。
  → 它给的正是你缺的东西：**"该不该开腔"是可以被标注、被度量、被训的**。
- **PRISM（ICLR 2026）**：cost-sensitive、acceptance-calibrated 的 gate（论文自称 *festina lente*，
  慢思/快思双过程），ProactiveBench 上 **false alarm −22.78%、F1 +20.14%**。
  链接：[ICLR 2026 poster](https://iclr.cc/virtual/2026/poster/10007161)。
- 统一决策框架（Tang et al., arXiv 2609.03727）把主动性形式化成 POMDP 上的四选一：
  **silent / ask / assist / act**，并把"打断、误解、越权、隐私"都算成代价。
  链接：[arXiv 2609.03727](https://arxiv.org/pdf/2609.03727v1.pdf)。
- **"Proactive Conversational AI: A Comprehensive Survey"**（ACM TOIS 43(3), 2025）——
  [NSF 版 PDF](https://par.nsf.gov/servlets/purl/10580599)。
- **"Overhearing LLM Agents"**（arXiv 2509.16325）：监控环境活动、**不索取注意力**地介入。
  链接：[ArxivLens 解析](https://arxivlens.com/paperview/details/overhearing-llm-agents-a-survey-taxonomy-and-roadmap-3248-2169d803)。
  → 这条和你的 **`note` 载荷**几乎是同一个东西：**"记录而不介入"和"介入"是两种模式，不是同一载荷的强弱**。
- 空闲算力这一支：**Sleep-time Compute**（Lin, Snell, Wang, Packer, Wooders, Stoica, Gonzalez；
  Letta × Berkeley）—— [arXiv 2504.13171](https://arxiv.org/abs/2504.13171)；
  以及 **"Anticipate and Learn: Unleashing Idle-Time Compute in Proactive Agents"** ——
  [arXiv 2605.25971](https://arxiv-org.ezproxy.obspm.fr/html/2605.25971v1)。
  → 你的 **`callback` 载荷**（不需要模型、纯预计算）就是这一支的机制面。
- 基准侧已经有：π-Bench（[arXiv 2605.14678](https://export.arxiv.org/pdf/2605.14678)）、
  ProactBench（[arXiv 2605.09228](https://export.arxiv.org/pdf/2605.09228)）。

### 结论

你的 `note` / `callback` / `prompt` 三分**正好**对应文献里的"记录 / 预计算 / 介入"，缺的是**介入前的 gate**。
最小改动建议：

- gate 的位置：**投递之前**，即 `proactive-resume-one!`（259）取 pending 的时候，而不是 `queue!`（181）的时候
  ——排队的时刻和开腔的时刻本来就不一样（§4 示例 1 已经证明"触发"与"看见"会隔很久）。
- 默认策略：**降级为 `note`**，只有同时满足"运行时空闲 + 用户静默 ≥ N 秒 + 与上次介入不重复"才升为 `prompt`。
- **把它做成一个 veto hook**（`before-proactive-fire`），而不是写死在插件里：sah 已经有
  `before-compact` / `before-fork` 这种 fail-closed 的 veto 阶段，gate 是策略，应该可替换。
- 指标：**FAR/h（每小时误报）**。你现在连这个数都报不出来，而文献唯一反复验证的结论就是
  主动性要靠校准而不是靠能力。

---

## 2. 续延与协作调度：家谱极准，而且作者就是 Chez 的作者

### 现状（对应 STATUS §5.1 / §5.2 / §3.3）

调度循环顶端捕一个续延当**回卷点**（472）；回调挂起时捕自己的续延入队、调回卷点丢弃当前栈
（736）；恢复时调 `k` 把回调的栈帧装回来。`handoff!`（845）用

```scheme
(let ((reply (call/cc (lambda (k) <入队 k> (rewind 'handoff)))))
  reply)
```

消除"首次进入 vs 被恢复"的歧义——因为 `rewind` 永不返回，**唯一**能到达 `call/cc` 返回值的路径就是消费者调用 `k`。

### 文献

- **Bruggeman, Waddell & Dybvig, "Representing Control in the Presence of One-Shot Continuations"
  （PLDI'96）** —— [DOI 10.1145/231379.231395](https://doi.org/10.1145/231379.231395) ·
  [Semantic Scholar](https://www.semanticscholar.org/paper/Representing-control-in-the-presence-of-one-shot-Bruggeman-Waddell/2849cc9337fcd42c383f40f97682cd1f64dae764)。
  要点：
  - 线程/协程这类用途里**续延其实只用一次**，于是有 `call/1cc`：一次捕获**整段栈、零拷贝**；
    多 shot 的 `call/cc` 才需要拷回、还要处理 **promotion**（一次性的续延被套进多 shot 续延时必须升级）。
  - Chez 上实测：`call/1cc` 版本比 `call/cc` **快 13%、少分配 23%**。
  - 工程细节：要有**stack segment cache**（内部 free list），因为频繁 capture/release 会把
    storage manager 压垮。→ 这条值得对着你 §7 那条"250ms 定时器在负载下变成 394–576ms"看：
    挂起/恢复越频繁，这个效应越明显。
- **Kumar, Bruggeman & Dybvig, "Threads Yield Continuations"（Lisp and Symbolic Computation 10(3), 1998）**
  —— **这就是你的调度器**。"捕自己的续延、入队、让出"是这篇文章的标准形状。
- 基础是 **Hieb, Dybvig & Bruggeman, PLDI'90**（stack segmentation）。
- **trampolined style**（Ganz, Friedman & Wand, ICFP'99，*按下文 §8 标注为未核查*）里
  "唯一返回路径"的那套论证，就是你的 `handoff!` 技巧的一般形式。

你的 `handoff!` 在 PL 文献里还有第二个名字——**delimited continuation + algebraic effect handler**：

- **Dybvig, Peyton Jones & Sabry, "A Monadic Framework for Delimited Continuations"**，
  *JFP* 17(6):687–730, 2007 —— [DOI 10.1017/S0956796807006259](https://dlnext.acm.org/doi/10.1017/S0956796807006259)。
  （`shift`/`reset`、`control`/`prompt` 的统一 monadic 处理；"CPS 就够了"。）
- **Plotkin & Pretnar, "Handlers of Algebraic Effects"**，*ESOP* 2009, LNCS 5502:80–94 ——
  [DOI 10.1007/978-3-642-00590-9_7](https://dl.acm.org/doi/abs/10.1007/978-3-642-00590-9_7)。
  （**resumption 就是 delimited continuation 的调用**；这篇 2022 年拿了 ETAPS Test-of-Time。）

映射：消费者 `(handler value k)` 调用 `(k reply)` = **在 handler 自己的栈里恢复一个 delimited
continuation**（deep handler 风格）。"一个频道一个 handler、重复注册即替换"
= 一个**可变的 handler 栈**。文献里这一带正好有你需要回答的语义问题：

- **handler 被替换时，在途的续延归谁？** 你 §7 里"无 handler 的带续延事件 → journal 一条提示"
  是这个语义的兜底（否则生产者永远挂着）；但"handler 换成新的之后，旧的 `k` 再被调用"还没有定义。
- **deep vs shallow handler**：你现在是 deep（`k` 恢复的是整个消费者上下文）。要不要支持
  "只处理一层就返回"的 shallow 形式，取决于你想不想让事件能被**中间人**拦截改写。

### 结论（两条，第二条是硬的）

1. **把三处 `call/cc`（472 / 736 / 845）换成 Chez 的 `call/1cc`。**
   同一篇论文、同一批作者（Dybvig 就是 Chez 的作者），为你的用途写的：更快、更少分配、
   而且语义上**更诚实**——你的续延确实都只用一次。
2. **`call/1cc` 的二次恢复是 `error`，多 shot 的 `call/cc` 是静默允许。**
   这正好能把 STATUS §6.4 那条**你没能证明的**防御性测试变成**判决性测试**：
   - 换上去跑旧形状（一个 pass 触发整个 due 列表），如果**报二次恢复错** → 那个 bug 真实存在，新形状是被证明的修复；
   - 如果**永远不报错** → 它不可能发生，测试降级为纯防御（注释照实写）。
   你现在**没有办法区分这两种情况**，因为多 shot 续延把"重复恢复"当合法操作。
   → 这是本文里性价比最高的一条改动。

---

## 3. journal / 会话重放：**最重要的一节**

（这一节讲的是 sah 内核的 durable eval，`src/core/scope.ss` + `src/session/manager.ss`；
本插件目前是它最大的使用者之一——STATUS §4 的三个示例全部落在会话作用域里。）

### 现状

"成功的表单写进 journal，resume 时重放 rebuild scope"。而 **journal 记的是形式（form），不是值（value）**。
STATUS 里三处现象都是这一条的推论：

| STATUS 里的现象 | 在记录-重放理论里是什么 |
|---|---|
| §6.1 `(define p523-secret (random 1000000))`，"磁盘上从头到尾没有那个数字"，并把这当成优点 | **未记录的随机性**。现在能重放纯属运气（Chez 每线程默认同种子） |
| §9.2 "给示例换个真随机源" | **会把"碰巧能重放"变成"必然重放发散"，而且是静默的** |
| 今天两次会话砖死：`(define log (h (eval ... (interaction-environment))))` | **未记录的外部输入**（宿主绑定）。重放在这里发散，而发散被当成硬错误 → 整份 journal 打不开 |

（今天那两次砖死，我在内核侧把"重放失败"从**硬错误**改成了**跳过并逐条上报 + 插件依赖探测改成比较失败集合**。
那是**加载策略**的修法，不是这一节说的**根因**修法。）

### 文献

- **"A Survey of Deterministic Replay Schemes"**，*ACM Computing Surveys* ——
  [DOI 10.1145/2790077](https://dl.acm.org/doi/pdf/10.1145/2790077)。
  中心假设：程序本身是确定的，**不确定性全部来自输入**；因此"录下每一个非确定输入、重放时照录回放"
  就能忠实复原。**并且明确写着 record-and-replay 是 all-or-nothing。**
- 非确定性的四类来源（Flashback 那一系的分类）：① 非确定指令/系统调用/**读时钟**；
  ② 并发；③ **异步事件**；④ 共享内存。以及 **content-based（记值）vs order-based（记序）** 两种记录方式。
- 分级（Zamfir, Altekar, Candea & Stoica, 2011）：perfect / **value** / **output** / failure determinism。
- 系统实例：ReVirt（OSDI'02，VM 级重放）、rr（O'Callahan 等，把线程钉在单核上消除竞争）、
  Flashback、vPlay。

### 结论：先钉"必须记录"的清单，再做校验

1. **必须记录的外部输入清单**（照抄上面的分类，落到 sah 的会话作用域上）：
   **随机性**（值或种子）· **时钟**（`now-ms`）· **宿主查找**（`(h 'name)` 这一类 `eval` 到
   `interaction-environment` 的读取）· **文件 I/O** · **外部进程输出**。
2. **`define` 应该重放成"绑定"，而不是"重新计算"。** 这是这一节最可用的一条设计决定：
   - 右值是**可序列化 datum** 的 `define` → journal 里**记值**，重放时直接绑上去。
     于是值确定性成立，而且 `(define log (h 'probe-log))` 这一类**根本不需要再碰宿主**——
     那一整类砖死从根上消失。
   - 右值是**过程/语法/import** 的（`(define (f x) ...)`、`define-syntax`、`import`、`include`）
     → 没法记值（闭包不可序列化），只能重新求值。**这些才是记值之后唯一可能重放失败的类别**。
     注意今天砖死的两次恰好都是**值型** `define`（所以 P1 能治），而这一类你**还没撞过**：
     一个引用了已消失绑定的闭包一样会炸，而它看起来完全无害。
   - 一句话不变量，可以写进文档：
     > **数据绑定：值确定性（记值，必然可重放）；过程/语法绑定：重新求值，可能失败（上报，不致命）。**
3. **加一条回放校验**：重放完成后，把 journal 里记过值的那批绑定与重建出来的绑定点名比对。
   这就是"回放等价 oracle"在文献里的名字——**value determinism 检查**，而且它天然可判定：
   不等就是 bug，反例是具体的 `name`。
4. **顺序**：**先做第 2 条（记值），再谈 §9.2 的播种**。否则你会先引入一个静默发散。

---

## 4. 调度形状（§6.4）：你有名字了 —— ECA 的 coupling mode

### 现状

| 你的载荷 | 语义 | ECA 里的名字 |
|---|---|---|
| `callback` | 事件一发生就地跑，打断调度循环 | **immediate** |
| `prompt` | 等运行时空闲、**在自己的线程上**投递 | **detached / decoupled** |
| §6.4 的新形状（一个 pass 只触发一个、且触发是 pass 的最后一步） | 攒到"一个 pass 的末尾"再跑 | **deferred** |

### 文献

定时器/事件 → 动作，在 active database 里叫 **Event-Condition-Action 规则**，而"动作什么时候跑"
叫 **coupling mode**，三档（**immediate / deferred / detached**，含 causally-dependent 等子类）。
综述：Paton & Díaz, *Active Database Systems*, **ACM Computing Surveys 31(1), 1999** ——
[PDF](https://static.aminer.org/pdf/PDF/000/000/006/active_database_systems.pdf)；
文中比较的系统有 POSTGRES、HiPAC、Starburst、SAMOS、SQL:1999 等。

这一支早就把你会撞的坑列全了：

- **cascading**（规则动作又产生事件）的**终止性一般不可判定**；工程上的标准处置是
  **触发深度/次数上限** + **环检测**（同一规则同参数再次触发就停）。
- 一个事件触发多条规则时，需要 **conflict resolution / priority**（数值优先级、`precedes`/`follows`…）。

你现在**没有深度上限、没有环检测**（`grep` 过：只有错误隔离用的 `guard`）。
`proactive-every!` 的 callback 里再排一个同键任务，就可以自激；而 §5.4 那条"用户开始的回合就取消自己"
其实已经是一条 priority 策略，只是没被当成策略写下来。

### 结论

- 把 §6.4 的形状改动**正名为 deferred coupling**，并让三档成为显式配置（per job）。
- 加两条 if：**级联深度上限**（一个 pass 链上最多再触发 N 次）+ **同键环检测**（同一 `name`
  在自己的触发期间又被排入就拒）。两条都要有回归测试。
- 在文档里**声明"级联不保证终止，超过深度上限即丢弃并 journal 一条"**——这是这一支的标准免责声明。

---

## 5. 组合上的位置（新意判断，以及它的边界）

单独看，每一块都有家谱：主动性（§1）、one-shot continuations / 线程让出续延（§2）、
delimited continuations / effect handlers（§2）、deterministic replay（§3）、ECA coupling（§4）。

**我这几次检索的范围内，没有见到把这三样叠在同一个系统里的**：

1. 一个 **session 的宿主语言本身可重放**（durable eval + scope rebuild）；
2. **续延（调用栈）被当作 session 内的消息在任务间交接**（job1 的栈在 job2 的栈里续跑）；
3. **每个动态作用都可撤销**（§5.5，全部 pin 在 owner 上的 capability）。

所以新意大概在**组合与载体**（Chez + op algebra + owner/undo + durable form），不在任何单个机制。
**这是判断，不是检索结论**：我做了 5 次定向检索，不是系统性综述，也没有查 PL 之外的会议
（比如 ICSME/ICSE 那侧关于"可重放 agent 会话"的工作我完全没扫）。

如果要写论文，我觉着最硬的一点不是"主动 agent"（那边已经卷爆了，见 §1 的基准列表），
而是 **§3 那条**：*一个可重放的 LLM agent 会话* —— 把 record-and-replay 的 all-or-nothing
定律用在 agent 的 journal 上，给出会话作用域的 **determinism 分级与可判定校验**。
memory 和 gating 那两侧现在都在卷，但"会话本身能不能被忠实重建"几乎没人正面处理。

---

## 6. 下一步计划（按性价比排序）

每项都给：**为什么 / 改哪里 / 怎么验证 / 完成标准**。

### P0 —— `call/cc` → `call/1cc`，并把 §6.4 变成判决性测试

- **为什么**：更快更省（PLDI'96 实测 13% / 23%）；而且把"重复恢复"从静默合法变成报错，
  直接判决 §6.4 那条悬而未决的防御性测试。
- **改哪里**：`plugin.ss` 472（回卷点）、736（`proactive-pause!`）、845（`proactive-handoff!`）。
- **怎么验证**：`proactive-check.ss` 34 项全过；**另外**把调度器临时回退到旧形状跑一次，
  记录是否报二次恢复错。
- **完成标准**：一条明确的判决写进 STATUS §6.4（"证伪"或"坐实"），而不是继续挂着"未能证明"。
- **注意**：`call/1cc` 的续延**只能恢复一次**；如果哪天要做 Prolog 式的回溯或多路恢复，
  这一处必须换回 `call/cc`。另外 promotion 的坑：一次性续延被套进多 shot 续延时语义会变。

### P1 —— durable form 记值 + 回放校验（**先做这个，再谈播种**）

- **为什么**：§3。这是"会话能不能被忠实重建"的根因；也是今天那类砖死的根因。
- **改哪里**：`src/core/scope.ss`（重放）+ `src/session/manager.ss`（`session-add-scope-form!`
  与重放路径）：右值是可序列化 datum 的 `define` 记值；`define-syntax` / `import` / `include` /
  过程型 `define` 仍重新求值。
- **怎么验证**：① `(define x (random 1000000))` 播种后 journal、重建、断言**值相同**；
  ② 造一个"引用已消失的宿主名字"的 durable `define`，断言重建后**值仍在**（砖死类从根上消失）；
  ③ 过程型 `define` 失败仍走"上报不致命"。
- **完成标准**：`scope-replay!` 的返回里，失败项只剩"过程/语法类"；文档里落下 §3 那句不变量。

### P2 —— 给 `proactive-fire` 加 gate，并开始记 FAR/h

- **为什么**：§1。你现在是"到点即开腔"，而文献共识是校准问题。
- **改哪里**：`proactive-resume-one!`（259）取 pending 的时刻；gate 做成 `before-proactive-fire`
  veto hook（对齐内核的 `before-compact` / `before-fork`）。
- **默认策略**：降级为 `note`；仅在"空闲 + 用户静默 ≥ N 秒 + 与上次介入不重复"时升为 `prompt`。
- **怎么验证**：`proactive-check.ss` 加 gate 的单元测试（各条件组合）；实机跑一天，报 FAR/h。
- **完成标准**：能报出一个 FAR/h 数字，并且 gate 可以被第三方插件替换。

### P3 —— 级联深度上限 + 同键环检测

- **为什么**：§4。级联终止性不可判定，这是唯一的工程处置。
- **改哪里**：`proactive-queue!`（181）/ `proactive-run-job!`（229）链上带一个深度计数；
  同键在自己触发期间再入队就拒。
- **怎么验证**：两个回归测试（自激的 `every` 任务；`A→B→A` 环）。
- **完成标准**：越限即丢弃并 journal 一条说明；文档声明"级联不保证终止"。

### P4 —— 定时器持久化（可选，但它会放大 §3）

- **为什么**：§7 "定时器不持久"。sah 有 `session-add-custom!`，job 表完全可以进 journal。
- **改哪里**：排活/取消时写一条 `custom` 条目；`session-start` 时重放 job 表。
- **必须同时决定的两件事**：
  1. **`callback` 载荷本质上不可持久**（闭包不可序列化）→ 可持久化的子集只有 `prompt` / `note`；
  2. **停机期间错过的触发怎么算**：补跑一次？跳过？全补？这是调度器的经典抉择，必须写死一条规则。
- **注意**：这一步会把 §3 的问题放大——重放出的 job 表若带副作用，就必须**幂等**。

### P5 —— 文档正名（半小时的事，但能让后面少吵）

- README 里写下：每个载荷的 **coupling mode**（immediate / deferred / detached）、
  「级联不保证终止」、以及 §3 那句 **determinism 不变量**。
- STATUS §6.4 的注释同步为 P0 的判决结果。

---

## 7. 我没有做、也不该假装做了的事

- **没有系统性检索**：5 次定向检索 + 若干经典的家谱回溯。**没有**扫 PL 之外的会议，
  也没有扫工业界（Temporal / Durable Functions 那一侧的"durable execution"是 §3、P4 的另一个直接对照面，本文没展开）。
- **没有跑任何实验**：本文所有"结论"都是从你 `STATUS.md` 的实测 + 文献推出来的。
  P0 的判决、P1 的记值、P2 的 FAR/h 都要你（或 sah 里的 agent）实跑。
- **新意判断是弱的**：§5 只是"我没搜到"，不是"没有"。

---

## 8. 引用核查状态

**本次检索核对过（带链接，§1–§4 引用）：**
Bruggeman/Waddell/Dybvig PLDI'96 · Kumar/Bruggeman/Dybvig 1998 · Hieb/Dybvig/Bruggeman PLDI'90 ·
Dybvig/Peyton Jones/Sabry JFP 2007 · Plotkin & Pretnar ESOP 2009 ·
ACM CSUR *Survey of Deterministic Replay Schemes* · Zamfir/Altekar/Candea/Stoica 2011 ·
Lu et al. ICLR 2025（ProactiveBench）· PRISM ICLR 2026 · Tang et al. arXiv 2609.03727 ·
*Proactive Conversational AI* ACM TOIS 43(3) 2025 · *Overhearing LLM Agents* arXiv 2509.16325 ·
*Sleep-time Compute* arXiv 2504.13171 · *Anticipate and Learn* arXiv 2605.25971 ·
π-Bench arXiv 2605.14678 · ProactBench arXiv 2605.09228 ·
Paton & Díaz *Active Database Systems* ACM CSUR 31(1) 1999。

**按记忆列出、本次未逐条核对（引用前请自己核一下）：**
Ganz/Friedman/Wand *Trampolined Style*（ICFP'99）·
Danvy & Filinski *Abstracting Control*（1990，`shift`/`reset`）·
Reynolds *Definitional Interpreters*（1972，去函数化的源头）·
Danvy & Nielsen *Defunctionalization at Work*（2001）。
