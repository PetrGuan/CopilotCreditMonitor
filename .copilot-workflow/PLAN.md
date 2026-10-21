# Plan

原生 macOS Copilot Credit Monitor；本次仅规划，完成后交给 Implementer。
Architect：GPT-6 Astra（gpt-5.5 不可用后，经用户明确批准替代）。

## Problem

用户需要一个不占 Dock、不常驻普通窗口的菜单栏工具，平时只显示图标，单击立即看到本周还剩多少美元预算。

这里的“剩余”必须定义为 **$1,000 周预算减去本机已记录 Copilot credits 的美元折算**，不是 GitHub 账户的可支付余额。已确认只覆盖本机兼容 CLI / SDK 的会话日志，不覆盖其他机器、IDE 原生 Chat、GitHub 网页。

规划时项目为新建目录，只有 `.copilot-workflow`，无现有应用源码或构建系统。参考项目 `~/Downloads/copilot-credit-monitor` 只读，不修改、不启动；参考文件不随本仓库分发。

## Proposed approach

### 1. 技术和 MVP 范围

- Swift + AppKit，最低 macOS 13。使用系统 Foundation、CryptoKit 和 CoreServices；不引入第三方依赖、Go sidecar、SwiftUI、Electron 或 WebView。
- Swift Package Manager 管理一个纯逻辑库、一个 AppKit executable、一个单元测试 target；小型打包脚本生成可双击的 `.app`，不手工维护 `.pbxproj`。
- `NSStatusItem` + `NSPopover(.transient)`；`LSUIElement = true`，并使用 accessory activation policy，不使用禁止创建窗口的 prohibited policy。
- 首版只读默认 `~/.copilot/session-state`。保留重复 `--session-dir <absolute-path>` 作为高级入口，指定时替换默认路径；持久化文件记录规范化后的源集合，不能悄悄合并不同配置的账本。
- 首版不做账户登录、云同步、账单 API、历史图表、通知、预算编辑或自动更新。开机启动和设置窗口延后，不阻塞主需求。
- 自己实现原生 Swift 逻辑，参考数据契约和边界而非直接搬运源码；参考目录未见顶层 LICENSE，未经确认不能认定可以复制或再分发参考实现。SF Symbols 使用系统内置非品牌图标，不冒用 GitHub 官方应用标识。

### 2. 菜单栏交互

菜单栏固定方形模板图标，适配明暗模式。保留 `NSStatusItem` 强引用，点击图标切换约 320pt 宽的原生弹出卡片；点击外部或 Escape 关闭，关闭卡片不退出后台监控。

卡片从上到下：

1. “本周剩余”及突出显示的 `$xxx.xx`；超支显示负数，不截断为零。
2. “本周已用 $xxx.xx / 预算 $1,000.00”和进度条；进度条可以钳制至 0–100%，金额不可钳制。
3. 下次重置的绝对日期、时间及“北京时间 UTC+8”，避免每秒倒计时。
4. 最近成功扫描时间、监听状态；异常时说明原因，不能只改变颜色。
5. 始终可见的“仅本机 CLI / SDK 日志，非账户余额”和“按 100 credits = $1 折算”。
6. “立即刷新”和“退出”按钮。

用系统字体、monospaced digits 和 Auto Layout；支持 VoiceOver 名称、键盘焦点和合理对比度。错误文本支持换行，不让大额金额或路径挤出卡片。

状态必须可区分：

| 状态 | 金额及反馈 |
| --- | --- |
| 首次导入中 | `—`，说明“正在补算本周用量”，不短暂显示 $1,000 |
| 就绪 | 已扫描日志中报告完整的本地预算余额；覆盖范围说明仍保留 |
| partial / unavailable | “本周剩余至多 $X”，已用“至少 $Y”，显示不完整请求数 |
| 无目录 / 无日志 / 无可识别用量事件 | `—`，分别显示未找到来源 / 尚无可验证用量，不能宣称完整预算 |
| 解析、权限或持久化错误 | 无成功快照时显示 `—`；否则显示明确标注的“上次成功读数（已过期）”，不可当作当前余额 |
| 监听失效 | 明示自动更新已停止，仍可手动刷新；刷新成功不等于监听恢复 |

历史存在有效支持格式、当前周确实无请求时，可以显示 $1,000，但仍不能保证本机日志未被用户删去。已扫描日志范围不是账户完整覆盖的证明。

### 3. 预算和解析契约

