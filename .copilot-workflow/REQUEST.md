# Request

# 原始需求

我想参考这个 “Downloads/copilot-credit-monitor”，做一个 Mac 的状态栏的 copilot credit monitor，点一下就能看到这周还剩多少美元可以用

# 已确认的范围和交接方式

- 本次模型例外：gpt-5.5 启动失败（当前 CLI 不支持）；用户明确同意改由当前 GPT-6 Astra 会话完成 Architect 方案。此例外不改变其他角色的默认模型。

- 项目目录：`CopilotCreditMonitor` 仓库根目录。
- 用户选择：先写方案，按三角色流程交接；本次仅 Architect 规划，不实现应用、不启动 Implementer 或 Reviewer。
- 参考项目：`~/Downloads/copilot-credit-monitor`（本地参考，不随仓库分发），只读参考，不修改原项目。
- 沿用参考项目规则，只统计本机，并明确标注非 GitHub 账户余额。
- 每周预算 $1,000 = 100,000 credits；100 credits = $1；北京时间周一 01:00 重置。美元是预算折算，不代表官方账单。
- 菜单栏平时仅显示图标；点击显示本周剩余美元，可辅助显示本周已用、预算、下次重置时间和刷新状态。
- 推荐原生 macOS AppKit 实现，不需要网页、Electron 或常驻普通窗口；技术选型由 Architect 在方案中说明。

# 参考代码已确认的关键语义

- README.md 明确其数据仅为本机 session usage subtotal。不覆盖 IDE 原生 Chat、其他设备、GitHub 网页。
- collector.go 读取 session.usage_record 中 data.usage.copilotUsage.totalNanoAiu，1e9 nano AI units = 1 credit；不把 data.usage.cost 当美元。
- 按 apiCallId 的 SHA-256 去重，event ID 兜底；排除 BYOK；partial / unavailable 不能算免费，缺失时已用为下界、剩余为上界。
- 首次回填本周已发生用量，按请求时间归属；支持重启恢复、增量扫描、半行等待、日志截断/重写和去重。
- 原版有本地持久化、文件监听、手动刷新；损坏历史和监听失败明确报错，不能静默显示完整预算。
- Architect 需自行核对参考代码中相关实现和边界，并设计适合 macOS 菜单栏的方案；未经核验的兼容性应显式注明。

# 约束

- 此次只写 .copilot-workflow/PLAN.md 等角色允许的工作流状态，不修改或生成应用源码。
- 除用户明确授权外不 commit、不 push，不创建 GitHub Actions。
- 后续实现只自动运行 build，不运行任何测试；单元测试可在方案中列出由用户手动执行，不设置 UI test target。
- 不读取真实会话日志或凭据，不向工作流文件保存对话、密钥或私人用量；使用参考代码和合成样本设计解析器。
- 方案必须明确本地统计覆盖限制、美元精度/溢出、时间边界、未知格式/数据损坏的错误状态、并发与持久化、菜单栏交互、打包和用户验收清单。
- 尽量简单，避免无关功能。完成后运行 copilot-flow set-status ready-for-implementation，停在实现交接点。

## Submitted

2026-10-21T03:19:33Z

## Repository initialization

用户后续明确要求：“先初始化这个 github 项目，然后推送到 github，项目是 public 的”。
本次授权初始化 Git、创建公开仓库 `PetrGuan/CopilotCreditMonitor`、提交并推送当前需求和方案；不启动应用实现。
发布时移除文档中的机器专属绝对路径，生成的本地元数据和视图不提交，保留当前实现交接状态。
