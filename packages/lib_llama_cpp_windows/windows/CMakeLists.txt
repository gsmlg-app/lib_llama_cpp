cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "lib_llama_cpp_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(lib_llama_cpp_windows_bundled_libraries
  $<TARGET_FILE:lib_llama_cpp_windows>
  PARENT_SCOPE
)
