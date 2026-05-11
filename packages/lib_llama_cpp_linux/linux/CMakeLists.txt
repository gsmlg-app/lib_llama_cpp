cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "lib_llama_cpp_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(_lib_llama_cpp_prebuilt_arch "")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  set(_lib_llama_cpp_prebuilt_arch "x64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
  set(_lib_llama_cpp_prebuilt_arch "arm64")
endif()

set(_lib_llama_cpp_prebuilt_library "")
if(NOT _lib_llama_cpp_prebuilt_arch STREQUAL "")
  set(
    _lib_llama_cpp_prebuilt_candidate
    "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${_lib_llama_cpp_prebuilt_arch}/liblib_llama_cpp_linux.so")
  if(EXISTS "${_lib_llama_cpp_prebuilt_candidate}")
    get_filename_component(
      _lib_llama_cpp_prebuilt_library
      "${_lib_llama_cpp_prebuilt_candidate}"
      REALPATH)
  endif()
endif()

if(_lib_llama_cpp_prebuilt_library STREQUAL "")
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
  set(_lib_llama_cpp_bundled_library "$<TARGET_FILE:lib_llama_cpp_linux>")
else()
  message(STATUS "Using prebuilt lib_llama_cpp Linux library: ${_lib_llama_cpp_prebuilt_library}")
  set(_lib_llama_cpp_bundled_library "${_lib_llama_cpp_prebuilt_library}")
endif()

set(lib_llama_cpp_linux_bundled_libraries
  ${_lib_llama_cpp_bundled_library}
  PARENT_SCOPE
)
