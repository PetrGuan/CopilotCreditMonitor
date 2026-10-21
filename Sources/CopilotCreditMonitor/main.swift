import AppKit

let configuration = AppConfiguration.from(arguments: CommandLine.arguments)
let delegate = AppDelegate(configuration: configuration)
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
