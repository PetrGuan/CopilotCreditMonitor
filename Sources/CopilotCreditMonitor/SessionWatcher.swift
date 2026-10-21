import CoreServices
import Foundation

final class SessionWatcher {
    private let roots: [URL]
    private let callbackQueue = DispatchQueue(label: "CopilotCreditMonitor.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?
    private var firstPendingAt: Date?

    var onNeedsScan: (() -> Void)?
    var onWatcherError: ((String) -> Void)?

    init(roots: [URL]) {
        self.roots = roots
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()
        let paths = roots.map(\.path) as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, _, eventPathsPointer, eventFlagsPointer, eventIdsPointer) in
                guard let info else { return }
                let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleCallback(
                    eventPaths: unsafeBitCast(eventPathsPointer, to: NSArray.self),
                    eventFlagsPointer: eventFlagsPointer,
                    eventIdsPointer: eventIdsPointer
                )
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            throw NSError(domain: "SessionWatcher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create FSEvent stream.",
            ])
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        if !FSEventStreamStart(stream) {
            stop()
            throw NSError(domain: "SessionWatcher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to start FSEvent stream.",
            ])
        }
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        firstPendingAt = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handleCallback(
        eventPaths: NSArray,
        eventFlagsPointer: UnsafePointer<FSEventStreamEventFlags>?,
        eventIdsPointer _: UnsafePointer<FSEventStreamEventId>?
    ) {
        guard let eventFlagsPointer else { return }
        var shouldRescan = false
        var hasRootIssue = false

        for idx in 0..<eventPaths.count {
            let flags = eventFlagsPointer[idx]
            let eventPath = eventPaths[idx] as? String ?? ""
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                hasRootIssue = true
                shouldRescan = true
                continue
            }
            if eventPath.contains("/events.jsonl") {
                shouldRescan = true
            }
        }

        if hasRootIssue {
            onWatcherError?("目录监听发生丢事件或根变更，已切换到手动刷新/后续重扫。")
        }
        guard shouldRescan else { return }
        debounceRescan()
    }

    private func debounceRescan() {
        let now = Date()
        if firstPendingAt == nil {
            firstPendingAt = now
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.firstPendingAt = nil
            self?.onNeedsScan?()
        }
        debounceWork = work
        let forceAt = firstPendingAt!.addingTimeInterval(1.0)
        let delay = min(0.2, max(0, forceAt.timeIntervalSince(now)))
        callbackQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
