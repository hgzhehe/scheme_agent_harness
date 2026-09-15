# sah 设计：核心机制与背后的数据结构

> 本文说明 sah 的*核心*是什么、建立在哪些持久化数据结构之上，以及和 pi
> （`docs/ext-ref/ARCHITECTURE.md`）的差异。文中数字来自
> `sah/bench/bench-fp.ss`，可用 `scheme --script bench/bench-fp.ss` 复现——是实测，
> 不是宣称。
>
> 本文以持久数据结构和会话格式为主。控制、作用、历史与作用域的当前统一设计见
> [CORE-MECHANISMS.md](CORE-MECHANISMS.md)，剩余工作见
> [GAP-IMPLEMENTATION.md](GAP-IMPLEMENTATION.md)。

## 什么算“核心”

当前核心有五个中心：

1. **runtime 是唯一的动态状态所有者。** 工具、命令、hook、event subscriber、plugin
   和资源都属于具体 runtime。
2. **machine 显式描述控制。** provider、tool、compaction 和 journal 写入都是由
   effect interpreter 执行的请求。
3. **会话是带游标的不可变 entry 树。** 模型上下文和 session lexical scope 都从当前
   路径推导。
4. **plugin 是 op program。** dependency graph 先链接，完整 effect plan 先 prepare，
   再统一 commit，失败则按 frame 逆序 rollback。
5. **events 只观察，hooks 可改变流程。** 二者由 `core/runtime.ss` 集中拥有和规定失败
   策略。

## 会话日志（`src/session/log.ss`）

```scheme
(slog VEC CURSOR LINEAR?)
```

`VEC` 是按插入顺序存放 entry 的持久向量。`CURSOR` 是下一次追加所从属的 entry id。
entry 自带 parent 下标，于是所有 entry 构成一棵树。三个后果：

- **分叉就是移动游标。** `log-set-leaf` 是 O(1) 且不复制任何东西；之后追加就产生
  一个兄弟分支。在文件里，这只是又一行、其 `parent` 指向上层。REPL 的 `/tree`
  把这件事暴露给用户。
- **什么都不被销毁。** 从任意 entry 回溯到根的完整路径永远可以重建，所以 compaction
  可以把前缀折成摘要，而原始消息仍在磁盘上、仍然可达。
- **上下文是一个视图。** `log-context-messages` 从游标沿父链回溯，找到该路径上最新
  的 `compaction` entry，返回 `摘要 + 其 first-kept id 起的 entry`。这与 pi 的
  `buildSessionContext` 完全一致，大约十行。
- **两种 token 口径，不可互换。** *触发*比较的是 provider 报告的、它实际收到的那次
  prompt 的大小（`usage.input`）——拿它跟窗口比才是对的，因为它把系统提示和工具 schema
  也算进去了。*切点*与 `keep-recent-tokens` 预算用的是日志自己的逐 entry 估计，只算消息，
  比前者低约四分之一。两者必须分清。尤其：OpenAI 兼容的 provider 里 `input` 是**整个**
  prompt，而 `cache-read` 是其中命中缓存的那一部分，于是 `input + cache-read` 把缓存前缀
  算了两遍——长会话上是 1.8~2 倍，结果是触发在远未接近窗口的上下文上开火，下一轮又开火，
  反复丢掉根本没超预算的上下文。

### Entry 形状

```scheme
(message    ID PARENT TS MSG)
(compaction ID PARENT TS SUMMARY FIRST-KEPT-ID TOKENS-BEFORE DETAILS)
```

`ID` 是 entry 在日志中的**下标**，所以 `PARENT` 也只是另一个下标。这个选择比看上去
更重要：

- 任何地方都不需要 id→entry 的映射表（树回溯就是对整数做 `log-ref`）；
- 文件自解释：`(message 3 2 ...)` 读作“entry 3，父节点是 2”；
- 相比 8 位 hex id，会话文件更小、diff 更干净。

