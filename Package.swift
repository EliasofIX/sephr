// swift-tools-version: 5.9
// Sephr — proprietary. Not for redistribution.
import PackageDescription

let package = Package(
    name: "Sephr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sephr", targets: ["Sephr"]),
        .executable(name: "sephr-smoke", targets: ["SephrSmoke"]),
        .library(name: "CAL", targets: ["CAL"]),
        .library(name: "SephrKit", targets: ["SephrKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.26.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.2"),
    ],
    targets: [
        // SephrKit — pure-Swift library (no Sephrium dependency) so app
        // infrastructure like TabEventBus is importable from tests.
        .target(name: "SephrKit", path: "sephrkit/Sources/SephrKit"),
        .testTarget(name: "SephrKitTests",
                    dependencies: ["SephrKit"],
                    path: "sephrkit/Tests/SephrKitTests"),
        // CAL — ObjC++ bridge to Sephrium.framework.
        .target(
            name: "CAL",
            path: "cal/Sources",
            publicHeadersPath: ".",
            cxxSettings: [
                .headerSearchPath("../../build/Sephrium.framework/Headers",
                                  .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-F", "build", "-framework", "Sephrium"],
                    .when(platforms: [.macOS])),
            ]
        ),
        // Phase 1 smoke harness — depends only on CAL.
        .executableTarget(
            name: "SephrSmoke",
            dependencies: ["CAL"],
            path: "smoke/Sources/SephrSmoke",
            linkerSettings: [
                .unsafeFlags(
                    ["-F", "build", "-framework", "Sephrium",
                     "-Xlinker", "-rpath",
                     "-Xlinker", "@executable_path/../../../build"],
                    .when(platforms: [.macOS])),
            ]
        ),
        // Sephr — native Swift app.
        .executableTarget(
            name: "Sephr",
            dependencies: [
                "CAL",
                "SephrKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "sephr/Sources",
            resources: [
                .copy("../Resources/Assets.xcassets"),
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ],
            linkerSettings: [
                // Link Sephrium.framework from build/. Two rpath entries:
                //   1. @executable_path/../Frameworks — the macOS .app
                //      bundle convention (Sephr.app/Contents/Frameworks).
                //      scripts/make_app.sh wires this up.
                //   2. @executable_path/../../../build — for `swift run`
                //      development against the un-bundled binary.
                // dyld tries them in order; the first matching directory
                // resolves the framework.
                .unsafeFlags(
                    ["-F", "build", "-framework", "Sephrium",
                     "-Xlinker", "-rpath",
                     "-Xlinker", "@executable_path/../Frameworks",
                     "-Xlinker", "-rpath",
                     "-Xlinker", "@executable_path/../../../build"],
                    .when(platforms: [.macOS])),
            ]
        ),
    ]
)
