// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Ajar", platforms: [.macOS(.v14)], products: [.executable(name: "Ajar", targets: ["Ajar"])], targets: [.executableTarget(name: "Ajar", path: "Ajar", resources: [.copy("Rendering/Shaders.metal")]), .testTarget(name: "AjarTests", dependencies: ["Ajar"], path: "Tests")])
