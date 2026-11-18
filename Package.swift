// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "AgentBoard",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentBoardCore", targets: ["AgentBoardCore"]),
        .executable(name: "AgentBoardApp", targets: ["AgentBoardApp"]),
        .executable(name: "agentboard", targets: ["agentboard"])
    ],
    targets: [
        .target(
            name: "AgentBoardCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("CoreServices")
            ]
        ),
        .executableTarget(
            name: "AgentBoardApp",
            dependencies: ["AgentBoardCore"],
            linkerSettings: [.linkedFramework("CoreServices")]
        ),
        .executableTarget(
            name: "agentboard",
            dependencies: ["AgentBoardCore"]
        ),
        .testTarget(
            name: "AgentBoardCoreTests",
            dependencies: ["AgentBoardCore"]
        )
    ]
)
