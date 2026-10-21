import Darwin
import Foundation

public struct ScanWarning: Codable, Sendable {
    public let message: String
    public let source: String
}

public struct ScanProgress: Sendable {
    public let phase: String
    public let processedFiles: Int
    public let totalFiles: Int
    public let processedBytes: Int64
    public let totalBytes: Int64

    public init(phase: String, processedFiles: Int, totalFiles: Int, processedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.processedFiles = processedFiles
        self.totalFiles = totalFiles
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
    }
}

public struct ScanSnapshot: Sendable {
    public let ledger: Ledger
    public let warnings: [ScanWarning]
    public let scannedFileCount: Int
    public let hadMutations: Bool
}

public enum ScanError: Error, LocalizedError {
    case sourceRootMissing(String)
    case sourceRootNotDirectory(String)
    case lineTooLong(String)
    case utf8Decode(String)
    case ioFailure(String)
    case parseFailure(String, Int64, String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .sourceRootMissing(let root):
            return "Source root does not exist: \(root)"
        case .sourceRootNotDirectory(let root):
            return "Source root is not a directory: \(root)"
        case .lineTooLong(let file):
            return "Encountered a JSONL line larger than allowed in \(file)."
        case .utf8Decode(let file):
            return "Invalid UTF-8 while reading \(file)."
        case .ioFailure(let detail):
            return "Failed to read session logs: \(detail)"
        case .parseFailure(let source, let offset, let reason):
            return "Failed to parse usage record at \(source) byte \(offset): \(reason)"
        case .cancelled:
            return "Scan cancelled."
        }
    }
}

public struct ScanCancellation: Sendable {
    public let isCancelled: @Sendable () -> Bool

    public init(isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
    }
}

public final class SessionScanner: @unchecked Sendable {
    // Tool-result events can contain large documents even when they carry no usage.
    public static let maxLineBytes = 64 * 1024 * 1024
    public static let defaultChunkSize = 256 * 1024
    public static let defaultWorkerCount = 3

    private let sourceRoots: [URL]
    private let workerCount: Int

    public init(sourceRoots: [URL], workerCount: Int = SessionScanner.defaultWorkerCount) {
        self.sourceRoots = sourceRoots
        self.workerCount = max(2, min(4, workerCount))
    }

    public func normalizedSourceRoots() -> [String] {
        sourceRoots.map { $0.standardizedFileURL.path }.sorted()
    }