代价是 id 只在单个会话文件内有意义。跨会话引用（pi 的 `parentSession`、指向别的
文件的 label）需要额外带上文件限定符；这是有意的取舍，而 header 里仍然保留着会话
自己的短 id。

### 版本

| 版本 | entry id | 说明 |
|------|----------|------|
| 1 | 随机 hex | 最初的格式 |
| 2 | 日志下标 | 下标 id 与 entry 树 |
| 3 | 日志下标 | 当前：tool 消息带 `isError` 标记 |

`manager.ss` 在加载时做 v1 → v2 迁移（parent 和 compaction 的 `first-kept` 通过一张
哈希表统一重映射），并在下次追加时写回 v3。v2 → v3 只是给 tool 消息补上错误槽，
所以 v2 文件能原样加载，首次被追加时才重写。真正重要的性质是“可重建”而不是“字节
相同”：丢了 header 的文件仍能加载（id 从文件名恢复），并在下次追加时自愈。

## 数据结构（`src/fp/measured-vector.ss`）

这个向量叠了三个经典想法：

1. **位分区 trie**（Clojure 的 `PersistentVector`）。32 叉 trie，下标位逐层选子节点：
   `ref` 是 `log32 n` 次向量访问，更新每层复制一个 32 槽向量。**没有任何再平衡**，
   这正是它比带 split/join 的 AVL/红黑树更容易验证的原因。（我们先试了带
   split/join 的 AVL，不变量确实很难守住；结果是删掉而不是硬调。）
2. **tail。** 最新的 ≤32 个元素放在一个扁平向量里，于是 `conj` 只复制一个 32 槽向量，
   并用**一次** combine 更新缓存 measure，而不必下降 trie、在每一层用 32 个子节点
   重建 measure。tail 满了就作为一整片叶子压进 trie，把这份工作摊还到 O(1)/32。
3. **每个节点缓存 monoid measure**（finger tree 的核心思想）。每个节点缓存其子树的
   `combine(...)`，于是“前缀 measure 在哪里越过预算”是一次下降，而不是一次扫描。

会话使用的 measure 是各 entry token 估计值之和，于是 `log-tokens` 是 O(1)，
compaction 的切点是二分查找。

### 为什么不用真正的 finger tree

finger tree 用一次 O(log n) 下降完成 `split-by-measure`。我们把 `prefix-measure`
（O(log32 n)）和二分查找组合成 O(log² n)，换来短得多、且显然正确的定义。在会话
规模下这点差异是噪声；代码量的差异不是。

### 不变量

在 `tests/run-tests.ss` 中，对每个关键规模（0、31、32、33、63、64、65、1023、
1024、1025、1055、1056、1057、3000）以及每次操作后都做检查：

- `count = root-count + tail-len`，且 `root-count` 是 32 的倍数；
- 只有 trie 的最右脊柱可能半满；
- 每个节点缓存的 measure 等于其子节点 measure 的 combine；
- 总 measure 等于 `combine(root measure, tail measure)`；
- 每个前缀 measure 与 list 模型一致。

## 实测

`scheme --script bench/bench-fp.ss`，n = 20000 条，取 3 次最好：

| 操作 | measured-vector | entries-rev list（被替换的旧表示） |
|---|---:|---:|
| 追加 n 条 | 1.0 ms | 0.07 ms |
| 顺序读全部 n 条 | 0.11 ms | 0.05 ms |
| n 次随机下标读取 | **0.47 ms** | **242.8 ms** |
| compaction 切点（线性日志） | 0.02 ms | 0.005 ms（反向扫描） |
| compaction 切点（分叉日志） | 3.86 ms | — |
| `log-tokens`（O(1) measure） | <0.001 ms | 2.68 ms（对上下文求和） |
| 分叉（移动游标） | <0.001 ms | 写盘 0.1 ms + 重建 3.28 ms |

诚实解读：

