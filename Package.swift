// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudyApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StudyApp", targets: ["StudyApp"]),
        .library(name: "StudyDomain", targets: ["StudyDomain"]),
        .library(name: "StudyDocuments", targets: ["StudyDocuments"]),
        .library(name: "StudyEngine", targets: ["StudyEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // Pinned to the revision whose Parakeet Unified/TDT APIs this app was built against.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e396cf780c4abf8e395087467c0585d3b0d17f68"),
    ],
    targets: [
        // MARK: Core
        .target(
            name: "StudyDomain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudyPersistence",
            dependencies: [
                "StudyDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudyDocuments",
            dependencies: [
                "StudyDomain",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "StudyRetrieval",
            dependencies: ["StudyDomain"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudyPrompts",
            dependencies: ["StudyDomain", "StudyPersistence"],
            resources: [.copy("Resources/AGENT.md")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudyProviders",
            dependencies: ["StudyDomain"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "StudyEngine",
            dependencies: ["StudyDomain", "StudyRetrieval", "StudyPrompts", "StudyProviders", "StudyPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudySpeech",
            dependencies: [
                "StudyDomain",
                "StudyProviders",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .target(
            name: "StudyDesignSystem",
            dependencies: ["StudyDomain"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: App
        .executableTarget(
            name: "StudyApp",
            dependencies: [
                "StudyDomain",
                "StudyPersistence",
                "StudyDocuments",
                "StudyRetrieval",
                "StudyPrompts",
                "StudyProviders",
                "StudyEngine",
                "StudySpeech",
                "StudyDesignSystem",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit")]
        ),

        // MARK: Tests
        .testTarget(
            name: "DocumentParsingTests",
            dependencies: [
                "StudyDocuments",
                "StudyDomain",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            linkerSettings: [.linkedFramework("PDFKit"), .linkedFramework("AppKit")]
        ),
        .testTarget(name: "GroundingTests", dependencies: ["StudyEngine", "StudyDomain", "StudyRetrieval", "StudyPrompts", "StudyPersistence"]),
        .testTarget(name: "ProviderTests", dependencies: ["StudyProviders", "StudyDomain"]),
        .testTarget(name: "EvaluationTests", dependencies: ["StudyEngine", "StudyDomain", "StudyRetrieval", "StudyPrompts", "StudyPersistence"]),
        .testTarget(name: "PersistenceTests", dependencies: ["StudyPersistence", "StudyDomain", "StudyPrompts"]),
        .testTarget(name: "UIBasicsTests", dependencies: ["StudyDomain", "StudyDesignSystem", "StudyEngine", "StudyPrompts", "StudyPersistence", "StudySpeech"]),
    ]
)
