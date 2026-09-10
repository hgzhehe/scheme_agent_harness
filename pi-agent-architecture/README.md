# Pi (pi-coding-agent) 架构资料合集

本目录是对 **Pi**（`@earendil-works/pi-coding-agent`，版本 **0.84.3**）的架构文档汇总。
Pi 是一个“极简终端编码 harness”：核心保持小，通过 TypeScript 扩展、Skills、Prompt 模板、主题、Pi Packages 来扩展。

- 上游仓库：`github.com/earendil-works/pi-mono`（monorepo）
- 本机安装位置：`~/AppData/Local/pi-node/current/node_modules/@earendil-works/pi-coding-agent`
- 官方站点：https://pi.dev

## 本目录内容

```
pi-agent-architecture/
├── README.md                 # 本文件：合集索引
├── ARCHITECTURE.md           # ⭐ 综合架构说明（推荐先读）
├── README.upstream.md        # 上游官方 README（CLI 参考、功能总览）
├── docs/                     # 上游官方文档全量拷贝
│   ├── index.md              # 官方文档总入口
│   ├── docs.json             # 官方文档导航结构
│   ├── quickstart.md         # 安装、认证、首次会话
│   ├── usage.md              # 交互模式、slash 命令、上下文文件、CLI 参考
│   ├── providers.md          # 内置 provider 认证（订阅 / API key）
│   ├── models.md             # 自定义模型（models.json：Ollama/vLLM/LM Studio…）
│   ├── custom-provider.md    # 自定义 provider（自定义 API / OAuth / 流式实现）
│   ├── settings.md           # 全局与项目 settings.json 全量选项
│   ├── keybindings.md        # 默认与自定义键位
│   ├── sessions.md           # 会话管理、分支、树导航
│   ├── session-format.md     # ⭐ JSONL 会话文件格式、entry 类型、SessionManager API
│   ├── compaction.md         # ⭐ 上下文压缩与分支摘要内部机制
│   ├── extensions.md         # ⭐ 扩展 API、事件生命周期、自定义工具/UI（超大）
│   ├── skills.md             # Agent Skills
│   ├── prompt-templates.md   # Prompt 模板
│   ├── themes.md             # 内置/自定义主题
│   ├── packages.md           # Pi Packages（npm/git 分发扩展、skill、prompt、theme）
│   ├── tui.md                # ⭐ TUI 组件系统（自定义终端 UI）
│   ├── sdk.md                # ⭐ Node.js SDK（嵌入 pi）
│   ├── rpc.md                # ⭐ RPC 模式 JSON 协议（跨语言集成）
│   ├── json.md               # JSON 事件流模式（--mode json）
│   ├── security.md           # 项目信任、无内建沙箱、安全边界
│   ├── containerization.md   # 容器化：Gondolin / Docker / OpenShell
│   ├── environment-variables.md # 环境变量与 shell 工具会话语境
│   ├── llama-cpp.md          # 本地 llama.cpp router 集成
│   ├── development.md        # 本地开发、项目结构、调试
│   ├── windows.md / termux.md / tmux.md / terminal-setup.md / shell-aliases.md
│   └── images/               # 文档配图
├── examples/                 # 上游示例
│   ├── extensions/           # 各类扩展示例（权限门、git checkpoint、自定义 UI…）
│   └── sdk/                  # SDK 示例
└── meta/
    ├── package.json          # 上游包元数据（依赖、exports、构建脚本）
    └── CHANGELOG.md          # 上游变更历史
```

## 阅读建议

| 目标 | 先读 |
|------|------|
| 快速建立整体认识 | `ARCHITECTURE.md` |
| 只想用起来 | `docs/quickstart.md` → `docs/usage.md` |
| 写扩展 | `docs/extensions.md` → `docs/tui.md` → `examples/extensions/` |
| 嵌入/集成 | `docs/sdk.md` 或 `docs/rpc.md` / `docs/json.md` |
| 理解会话与压缩 | `docs/session-format.md` → `docs/compaction.md` |
| 接自定义模型/供应商 | `docs/models.md` → `docs/custom-provider.md` |
| 安全与隔离 | `docs/security.md` → `docs/containerization.md` |
| 二次开发 | `docs/development.md` + `meta/package.json` |

> 上游源码在 monorepo `pi-mono` 中按包分层：`ai` / `agent` / `tui` / `coding-agent`（另含 `protocol` / `client` / `telemetry`）。
> 相关独立包：`@earendil-works/pi-ai`（LLM 工具包）、`@earendil-works/pi-agent-core`（agent 框架）、`@earendil-works/pi-tui`（终端 UI 组件）。
