repo_root = File.expand_path('../../..', File.realpath(__dir__))

Pod::Spec.new do |s|
  s.name             = 'lib_llama_cpp_ios'
  s.version          = '0.1.0'
  s.summary          = 'iOS native build for lib_llama_cpp.'
  s.description      = 'Builds and bundles the iOS llama.cpp FFI library.'
  s.homepage         = 'https://github.com/gsmlg-app/lib_llama_cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'GSMLG' => 'dev@gsmlg.com' }
  s.source           = { :path => '.' }
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
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.libraries = 'c++'
  s.preserve_paths = 'llama_cpp_sources/llama.cpp/**/*.{h,hpp}'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
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
  s.swift_version = '5.0'
end