固定规则：1 credit = 1,000,000,000 nano AI units；100 credits = $1；周预算为 100,000 credits，即 100,000,000,000,000 nano units。周界为固定 UTC+8 的周一 01:00，与系统时区、夏令时无关。

- 全程以非负 `Int64` 保存单请求 nano 数量，解码时拒绝小数、负数及超出范围的值；参考实现的单请求上限为 1e18。汇总用 checked arithmetic，溢出成为显式错误，不能回绕、截断或崩溃。
- 显示时用 Decimal / 整数换算，不能累加 Double。正常金额四舍五入为两位；不完整数据的已用下界向下舍入、剩余上界向上舍入（包括负数），保证“至少/至多”在分位上仍成立。避免 `-$0.00`。
- 周区间为 `[本周起点, 下周起点)`；按事件时间归属，汇总仅计入不晚于当前时间的事件。时钟回拨、睡眠恢复后重新计算；未来事件保留，时间到达后可计入而不依赖新日志写入。
- 首次回填从当前周起点开始，而不是安装时间。重启后保留已收集记录，不能因源文件被删除而返还预算。首版不自动清理账本、不迁移或覆盖旧 Go 程序的存储文件。
- 只处理 `type == "session.usage_record"`，读取 `data.usage.copilotUsage.totalNanoAiu`，并解析 ISO-8601 时间（有无小数秒、UTC 或偏移量）。忽略合法的非用量事件，不读取 `usage.cost`、token 数、汇总/checkpoint/shutdown 金额作为消费。
- BYOK 先排除。去重 key 为带类型前缀的 `apiCallId` 的 SHA-256，缺失时使用 event ID；缺少必需标识或时间时报错。复制日志和多目录重复不能重复扣费。
- 状态支持 complete / partial / unavailable。缺状态且有金额归 partial，缺状态且无金额归 unavailable；unavailable 的金额不参与汇总；complete 无金额、未知状态或类型错误均报错。
- partial 可被更完整数据补齐；已知 partial 金额取更大的已报告下界，不能被 unavailable 覆盖；complete 覆盖 partial 而非相加；complete 不被降级。两条 complete 金额冲突报错。保留第一次接受的时间归属，诊断不包含原始请求 ID 或原始行。
- 完整 JSONL 行才处理；半行不推进游标，补全后再读。使用分块读取，不把所有日志读入内存；设置合理的单行内存上限，越限显式报错，不默默跳过用量。
- 账本采用带版本的 Codable 模型，验证数量、时间、状态、游标和源配置。损坏或未知版本不自动重置、不覆盖原文件。

### 4. 文件监听、调度和持久化

使用一个串行后台工作队列负责扫描和写盘，UI 只在 MainActor 更新；不要在 MainActor 或 Swift cooperative executor 上执行大批阻塞文件读取。用不可变 Sendable 快照传回 UI，禁止用 unchecked Sendable 掩盖线程归属问题。

- FSEvents 先注册规范化后的源目录，再开始初次扫描。只发现根目录下一级非隐藏会话目录的 `events.jsonl`；回调过滤无关变更，不递归读取其他文件，不跟随路径逃逸的符号链接。
- 事件按 200ms debounce、最长 1s 合并；callback 只发失效信号，扫描始终串行。事件风暴最多排队一次后续扫描，不创建无界任务。
- FSEvents dropped / must-scan-subdirs / root-changed 等标记触发重新发现和完整一致性核对；根目录失效或监听启动失败公开错误，提供手动刷新以重新尝试注册。
- 游标记录文件身份、byte offset、size、mtime，以及已消费区段边界 fingerprint。截断、替换和可检测重写从头重放，再按请求 key 去重。首版不声称能检测保留所有元数据与指纹的任意原地篡改；文件系统事件表明文件被改写时不能仅凭相同 size/mtime 提前跳过。
- 每次扫描使用文件大小快照，只消费已完整写入的行；扫描期间追加由后续扫描处理。手动刷新即使后台繁忙也能排队，按钮仅在已有手动请求待完成时禁用。
- 采用候选账本事务：扫描/验证全部成功后，先原子持久化，再发布新快照和游标。失败不提交候选游标或成功读数；保留上次成功状态并说明失败。其他日志有新增时若某文件损坏，首版选择“整体过期”，而非制造看似完整的余额。
- 独立存储：`~/Library/Application Support/CopilotCreditMonitor/ledger-v1.json`，不与原版 `Copilot Credit Monitor/session-usage.json` 混用。目录 0700、文件 0600；同目录临时文件写入、同步、原子 rename，错误上报并清理本次临时文件。
- 只保存必要的哈希 key、时间、数量、完整性、游标和源配置，不保存 prompt、回答、工具参数、凭据、原始请求 ID。读取混合日志不可避免接触文本字节，但不提取、不输出、不上传这些内容。
- 使用应用私有目录中非阻塞 `flock` 防止两个进程并发写同一账本；锁忙时退出第二实例，真实锁 I/O 错误明确报告。不通过删除锁文件绕开运行实例。
- 在下次周界、未来事件到时、系统时钟改变和唤醒时更新统计与调度；打开弹出卡片时也重新核对时间并安排刷新。无需每秒轮询或重绘，空闲时不重写账本。
- 退出时停止事件流和定时器、取消排队工作，并使正在提交的写入安全完成；不得留下部分覆盖的账本。

