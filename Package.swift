// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Luna", platforms: [.macOS(.v14)],
    products: [.executable(name: "Luna", targets: ["Luna"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "LunaCore"),
        .executableTarget(name: "Luna", dependencies: ["LunaCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LunaCoreTests", dependencies: ["LunaCore"]),
        .testTarget(name: "LunaTests", dependencies: ["Luna", "LunaCore"], resources: [.copy("Fixtures")])
    ], swiftLanguageModes: [.v5]
)
