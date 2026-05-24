// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let prebuiltFrameworkPath = packageRoot + "/Frameworks/lib_llama_cpp_ios.xcframework"
let sourcesPath = packageRoot + "/llama_cpp_sources"

let usePrebuilt = FileManager.default.fileExists(atPath: prebuiltFrameworkPath)
let hasSources = FileManager.default.fileExists(atPath: sourcesPath)

let commonSettings: [PackageDescription.CSetting] = [
    .headerSearchPath("llama_cpp_sources/llama.cpp/include"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/src"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/src/models"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/common"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/tools/mtmd"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/tools/server"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/vendor"),
    .headerSearchPath("llama_cpp_sources/lib_llama_cpp_ffi/include"),
    .headerSearchPath("llama_cpp_sources/lib_llama_cpp_ffi/src/shim"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/include"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src/ggml-cpu"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src/ggml-metal"),
    .define("DART_SHARED_LIB", to: "1"),
    .define("LLAMA_BUILD", to: "1"),
    .define("LLAMA_SHARED", to: "1"),
    .define("GGML_USE_CPU", to: "1"),
    .define("GGML_USE_METAL", to: "1"),
    .define("GGML_METAL_EMBED_LIBRARY", to: "1"),
    .define("GGML_CPU_GENERIC", to: "1"),
    .define("GGML_SCHED_MAX_COPIES", to: "4"),
    .define("GGML_VERSION", to: "\"2bacb1e\""),
    .define("GGML_COMMIT", to: "\"2bacb1e\""),
    .define("_XOPEN_SOURCE", to: "600"),
    .define("_DARWIN_C_SOURCE", to: "1")
]

let commonCxxSettings: [PackageDescription.CXXSetting] = [
    .headerSearchPath("llama_cpp_sources/llama.cpp/include"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/src"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/src/models"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/common"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/tools/mtmd"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/tools/server"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/vendor"),
    .headerSearchPath("llama_cpp_sources/lib_llama_cpp_ffi/include"),
    .headerSearchPath("llama_cpp_sources/lib_llama_cpp_ffi/src/shim"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/include"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src/ggml-cpu"),
    .headerSearchPath("llama_cpp_sources/llama.cpp/ggml/src/ggml-metal"),
    .define("DART_SHARED_LIB", to: "1"),
    .define("LLAMA_BUILD", to: "1"),
    .define("LLAMA_SHARED", to: "1"),
    .define("GGML_USE_CPU", to: "1"),
    .define("GGML_USE_METAL", to: "1"),
    .define("GGML_METAL_EMBED_LIBRARY", to: "1"),
    .define("GGML_CPU_GENERIC", to: "1"),
    .define("GGML_SCHED_MAX_COPIES", to: "4"),
    .define("GGML_VERSION", to: "\"2bacb1e\""),
    .define("GGML_COMMIT", to: "\"2bacb1e\""),
    .define("_XOPEN_SOURCE", to: "600"),
    .define("_DARWIN_C_SOURCE", to: "1")
]

let target: Target
if usePrebuilt {
    target = .binaryTarget(
        name: "lib_llama_cpp_ios",
        path: "Frameworks/lib_llama_cpp_ios.xcframework"
    )
} else if hasSources {
    target = .target(
        name: "lib_llama_cpp_ios",
        dependencies: [],
        path: ".",
        exclude: [
            "llama_cpp_sources/llama.cpp/common/arg.cpp",
            "llama_cpp_sources/llama.cpp/common/download.cpp",
            "llama_cpp_sources/llama.cpp/common/hf-cache.cpp",
            "llama_cpp_sources/llama.cpp/common/preset.cpp",
            "llama_cpp_sources/llama.cpp/tools/mtmd/deprecation-warning.cpp",
            "llama_cpp_sources/llama.cpp/tools/mtmd/mtmd-cli.cpp",
            "llama_cpp_sources/llama.cpp/tools/server/server.cpp",
            "llama_cpp_sources/llama.cpp/tools/server/server-http.cpp",
            "llama_cpp_sources/llama.cpp/tools/server/server-models.cpp",
            "llama_cpp_sources/llama.cpp/tools/server/server-tools.cpp",
            "llama_cpp_sources/llama.cpp/tools/server/server-cors-proxy.h",
            "lib_llama_cpp_ios.podspec",
            "Frameworks",
            "CMakeLists.txt",
            "test"
        ],
        sources: [
            "Classes",
            "llama_cpp_sources/lib_llama_cpp_ffi/src",
            "llama_cpp_sources/lib_llama_cpp_ffi/src/shim",
            "llama_cpp_sources/llama.cpp/src",
            "llama_cpp_sources/llama.cpp/src/models",
            "llama_cpp_sources/llama.cpp/common",
            "llama_cpp_sources/llama.cpp/common/jinja",
            "llama_cpp_sources/llama.cpp/tools/mtmd",
            "llama_cpp_sources/llama.cpp/tools/mtmd/models",
            "llama_cpp_sources/llama.cpp/tools/server",
            "llama_cpp_sources/llama.cpp/ggml/src",
            "llama_cpp_sources/llama.cpp/ggml/src/ggml-cpu",
            "llama_cpp_sources/llama.cpp/ggml/src/ggml-metal",
            "llama_cpp_sources/llama.cpp/ggml/src/ggml-metal/autogenerated"
        ],
        publicHeadersPath: "Classes",
        cSettings: commonSettings,
        cxxSettings: commonCxxSettings
    )
} else {
    target = .target(
        name: "lib_llama_cpp_ios",
        dependencies: [],
        path: ".",
        sources: ["Classes"],
        publicHeadersPath: "Classes"
    )
}

let package = Package(
    name: "lib_llama_cpp_ios",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(
            name: "lib_llama_cpp_ios",
            targets: ["lib_llama_cpp_ios"]
        )
    ],
    dependencies: [],
    targets: [
        target
    ],
    cLanguageStandard: .c99,
    cxxLanguageStandard: .cxx17
)
