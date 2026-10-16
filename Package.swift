// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MonkShift",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MonkShift", targets: ["MonkShift"])],
    targets: [
        .target(name: "MonkShiftCore"),
        .executableTarget(name: "MonkShift", dependencies: ["MonkShiftCore"]),
        // A small Foundation test runner also works with Command Line Tools (no XCTest SDK).
        .executableTarget(name: "MonkShiftChecks", dependencies: ["MonkShiftCore"], path: "Tests/MonkShiftCoreTests")
    ]
)
