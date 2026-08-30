// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VeneraKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "VeneraKit", targets: ["VeneraKit"]),
    ],
    targets: [
        // SwiftSoup 以 vendor 形式纳入（swift/Vendored/SwiftSoup），
        // 避免 xcodebuild -target 模式对外部包依赖的构建缺口。
        .target(name: "SwiftSoup", path: "Vendored/SwiftSoup"),
.target(name: "ZIPFoundation", path: "Vendored/ZIPFoundation/Sources/ZIPFoundation"),
        .target(name: "VeneraKit", dependencies: ["SwiftSoup", "ZIPFoundation"]),
        .testTarget(name: "VeneraKitTests", dependencies: ["VeneraKit"]),
    ]
)
