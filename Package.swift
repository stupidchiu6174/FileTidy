// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FileTidy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FileTidy", targets: ["FileTidy"]),
        .library(name: "FileTidyCore", targets: ["FileTidyCore"]),
        .executable(name: "FileTidyApp", targets: ["FileTidyApp"]),
    ],
    targets: [
        .target(name: "FileTidy", dependencies: ["FileTidyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FileTidyCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "FileTidyApp", dependencies: ["FileTidy"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FileTidyCoreTests", dependencies: ["FileTidyCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
