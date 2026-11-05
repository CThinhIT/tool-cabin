# Native part of win_audio: WASAPI capture/render, process loopback, session volume.
# Built by the Flutter tool through ../windows/CMakeLists.txt, and by ../native_test for
# a console smoke test without Flutter.
cmake_minimum_required(VERSION 3.14)

project(win_audio_library VERSION 0.1.0 LANGUAGES CXX)

if(NOT MSVC)
  message(FATAL_ERROR "win_audio needs MSVC (Visual Studio 2022 C++ tools).")
endif()

add_library(win_audio SHARED
  "win_audio.cpp"
  "common.cpp"
  "com_worker.cpp"
  "devices.cpp"
  "sessions.cpp"
  "capture_stream.cpp"
  "render_stream.cpp"
  "device_notifier.cpp"
)

set_target_properties(win_audio PROPERTIES
  PUBLIC_HEADER win_audio.h
  OUTPUT_NAME "win_audio"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)

target_include_directories(win_audio PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")

# Process loopback (AUDIOCLIENT_ACTIVATION_PARAMS) is declared only for NTDDI >= WIN10_FE.
target_compile_definitions(win_audio PRIVATE
  WA_BUILDING_DLL UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
  _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A00000C)

target_compile_options(win_audio PRIVATE /W4 /permissive- /utf-8 /EHsc)
target_link_libraries(win_audio PRIVATE ole32 mmdevapi avrt)
