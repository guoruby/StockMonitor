// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StockMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StockMonitor", targets: ["StockMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "StockMonitor",
            path: "Sources"
        )
    ]
)