- **真正的收益是随机访问和 measure。** 对 20000 条的 list 做 `list-ref` 是 O(n)，
  而旧的会话表示每次读取都要 reverse 整个列表；下标即 id + trie 把这两件事都去掉。
- **追加并没有更快，也不指望它更快。** 20000 条 `cons` 是 0.07 ms，向量是 1.0 ms。
  摊到单次是 0.05 µs 对 0.007 µs——放在一次网络往返旁边都无所谓；而向量才让 O(1)
  的 measure 与 O(1) 的分叉成为可能。（最初没有 tail 的实现在同样工作上要 7.0 ms；
  加上 tail 让 `conj` 便宜了 6×，这就是 tail 存在的理由。）
- **切点不是时间花掉的地方。** 反向扫描在 20000 条时本来就已是亚微秒级，因为预算
  一满足它就停。二分查找的优势是渐近的（不随 `keep` 增长），而让它保持在 0.02 ms
  的是**线性日志的快路径**——直接复用日志自身的缓存 measure，而不是重建一份
  测量视图；天真地重建视图要 1.14 ms，那会是一次伪装成优化的净退化。它是被测出来、
  发现不划算、然后修掉的。
- **分叉日志仍然要付 3.86 ms** 来物化路径再二分。compaction 很少发生且只发生一次，
  所以这里选择接受而不是优化。记下来，免得别人重新踩一遍。

## 与 pi 的对比

| 机制 | pi | sah |
|---|---|---|
| 会话条目 | JSONL，内存里是数组 | SexprL，带缓存 token measure 的持久向量 |
| entry id | 随机 8 位 hex，`Map` 查找 | 日志下标，完全不需要查找 |
| 分叉 | `id`/`parent` + leaf 指针，有 `/tree` UI | 同一模型；TUI selector 与命令共用 cursor API |
| 上下文 | `buildContextEntries` → `buildSessionContext` | `log-path` → `log-context-messages` |
| compaction | 反向扫描累加 token | 对缓存 measure 做二分查找（分叉后有物化回退） |
| fork | 复制到新文件 | O(1) 移动游标（同一个文件） |
| 快照 | 未建模 | 免费，因为日志不可变 |
| 扩展机制 | 一等公民（`pi.on`、`registerTool`…） | owner registry + plugin op/frame transaction |
| 流式 | SSE，delta-only 的 `message_update` | SSE，`message-delta` / `thinking-delta`；拼出的消息与阻塞调用一致 |
| 工具 | 内置 8 个，默认开 4 个；`--tools`/`--exclude-tools` | 内置 8 个，全开；同样的允许/排除列表（另有 `--no-tools`） |
| skills / prompt 模板 | `SKILL.md` + `/名称`，渐进披露 | 同左（extend/skills.ss、extend/prompts.ss） |
| 项目信任 | 门控项目资源 | **未实现**（已记录在案） |
| TUI | 完整组件系统 | 第一版全屏 engine：editor、selector、viewport、widget |
| RPC/JSON | 异步 JSONL 与增量事件 | 同步 JSONL RPC 与 canonical JSON event |

sah 有意领先的地方是会话数据结构（不可变、带 measure、下标寻址）以及对“这带来了
什么”的诚实核算。有意落后的地方是信任模型、异步取消、完整 TUI component API 和
成熟的 package 生态。

## 这为下一步解锁了什么

本节原先列的 4 项里已有 3 项落地：`/fork` 与 `--fork`、`/tree` 离开分支时的
分支摘要、以及 `label` entry 类型。剩下的是：

- `/context` 扩展：分段的 token 大小可由 `prefix-measure` 直接得到
  （目前该命令只报总数）。

而缺失的核心机制，按价值排序：

1. **Durable machine checkpoint**：显式 kont 还没有跨进程写入 journal。
2. **取消与 writer lease**：运行中的 provider/tool 仍是同步的，同一 session 也没有
   正式的单 writer 协议。
3. **原子 reload 与 trust**：plugin 单次 mount 已有事务，但整批 resource reload 和
   project resource 加载仍缺 candidate-runtime 与信任门控。

