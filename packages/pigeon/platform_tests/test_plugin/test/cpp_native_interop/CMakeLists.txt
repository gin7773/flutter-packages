# Copyright 2013 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)
project(pigeon_cpp_native_interop LANGUAGES CXX)
find_package(Threads REQUIRED)
if(NOT FLUTTER_WRAPPER_DIR OR NOT GENERATED_DIR)
  message(FATAL_ERROR "Set FLUTTER_WRAPPER_DIR and GENERATED_DIR; see docs/cpp_native_interop.md")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SOURCES
  "${GENERATED_DIR}/messages.cpp"
  "${GENERATED_DIR}/messages.ffi.cpp"
  "${FLUTTER_WRAPPER_DIR}/standard_codec.cc"
  fixture.cpp
)
add_library(pigeon_cpp_test SHARED ${SOURCES})
add_executable(pigeon_cpp_native_test native_test.cpp ${SOURCES})
foreach(target pigeon_cpp_test pigeon_cpp_native_test)
  target_include_directories(${target} PRIVATE "${GENERATED_DIR}" "${FLUTTER_WRAPPER_DIR}/include")
  target_link_libraries(${target} PRIVATE Threads::Threads)
  if(MSVC)
    target_compile_options(${target} PRIVATE /EHsc /bigobj)
    target_compile_definitions(${target} PRIVATE _HAS_EXCEPTIONS=1)
  endif()
endforeach()
enable_testing()
add_test(NAME cpp_native_interop COMMAND pigeon_cpp_native_test)
set_tests_properties(cpp_native_interop PROPERTIES TIMEOUT 60)
