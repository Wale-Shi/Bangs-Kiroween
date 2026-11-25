// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Bangs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionEvents", targets: ["SessionEvents"]),
        .executable(name: "Bangs", targets: ["Bangs"]),
        .executable(name: "bangs-hook", targets: ["bangs-hook"]),
        .executable(name: "bangs-charge", targets: ["bangs-charge"]),
        .executable(name: "session-timeline", targets: ["SessionTimeline"]),
    ],
    targets: [
        // Shared by the app and the hook: the wire protocol, harness definitions and hook installation.
        .target(name: "BangsCore", dependencies: ["SessionEvents"]),
        // Foundation-only event parser shared by BangsCore and SessionTimeline; reusable on its own.
        .target(name: "SessionEvents"),
        // Prints a recorded JSONL session as a timeline. Does not link BangsCore or the GUI.
        .executableTarget(name: "SessionTimeline", dependencies: ["SessionEvents"], path: "apps/SessionTimeline"),
        .executableTarget(name: "Bangs", dependencies: ["BangsCore"], path: "apps/Bangs", exclude: ["Logos"]),
        .executableTarget(name: "bangs-hook", dependencies: ["BangsCore"]),
        // Runs as root to hold a MacBook's battery at the charge limit.
        .executableTarget(name: "bangs-charge", dependencies: ["BangsCore"]),
        .testTarget(name: "BangsCoreTests", dependencies: ["BangsCore", "bangs-hook"]),
        .testTarget(name: "SessionEventsTests", dependencies: ["SessionEvents", "BangsCore"]),
        .testTarget(name: "SessionTimelineTests", dependencies: ["SessionTimeline"]),
        .testTarget(name: "BangsTests", dependencies: ["Bangs"]),
    ]
)