## Files likely involved

以下是实现阶段建议结构，不在规划阶段创建：

| 文件 | 职责 |
| --- | --- |
| `Package.swift` | macOS 13+、Core / executable / unit-test targets，无外部依赖 |
| `Sources/CreditMonitorCore/UsageRecord.swift` | 最小日志数据模型、解析、状态与去重规则 |
| `Sources/CreditMonitorCore/Budget.swift` | 周界、checked 汇总、上下界和美元格式 |
| `Sources/CreditMonitorCore/LedgerStore.swift` | 版本化账本、验证、原子保存和持久化错误 |
| `Sources/CreditMonitorCore/SessionScanner.swift` | 源发现、增量 JSONL、指纹与事务候选 |
| `Sources/CopilotCreditMonitor/main.swift` | AppKit 启动、参数和生命周期 |
| `Sources/CopilotCreditMonitor/AppDelegate.swift` | 应用服务持有、单实例锁及退出协调 |
| `Sources/CopilotCreditMonitor/MonitorController.swift` | 串行调度、快照、手动刷新和边界定时器 |
| `Sources/CopilotCreditMonitor/SessionWatcher.swift` | FSEvents 生命周期、合并与失效处理 |
| `Sources/CopilotCreditMonitor/StatusItemController.swift` | 菜单栏模板图标、popover 与切换 |
| `Sources/CopilotCreditMonitor/PopoverViewController.swift` | 原生余额卡片、错误和辅助功能 |
| `Resources/Info.plist` | 稳定 bundle ID、版本、LSUIElement、最低系统版本 |
| `scripts/build-app.sh` | release build、构造 app bundle、本地 ad-hoc 签名 |
| `Tests/CreditMonitorCoreTests/*.swift` | 合成 fixture 的单元测试；由用户运行 |
| `README.md`, `.gitignore` | 构建/启动/统计边界/隐私/恢复说明；只忽略产物，不忽略工作台 |

允许在职责不变的前提下合并小文件，避免为简单状态增加多层协议或插件架构。

## Implementation steps

1. 建立 package 和可打包启动的 AppKit menu bar 外壳，确定 executable / bundle 名称一致；`LSUIElement`、popover、退出先连通。
2. 实现 Budget、UsageRecord、去重与合成单元测试文件，明确金额精度和周界契约；不运行测试。
3. 实现 LedgerStore、SessionScanner 和单实例写锁；先完成重启恢复、首次回填与失败事务，再接自动刷新。
4. 接入 FSEvents、串行队列、debounce/排队刷新、睡眠和时间边界处理；监听失败不得被后续 UI 状态覆盖。
5. 完成卡片所有状态与辅助功能，并将“仅本机、非账户余额”作为常驻文案。
6. 完成 `.app` 打包脚本和 README；脚本仅 build/打包/签名，不启动应用、不读取真实会话、不运行测试、不下载依赖。
7. 执行下面的 build-only 验证。写 `IMPLEMENTATION.md`，列出真实执行的命令、已知限制和用户手动验收项，转 `ready-for-review`，不自行提交、推送或合并。

## Validation

本次只检查了参考代码、文档及工具版本，未实现、编译或运行应用。当前机器有 Apple Swift 6.4、Xcode 27.1，arm64；这不证明 macOS 13 或 Intel 的运行兼容性。

实现阶段允许自动执行：

```sh
swift build
bash scripts/build-app.sh
plutil -lint dist/CopilotCreditMonitor.app/Contents/Info.plist
codesign --verify --strict dist/CopilotCreditMonitor.app
```

