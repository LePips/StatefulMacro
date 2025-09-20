// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "StatefulMacros",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "StatefulMacros",
            targets: ["StatefulMacros"]
        ),
        .executable(
            name: "StatefulMacrosClient",
            targets: ["StatefulMacrosClient"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0-latest"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths.git", from: "1.0.0"),
    ],
    targets: [
        .macro(
            name: "StatefulMacrosMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .target(name: "StatefulMacros", dependencies: ["StatefulMacrosMacros"]),
        .executableTarget(
            name: "StatefulMacrosClient",
            dependencies: [
                "StatefulMacros",
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
    ]
)
