Pod::Spec.new do |s|
  s.name             = 'lib_llama_cpp_ios'
  s.version          = '0.1.0'
  s.summary          = 'iOS native build for lib_llama_cpp.'
  s.description      = 'Builds and bundles the iOS llama.cpp FFI library.'
  s.homepage         = 'https://github.com/gsmlg-app/lib_llama_cpp'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'GSMLG' => 'dev@gsmlg.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -std=c++17'
  }
  s.swift_version = '5.0'
end
