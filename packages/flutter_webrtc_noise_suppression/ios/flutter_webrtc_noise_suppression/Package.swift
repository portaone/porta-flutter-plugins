// swift-tools-version: 5.9
import PackageDescription

// Three targets, one plugin: the C core (noise_suppressor.h + RNNoise v0.1.1), the suppressor's iOS
// interface on it (NSPNoiseSuppressor), and the flutter_webrtc add-on that hands captured frames to
// that interface; a fourth, RNNoise v0.2, when the app asks for it. flutter_webrtc is a sibling
// package: Flutter lays the app's plugins out side by side and rewrites this path to the one
// flutter_webrtc gets there.

// RNNoise v0.2 adds about 5 MB, so it is built only when the app asks for it:
// FLUTTER_WEBRTC_NS_RNNOISE02=1 in the environment of the build (`flutter build ios`, Xcode).
let withRnnoise02 = Context.environment["FLUTTER_WEBRTC_NS_RNNOISE02"] == "1"

// RNNoise v0.2 with its standard model. Its own include path, because its rnnoise.h has the name of
// v0.1.1's; only units/ are compiled, which rename its globals (rnnoise02_prefix.h), and only
// ns_rnnoise02.h is public. compat/ stands in for a header v0.2 does not ship.
let rnnoise02 = Target.target(
    name: "NoiseSuppressionRnnoise02",
    path: "Sources/NoiseSuppressionRnnoise02",
    exclude: ["rnnoise/src", "rnnoise/COPYING", "rnnoise/AUTHORS"],
    publicHeadersPath: "include",
    cSettings: [
        .headerSearchPath("rnnoise/include"),
        .headerSearchPath("rnnoise/src"),
        .headerSearchPath("compat"),
    ]
)

let package = Package(
    name: "flutter_webrtc_noise_suppression",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-webrtc-noise-suppression", targets: ["flutter_webrtc_noise_suppression"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(name: "flutter_webrtc", path: "../flutter_webrtc"),
    ],
    targets: [
        // The C core. The Android build compiles the same files (android/src/main/cpp).
        .target(
            name: "NoiseSuppressionCore",
            dependencies: withRnnoise02 ? ["NoiseSuppressionRnnoise02"] : [],
            path: "Sources/NoiseSuppressionCore",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("rnnoise/include"),
                // RNNoise keeps its FFT state in a global called `common`.
                .define("common", to: "ns_rnnoise_common"),
            ] + (withRnnoise02 ? [.define("NS_WITH_RNNOISE02")] : [])
        ),
        // The suppressor's interface, NSPNoiseSuppressor, and its RNNoise implementation. Knows
        // nothing about WebRTC.
        .target(
            name: "NoiseSuppression",
            dependencies: ["NoiseSuppressionCore"],
            path: "Sources/NoiseSuppression",
            publicHeadersPath: "include/NoiseSuppression"
        ),
        // The add-on: flutter_webrtc's capture slot to NSPNoiseSuppressor.
        .target(
            name: "flutter_webrtc_noise_suppression",
            dependencies: [
                "NoiseSuppression",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "flutter-webrtc", package: "flutter_webrtc"),
                .product(name: "WebRTC", package: "flutter_webrtc"),
            ],
            path: "Sources/flutter_webrtc_noise_suppression",
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
    ] + (withRnnoise02 ? [rnnoise02] : [])
)
