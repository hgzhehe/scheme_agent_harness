# sah 当前 gap 与实施路线

> 快照日期：2026-09-14
> 已完成一次内核级重写。本文只列当前实现之后仍然存在的 gap，不保留旧 M0 叙述。

## 1. 已经闭合的核心

本次重写已完成：

- 删除 process-global tool、command、hook、event、plugin registry；
- 引入显式 runtime ownership；
- 内置工具改为纯 datum 和显式 bootstrap；
- agent loop 改为 defunctionalized machine + effect interpreter；
- context overflow 改为显式 compact-and-retry transition；
- session `eval` 接入独立 lexical scope；
- durable `define` / `define-syntax` / `set!` 写入 `scope-form`；
- branch、resume、fork 按当前 journal path 重放 scope；
- durable eval 与 journal append 形成失败恢复事务；
- plugin dependency graph 与 lexical export facade 分离；
- mount 覆盖完整 dependency subgraph；
- 所有 op 先 prepare，再统一 commit；
- commit 失败逆序 rollback；
- rollback/dispose 失败保留 residual frame 和可重试状态；
- capability registry 使用 owner shadow stack；
- extension load failure 清除全部 owned definition；
- reload 清除动态 op handler 和 capability；
- generated system prompt 在 extension tool 加载后刷新；
- pi JSONL round trip 保留 scope-form；
- source、tests、build 共用 manifest；
- Windows standalone bundle 构建和 smoke check 通过。

这些机制已经有离线契约测试，不再属于路线图。

## 2. P0：让 machine 可恢复

### 现状

machine、effect、kont 已经是显式 datum，但 continuation 中仍直接携带 session record 和
config，且没有写入 journal。

### Gap

进程中断时，只能恢复已提交历史，不能回答：

- 当时处于哪个 phase；
- 正在等待哪个 provider/tool effect；
- 该 effect 是否已经执行但结果尚未 commit；
- 是否可以安全重试。

### 实施

1. 将 machine state 中的 runtime object reference 改为稳定 id；
2. 为 effect 分配 operation id；
3. journal 增加 `machine-checkpoint`、`effect-started`、`effect-committed`；
4. 区分可重试 effect 与最多一次 effect；
5. 启动时从最后 checkpoint 恢复；
6. 对未完成 provider/tool effect 应用明确恢复策略；
7. 增加 crash-point fault injection。

### 验收

- 在每个 await 前后强制退出都能得到确定恢复结果；
- tool 不会因为模糊重试而重复产生不可逆副作用；
- 恢复后的上下文、step 和 journal parent 与不中断运行一致。

## 3. P0：取消与并发控制

### 现状

machine 可以表达等待，但 interpreter 使用同步 provider、tool 调用。

### 实施

- effect interpreter 接受 cancellation token；
- provider transport 支持终止子进程和 stream；
- shell/tool effect 明确取消语义；
- machine 增加 `cancelled` terminal state；
- lifecycle 保证 `agent-end` / `agent-settled` 恰好一次；
- 同一个 session 同时只允许一个 writer，或引入显式 revision check。

### 验收

- provider、shell、tool batch 三处都能取消；
- 取消后 journal 保持完整 datum；
- 不留下无法关闭的 port/process；
- 下一次 run 可继续使用同一 session。

## 4. P0：Session recovery mode

### 现状

损坏 datum 会给出文件、datum index 和可用 byte offset；完整 rewrite 使用 staging 和
backup。但读取仍是“完整成功或抛错”。

### 实施

- `healthy`、`recovered`、`read-only`、`corrupt` 状态；
- 识别仅尾部截断和中段损坏；
- 保留 last-good offset；
- 提供显式 repair 命令，不在读取时静默改文件；
- session header 记录格式 feature；
- recovery 事件进入可观察面。

### 验收

- 尾部半条 datum 可只读恢复到 last-good entry；
- 中段损坏不会误当 EOF；
- repair 前原文件有完整备份；
- 恢复状态在 CLI 中可见。

## 5. P1：Provider state 与 usage 分离

### 现状

OpenAI Responses 的 opaque output 保存在 usage alist 的 `responses-output` 中。

### 问题

token accounting 与 provider continuation state 是两个概念。混在一起会让：

- compaction 代码知道 provider 私有字段；
- session format 难以演进；
- 跨 provider resume 语义不清楚。

