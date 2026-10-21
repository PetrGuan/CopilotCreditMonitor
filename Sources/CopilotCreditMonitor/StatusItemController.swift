import AppKit

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverController: PopoverViewController

    init(popoverController: PopoverViewController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popoverController = popoverController
        super.init()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.delegate = self
        popoverController.onContentSizeChange = { [weak self] size in
            self?.popover.contentSize = size
        }
        setupButton()
    }

    func update(snapshot: MonitorSnapshot) {
        popoverController.update(snapshot: snapshot)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverController.prepareForClose()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Copilot Credit Monitor")
        button.image?.isTemplate = true
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.toolTip = "Copilot Credit Monitor"
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            _ = popoverController.view
            popover.contentSize = popoverController.preferredContentSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }
}
