// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrintProgress",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PrintProgressCore", targets: ["PrintProgressCore"]),
        .executable(name: "printer-probe", targets: ["PrinterProbe"]),
    ],
    targets: [
        .target(name: "PrintProgressCore"),
        .executableTarget(name: "PrinterProbe", dependencies: ["PrintProgressCore"]),
        .testTarget(name: "PrintProgressCoreTests", dependencies: ["PrintProgressCore"]),
    ],
    swiftLanguageModes: [.v5]
)