流式、JSON mode、同步 JSONL RPC 和第一版 TUI 已经完成；它们现在是继续实现取消、
异步 steering 和高级 component 生命周期的前端基线。

## 与 pi 真实实现的实测对照

`bench/bench-scale.ss` 扫描 sah 的日志，`bench/pi-session-manager-bench.mjs`
用 node 驱动 pi 真实的 `SessionManager`（内存模式、不落盘）。两者 n = 10⁶，
单位是每元素纳秒：

| 操作 | sah | pi |
|---|---:|---:|
| append | 401 | 1777 |
| 路径回溯（root → leaf） | 91 | 224 |
| 按 id 查找 | 29 | 90 |
| 物化全部 entry | 16 | 19 |
| 构建上下文 | 262 | 377 |
| 分叉（移动游标） | 8 | 83 |
| 活跃内存/entry | 137 B | 207 B |
| token 总量 | O(1) | O(n) |
| `getChildren(id)` | `log-children`，另一个是单遍的 `log-children-index` | 每次调用 O(n) |

两个诚实的保留意见。第一，这既是在比数据结构，也是在比运行时；真正同口径的比较
应该用 Scheme 重新实现 pi 的「数组 + Map」，那件事没做。第二，pi 的 append 成本里
有一部分是 sah 根本不做的工作：它为每条 entry 生成全局唯一 id（`randomUUID()`
约 110 ns），因为它支持跨文件引用，而 sah 用稠密下标换掉了这个能力。更值得看的
其实是增长曲线：从 10⁴ 到 10⁷，sah 的 walk 是 62 → 157 ns/el，pi 是 24 → 224
——哈希字符串键是随机内存访问，父链上的整数下标是顺序访问，这才是「每步 O(log n)
的 walk 反而更快」的原因。

## sah 与 pi 会话格式的互转

因为两边的 entry 集合同构，两个格式之间是形状映射而不是翻译：
`session/pi-format.ss` 双向加起来约 250 行，`--export-pi` / `--import-pi` 是
建在它上面的一次性命令。

| sah | pi |
|---|---|
| `(message 3 2 TS (msg user "hi"))` | `{"type":"message","id":"00000003","parentId":"00000002",…}` |
| `(compaction … FIRST-KEPT-ID …)` | `firstKeptEntryId` |
| `(branch-summary … FROM-ID …)` | `fromId` |
| `(label … TARGET-ID LABEL)` | `targetId`、`label`（`null` 表示清除） |
| `(session-info … NAME)` | `{"type":"session_info","name":…}` |
| `(model-change … PROVIDER MODEL)` | `{"type":"model_change","modelId":…}` |
| `(thinking-level … LEVEL)` | `{"type":"thinking_level_change",…}` |
| `(custom … CUSTOM-TYPE DATA)` | `{"type":"custom","customType":…,"data":…}` |
| `(custom-message … …)` | `{"type":"custom_message",…}` |

有三件事无法抹平，转换器的文件头里写清了：sah 用下标编号 entry，pi 用随机 hex id
（导出时由下标派生确定的 8 位 hex，所以 `--export-pi` 可复现、往返稳定）；pi 的消息
带 thinking 块和图片，sah 不建模（thinking 丢弃、图片变成文本占位）；sah 不认识的
pi entry 类型会保留成 `customType` 为 `"pi-<类型>"` 的 `custom` entry，所以导入导出
往返是无损的。`isError` 原本也在这张清单上，格式 v3 给 tool 消息加了错误槽之后它
也能往返了。

实测：把一个真实的、六条 entry 带分叉的会话导出、导入、再导出，entry 逐字节相同。

## 值得保留的几条约定

这些来自一次全树审视（膨胀、数据形状、状态流转、正交性），现在是代码遵守的规则：

