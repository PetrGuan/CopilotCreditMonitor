// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopilotCreditMonitor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CreditMonitorCore", targets: ["CreditMonitorCore"]),
        .executable(name: "CopilotCreditMonitor", targets: ["CopilotCreditMonitor"]),
    ],
    targets: [
        .target(
            name: "CreditMonitorCore"
        ),
        .executableTarget(
            name: "CopilotCreditMonitor",
            dependencies: ["CreditMonitorCore"]
        ),
        .testTarget(
            name: "CreditMonitorCoreTests",
            dependencies: ["CreditMonitorCore"]
        ),
    ]
)
