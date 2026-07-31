// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Rex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Rex", targets: ["RexApp"])
    ],
    targets: [
        .executableTarget(
            name: "RexApp",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")],
            plugins: [.plugin(name: "ReleaseNotesValidationPlugin")]
        ),
        .executableTarget(
            name: "RexReleaseValidator",
            path: "Tools/ReleaseValidator"
        ),
        .executableTarget(
            name: "RexDistributionGate",
            path: "Tools/DistributionGate"
        ),
        .plugin(
            name: "ReleaseNotesValidationPlugin",
            capability: .buildTool(),
            dependencies: [.target(name: "RexReleaseValidator")]
        ),
        .testTarget(
            name: "RexAppTests",
            dependencies: ["RexApp"]
        )
    ]
)