    public func discoverEventFiles() throws -> [URL] {
        var files: [URL] = []
        for root in sourceRoots {
            let standardized = root.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) else {
                throw ScanError.sourceRootMissing(standardized.path)
            }
            guard isDir.boolValue else {
                throw ScanError.sourceRootNotDirectory(standardized.path)
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: standardized,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
            )
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                guard values.isDirectory == true, values.isHidden != true else { continue }
                let events = child.appendingPathComponent("events.jsonl")
                if FileManager.default.fileExists(atPath: events.path) {
                    files.append(events.standardizedFileURL)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func scan(
        ledger: Ledger,
        now: Date = Date(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        cancellation: ScanCancellation = ScanCancellation(isCancelled: { false })
    ) throws -> ScanSnapshot {
        if cancellation.isCancelled() { throw ScanError.cancelled }

        var candidate = ledger
        let roots = normalizedSourceRoots()
        candidate.sourceDirectories = roots

        let parserRevisionChanged = candidate.parserRevision < UsageRecordParser.parserRevision
        let currentWeekWindow = BudgetMath.weekWindow(containing: now)
        let firstImport = candidate.lastSuccessfulScanAt == nil
        let files = try discoverEventFiles()
        let plans = try files.enumerated().map { index, url in
            try FileScanPlan(
                index: index,
                fileURL: url,
                previousCursor: candidate.cursors[url.path],
                forceReplay: parserRevisionChanged
            )
        }
        let totalBytes = plans.reduce(Int64(0)) { partial, plan in
            partial + max(0, plan.eofSnapshot - plan.startOffset)
        }
        onProgress?(ScanProgress(
            phase: "discovering",
            processedFiles: 0,
            totalFiles: plans.count,
            processedBytes: 0,
            totalBytes: totalBytes
        ))
        let results = try runWorkers(
            plans: plans,
            currentWeekWindow: currentWeekWindow,
            keepCurrentWeekOnly: firstImport,
            cancellation: cancellation,
            totalBytes: totalBytes,
            onProgress: onProgress
        )
        if cancellation.isCancelled() { throw ScanError.cancelled }

        var hadMutations = false
        var warnings: [ScanWarning] = []
        var mergedEntries = candidate.entries
        var mergedCursors = candidate.cursors

        for result in results.sorted(by: { $0.planIndex < $1.planIndex }) {
            mergedCursors[result.cursor.path] = result.cursor.cursor
            warnings.append(contentsOf: result.warnings)
            for mutation in result.mutations {
                let merged = try UsageRecordParser.merge(
                    existing: mergedEntries[mutation.key],
                    incoming: mutation.record,
                    source: mutation.sourcePath
                )
                if merged.status != mergedEntries[mutation.key]?.status ||
                    merged.nanoUnits != mergedEntries[mutation.key]?.nanoUnits ||
                    merged.timestamp != mergedEntries[mutation.key]?.timestamp {
                    hadMutations = true
                }
                mergedEntries[mutation.key] = merged
            }
            if result.cursor.changed {
                hadMutations = true
            }
        }

        let activePaths = Set(files.map(\.path))
        mergedCursors = mergedCursors.filter { activePaths.contains($0.key) }

        candidate.entries = mergedEntries
        candidate.cursors = mergedCursors
        candidate.parserRevision = UsageRecordParser.parserRevision
        candidate.lastSuccessfulScanAt = now

        return ScanSnapshot(
            ledger: candidate,
            warnings: warnings,
            scannedFileCount: files.count,
            hadMutations: hadMutations || parserRevisionChanged
        )
    }

    private func runWorkers(
        plans: [FileScanPlan],
        currentWeekWindow: (start: Date, end: Date),
        keepCurrentWeekOnly: Bool,
        cancellation: ScanCancellation,
        totalBytes: Int64,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) throws -> [WorkerResult] {
        if plans.isEmpty { return [] }
        final class SharedState: @unchecked Sendable {
            var nextIndex = 0
            var results: [WorkerResult] = []
            var errors: [Error] = []
            var processedFiles = 0
            var processedBytes: Int64 = 0
            let lock = NSLock()
            var lastProgress = Date.distantPast
        }
        let state = SharedState()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "CopilotCreditMonitor.scanner.worker", qos: .utility, attributes: .concurrent)

        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                var parser = UsageRecordParser()
                while true {
                    if cancellation.isCancelled() { return }
                    let plan: FileScanPlan?
                    state.lock.lock()
                    if state.nextIndex < plans.count {
                        plan = plans[state.nextIndex]
                        state.nextIndex += 1
                    } else {
                        plan = nil
                    }
                    state.lock.unlock()
                    guard let plan else { return }

                    do {
                        let result = try self.scanSingleFile(
                            plan: plan,
                            parser: &parser,
                            currentWeekWindow: currentWeekWindow,
                            keepCurrentWeekOnly: keepCurrentWeekOnly,
                            cancellation: cancellation,
                            onChunkBytes: { bytesDelta in
                                state.lock.lock()
                                state.processedBytes += Int64(bytesDelta)
                                let now = Date()
                                let shouldEmit = now.timeIntervalSince(state.lastProgress) >= 0.2
                                if shouldEmit {
                                    state.lastProgress = now
                                    onProgress?(ScanProgress(
                                        phase: "scanning",
                                        processedFiles: state.processedFiles,
                                        totalFiles: plans.count,
                                        processedBytes: state.processedBytes,
                                        totalBytes: totalBytes
                                    ))
                                }
                                state.lock.unlock()
                            }
                        )
                        state.lock.lock()
                        state.results.append(result)
                        state.processedFiles += 1
                        let now = Date()
                        let shouldEmit = now.timeIntervalSince(state.lastProgress) >= 0.2
                        if shouldEmit {
                            state.lastProgress = now
                            onProgress?(ScanProgress(
                                phase: "scanning",
                                processedFiles: state.processedFiles,
                                totalFiles: plans.count,
                                processedBytes: state.processedBytes,
                                totalBytes: totalBytes
                            ))
                        }
                        state.lock.unlock()
                    } catch {
                        state.lock.lock()
                        state.errors.append(error)
                        state.lock.unlock()
                    }
                }
            }
        }

        group.wait()
        if let firstError = state.errors.first {
            throw firstError
        }
        onProgress?(ScanProgress(
            phase: "merging",
            processedFiles: plans.count,
            totalFiles: plans.count,
            processedBytes: totalBytes,
            totalBytes: totalBytes
        ))
        return state.results
    }

