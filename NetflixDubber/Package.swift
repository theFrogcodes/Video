// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NetflixDubber",
    platforms: [
        // Core Audio process taps need macOS 14.2+, and FluidAudio's Core ML
        // speaker models hit a known BNNS crash on macOS 14, so require 15.
        .macOS(.v15),
    ],
    products: [
        .executable(name: "NetflixDubber", targets: ["NetflixDubber"]),
        .library(name: "DubberCore", targets: ["DubberCore"]),
    ],
    dependencies: [
        // On-device neural speaker embeddings (WeSpeaker via Core ML / Neural Engine).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        // Platform-independent dubbing logic: DSP, speaker tracking, voice
        // design, pipeline orchestration and the cloud API clients.
        .target(name: "DubberCore"),

        // The macOS app: system audio capture, playback, Apple speech APIs, UI.
        .executableTarget(
            name: "NetflixDubber",
            dependencies: [
                "DubberCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        .testTarget(name: "DubberCoreTests", dependencies: ["DubberCore"]),
    ]
)
