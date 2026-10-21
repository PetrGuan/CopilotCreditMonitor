import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configuration: AppConfiguration
    private var lock: ProcessLock?
    private var monitorController: MonitorController?
    private var statusItemController: StatusItemController?
    private let popoverController = PopoverViewController()
    private var observers: [NSObjectProtocol] = []

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(
                at: configuration.dataDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let lockURL = configuration.dataDirectory.appendingPathComponent("monitor.lock")
            let processLock = ProcessLock(lockURL: lockURL)
            try processLock.acquire()
            self.lock = processLock
        } catch {
            showFatalAlertAndTerminate(message: error.localizedDescription)
            return
        }

        statusItemController = StatusItemController(popoverController: popoverController)
        let controller = MonitorController(configuration: configuration) { [weak self] snapshot in
            self?.statusItemController?.update(snapshot: snapshot)
        }
        monitorController = controller

        popoverController.onRefresh = { [weak controller] in
            controller?.refreshNow()
        }
        popoverController.onQuit = {
            NSApp.terminate(nil)
        }
        popoverController.onPreviewBudget = { [weak controller] input in
            controller?.budgetPreview(input: input)
        }
        popoverController.onSaveBudget = { [weak controller] input, completion in
            guard let controller else {
                completion(.failure(NSError(
                    domain: "AppDelegate",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "预算控制器不可用。"]
                )))
                return
            }
            controller.saveBudget(input: input, completion: completion)
        }
        registerTimeObservers()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        monitorController?.stop()
        lock?.release()
        lock = nil
    }

    private func registerTimeObservers() {
        let timeChanged = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitorController?.refreshNow()
            }
        }
        observers.append(timeChanged)

        let wallClockChange = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.monitorController?.refreshNow()
            }
        }
        observers.append(wallClockChange)
    }

    private func showFatalAlertAndTerminate(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "CopilotCreditMonitor 无法启动"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
