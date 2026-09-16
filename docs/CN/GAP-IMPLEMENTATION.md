# sah 当前边界

> 日期：2026-09-16
> 基线：`main` init baseline

## 1. 出发点

sah 已经形成自己的 agent harness 内核：

- pi 式小核心：provider、tool、session、resource、frontend 保持薄边界；
- Cordis 式动态组合：作用有 owner、安装证据和撤销路径；
- defunctionalized CPS：控制状态、effect 和 continuation 是 datum；
- Scheme 是共同实现语言，也是消息、历史、配置、plugin program 和 machine state 的
  共同数据语言。

这四项是当前实现，不是未来路线。后续设计以 sah 为基线，不再以“补齐 pi/Cordis”
组织工作。

## 2. 已闭合

- Runtime 是唯一进程内可变根；
- Session 只保存已提交事实；
- Machine 不携带 Runtime、Session 或 procedure；
- mode 只通过 `runtime-submit!` 提交输入；
- capability 使用统一 owner cell；
- plugin mount 有 prepare/apply/rollback transaction；
- journal、branch、compaction 和 session-local Scheme scope 已统一；
- TUI、REPL、print、JSON、RPC 共用 Runtime、Session 和 renderer；
- 当前 `96` 个离线契约测试通过。

完整不变量见 [CORE-MECHANISMS.md](CORE-MECHANISMS.md)。

## 3. 已知边界

这些是当前行为边界，不自动构成实施计划。

### 同步 Run

provider、tool batch 和 compaction 仍由同步 driver 执行。运行期间没有可靠的取消、
steering 或 follow-up queue。

只有在实现交互中断时，才设计局部 run handle；不得把第二份 agent state 放进 Runtime。

### 单进程 Session Writer

一个进程内的 journal append、恢复和 repair 已有明确语义。多个进程同时写同一 session
file 没有 writer lease。

只有出现真实的并发 writer 场景，才设计 lease 和 revision protocol。

### 已提交事实恢复

Machine 已数据化，但未完成的 effect 不写入 journal。进程恢复只能恢复已经提交的消息、
metadata 和 scope form，不能恢复一次进行中的 provider/tool effect。

这不是普通 session resume 的缺陷。只有需要 crash-resume 时，才重新设计 effect class
和 durable checkpoint。

### 动态层 Reload

单次 plugin mount 已有事务，整批 extension reload 还不是原子替换。该问题的唯一规范和
实施契约见 [CORDIS-KERNEL.md](CORDIS-KERNEL.md)。

### Project Trust

项目 `.sah/extensions` 当前以用户权限执行。最小 trust gate 同样在
[CORDIS-KERNEL.md](CORDIS-KERNEL.md) 中定义。

## 4. 新工作的进入条件

新增设计前必须先给出：

1. 一个当前行为无法满足的具体场景；
2. 一个最小可运行或可检查的失败；
3. 被改变的唯一 owner 和 datum；
4. 验收后可以删除的旧路径。

没有这四项，不进入核心设计。

本文不保存长期功能清单。新的真实问题出现后，再以当前 sah 内核为起点单独设计。
