// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lib_llama_cpp_ios",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "lib-llama-cpp-ios", targets: ["lib_llama_cpp_ios"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "lib_llama_cpp_ios",
            path: "Frameworks/lib_llama_cpp_ios.xcframework"
        )
    ]
)
