include_guard(GLOBAL)

set(LIB_LLAMA_CPP_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(lib_llama_cpp_configure_cpu_backend_options)
  if(APPLE)
    set(_lib_llama_cpp_enable_metal_default ON)
  else()
    set(_lib_llama_cpp_enable_metal_default OFF)
  endif()

  option(
    LIB_LLAMA_CPP_ENABLE_METAL
    "Enable the llama.cpp Metal backend for Apple builds."
    ${_lib_llama_cpp_enable_metal_default})
  option(
    LIB_LLAMA_CPP_ENABLE_CUDA
    "Enable the llama.cpp CUDA backend. Requires a CUDA Toolkit."
    OFF)
  option(
    LIB_LLAMA_CPP_ENABLE_VULKAN
    "Enable the llama.cpp Vulkan backend. Requires Vulkan SDK tools including glslc."
    OFF)

  if(LIB_LLAMA_CPP_ENABLE_METAL AND NOT APPLE)
    message(FATAL_ERROR "LIB_LLAMA_CPP_ENABLE_METAL is only supported on Apple platforms.")
  endif()

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
  set(GGML_CUDA ${LIB_LLAMA_CPP_ENABLE_CUDA} CACHE BOOL "Enable CUDA backend." FORCE)
  set(GGML_HIP OFF CACHE BOOL "Disable HIP backend." FORCE)
  set(GGML_MUSA OFF CACHE BOOL "Disable MUSA backend." FORCE)
  set(GGML_VULKAN ${LIB_LLAMA_CPP_ENABLE_VULKAN} CACHE BOOL "Enable Vulkan backend." FORCE)
  set(GGML_METAL ${LIB_LLAMA_CPP_ENABLE_METAL} CACHE BOOL "Enable Metal backend." FORCE)
  set(GGML_METAL_EMBED_LIBRARY ${LIB_LLAMA_CPP_ENABLE_METAL} CACHE BOOL "Embed Metal source library." FORCE)
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

  message(STATUS
    "lib_llama_cpp backends: CPU=ON "
    "Metal=${GGML_METAL} CUDA=${GGML_CUDA} Vulkan=${GGML_VULKAN}")
endfunction()

macro(lib_llama_cpp_prepare_backend_languages)
  lib_llama_cpp_configure_cpu_backend_options()
  if(LIB_LLAMA_CPP_ENABLE_METAL)
    enable_language(OBJC ASM)
  endif()
endmacro()

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

  set(_lib_llama_cpp_whole_archive_targets llama mtmd)
  if(DEFINED GGML_AVAILABLE_BACKENDS)
    list(APPEND _lib_llama_cpp_whole_archive_targets ${GGML_AVAILABLE_BACKENDS})
  endif()
  list(REMOVE_DUPLICATES _lib_llama_cpp_whole_archive_targets)

  set(_lib_llama_cpp_existing_whole_archive_targets)
  foreach(_target IN LISTS _lib_llama_cpp_whole_archive_targets)
    if(TARGET ${_target})
      list(APPEND _lib_llama_cpp_existing_whole_archive_targets ${_target})
    endif()
  endforeach()

  target_compile_definitions(llama PRIVATE LLAMA_BUILD LLAMA_SHARED)

  set(_lib_llama_cpp_ffi_dir "${_repo_root}/packages/lib_llama_cpp_ffi")
  set(_lib_llama_cpp_wrapper_source "${_lib_llama_cpp_ffi_dir}/src/lib_llama_cpp_wrapper.cc")
  set(_lib_llama_cpp_engine_source "${_lib_llama_cpp_ffi_dir}/src/shim/llcs_engine.cpp")

  # --- Build server_context sources (without httplib) ---
  set(_server_dir "${_llama_cpp_dir}/tools/server")
  if(EXISTS "${_server_dir}/server-context.cpp")
    set(_server_sources
      "${_server_dir}/server-context.cpp"
      "${_server_dir}/server-common.cpp"
      "${_server_dir}/server-task.cpp"
      "${_server_dir}/server-queue.cpp"
      "${_server_dir}/server-chat.cpp")
    add_library(llcs-server STATIC ${_server_sources})
    target_compile_features(llcs-server PUBLIC cxx_std_17)
    target_include_directories(llcs-server
      PUBLIC
        "${_server_dir}"
        "${_lib_llama_cpp_ffi_dir}/src/shim"
      PRIVATE
        "${_llama_cpp_dir}/include"
        "${_llama_cpp_dir}/ggml/include"
        "${_llama_cpp_dir}/common"
        "${_llama_cpp_dir}/tools/mtmd"
        "${_llama_cpp_dir}/vendor")
    target_link_libraries(llcs-server PRIVATE llama-common llama)
    set_target_properties(llcs-server PROPERTIES POSITION_INDEPENDENT_CODE ON)
  endif()

  add_library(${target_name} SHARED "${wrapper_source}" "${_lib_llama_cpp_wrapper_source}" "${_lib_llama_cpp_engine_source}")
  target_compile_features(${target_name} PUBLIC cxx_std_17)
  target_compile_definitions(${target_name} PUBLIC DART_SHARED_LIB)
  target_include_directories(${target_name}
    PRIVATE
      "${_lib_llama_cpp_ffi_dir}/include"
      "${_lib_llama_cpp_ffi_dir}/src/shim"
      "${_llama_cpp_dir}/include"
      "${_llama_cpp_dir}/ggml/include"
      "${_llama_cpp_dir}/common"
      "${_llama_cpp_dir}/tools/mtmd"
      "${_llama_cpp_dir}/tools/server"
      "${_llama_cpp_dir}/vendor")

  if(MSVC)
    target_link_libraries(
      ${target_name}
      PRIVATE
        llama-common
        $<TARGET_NAME_IF_EXISTS:llcs-server>
        ${_lib_llama_cpp_existing_whole_archive_targets})
    foreach(_target IN LISTS _lib_llama_cpp_existing_whole_archive_targets)
      target_link_options(${target_name} PRIVATE "/WHOLEARCHIVE:$<TARGET_FILE:${_target}>")
    endforeach()
    set_target_properties(${target_name} PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
  elseif(APPLE)
    target_link_libraries(
      ${target_name}
      PRIVATE
        llama-common
        $<TARGET_NAME_IF_EXISTS:llcs-server>
        ${_lib_llama_cpp_existing_whole_archive_targets})
    foreach(_target IN LISTS _lib_llama_cpp_existing_whole_archive_targets)
      target_link_options(${target_name} PRIVATE "-Wl,-force_load,$<TARGET_FILE:${_target}>")
    endforeach()
  else()
    target_link_libraries(
      ${target_name}
      PRIVATE
        llama-common
        $<TARGET_NAME_IF_EXISTS:llcs-server>
        "-Wl,--whole-archive"
        ${_lib_llama_cpp_existing_whole_archive_targets}
        "-Wl,--no-whole-archive")
  endif()
endfunction()
