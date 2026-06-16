// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lib_llama_cpp_macos",
    platforms: [
        .macOS("10.15")
    ],
    products: [
        .library(name: "lib-llama-cpp-macos", targets: ["lib_llama_cpp_macos"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "lib_llama_cpp_macos",
            path: "Frameworks/lib_llama_cpp_macos.xcframework"
        )
    ]
)
