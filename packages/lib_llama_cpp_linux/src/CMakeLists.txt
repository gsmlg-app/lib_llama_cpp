cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "lib_llama_cpp_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

add_library(${PROJECT_NAME} SHARED "lib_llama_cpp_stub.cc")
target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_17)
target_compile_definitions(${PROJECT_NAME} PUBLIC DART_SHARED_LIB)

# TODO(upstream-build): Replace this stub with llama.cpp submodule compilation
# configured for Linux CPU/Vulkan/OpenBLAS variants.
