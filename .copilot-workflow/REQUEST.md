# Request

# 原始需求

我想参考这个 “Downloads/copilot-credit-monitor”，做一个 Mac 的状态栏的 copilot credit monitor，点一下就能看到这周还剩多少美元可以用

# 已确认的范围和交接方式

- 本次模型例外：gpt-5.5 启动失败（当前 CLI 不支持）；用户明确同意改由当前 GPT-6 Astra 会话完成 Architect 方案。此例外不改变其他角色的默认模型。

- 项目目录：`CopilotCreditMonitor` 仓库根目录。
- 用户先选择完成 Architect 规划；现已明确要求“开始实现”，授权 Implementer 按确认的 Frost 方案实现并构建应用，完成后交接 Reviewer。
- 参考项目：`~/Downloads/copilot-credit-monitor`（本地参考，不随仓库分发），只读参考，不修改原项目。
- 沿用参考项目规则，只统计本机，并明确标注非 GitHub 账户余额。
- 每周预算由用户设置，默认 $1,000 = 100,000 credits；100 credits = $1；北京时间周一 01:00 重置。美元是预算折算，不代表官方账单。
- 已选定 Frost 轻透原生设计，适配深浅外观；卡片底部齿轮进入额度设置。
- 修改预算保存后立即应用于本周及后续周，保留本周已用金额，只重算剩余和进度；退出重启后保留设置。
- 菜单栏平时仅显示图标；点击显示本周剩余美元、本周已用、预算和比例。按用户最新反馈，移除主卡片的下次重置、统计范围、换算比例、更新时间和日常刷新来源文字。
- 推荐原生 macOS AppKit 实现，不需要网页、Electron 或常驻普通窗口；技术选型由 Architect 在方案中说明。

# 参考代码已确认的关键语义

- README.md 明确其数据仅为本机 session usage subtotal。不覆盖 IDE 原生 Chat、其他设备、GitHub 网页。
- collector.go 读取 session.usage_record 中 data.usage.copilotUsage.totalNanoAiu，1e9 nano AI units = 1 credit；不把 data.usage.cost 当美元。
- 按 apiCallId 的 SHA-256 去重，event ID 兜底；排除 BYOK；partial / unavailable 不能算免费，缺失时已用为下界、剩余为上界。
- 首次回填本周已发生用量，按请求时间归属；支持重启恢复、增量扫描、半行等待、日志截断/重写和去重。
- 原版有本地持久化、文件监听、手动刷新；损坏历史和监听失败明确报错，不能静默显示完整预算。
- Architect 需自行核对参考代码中相关实现和边界，并设计适合 macOS 菜单栏的方案；未经核验的兼容性应显式注明。

# 约束

- 当前阶段允许 Implementer 修改应用源码、构建配置、直接相关文档及 IMPLEMENTATION.md，并在完成后更新状态为 ready-for-review。
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

## Design confirmation

用户确认：“就第一个 frost，然后用户可以自己设置每周的额度（默认是 1000 美元一周）”。
生效规则确认：“立即生效：保留本周已用金额，只重算剩余额度”。
该反馈更新现有方案，不启动 Implementer，不新增提交或推送授权。

## Implementation authorization

用户最新指示：“开始实现”。按已确认方案实施 Frost 原生 macOS 应用和可配置周额度。
仅本地实现和 build，不运行测试，不自动启动真实日志监控，不 commit、不 push、不创建 GitHub issue 或 pull request。
此前创建公开仓库的授权已完成，不延伸到本轮开发；如任何通用工作流模板要求创建 issue/PR，服从本条任务范围。

## Scan performance correction

用户反馈：“一直显示正在补算本周用量，为什么这么慢？？你不能用什么多线程之类的吗”。
实现阶段继续修复首次导入性能：有上限的并行读取、线性分块 JSONL 扫描、必要字段解析、及时释放临时对象、可见且限频的进度、真正的增量刷新；不能让设置保存或退出同步等待全量扫描。
处理文件期间不得误报完整预算；去重与持久化必须保持一致，不能用跳过未知日志或漏算来换速度。诊断仅采集日志数量/体积和进程堆栈，不将本机路径、会话内容或诊断细节写入公开文档。

用户随后明确允许启动新版读取本机日志并观察导入是否完成、耗时和内存；这仅授权本次实际运行诊断，不授权运行测试套件、公开会话内容或提交/推送。

## UI simplification

用户要求删除截图中分散注意力的信息：主卡片不再显示下次重置、统计范围、credits 换算说明，以及更新状态/来源/时间整块文案；移除后收紧布局，不保留空白占位。
仅保留首次导入期间的必要进度及实际错误提示，正常和 partial 状态不常驻额外状态行。计算规则不变，覆盖限制保留在 README。

## Native visual redesign

用户要求重做余额页和额度设置页，使用高品质 macOS 原生视觉，而不是默认控件堆叠。
沿用 AppKit：原生 vibrancy/material、深色细内描边、突出余额与较小的次要标签、充足留白和模块化信息区、SF Symbols，以及遵循 Reduce Motion 的阻尼弹簧交互。
保留已确认的精简信息范围，不恢复已删除的重置、覆盖、换算、更新时间文案；不改变额度和记账逻辑，不提交或推送。

## Publishing authorization

用户最新明确要求：“commit and push”。本次授权提交并推送当前应用实现、性能修复、原生 UI 重设计及相关文档和合成设计稿到现有公开仓库。
不包含构建产物、实际用量数据、本机截图或机器专属工作台元数据；工作流仍为 ready-for-review，不将发布提交视为 Reviewer 批准。
