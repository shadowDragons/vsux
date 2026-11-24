// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "CmuxClone",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CmuxClone", targets: ["CmuxClone"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.7.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .systemLibrary(name: "CGhostty", path: "Sources/CGhostty"),
        .executableTarget(name: "CmuxClone", dependencies: ["CGhostty", .product(name: "Markdown", package: "swift-markdown"), .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Highlighting"), .copy("Localization")], linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            .unsafeFlags([root + "/Vendor/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"]),
            .linkedLibrary("c++"),
            .linkedFramework("AppKit"), .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
            .linkedFramework("CoreText"), .linkedFramework("CoreGraphics"), .linkedFramework("Carbon"),
            .linkedFramework("IOSurface"), .linkedFramework("CoreVideo"), .linkedFramework("Security"), .linkedFramework("JavaScriptCore")
        ]),
        .testTarget(name: "CmuxCloneTests", dependencies: ["CmuxClone"])
    ],
    swiftLanguageModes: [.v5]
)
