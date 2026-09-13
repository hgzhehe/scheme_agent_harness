# sah 设计：核心机制与背后的数据结构

> 本文说明 sah 的*核心*是什么、建立在哪些持久化数据结构之上，以及和 pi
> （`docs/ext-ref/ARCHITECTURE.md`）的差异。文中数字来自
> `sah/bench/bench-fp.ss`，可用 `scheme --script bench/bench-fp.ss` 复现——是实测，
> 不是宣称。

## 什么算“核心”

只有三个机制：

1. **事件流是唯一事实源。** 每个可观察步骤（agent 开始、tool 开始/结束、
   compaction 开始/结束、消息结束）都通过同一条总线发出（`core/event.ss`）。
   print 模式、REPL、以及将来的 RPC/JSON 模式都只是消费者。
2. **会话是带游标的不可变 entry 树。** 发给模型的上下文是每次请求时*推导*出来的，
   从不落盘。因此 compaction 只是一条普通 entry，而不是破坏性改写。
3. **工具是注册表，数据是位置化 tagged list。** 加一个工具 = 新增一个文件 + 一行
   加载；所有跨边界的东西都用 `match` 解构。

4. **扩展点** —— 具名 hook，以及由扩展文件注册的工具与命令（见
   [EXTENDING.md](EXTENDING.md)）。

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
| 2 | 日志下标 | 当前 |

`manager.ss` 在加载时做 v1 → v2 迁移（parent 和 compaction 的 `first-kept` 通过一张
哈希表统一重映射），并在下次追加时写回 v2。真正重要的性质是“可重建”而不是“字节
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
| 分叉 | `id`/`parent` + leaf 指针，有 `/tree` UI | 同一模型；移动游标就是全部实现，`/tree` 是 REPL 命令 |
| 上下文 | `buildContextEntries` → `buildSessionContext` | `log-path` → `log-context-messages` |
| compaction | 反向扫描累加 token | 对缓存 measure 做二分查找（分叉后有物化回退） |
| fork | 复制到新文件 | O(1) 移动游标（同一个文件） |
| 快照 | 未建模 | 免费，因为日志不可变 |
| 扩展 hook | 一等公民（`pi.on`、`registerTool`…） | 同一形状，约 120 行；扩展就是 Scheme 文件 |
| skills / prompt 模板 | `SKILL.md` + `/名称`，渐进披露 | 同左（core/skills.ss、core/prompts.ss） |
| 项目信任 | 门控项目资源 | **未实现**（已记录在案） |
| TUI | 完整组件系统 | 行式 REPL |

sah 有意领先的地方是会话数据结构（不可变、带 measure、下标寻址）以及对“这带来了
什么”的诚实核算。有意落后的地方是信任模型（sah 无条件加载项目扩展），以及所有
依赖 TUI 的下游能力。

## 这为下一步解锁了什么

树已经在了，所以下面这些变得很小：

- `/fork` 和 `--fork <id>`：把 `/tree` 的交互能力做成 CLI；
- **分支摘要**（pi 的 `session_before_tree`）：离开分支时把它摘要成一条
  `branch_summary` entry，而不是简单丢弃；
- `label` entry 类型做书签（`entry-kind` 已经预留）；
- `/context` 扩展：分段的 token 大小可由 `prefix-measure` 直接得到。

而缺失的核心机制，按价值排序：

1. **更多 hook 点（当它们能自证价值时）** —— 注册表只有 60 行，所以一旦真有需求，
   加 `turn-start` / `turn-end` 或 `user-bash` 阶段很便宜。凭空把列表撑大没有意义：
   pi 的约 30 种事件全都由 sah 还不具备的 TUI 与 RPC 模式触发。
2. **流式** —— 事件总线已经区分了 `message-end`；加上 `message-delta` 只需要
   provider 侧的 SSE 读取，不需要结构改动。

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
| `getChildren(id)` | 未实现 | 每次调用 O(n) |

两个诚实的保留意见。第一，这既是在比数据结构，也是在比运行时；真正同口径的比较
应该用 Scheme 重新实现 pi 的「数组 + Map」，那件事没做。第二，pi 的 append 成本里
有一部分是 sah 根本不做的工作：它为每条 entry 生成全局唯一 id（`randomUUID()`
约 110 ns），因为它支持跨文件引用，而 sah 用稠密下标换掉了这个能力。更值得看的
其实是增长曲线：从 10⁴ 到 10⁷，sah 的 walk 是 62 → 157 ns/el，pi 是 24 → 224
——哈希字符串键是随机内存访问，父链上的整数下标是顺序访问，这才是「每步 O(log n)
的 walk 反而更快」的原因。
