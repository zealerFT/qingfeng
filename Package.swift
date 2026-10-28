// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Qingfeng",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qingfeng", targets: ["QingfengApp"])],
    targets: [
        .target(name: "QingfengCore"),
        .executableTarget(name: "QingfengApp", dependencies: ["QingfengCore"]),
        .executableTarget(name: "QingfengCoreChecks", dependencies: ["QingfengCore"], path: "Tests/QingfengCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
