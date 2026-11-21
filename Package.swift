// swift-tools-version: 6.0
import PackageDescription

// Hard rule (docs/SPEC.md §5.2): nothing that runs as root links third-party code.
// `switchboardd` and everything it depends on must stay dependency-free.

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SwitchboardApp", targets: ["SwitchboardApp"]),
        .executable(name: "switchboardd", targets: ["switchboardd"]),
        .executable(name: "sbctl", targets: ["sbctl"]),
    ],
    targets: [
        // Models, flow engine, filter language, wire codec.
        .target(name: "SwitchboardCore"),

        // Our own declarations of kernel structures and functions that Apple
        // ships but does not put in the public SDK headers.
        .target(
            name: "CDarwinPrivate",
            linkerSettings: [.linkedLibrary("pcap")]
        ),

        // Source adapters: kernel socket list, libproc, NetworkStatistics, PKTAP.
        .target(
            name: "SwitchboardSources",
            dependencies: ["SwitchboardCore", "CDarwinPrivate"]
        ),

        // Root collector.
        .executableTarget(
            name: "switchboardd",
            dependencies: ["SwitchboardCore", "SwitchboardSources"]
        ),

        // Terminal viewer and diagnostics.
        .executableTarget(
            name: "sbctl",
            dependencies: ["SwitchboardCore", "SwitchboardSources", "SwitchboardStore"]
        ),

        // SQLite log, on the SQLite that ships with macOS. No third-party code.
        .target(
            name: "SwitchboardStore",
            dependencies: ["SwitchboardCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // Metal engine, layouts, picking.
        .target(
            name: "SwitchboardRender",
            dependencies: ["SwitchboardCore"],
            resources: [.copy("Shaders")]
        ),

        // SwiftUI shell. Wrapped into Switchboard.app by scripts/bundle.sh.
        .executableTarget(
            name: "SwitchboardApp",
            dependencies: [
                "SwitchboardCore",
                "SwitchboardSources",
                "SwitchboardStore",
                "SwitchboardRender",
            ]
        ),

        .testTarget(
            name: "SwitchboardCoreTests",
            dependencies: ["SwitchboardCore"]
        ),
        .testTarget(
            name: "SwitchboardSourcesTests",
            dependencies: ["SwitchboardSources", "SwitchboardCore", "CDarwinPrivate"]
        ),
        .testTarget(
            name: "SwitchboardStoreTests",
            dependencies: ["SwitchboardStore", "SwitchboardCore"]
        ),
        .testTarget(
            name: "SwitchboardRenderTests",
            dependencies: ["SwitchboardRender", "SwitchboardCore"]
        ),
        .testTarget(
            name: "SwitchboardAppTests",
            dependencies: ["SwitchboardApp", "SwitchboardCore"]
        ),
    ]
)
