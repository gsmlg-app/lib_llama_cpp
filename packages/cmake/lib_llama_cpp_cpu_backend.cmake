include_guard(GLOBAL)

set(LIB_LLAMA_CPP_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(lib_llama_cpp_configure_cpu_backend_options)
  set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build llama.cpp static libraries for the Flutter FFI wrapper." FORCE)
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)

  set(LLAMA_BUILD_COMMON ON CACHE BOOL "Build llama.cpp common chat/template utilities." FORCE)
  set(LLAMA_BUILD_TESTS OFF CACHE BOOL "Disable llama.cpp tests." FORCE)
  set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "Disable llama.cpp tools." FORCE)
  set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "Disable llama.cpp examples." FORCE)
  set(LLAMA_BUILD_SERVER OFF CACHE BOOL "Disable llama.cpp server." FORCE)
  set(LLAMA_BUILD_WEBUI OFF CACHE BOOL "Disable llama.cpp server web UI." FORCE)
  set(LLAMA_OPENSSL OFF CACHE BOOL "Disable llama.cpp OpenSSL support." FORCE)
  set(LLAMA_LLGUIDANCE OFF CACHE BOOL "Disable llguidance dependency." FORCE)

  set(GGML_NATIVE OFF CACHE BOOL "Disable host-specific CPU tuning." FORCE)
  set(GGML_CPU ON CACHE BOOL "Enable ggml CPU backend." FORCE)
  set(GGML_CPU_ALL_VARIANTS OFF CACHE BOOL "Disable runtime CPU backend variants." FORCE)
  set(GGML_BACKEND_DL OFF CACHE BOOL "Disable dynamic ggml backends." FORCE)
  set(GGML_OPENMP OFF CACHE BOOL "Disable OpenMP runtime dependency." FORCE)
  set(GGML_ACCELERATE OFF CACHE BOOL "Disable Apple Accelerate backend." FORCE)
  set(GGML_BLAS OFF CACHE BOOL "Disable BLAS backend." FORCE)
  set(GGML_LLAMAFILE OFF CACHE BOOL "Disable llamafile kernels." FORCE)
  set(GGML_CUDA OFF CACHE BOOL "Disable CUDA backend." FORCE)
  set(GGML_HIP OFF CACHE BOOL "Disable HIP backend." FORCE)
  set(GGML_MUSA OFF CACHE BOOL "Disable MUSA backend." FORCE)
  set(GGML_VULKAN OFF CACHE BOOL "Disable Vulkan backend." FORCE)
  set(GGML_METAL OFF CACHE BOOL "Disable Metal backend." FORCE)
  set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "Disable embedded Metal library." FORCE)
  set(GGML_OPENCL OFF CACHE BOOL "Disable OpenCL backend." FORCE)
  set(GGML_RPC OFF CACHE BOOL "Disable RPC backend." FORCE)
  set(GGML_SYCL OFF CACHE BOOL "Disable SYCL backend." FORCE)
  set(GGML_OPENVINO OFF CACHE BOOL "Disable OpenVINO backend." FORCE)
  set(GGML_WEBGPU OFF CACHE BOOL "Disable WebGPU backend." FORCE)
  set(GGML_VIRTGPU OFF CACHE BOOL "Disable VirtGPU backend." FORCE)
  set(GGML_ZDNN OFF CACHE BOOL "Disable zDNN backend." FORCE)
  set(GGML_ZENDNN OFF CACHE BOOL "Disable ZenDNN backend." FORCE)
  set(GGML_CANN OFF CACHE BOOL "Disable CANN backend." FORCE)
  set(GGML_HEXAGON OFF CACHE BOOL "Disable Hexagon backend." FORCE)
endfunction()

