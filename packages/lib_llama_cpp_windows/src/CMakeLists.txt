cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "lib_llama_cpp_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(LIB_LLAMA_CPP_CMAKE_HELPER "")
set(_lib_llama_cpp_search_dir "${CMAKE_CURRENT_SOURCE_DIR}")
set(_lib_llama_cpp_in_plugin_symlink OFF)
if(CMAKE_CURRENT_SOURCE_DIR MATCHES "\\.plugin_symlinks")
  set(_lib_llama_cpp_in_plugin_symlink ON)
endif()

foreach(_index RANGE 0 8)
  if(NOT _lib_llama_cpp_in_plugin_symlink AND EXISTS "${_lib_llama_cpp_search_dir}/../../cmake/lib_llama_cpp_cpu_backend.cmake")
    get_filename_component(
      LIB_LLAMA_CPP_CMAKE_HELPER
      "${_lib_llama_cpp_search_dir}/../../cmake/lib_llama_cpp_cpu_backend.cmake"
      REALPATH)
    break()
  endif()

  if(EXISTS "${_lib_llama_cpp_search_dir}/packages/cmake/lib_llama_cpp_cpu_backend.cmake")
    get_filename_component(
      LIB_LLAMA_CPP_CMAKE_HELPER
      "${_lib_llama_cpp_search_dir}/packages/cmake/lib_llama_cpp_cpu_backend.cmake"
      REALPATH)
    break()
  endif()

  get_filename_component(_lib_llama_cpp_search_dir "${_lib_llama_cpp_search_dir}/.." ABSOLUTE)
endforeach()

if(LIB_LLAMA_CPP_CMAKE_HELPER STREQUAL "")
  message(FATAL_ERROR "Could not locate packages/cmake/lib_llama_cpp_cpu_backend.cmake")
endif()

include("${LIB_LLAMA_CPP_CMAKE_HELPER}")
lib_llama_cpp_prepare_backend_languages()
lib_llama_cpp_add_cpu_backend(${PROJECT_NAME} "lib_llama_cpp_stub.cc")
