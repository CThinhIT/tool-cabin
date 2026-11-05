# Console smoke test of the win_audio C API, without Flutter.
#   cmake -S . -B build -G "Visual Studio 17 2022" -A x64
#   cmake --build build --config Release
#   build\Release\win_audio_smoke.exe [--pid N] [--render-device ID] [--tone]
cmake_minimum_required(VERSION 3.14)
project(win_audio_smoke LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/win_audio")

add_executable(win_audio_smoke main.cpp)
set_target_properties(win_audio_smoke PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
target_compile_options(win_audio_smoke PRIVATE /W4 /permissive- /utf-8 /EHsc)
target_compile_definitions(win_audio_smoke PRIVATE UNICODE _UNICODE NOMINMAX)
target_link_libraries(win_audio_smoke PRIVATE win_audio)

# Put the DLL next to the exe.
add_custom_command(TARGET win_audio_smoke POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:win_audio> $<TARGET_FILE_DIR:win_audio_smoke>)
