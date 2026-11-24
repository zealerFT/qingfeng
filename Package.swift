// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Qingfeng",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Qingfeng", targets: ["QingfengApp"])],
    targets: [
        .target(name: "QingfengCore"),
        .executableTarget(name: "QingfengApp", dependencies: ["QingfengCore"]),
        .executableTarget(name: "QingfengCoreChecks", dependencies: ["QingfengCore"], path: "Tests/QingfengCoreTests"),
        .executableTarget(name: "QingfengAITransportChecks", dependencies: ["QingfengCore"], path: "Tests/QingfengAITransportChecks")
    ],
    swiftLanguageModes: [.v5]
)
