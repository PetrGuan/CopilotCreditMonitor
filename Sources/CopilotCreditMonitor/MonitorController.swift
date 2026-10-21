import CreditMonitorCore
import Foundation

enum MonitorStatus {
    case bootstrapping
    case ready
    case partial
    case unavailable
    case stale(String)
    case error(String)
}

struct MonitorSnapshot {
    var status: MonitorStatus
    let remainingText: String
    let usedText: String
    let budgetText: String
    let progressText: String
    let progressValue: Double?
    let nextResetText: String
    let coverageText: String
    let statusText: String
    let warningText: String?
    let lastRefreshText: String
    let budgetCents: Int64
    let usedLowerNano: Int64
    let hasIncompleteData: Bool
}

final class MonitorController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CopilotCreditMonitor.monitor", qos: .utility)
    private let scanQueue = DispatchQueue(label: "CopilotCreditMonitor.scan", qos: .utility)
    private let configuration: AppConfiguration
    private let scanner: SessionScanner
    private let ledgerStore: LedgerStore
    private let settingsStore: BudgetSettingsStore
    private var ledger: Ledger = Ledger()
    private var settings = BudgetSettings()
    private var watcher: SessionWatcher?

    private var isScanRunning = false
    private var scanRequested = false
    private var isStopped = false
    private var activeScanToken: Int = 0
    private var activeCancellation: CancellationFlag?
    private var hasTrustedSnapshot = false
    private var blockedError: String?
    private var watcherFailureMessage: String?
    private var lastProgressPush = Date.distantPast

    private let snapshotLock = NSLock()
    private let lifecycleLock = NSLock()
    private var stoppedFlag = false
    private var latestSnapshot = MonitorSnapshot(
        status: .bootstrapping,
        remainingText: "—",
        usedText: "—",
        budgetText: "$1,000.00",
        progressText: "—",
        progressValue: nil,
        nextResetText: "—",
        coverageText: "仅本机 CLI / SDK · 非账户余额",
        statusText: "准备中",
        warningText: nil,
        lastRefreshText: "未刷新",
        budgetCents: BudgetMath.defaultWeeklyBudgetCents,
        usedLowerNano: 0,
        hasIncompleteData: false
    )

    private let onSnapshot: @Sendable @MainActor (MonitorSnapshot) -> Void

    init(configuration: AppConfiguration, onSnapshot: @escaping @Sendable @MainActor (MonitorSnapshot) -> Void) {
        self.configuration = configuration
        scanner = SessionScanner(sourceRoots: configuration.sourceRoots)
        ledgerStore = LedgerStore(dataDirectory: configuration.dataDirectory)
        settingsStore = BudgetSettingsStore(dataDirectory: configuration.dataDirectory)
        self.onSnapshot = onSnapshot
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            do {
                try self.ledgerStore.ensureDataDirectory()
                self.ledger = try self.ledgerStore.load()
                self.settings = try self.settingsStore.loadOrDefault()
            } catch {
                self.blockedError = error.localizedDescription
                self.publishError(message: "配置或账本损坏：\(error.localizedDescription)")
                return
            }

            self.startWatcher()
            self.requestScan(trigger: "startup")
        }
    }

    func stop() {
        lifecycleLock.lock()
        stoppedFlag = true
        lifecycleLock.unlock()
        activeCancellation?.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.activeScanToken += 1
            self.activeCancellation = nil
            self.watcher?.stop()
            self.watcher = nil
        }
    }

    func saveBudget(input: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let blockedError = self.blockedError {
                DispatchQueue.main.async {
                    completion(.failure(NSError(
                        domain: "MonitorController",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: blockedError]
                    )))
                }
                return
            }
            do {
                let cents = try BudgetSettingsStore.parseBudgetCents(input: input)
                let next = BudgetSettings(version: 1, weeklyBudgetCents: cents)
                try self.settingsStore.save(next)
                self.settings = next
                self.publishSummary(trigger: "budget-saved", warnings: [], preserveProcessingState: true)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func budgetPreview(input: String) -> String? {
        let snapshot = readLatestSnapshot()
        switch snapshot.status {
        case .ready, .partial:
            break
        default:
            return nil
        }
        guard let cents = try? BudgetSettingsStore.parseBudgetCents(input: input),
              let budgetNano = try? BudgetMath.budgetNano(fromCents: cents),
              let remaining = try? BudgetMath.subtractExact(budgetNano, snapshot.usedLowerNano)
        else {
            return nil
        }
        if snapshot.hasIncompleteData {
            return "≤ \(MoneyFormatter.upperBoundUSD(fromNano: remaining))"
        }
        return MoneyFormatter.exactUSD(fromNano: remaining)
    }

    func refreshNow() {
        queue.async { [weak self] in
            self?.requestScan(trigger: "manual")
        }
    }

    private func startWatcher() {
        let watcher = SessionWatcher(roots: configuration.sourceRoots)
        watcher.onNeedsScan = { [weak self] in
            guard let self else { return }
            let controller = self
            self.queue.async {
                controller.requestScan(trigger: "watch")
            }
        }
        watcher.onWatcherError = { [weak self] message in
            guard let self else { return }
            let controller = self
            self.queue.async {
                controller.watcherFailureMessage = message
                controller.publishStale(message: message)
            }
        }
        self.watcher = watcher
        do {
            try watcher.start()
        } catch {
            watcherFailureMessage = "监听启动失败：\(error.localizedDescription)"
            publishStale(message: watcherFailureMessage!)
        }
    }

    private func requestScan(trigger: String) {
        guard !isStopped, blockedError == nil else { return }
        if isScanRunning {
            scanRequested = true
            return
        }
        isScanRunning = true
        activeScanToken += 1
        let token = activeScanToken
        let cancellation = CancellationFlag()
        activeCancellation = cancellation
        let ledgerSnapshot = ledger
        publishScanStart(trigger: trigger)
        scanQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<ScanSnapshot, Error>
            do {
                let snapshot = try self.scanner.scan(
                    ledger: ledgerSnapshot,
                    now: Date(),
                    onProgress: { [weak self] progress in
                        guard let self else { return }
                        self.queue.async {
                            self.publishScanProgress(progress: progress, token: token, trigger: trigger)
                        }
                    },
                    cancellation: ScanCancellation(isCancelled: { cancellation.isCancelled })
                )
                result = .success(snapshot)
            } catch {
                result = .failure(error)
            }
            self.queue.async { [weak self] in
                self?.completeScan(result: result, token: token, trigger: trigger)
            }
        }
    }

    private func finishScanAndQueueNext(trigger: String) {
        isScanRunning = false
        if scanRequested {
            scanRequested = false
            requestScan(trigger: "queued-\(trigger)")
        }
    }

    private func publishScanStart(trigger: String) {
        let current = readLatestSnapshot()
        let snapshot = MonitorSnapshot(
            status: hasTrustedSnapshot ? .stale("正在扫描，显示上次读数") : .bootstrapping,
            remainingText: hasTrustedSnapshot ? current.remainingText : "—",
            usedText: hasTrustedSnapshot ? current.usedText : "—",
            budgetText: current.budgetText,
            progressText: hasTrustedSnapshot ? current.progressText : "—",
            progressValue: hasTrustedSnapshot ? current.progressValue : nil,
            nextResetText: hasTrustedSnapshot ? current.nextResetText : "—",
            coverageText: "仅本机 CLI / SDK · 非账户余额\n100 credits = $1",
            statusText: "正在扫描（\(trigger)）",
            warningText: watcherFailureMessage,
            lastRefreshText: current.lastRefreshText,
            budgetCents: settings.weeklyBudgetCents,
            usedLowerNano: current.usedLowerNano,
            hasIncompleteData: current.hasIncompleteData
        )
        push(snapshot)
    }

    private func completeScan(result: Result<ScanSnapshot, Error>, token: Int, trigger: String) {
        guard !isStopped, activeScanToken == token else { return }
        activeCancellation = nil
        switch result {
        case .success(let snapshot):
            if snapshot.hadMutations {
                publishScanProgress(progress: ScanProgress(
                    phase: "saving",
                    processedFiles: snapshot.scannedFileCount,
                    totalFiles: snapshot.scannedFileCount,
                    processedBytes: 0,
                    totalBytes: 0
                ), token: token, trigger: trigger)
                do {
                    try ledgerStore.save(snapshot.ledger)
                } catch {
                    publishError(message: "保存账本失败：\(error.localizedDescription)")
                    finishScanAndQueueNext(trigger: trigger)
                    return
                }
            }
            ledger = snapshot.ledger
            hasTrustedSnapshot = true
            publishSummary(trigger: trigger, warnings: snapshot.warnings)
            finishScanAndQueueNext(trigger: trigger)
        case .failure(let error as ScanError):
            if case .cancelled = error {
                finishScanAndQueueNext(trigger: trigger)
            } else {
                publishError(message: error.localizedDescription)
                finishScanAndQueueNext(trigger: trigger)
            }
        case .failure(let error):
            publishError(message: error.localizedDescription)
            finishScanAndQueueNext(trigger: trigger)
        }
    }

    private func publishScanProgress(progress: ScanProgress, token: Int, trigger: String) {
        guard activeScanToken == token, !isStopped, isScanRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgressPush) >= 0.2 else { return }
        lastProgressPush = now
        let current = readLatestSnapshot()
        let percent: String
        if progress.totalBytes > 0 {
            let ratio = max(0, min(1, Double(progress.processedBytes) / Double(progress.totalBytes)))
            percent = String(format: "%.1f%%", ratio * 100)
        } else {
            percent = "0.0%"
        }
        let statusText = "\(progress.phase) \(progress.processedFiles)/\(progress.totalFiles) · \(percent) · \(trigger)"
        let snapshot = MonitorSnapshot(
            status: current.status,
            remainingText: current.remainingText,
            usedText: current.usedText,
            budgetText: current.budgetText,
            progressText: current.progressText,
            progressValue: current.progressValue,
            nextResetText: current.nextResetText,
            coverageText: current.coverageText,
            statusText: statusText,
            warningText: current.warningText,
            lastRefreshText: current.lastRefreshText,
            budgetCents: current.budgetCents,
            usedLowerNano: current.usedLowerNano,
            hasIncompleteData: current.hasIncompleteData
        )
        push(snapshot)
    }

    private func publishSummary(trigger: String, warnings: [ScanWarning], preserveProcessingState: Bool = false) {
        let now = Date()
        do {
            let summary = try BudgetMath.summarize(
                entries: Array(ledger.entries.values),
                budgetCents: settings.weeklyBudgetCents,
                now: now
            )
            let budgetText = MoneyFormatter.exactUSD(fromNano: summary.budgetNano)
            let nextReset = DateFormatter.humanReset.string(from: summary.nextReset)
            let lastRefresh = DateFormatter.humanRefresh.string(from: now)

            var status: MonitorStatus
            let remainingText: String
            let usedText: String
            let progressText: String
            let progressValue: Double?
            var statusLabel: String

            if summary.eventCount == 0 {
                status = .unavailable
                remainingText = "—"
                usedText = "—"
                progressText = "—"
                progressValue = nil
                statusLabel = "尚无可验证用量"
            } else if summary.hasIncompleteData {
                status = .partial
                remainingText = "≤ \(MoneyFormatter.upperBoundUSD(fromNano: summary.remainingUpperNano))"
                usedText = "至少 \(MoneyFormatter.lowerBoundUSD(fromNano: summary.usedLowerNano))"
                progressText = "至多 \(MoneyFormatter.remainingPercentage(remainingNano: summary.remainingUpperNano, budgetNano: summary.budgetNano))"
                progressValue = min(1, max(0, Double(summary.remainingUpperNano) / max(1, Double(summary.budgetNano))))
                statusLabel = "部分用量尚未完整报告"
            } else {
                status = .ready
                remainingText = MoneyFormatter.exactUSD(fromNano: summary.remainingUpperNano)
                usedText = MoneyFormatter.exactUSD(fromNano: summary.usedLowerNano)
                progressText = MoneyFormatter.remainingPercentage(remainingNano: summary.remainingUpperNano, budgetNano: summary.budgetNano)
                progressValue = min(1, max(0, Double(summary.remainingUpperNano) / max(1, Double(summary.budgetNano))))
                statusLabel = "数据已更新"
            }

            if preserveProcessingState, isScanRunning {
                if hasTrustedSnapshot {
                    status = .stale("正在扫描，显示上次读数")
                    statusLabel = "预算已保存，等待扫描完成"
                } else {
                    status = .bootstrapping
                    statusLabel = "预算已保存，等待首次导入完成"
                }
            }

            let warning = warnings.first?.message ?? watcherFailureMessage
            let snapshot = MonitorSnapshot(
                status: status,
                remainingText: remainingText,
                usedText: usedText,
                budgetText: budgetText,
                progressText: progressText,
                progressValue: progressValue,
                nextResetText: "\(nextReset) 北京时间",
                coverageText: "仅本机 CLI / SDK · 非账户余额\n100 credits = $1",
                statusText: "\(statusLabel) · \(trigger)",
                warningText: warning,
                lastRefreshText: "更新于 \(lastRefresh)",
                budgetCents: settings.weeklyBudgetCents,
                usedLowerNano: summary.usedLowerNano,
                hasIncompleteData: summary.hasIncompleteData
            )
            push(snapshot)
        } catch {
            publishError(message: error.localizedDescription)
        }
    }

    private func publishError(message: String) {
        let current = readLatestSnapshot()
        let snapshot = MonitorSnapshot(
            status: .error(message),
            remainingText: hasTrustedSnapshot ? current.remainingText : "—",
            usedText: hasTrustedSnapshot ? current.usedText : "—",
            budgetText: current.budgetText,
            progressText: hasTrustedSnapshot ? current.progressText : "—",
            progressValue: hasTrustedSnapshot ? current.progressValue : nil,
            nextResetText: hasTrustedSnapshot ? current.nextResetText : "—",
            coverageText: current.coverageText,
            statusText: "错误",
            warningText: message,
            lastRefreshText: current.lastRefreshText,
            budgetCents: current.budgetCents,
            usedLowerNano: current.usedLowerNano,
            hasIncompleteData: current.hasIncompleteData
        )
        push(snapshot)
    }

    private func publishStale(message: String) {
        let current = readLatestSnapshot()
        let snapshot = MonitorSnapshot(
            status: .stale(message),
            remainingText: hasTrustedSnapshot ? current.remainingText : "—",
            usedText: hasTrustedSnapshot ? current.usedText : "—",
            budgetText: current.budgetText,
            progressText: hasTrustedSnapshot ? current.progressText : "—",
            progressValue: hasTrustedSnapshot ? current.progressValue : nil,
            nextResetText: hasTrustedSnapshot ? current.nextResetText : "—",
            coverageText: current.coverageText,
            statusText: "监听异常",
            warningText: message,
            lastRefreshText: current.lastRefreshText,
            budgetCents: current.budgetCents,
            usedLowerNano: current.usedLowerNano,
            hasIncompleteData: current.hasIncompleteData
        )
        push(snapshot)
    }

    private func readLatestSnapshot() -> MonitorSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return latestSnapshot
    }

    private func push(_ snapshot: MonitorSnapshot) {
        guard !isStopped else { return }
        snapshotLock.lock()
        latestSnapshot = snapshot
        snapshotLock.unlock()
        let callback = onSnapshot
        Task { @MainActor [weak self] in
            guard let self, !self.isLifecycleStopped() else { return }
            callback(snapshot)
        }
    }

    private func isLifecycleStopped() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stoppedFlag
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private extension DateFormatter {
    static let humanReset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = BudgetMath.beijingTimeZone
        formatter.dateFormat = "周E MM/dd · HH:mm"
        return formatter
    }()

    static let humanRefresh: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
