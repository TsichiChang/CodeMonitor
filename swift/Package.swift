// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CodeMonitor",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(
      name: "CodeMonitor",
      path: "Sources/CodeMonitor",
      swiftSettings: [.swiftLanguageMode(.v6)]
    )
  ]
)