打包脚本内部应使用 `swift build -c release` 和 `swift build -c release --show-bin-path` 查找 executable，复制到 `Contents/MacOS`，使用本地 ad-hoc 签名。首版产物是当前机器 arm64 的本地 `.app`；不承诺 universal、Developer ID、notarization 或 App Store 分发。应用为非 sandbox，读取用户目录无需把 Full Disk Access 当作默认解决方案；遇到权限错误按实际来源提示。

禁止自动执行 `swift test`、`xcodebuild test`、UI/smoke/integration 测试或启动应用读取真实会话。不得添加 UI test target、GitHub Actions。单元测试源码可以新增，执行权留给用户。

交给用户的手动验证矩阵（使用隔离临时 session 根目录及独立测试账本；实现时为合成运行提供明确的 `--data-dir` 参数，不得误用正式账本）：

| 场景 | 预期 |
| --- | --- |
| 本周 complete 100 credits | 本周已用 $1.00，剩余 $999.00 |
| 本周 complete 100,100 credits | 剩余 -$1.00，进度条不溢出布局 |
| partial 与 unavailable | 不能显示为精确余额，正确显示上下界与缺失计数 |
| 小于一美分的值及负上界 | 舍入仍保持“至少/至多”不等式，无负零 |
| 周一 00:59:59 / 01:00:00 UTC+8、跨年、改系统时区 | 前者属于上一周，后者属于新周；系统时区不改变周界 |
| 初装、重启、复制日志、重写/截断、跨目录重复、partial 升级 | 回填正确，不重复扣费、不因重启丢数 |
| 最后一行未带换行，之后补齐 | 未补齐不计入，补齐后只计一次 |
| 坏 JSON、未知状态、冲突 complete、非法数量、整数溢出 | 显式错误，保持上次已持久化快照，不显示伪成功 |
| 无日志 / 无支持格式 / 权限失败 / 坏账本 / 写盘失败 | 区分原因，不重置成 $1,000、不覆盖损坏历史 |
| 后台扫描时点刷新、连续大量文件事件、空闲 | 可排队一次，反馈清楚，无并发写入或每秒扫描 |
| 睡眠跨周、时钟改变、未来时间事件到时 | 无新日志写入也重新归属和更新 |
| 双击 app、第二实例、关闭 popover、点击外部、Escape、退出 | 无 Dock 主窗口，第二实例无竞争，popover 关闭不退出监控 |
| 深浅色、VoiceOver、键盘、大金额和长错误文案 | 图标清晰，余额可读，布局不截断关键提示 |

## Risks and open questions

- **覆盖不完整是产品边界，不是待修复的账户同步 bug。** 本机日志可能被删、客户端可能未报告；不能把完整 credits 字段等同于账户完整账单。已由用户确认接受此范围。
- `session.usage_record` 为客户端日志契约，可能变化。当前仅核对参考代码，未读取用户真实日志；上线前由用户用本机运行验收确认格式。遇到不兼容需显式报错，不回退到 token 估算。
- FSEvents 提供失效通知而非逐条账单保证，必须处理合并/丢失/新建目录/根路径变化，并在唤醒、打开卡片和手动刷新时补扫。性能和长会话内存需在真实规模上由用户确认。
- 最低 macOS 13 是设计目标，实际 API availability 和 deployment target 必须在实现 build 时校验；arm64 build 不能替代 Intel 或旧系统运行验证。
- 首版账本随使用增长，不自动清理；后续如需保留期，须单独设计跨周回放/去重不丢账的迁移方案。
- 不直接导入旧 Go 账本。因此只存在于旧账本、已从源日志删除的历史用量不会自动恢复；常驻覆盖说明必须清楚，不能声称与旧 widget 数值必然一致。
- 参考实现 `summarize` 使用未检查的 int64 加法、`money` 使用 float64，Swift 实现应落实上面的溢出和 Decimal 规则，而非照搬。

依据：参考 `README.md` 的 Supported sources / Actual credit data / Budget rules / Privacy；`budget.go` 的 periodStarts / summarize / loadLedger / saveLedger；`collector.go` 的 eventUsage / scanFile / collect；`watcher.go` 的 startWatching / watchChanges；`main.go` 的 beginScan / refresh / completeScan；`budget_test.go` 的边界 fixture。

AppKit 文档经 Context7 核对：
- https://developer.apple.com/documentation/appkit/nsstatusbar
- https://developer.apple.com/documentation/appkit/nspopover/behavior-swift.enum
- https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited
