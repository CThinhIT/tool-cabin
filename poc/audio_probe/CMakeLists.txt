cmake_minimum_required(VERSION 3.20)
project(audio_probe LANGUAGES CXX)

if(NOT MSVC)
  message(FATAL_ERROR
    "audio_probe needs MSVC (Visual Studio 2022 C++ tools).\n"
    "Configure with: cmake -S . -B build -G \"Visual Studio 17 2022\" -A x64")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(audio_probe
  src/main.cpp
  src/common.cpp
  src/devices.cpp
  src/sessions.cpp
  src/wav.cpp
  src/capture.cpp
  src/render.cpp
)

# Process loopback (AUDIOCLIENT_ACTIVATION_PARAMS) is declared only for NTDDI >= WIN10_FE.
target_compile_definitions(audio_probe PRIVATE
  UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
  _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A00000C)

target_compile_options(audio_probe PRIVATE /W4 /permissive- /utf-8 /EHsc)
target_link_libraries(audio_probe PRIVATE ole32 mmdevapi avrt)
