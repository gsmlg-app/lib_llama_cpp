repo_root = File.expand_path('../../..', File.realpath(__dir__))
prebuilt_framework = File.expand_path('Frameworks/lib_llama_cpp_macos.xcframework', File.realpath(__dir__))

Pod::Spec.new do |s|
  s.name             = 'lib_llama_cpp_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS native build for lib_llama_cpp.'
  s.description      = 'Builds and bundles the macOS llama.cpp FFI library.'
  s.homepage         = 'https://github.com/gsmlg-app/lib_llama_cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'GSMLG' => 'dev@gsmlg.com' }
  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.libraries = 'c++'

  if File.exist?(prebuilt_framework)
    s.vendored_frameworks = 'Frameworks/lib_llama_cpp_macos.xcframework'
    s.preserve_paths = 'Frameworks/lib_llama_cpp_macos.xcframework'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES'
    }
  else
    s.prepare_command  = <<-CMD
      set -e
      rm -rf llama_cpp_sources
      mkdir -p llama_cpp_sources
      rsync -a --exclude .git "#{repo_root}/third_party/llama.cpp/" llama_cpp_sources/llama.cpp/
    CMD
    s.source_files     = [
      'Classes/**/*',
      'llama_cpp_sources/llama.cpp/src/*.cpp',
      'llama_cpp_sources/llama.cpp/src/models/*.cpp',
      'llama_cpp_sources/llama.cpp/ggml/src/*.{c,cpp}',
      'llama_cpp_sources/llama.cpp/ggml/src/ggml-cpu/*.{c,cpp}',
    ]
    s.preserve_paths = 'llama_cpp_sources/llama.cpp/**/*.{h,hpp}'
    s.pod_target_xcconfig = {
      'DEFINES_MODULE' => 'YES',
      'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) DART_SHARED_LIB=1 LLAMA_BUILD=1 LLAMA_SHARED=1 GGML_USE_CPU=1 GGML_CPU_GENERIC=1 GGML_SCHED_MAX_COPIES=4 GGML_VERSION=\"2bacb1e\" GGML_COMMIT=\"2bacb1e\" _XOPEN_SOURCE=600 _DARWIN_C_SOURCE=1',
      'HEADER_SEARCH_PATHS' => [
        '$(inherited)',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/include',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/src',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/src/models',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/ggml/include',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/ggml/src',
        '$(PODS_TARGET_SRCROOT)/llama_cpp_sources/llama.cpp/ggml/src/ggml-cpu',
      ].join(' '),
      'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -std=c++17'
    }
  end

  s.swift_version = '5.0'
end
