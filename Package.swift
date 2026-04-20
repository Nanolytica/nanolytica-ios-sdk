// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nanolytica",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
    ],
    products: [
        .library(name: "Nanolytica", targets: ["Nanolytica"]),
    ],
    targets: [
        .target(
            name: "Nanolytica",
            path: "Sources/Nanolytica"
        ),
        // Executable test runner instead of an XCTest/Swift-Testing target so
        // `swift test`/`swift run NanolyticaTests` works on a stock Swift
        // toolchain without Xcode.
        .executableTarget(
            name: "NanolyticaTests",
            dependencies: ["Nanolytica"],
            path: "Tests/NanolyticaTests"
        ),
    ]
)
