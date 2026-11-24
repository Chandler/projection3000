// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Patch", platforms: [.macOS(.v14)], products: [
    .executable(name: "Patch", targets: ["PatchApp"]),
    .executable(name: "patch-migrate", targets: ["PatchMigrate"]),
    .library(name: "PatchCore", targets: ["PatchCore"]),
    .library(name: "PatchKit", type: .dynamic, targets: ["PatchKit"])
], targets: [
    .target(name: "PatchCore"),
    .target(name: "OutputBridge", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Foundation"), .linkedFramework("CoreVideo")]),
    .target(name: "PatchKit", dependencies: ["PatchCore", "OutputBridge"], resources: [.copy("Resources/Shaders.metal")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("MetalKit"), .linkedFramework("AVFoundation")]),
    .executableTarget(name: "PatchMigrate", dependencies: ["PatchCore"]),
    .executableTarget(name: "PatchApp", dependencies: ["PatchKit"]),
    .executableTarget(name: "PatchCoreChecks", dependencies: ["PatchCore"], path: "Tests/PatchCoreTests")
], swiftLanguageModes: [.v5])
