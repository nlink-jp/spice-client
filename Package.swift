// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SpiceClient",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "SpiceClient", targets: ["SpiceClient"])],
    dependencies: [.package(path: "Vendor/SwiftSpice")],
    targets: [
        .target(name: "ConnectionCore"),
        .target(name: "SessionCore", dependencies: ["ConnectionCore"]),
        .target(name: "SwiftSpiceAdapter", dependencies: [
            "ConnectionCore", "SessionCore", .product(name: "SwiftSpice", package: "SwiftSpice")
        ]),
        .executableTarget(name: "SpiceClient", dependencies: [
            "ConnectionCore", "SessionCore", "SwiftSpiceAdapter",
            .product(name: "SwiftSpice", package: "SwiftSpice")
        ]),
        .testTarget(name: "ConnectionCoreTests", dependencies: ["ConnectionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore", "SwiftSpiceAdapter"]),
        .testTarget(name: "SpiceClientTests", dependencies: ["SpiceClient"]),
    ],
    swiftLanguageModes: [.v6]
)
