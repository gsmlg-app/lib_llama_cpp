Pod::Spec.new do |s|
  s.name             = 'lib_llama_cpp_macos'
  s.version          = '0.1.0'
  s.summary          = 'macOS native build for lib_llama_cpp.'
  s.description      = 'Builds and bundles the macOS llama.cpp FFI library.'
  s.homepage         = 'https://github.com/gsmlg-app/lib_llama_cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'GSMLG' => 'dev@gsmlg.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -std=c++17'
  }
  s.swift_version = '5.0'
end
