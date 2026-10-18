// swift-tools-version:5.9
// DO NOT EDIT without reading CONTRACT.md. Every module is pre-declared so no
// session needs to touch this file. If you truly need a change, append a line
// to plans/REQUESTS.md and the build session (plan 10) will apply it.
import PackageDescription

let package = Package(
    name: "Flamingo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flamingo", targets: ["Flamingo"]),
        .executable(name: "flamingo-index", targets: ["FlamingoIndexCLI"]),
    ],
    targets: [
        // The app. Owns the window, navigation, and wiring of every other module.
        .executableTarget(
            name: "Flamingo",
            dependencies: ["FlamingoCore", "FlamingoDesign", "FlamingoCapture", "FlamingoExtract",
                           "FlamingoIndex", "FlamingoGraph", "FlamingoTrail", "FlamingoAsk", "FlamingoThoughts", "FlamingoAgents", "FlamingoConnectors"],
            path: "Sources/Flamingo"
        ),
        // Pure model layer: vault, file identity, sidecar notes, wikilinks, graph model.
        .target(name: "FlamingoCore", path: "Sources/FlamingoCore", resources: [.copy("Templates")]),
        // Design tokens and reusable components. Depends on nothing.
        .target(name: "FlamingoDesign", path: "Sources/FlamingoDesign"),
        // Comment capture: hotkey, floating panel, frontmost-app context.
        .target(name: "FlamingoCapture", dependencies: ["FlamingoCore", "FlamingoDesign", "FlamingoTrail"], path: "Sources/FlamingoCapture"),
        // Text and structure extraction for every file type.
        .target(name: "FlamingoExtract", dependencies: ["FlamingoCore"], path: "Sources/FlamingoExtract"),
        // SQLite FTS5 index, file watching, search, graph building.
        .target(name: "FlamingoIndex", dependencies: ["FlamingoCore", "FlamingoExtract"], path: "Sources/FlamingoIndex"),
        .executableTarget(name: "FlamingoIndexCLI", dependencies: ["FlamingoIndex", "FlamingoCore", "FlamingoAgents"], path: "Sources/FlamingoIndexCLI"),
        // Graph view.
        .target(name: "FlamingoGraph", dependencies: ["FlamingoCore", "FlamingoDesign"], path: "Sources/FlamingoGraph"),
        // Trails: session recording and thought chains.
        .target(name: "FlamingoTrail", dependencies: ["FlamingoCore", "FlamingoDesign"], path: "Sources/FlamingoTrail"),
        // Ask: natural-language questions over the vault.
        .target(name: "FlamingoAsk", dependencies: ["FlamingoCore", "FlamingoIndex", "FlamingoDesign"], path: "Sources/FlamingoAsk"),
        // Thoughts that act: night shift, attention ranking, the daily briefing engine. No views.
        // Local models only: thoughts never leave this Mac.
        .target(name: "FlamingoThoughts", dependencies: ["FlamingoCore", "FlamingoIndex", "FlamingoAsk", "FlamingoTrail"], path: "Sources/FlamingoThoughts"),
        // Agent projects (plan 18): which harness works where, from processes and session logs.
        .target(name: "FlamingoAgents", dependencies: ["FlamingoCore"], path: "Sources/FlamingoAgents"),
        // Connectors (plan 19): calendar feeds and Apple Calendar brought in as items, by purpose card.
        // Items stay on this Mac; Claude only drafts the card from a description and the feed's shape.
        .target(name: "FlamingoConnectors", dependencies: ["FlamingoCore"], path: "Sources/FlamingoConnectors"),

        .testTarget(name: "FlamingoCoreTests", dependencies: ["FlamingoCore"], path: "Tests/FlamingoCoreTests"),
        .testTarget(name: "FlamingoExtractTests", dependencies: ["FlamingoExtract"], path: "Tests/FlamingoExtractTests"),
        .testTarget(name: "FlamingoIndexTests", dependencies: ["FlamingoIndex"], path: "Tests/FlamingoIndexTests"),
        .testTarget(name: "FlamingoTrailTests", dependencies: ["FlamingoTrail"], path: "Tests/FlamingoTrailTests"),
        .testTarget(name: "FlamingoAskTests", dependencies: ["FlamingoAsk"], path: "Tests/FlamingoAskTests"),
        .testTarget(name: "FlamingoThoughtsTests", dependencies: ["FlamingoThoughts", "FlamingoCore", "FlamingoIndex", "FlamingoAsk", "FlamingoTrail"], path: "Tests/FlamingoThoughtsTests"),
        .testTarget(name: "FlamingoCaptureTests", dependencies: ["FlamingoCapture", "FlamingoCore"], path: "Tests/FlamingoCaptureTests"),
        .testTarget(name: "FlamingoGraphTests", dependencies: ["FlamingoGraph", "FlamingoCore"], path: "Tests/FlamingoGraphTests"),
        .testTarget(name: "FlamingoAgentsTests", dependencies: ["FlamingoAgents", "FlamingoCore"], path: "Tests/FlamingoAgentsTests"),
        .testTarget(name: "FlamingoConnectorsTests", dependencies: ["FlamingoConnectors"], path: "Tests/FlamingoConnectorsTests"),
        .testTarget(name: "FlamingoAppTests", dependencies: ["Flamingo"], path: "Tests/FlamingoAppTests"),
    ]
)
