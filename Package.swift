// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PortlyApp", targets: ["PortlyApp"]),
        .executable(name: "portly", targets: ["PortlyCLI"]),
        .library(name: "PortlyCore", targets: ["PortlyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "PortlyCore",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyApp",
            dependencies: [
                "PortlyCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyCLI",
            dependencies: [
                "PortlyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