### 实施

将 assistant message 演进为显式 metadata：

```scheme
(msg assistant CONTENT CALLS STOP USAGE PROVIDER-STATE)
```

或引入向后兼容的 tagged metadata entry。需要同步 migration、pi conversion、context
projection 和 provider adapter。

## 6. P1：Plugin 生命周期完善

### 已有

依赖图解析、export facade、两阶段 mount、逆序 rollback、residual retry 已成立。

### 剩余

1. dependency activation 目前没有显式 reference count；
2. plugin definition owner 与 mount request owner 尚未分开；
3. 整批 resource reload 不是跨所有文件的单一事务；
4. frame 没有时间戳和 journal projection；
5. 自定义 op constructor 仍依赖 runtime root 中可见的 Scheme binding；
6. mounted plugin 的 handler algebra 不能动态替换，当前通过 kind 唯一性避免歧义。

### 实施建议

- 增加 activation lease，而不是简单 mounted boolean；
- mount request 记录 root 与 dependency reason；
- resource loader 先解析全部文件到 candidate runtime，再原子交换；
- 为 frame 增加 stable id 和 lifecycle event id；
- 提供显式 plugin DSL binding table。

## 7. P1：结构化 tool contract

### 现状

tool schema 会发送给模型，但本地只检查少量 handler 自己关心的字段。

### 实施

- 在 `runtime-call-tool` 前统一校验 JSON Schema 子集；
- 区分 invalid-arguments、blocked、execution-error、cancelled；
- tool result 使用结构化 datum，而不是 `(values string boolean)`；
- 为大输出提供 artifact reference；
- 对 write/edit/shell 增加可配置 policy。

## 8. P1：项目 trust 与能力策略

### 现状

项目 `.sah/extensions` 会在本机用户权限下直接 load。session eval 也不是安全沙箱。

### 实施

- canonical cwd trust store；
- global extension 与 project extension 分阶段加载；
- 非交互模式明确默认策略；
- project extension 在 trust 通过前不可注册 effect；
- shell/write/edit capability policy；
- 文档明确“lexical isolation 不等于 security sandbox”。

## 9. P2：RPC、TUI 与多前端

当前 event bus 和 machine 已经允许新增前端，但还没有稳定协议。

顺序建议：

1. 定义 versioned event envelope；
2. 增加 JSONL RPC driver；
3. 增加 command request/reply；
4. 暴露 machine state 和 pending effect；
5. 最后构建 TUI。

不要让 TUI 直接调用 session 内部 mutation。所有前端都应使用同一 driver/runtime API。

## 10. P2：测试深化

当前 42 个测试覆盖核心不变量。下一步不是恢复上千个细碎断言，而是增加：

- journal tree property tests；
- branch/scope model-based tests；
- plugin transaction fault matrix；
- reload candidate-runtime 测试；
- provider stream fixture；
- crash recovery fault injection；
- Windows/POSIX build matrix。

重点 fault point：

```text
after scope eval / before journal flush
after each plugin apply
after each rollback
after staged session write
after backup rename
before provider result commit
after tool effect / before tool-result journal append
```

## 11. 推荐实施顺序

| 顺序 | 工作 | 原因 |
|---|---|---|
| 1 | durable machine checkpoint + effect id | 让显式 CPS 真正跨进程 |
| 2 | cancellation + session writer discipline | machine 可恢复后才能定义可靠取消 |
| 3 | session recovery mode | 补齐 durable substrate |
| 4 | provider state 独立 | 为跨 provider resume 清理数据模型 |
| 5 | structured tool result/schema validation | 稳定 effect 边界 |
| 6 | plugin activation lease + candidate reload | 完善动态组合 |
| 7 | project trust/policy | 在扩展面扩大前建立安全边界 |
| 8 | RPC/TUI | 建立在稳定 runtime 和 event protocol 上 |

## 12. 暂不追求

- 与 pi TypeScript extension API 兼容；
- 把任意 Scheme 副作用自动变成可回滚 effect；
- 在核心中内置复杂 planning/todo 产品功能；
- 通过 lexical scope 冒充安全 sandbox；
- 为了“纯函数”而把所有 Chez runtime object 强行序列化。

目标仍然是小而完整：先让控制、历史、作用和作用域的语义闭合，再扩展产品面。
