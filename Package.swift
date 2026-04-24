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
        .executable(
            name: "StatefulGraph",
            targets: ["StatefulGraph"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0-latest"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths.git", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.18.9"),
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
        .target(
            name: "StatefulMacros",
            dependencies: [
                "StatefulMacrosMacros",
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
            ]
        ),
        .executableTarget(
            name: "StatefulMacrosClient",
            dependencies: [
                "StatefulMacros",
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .executableTarget(
            name: "StatefulGraph",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "StatefulMacrosMacrosTests",
            dependencies: [
                "StatefulMacrosMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
        .testTarget(
            name: "StatefulMacrosTests",
            dependencies: [
                "StatefulMacros",
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .testTarget(
            name: "StatefulGraphTests",
            dependencies: [
                "StatefulGraph",
            ]
        ),
    ]
)
