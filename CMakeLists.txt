cmake_minimum_required(VERSION 3.24)

project(SpatialAudioLab LANGUAGES CXX)

include(CTest)

add_executable(SpatialAudioLab.CLI
  src/asio_renderer.cpp
  src/audio_platform.cpp
  src/bridge_meter.cpp
  src/capture_commands.cpp
  src/dolby_probe.cpp
  src/dtsx_analysis.cpp
  src/layout_mix.cpp
  src/media_foundation_probe.cpp
  src/mat_analysis.cpp
  src/mat_capture_client.cpp
  src/mat_format.cpp
  src/mat_pipeline.cpp
  src/multi_endpoint_renderer.cpp
  src/pcm_queue.cpp
  src/pcm_pipeline.cpp
  src/speaker_layout.cpp
  src/spatial_audio_sample.cpp
  src/wave_io.cpp
)
target_compile_features(SpatialAudioLab.CLI PRIVATE cxx_std_20)
target_compile_definitions(SpatialAudioLab.CLI PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(SpatialAudioLab.CLI PRIVATE ole32 runtimeobject windowsapp uuid avrt propsys mmdevapi mf mfplat mfreadwrite mfuuid)

if(MSVC)
  target_compile_options(SpatialAudioLab.CLI PRIVATE /W4 /permissive- /EHsc)
endif()

if(BUILD_TESTING)
  add_executable(SpatialAudioLab.NativeTests
    tests/native/layout_mix_tests.cpp
    src/audio_platform.cpp
    src/layout_mix.cpp
    src/speaker_layout.cpp
  )
  target_compile_features(SpatialAudioLab.NativeTests PRIVATE cxx_std_20)
  target_compile_definitions(SpatialAudioLab.NativeTests PRIVATE
    UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
  target_include_directories(SpatialAudioLab.NativeTests PRIVATE src)
  target_link_libraries(SpatialAudioLab.NativeTests PRIVATE
    ole32 runtimeobject windowsapp uuid avrt propsys mmdevapi)
  if(MSVC)
    target_compile_options(SpatialAudioLab.NativeTests PRIVATE /W4 /permissive- /EHsc)
  endif()
  add_test(NAME SpatialAudioLab.NativeTests COMMAND SpatialAudioLab.NativeTests)
endif()

# Keep the original WASAPI-only build usable without the ASIO SDK.
set(SAL_ASIO_SDK_ROOT "$ENV{SAL_ASIO_SDK_ROOT}" CACHE PATH "Steinberg ASIO SDK root")
if(SAL_ASIO_SDK_ROOT)
  if(NOT EXISTS "${SAL_ASIO_SDK_ROOT}/common/iasiodrv.h")
    message(FATAL_ERROR "SAL_ASIO_SDK_ROOT must contain common/iasiodrv.h")
  endif()
  target_compile_definitions(SpatialAudioLab.CLI PRIVATE SAL_ENABLE_ASIO=1)
  target_include_directories(SpatialAudioLab.CLI PRIVATE "${SAL_ASIO_SDK_ROOT}/common")
  target_link_libraries(SpatialAudioLab.CLI PRIVATE advapi32 user32)
  message(STATUS "SpatialAudioLab ASIO output enabled")
else()
  message(STATUS "SpatialAudioLab WASAPI output only; set SAL_ASIO_SDK_ROOT to enable ASIO")
endif()
if(BUILD_TESTING)
  find_package(Threads REQUIRED)
  add_executable(SpatialAudioLab.AsioAudioTests tests/native/asio_audio_tests.cpp)
  target_compile_features(SpatialAudioLab.AsioAudioTests PRIVATE cxx_std_20)
  target_include_directories(SpatialAudioLab.AsioAudioTests PRIVATE src)
  target_link_libraries(SpatialAudioLab.AsioAudioTests PRIVATE Threads::Threads)
  add_test(NAME SpatialAudioLab.AsioAudioTests COMMAND SpatialAudioLab.AsioAudioTests)
endif()