function(lib_llama_cpp_add_cpu_backend target_name wrapper_source)
  get_filename_component(_repo_root "${LIB_LLAMA_CPP_CMAKE_DIR}/../.." ABSOLUTE)
  get_filename_component(_llama_cpp_dir "${_repo_root}/third_party/llama.cpp" ABSOLUTE)

  if(NOT EXISTS "${_llama_cpp_dir}/CMakeLists.txt")
    message(FATAL_ERROR
      "third_party/llama.cpp is missing CMakeLists.txt. "
      "The native CPU backend requires a complete llama.cpp source checkout at ${_llama_cpp_dir}.")
  endif()

  lib_llama_cpp_configure_cpu_backend_options()
  set(_lib_llama_cpp_skip_install_rules "${CMAKE_SKIP_INSTALL_RULES}")
  set(CMAKE_SKIP_INSTALL_RULES ON)
  add_subdirectory("${_llama_cpp_dir}" "${CMAKE_CURRENT_BINARY_DIR}/llama_cpp" EXCLUDE_FROM_ALL)
  if(EXISTS "${_llama_cpp_dir}/tools/mtmd/CMakeLists.txt" AND NOT TARGET mtmd)
    if(NOT DEFINED LLAMA_INSTALL_VERSION OR "${LLAMA_INSTALL_VERSION}" STREQUAL "")
      set(LLAMA_INSTALL_VERSION "0.0.0")
    endif()
    add_subdirectory(
      "${_llama_cpp_dir}/tools/mtmd"
      "${CMAKE_CURRENT_BINARY_DIR}/llama_cpp/tools/mtmd"
      EXCLUDE_FROM_ALL)
  endif()
  set(CMAKE_SKIP_INSTALL_RULES "${_lib_llama_cpp_skip_install_rules}")

  set(_lib_llama_cpp_static_targets llama llama-common llama-common-base mtmd ggml ggml-base ggml-cpu)
  if(DEFINED GGML_AVAILABLE_BACKENDS)
    list(APPEND _lib_llama_cpp_static_targets ${GGML_AVAILABLE_BACKENDS})
  endif()

  foreach(_target IN LISTS _lib_llama_cpp_static_targets)
    if(TARGET ${_target})
      set_target_properties(${_target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
    endif()
  endforeach()

  target_compile_definitions(llama PRIVATE LLAMA_BUILD LLAMA_SHARED)

  set(_lib_llama_cpp_ffi_dir "${_repo_root}/packages/lib_llama_cpp_ffi")
  set(_lib_llama_cpp_wrapper_source "${_lib_llama_cpp_ffi_dir}/src/lib_llama_cpp_wrapper.cc")

  add_library(${target_name} SHARED "${wrapper_source}" "${_lib_llama_cpp_wrapper_source}")
  target_compile_features(${target_name} PUBLIC cxx_std_17)
  target_compile_definitions(${target_name} PUBLIC DART_SHARED_LIB)
  target_include_directories(${target_name}
    PRIVATE
      "${_lib_llama_cpp_ffi_dir}/include"
      "${_llama_cpp_dir}/include"
      "${_llama_cpp_dir}/ggml/include"
      "${_llama_cpp_dir}/common"
      "${_llama_cpp_dir}/tools/mtmd"
      "${_llama_cpp_dir}/vendor")

  if(MSVC)
    target_link_libraries(${target_name} PRIVATE llama-common mtmd llama)
    target_link_options(${target_name} PRIVATE "/WHOLEARCHIVE:$<TARGET_FILE:llama>")
    target_link_options(${target_name} PRIVATE "/WHOLEARCHIVE:$<TARGET_FILE:mtmd>")
    set_target_properties(${target_name} PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
  elseif(APPLE)
    target_link_libraries(${target_name} PRIVATE llama-common mtmd llama)
    target_link_options(${target_name} PRIVATE "-Wl,-force_load,$<TARGET_FILE:llama>")
    target_link_options(${target_name} PRIVATE "-Wl,-force_load,$<TARGET_FILE:mtmd>")
  else()
    target_link_libraries(
      ${target_name}
      PRIVATE
        llama-common
        "-Wl,--whole-archive" llama mtmd "-Wl,--no-whole-archive")
  endif()
endfunction()