    private func scanSingleFile(
        plan: FileScanPlan,
        parser: inout UsageRecordParser,
        currentWeekWindow: (start: Date, end: Date),
        keepCurrentWeekOnly: Bool,
        cancellation: ScanCancellation,
        onChunkBytes: @escaping @Sendable (Int) -> Void
    ) throws -> WorkerResult {
        if cancellation.isCancelled() { throw ScanError.cancelled }
        if plan.isUnchanged {
            return WorkerResult(
                planIndex: plan.index,
                cursor: CursorMutation(path: plan.path, cursor: plan.nextCursor, changed: false),
                mutations: [],
                warnings: [],
                bytesRead: 0
            )
        }

        let handle = try FileHandle(forReadingFrom: plan.fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(plan.startOffset))

        var buffer = Data(capacity: Self.defaultChunkSize + 1_024)
        var bufferReadStart = 0
        var consumedOffset = plan.startOffset
        var newlineSearchStart = 0
        var bytesRead: Int64 = 0
        var mutations: [UsageMutation] = []
        var remaining = plan.eofSnapshot - plan.startOffset
        var reachedEOF = false

        while remaining > 0, !reachedEOF {
            if cancellation.isCancelled() { throw ScanError.cancelled }
            try autoreleasepool {
                let toRead = Int(min(Int64(Self.defaultChunkSize), remaining))
                let chunk = try handle.read(upToCount: toRead) ?? Data()
                if chunk.isEmpty {
                    reachedEOF = true
                    return
                }
                remaining -= Int64(chunk.count)
                bytesRead += Int64(chunk.count)
                onChunkBytes(chunk.count)
                buffer.append(chunk)

                while let newlineAt = findNewlineIndex(in: buffer, from: newlineSearchStart) {
                    let lineLength = newlineAt - bufferReadStart
                    if lineLength > Self.maxLineBytes {
                        throw ScanError.lineTooLong(plan.path)
                    }
                    if lineLength > 0 {
                        try autoreleasepool {
                            let lineData = buffer.subdata(in: bufferReadStart..<newlineAt)
                            do {
                                let parsed = try parser.parseUsageLine(lineData)
                                if keepCurrentWeekOnly,
                                   (parsed.timestamp < currentWeekWindow.start || parsed.timestamp >= currentWeekWindow.end) {
                                    return
                                }
                                mutations.append(UsageMutation(key: parsed.key, record: parsed, sourcePath: plan.path))
                            } catch UsageParseError.unknownEvent, UsageParseError.byokExcluded {
                                return
                            } catch {
                                throw ScanError.parseFailure(plan.path, consumedOffset, error.localizedDescription)
                            }
                        }
                    }
                    let consumedLineBytes = lineLength + 1
                    bufferReadStart += consumedLineBytes
                    consumedOffset += Int64(consumedLineBytes)
                    newlineSearchStart = bufferReadStart
                }

                let pendingLineBytes = buffer.count - bufferReadStart
                if pendingLineBytes > Self.maxLineBytes {
                    throw ScanError.lineTooLong(plan.path)
                }
                if newlineSearchStart == buffer.count {
                    newlineSearchStart = bufferReadStart
                } else {
                    newlineSearchStart = max(bufferReadStart, buffer.count - 1)
                }
                if bufferReadStart > 0, bufferReadStart >= Self.defaultChunkSize {
                    let trimmed = bufferReadStart
                    buffer.removeSubrange(0..<trimmed)
                    bufferReadStart = 0
                    newlineSearchStart = max(0, newlineSearchStart - trimmed)
                }
            }
        }

        return WorkerResult(
            planIndex: plan.index,
            cursor: CursorMutation(path: plan.path, cursor: plan.nextCursor.withOffset(consumedOffset), changed: consumedOffset != plan.previousOffset),
            mutations: mutations,
            warnings: [],
            bytesRead: bytesRead
        )
    }

    private func findNewlineIndex(in buffer: Data, from start: Int) -> Int? {
        guard start < buffer.count else { return nil }
        return buffer.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let cursor = baseAddress.advanced(by: start)
            let length = buffer.count - start
            guard let found = memchr(cursor, 0x0A, length) else { return nil }
            let base = baseAddress.assumingMemoryBound(to: UInt8.self)
            let match = found.assumingMemoryBound(to: UInt8.self)
            return base.distance(to: match)
        }
    }
}

private struct FileScanPlan: Sendable {
    let index: Int
    let fileURL: URL
    let path: String
    let inode: UInt64
    let mtimeSeconds: Int64
    let startOffset: Int64
    let eofSnapshot: Int64
    let previousOffset: Int64
    let isUnchanged: Bool

    var nextCursor: FileCursor {
        FileCursor(inode: inode, offset: startOffset, size: eofSnapshot, mtimeSeconds: mtimeSeconds)
    }

    init(index: Int, fileURL: URL, previousCursor: FileCursor?, forceReplay: Bool) throws {
        self.index = index
        self.fileURL = fileURL
        path = fileURL.path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        eofSnapshot = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = ((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        mtimeSeconds = Int64(mtime)
        previousOffset = previousCursor?.offset ?? 0
        if forceReplay {
            startOffset = 0
            isUnchanged = false
            return
        }

        if let previousCursor,
           previousCursor.inode == inode,
           previousCursor.offset >= 0,
           previousCursor.offset <= eofSnapshot,
           previousCursor.mtimeSeconds == mtimeSeconds,
           previousCursor.size == eofSnapshot
        {
            startOffset = previousCursor.offset
            isUnchanged = true
        } else if let previousCursor,
                  previousCursor.inode == inode,
                  previousCursor.offset >= 0,
                  previousCursor.offset <= eofSnapshot
        {
            startOffset = previousCursor.offset
            isUnchanged = false
        } else {
            startOffset = 0
            isUnchanged = false
        }
    }
}

private struct UsageMutation: Sendable {
    let key: String
    let record: ParsedUsageRecord
    let sourcePath: String
}

private struct CursorMutation: Sendable {
    let path: String
    let cursor: FileCursor
    let changed: Bool
}

private struct WorkerResult: Sendable {
    let planIndex: Int
    let cursor: CursorMutation
    let mutations: [UsageMutation]
    let warnings: [ScanWarning]
    let bytesRead: Int64
}

private extension FileCursor {
    func withOffset(_ offset: Int64) -> FileCursor {
        FileCursor(inode: inode, offset: offset, size: size, mtimeSeconds: mtimeSeconds)
    }
}