1. **events 只观察，hooks 可改写。** 二者都由 `core/runtime.ss` 持有，但 subscriber
   异常不改变流程，hook 则按 stage 的 fail-open/fail-closed 策略处理。
2. **只有一处决定模型看到什么。** `core/data.ss` 的 `entry->context-messages` 是唯一
   投影点；十种 entry 里四种产生消息、六种什么都不产生，所以元数据可以随时追加而不
   扰动对话。
3. **每种 entry 的形状只有一处定义。** `core/data.ss` 里的 slot 表就是定义，
   `entry-field` 是唯一对列表取下标的地方，契约测试覆盖全部 kind 的投影规则。
   把表写下来当场就暴露了一个真陷阱：摘要对 compaction 是 slot 4，对
   branch-summary 是 slot 5。）
4. **会话状态的变更只有一处入口。** 所有变更都走 `session-push!` 和唯一的
   `session-flush!`，所以"什么时候需要整文件重写"只有一个实现。多步变更各自成为函数
   （`session-branch-summary!`），而不是在调用处排队；昂贵且可能失败的步骤（模型调用）
   发生在任何状态移动**之前**。
5. **命令是能力而不是模式。** 由 `main` 为所有模式注册，所以 `sah "/context"` 在
   print 模式下和 REPL 里一样可用。
6. **输入管线是一串阶段。** command、input hook、skill 和 prompt handler 都在
   `core/capability.ss` 的 runtime-owned pipeline 中组合。
7. **cursor 同时决定消息和 Scheme 环境。** branch/resume 只重放当前 path 上的
   `scope-form`，放弃分支上的定义不会泄漏。
8. **控制与作用分开。** `agent/machine.ss` 决定下一步，`agent/agent.ss` 解释 effect。

### 把一个 turn 切成两半（split turn）

切点是压缩唯一可能“错得要紧”的地方，所以这条规则值得写明：

- token 边界是对日志缓存 measure 的二分查找（见上面的实测）。
- 切点随后**向前**移动到下一个安全点，而不是向后回退到上一个 user 消息。安全点是
  user 消息（turn 边界）或 assistant 消息（此时该 turn 的工具批次已经完整——循环一定把
  一个批次的全部结果追加完才会再次调用模型）。切在 tool result 之前会让它回答的那个
  调用变成孤儿。
- **向前**移动才使“单个 turn 大于整个上下文预算”这种情况可以被压缩。回退到该 turn
  自己的 user 消息会保留整个 turn，于是旧行为什么也压不掉，无论压缩跑多少次上下文都
  可能超出窗口。这是一个真实的故障模式，现在由一个测试覆盖：构造一个 2000 token 的
  单个 turn，预算只有 200 token。
- 当切点落在一个 turn 中间时，前缀会被分成两部分摘要——历史，以及这个 turn 被留下
  的前半段——然后合并，因为一份结构化的“历史摘要”并不适合表达“我们当前这个 turn
  已经做到哪了”。pi 把这个叫 split turn。

`retainedTail`（pi 在 compaction entry 里存一份保留尾巴的自包含副本）**有意不实现**：
它存在是为了让只认识 `firstKeptEntryId` 的读取者也能重建上下文。sah 只有一个读取者，
并且日志总是存在；导出到 pi 时会带上整个日志，引用在那边同样能解析。

### Fork

`session-extract`（session/manager.ss）把 root→entry 的路径写成一个新的会话文件。因为
id 是位置，抽取会**重新编号**；沿用旧编号会静默指向别的 entry。有两类引用可能指向被抽
取路径之外——branch summary 的 `from-id` 和 label 的 `target-id`——它们变成 `#f`：文本
保留，悬空引用被丢弃，而不是留一个指向陌生 entry 的下标。

header 增加了一个可选的父会话字段，所以 fork 保留了来源；`session-load` 两种形状都
接受，`pi-format.ss` 在它与 pi 的 `parentSession` 之间双向映射。可通过
`/fork [entry-id]` 和 `sah --fork [--session <id>]` 使用。
