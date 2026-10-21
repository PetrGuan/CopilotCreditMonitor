import Foundation

struct AppConfiguration {
    let sourceRoots: [URL]
    let dataDirectory: URL

    static func from(arguments: [String]) -> AppConfiguration {
        let defaultSource = URL(fileURLWithPath: NSString(string: "~/.copilot/session-state").expandingTildeInPath)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultData = appSupport.appendingPathComponent("CopilotCreditMonitor", isDirectory: true)

        var sourceRoots = [defaultSource]
        var dataDir = defaultData
        var idx = 1
        while idx < arguments.count {
            let token = arguments[idx]
            if token == "--session-dir", idx + 1 < arguments.count {
                sourceRoots = [URL(fileURLWithPath: NSString(string: arguments[idx + 1]).expandingTildeInPath)]
                idx += 2
                continue
            }
            if token == "--data-dir", idx + 1 < arguments.count {
                dataDir = URL(fileURLWithPath: NSString(string: arguments[idx + 1]).expandingTildeInPath)
                idx += 2
                continue
            }
            idx += 1
        }
        return AppConfiguration(sourceRoots: sourceRoots, dataDirectory: dataDir)
    }
}
