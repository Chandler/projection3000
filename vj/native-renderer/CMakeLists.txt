cmake_minimum_required(VERSION 3.16)
if(POLICY CMP0167)
    cmake_policy(SET CMP0167 NEW)
endif()
project(vibe_native_renderer LANGUAGES CXX)

# CMake's implicit Apple architecture depends on a sysctl probe that can be
# denied in sandboxed builds. Cache the detected target CPU so normal launches
# and sandboxed edits do not alternate compiler flags and rebuild every object.
# Preserve an explicitly configured architecture (including universal builds).
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES
   AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|x86_64)$")
    set(CMAKE_OSX_ARCHITECTURES "${CMAKE_SYSTEM_PROCESSOR}" CACHE STRING
        "Build architectures for OSX" FORCE)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(Boost REQUIRED)
find_package(OpenGL REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET
    libavformat libavcodec libavutil libswscale libswresample libavdevice)
pkg_check_modules(AVFILTER QUIET IMPORTED_TARGET libavfilter)
find_package(JPEG REQUIRED)
find_package(nlohmann_json REQUIRED)
find_package(Threads REQUIRED)
include(CTest)

# Vector recipes execute the exact same WebAssembly modules as the browser.
# Use Bytecode Alliance's official prebuilt C API and link it statically so
# the installed kiosk binary has no host-specific runtime dependency.
include(${CMAKE_CURRENT_LIST_DIR}/cmake/Wasmtime.cmake)
add_library(vibe_wasmtime_static STATIC IMPORTED)
set_target_properties(vibe_wasmtime_static PROPERTIES
    IMPORTED_LOCATION "${vibe_wasmtime_SOURCE_DIR}/lib/libwasmtime.a"
    INTERFACE_INCLUDE_DIRECTORIES "${vibe_wasmtime_SOURCE_DIR}/include"
)

add_executable(vibe-native-render
    src/main.cpp
    src/media_decoder.cpp
    src/live_capture.cpp
    src/native_audio.cpp
    src/native_render_graph.cpp
    src/monitor_frame_publisher.cpp
)
if(APPLE)
    # Command-line renderers also need a camera usage description for TCC.
    target_link_options(vibe-native-render PRIVATE
        "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
    set_property(TARGET vibe-native-render APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
endif()
target_compile_definitions(vibe-native-render PRIVATE BOOST_ERROR_CODE_HEADER_ONLY)
if(AVFILTER_FOUND)
    target_compile_definitions(vibe-native-render PRIVATE VIBE_HAS_AVFILTER=1)
endif()
target_link_libraries(vibe-native-render PRIVATE
    Boost::headers
    OpenGL::GL
    PkgConfig::SDL2
    PkgConfig::FFMPEG
    JPEG::JPEG
    nlohmann_json::nlohmann_json
    vibe_wasmtime_static
    Threads::Threads
    ${CMAKE_DL_LIBS}
)
if(AVFILTER_FOUND)
    target_link_libraries(vibe-native-render PRIVATE PkgConfig::AVFILTER)
endif()
if(UNIX AND NOT APPLE)
    target_link_libraries(vibe-native-render PRIVATE m)
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(vibe-native-render PRIVATE -O3 -Wall -Wextra -Wpedantic)
endif()

if(BUILD_TESTING)
    add_executable(vibe-selection-marker-test tests/selection_marker_test.cpp)
    target_compile_options(vibe-selection-marker-test PRIVATE -UNDEBUG)
    add_test(NAME native_selection_marker COMMAND vibe-selection-marker-test)
    add_executable(vibe-rounded-surface-test tests/rounded_surface_test.cpp)
    target_compile_options(vibe-rounded-surface-test PRIVATE -UNDEBUG)
    add_test(NAME native_rounded_surface COMMAND vibe-rounded-surface-test)
    add_executable(vibe-surface-curvature-test tests/surface_curvature_test.cpp)
    add_test(NAME native_surface_curvature COMMAND vibe-surface-curvature-test)
    add_executable(vibe-plane-pattern-test tests/plane_pattern_test.cpp)
    target_include_directories(vibe-plane-pattern-test PRIVATE src)
    target_link_libraries(vibe-plane-pattern-test PRIVATE OpenGL::GL PkgConfig::SDL2)
    add_test(NAME native_plane_pattern COMMAND vibe-plane-pattern-test)
    add_executable(vibe-flash-faces-test tests/flash_faces_test.cpp)
    target_include_directories(vibe-flash-faces-test PRIVATE src)
    target_link_libraries(vibe-flash-faces-test PRIVATE nlohmann_json::nlohmann_json)
    add_test(NAME native_flash_faces COMMAND vibe-flash-faces-test)
    add_executable(vibe-mapping-fit-test tests/mapping_fit_test.cpp)
    target_include_directories(vibe-mapping-fit-test PRIVATE src)
    add_test(NAME native_mapping_fit COMMAND vibe-mapping-fit-test)

    add_executable(vibe-live-capture-test
        tests/live_capture_test.cpp src/live_capture.cpp)
    target_include_directories(vibe-live-capture-test PRIVATE src)
    target_link_libraries(vibe-live-capture-test PRIVATE
        PkgConfig::FFMPEG Threads::Threads)
    if(APPLE)
        target_link_options(vibe-live-capture-test PRIVATE
            "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
    endif()
    add_test(NAME native_live_capture COMMAND vibe-live-capture-test)

    add_executable(vibe-webcam-layer-test
        tests/webcam_layer_test.cpp src/native_render_graph.cpp
        src/media_decoder.cpp src/native_audio.cpp src/live_capture.cpp)
    target_include_directories(vibe-webcam-layer-test PRIVATE src)
    target_link_libraries(vibe-webcam-layer-test PRIVATE
        OpenGL::GL PkgConfig::SDL2 PkgConfig::FFMPEG JPEG::JPEG
        nlohmann_json::nlohmann_json Threads::Threads)
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-webcam-layer-test PRIVATE VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-webcam-layer-test PRIVATE PkgConfig::AVFILTER)
    endif()
    add_test(NAME native_webcam_layer COMMAND vibe-webcam-layer-test)
    set_tests_properties(native_webcam_layer PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy")

    add_executable(vibe-image-layer-test
        tests/image_layer_test.cpp src/native_render_graph.cpp
        src/media_decoder.cpp src/native_audio.cpp src/live_capture.cpp)
    target_include_directories(vibe-image-layer-test PRIVATE src)
    target_link_libraries(vibe-image-layer-test PRIVATE
        OpenGL::GL PkgConfig::SDL2 PkgConfig::FFMPEG JPEG::JPEG
        nlohmann_json::nlohmann_json Threads::Threads)
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-image-layer-test PRIVATE VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-image-layer-test PRIVATE PkgConfig::AVFILTER)
    endif()
    add_test(NAME native_image_layer COMMAND vibe-image-layer-test)
    set_tests_properties(native_image_layer PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy")
    add_test(NAME native_media_collection COMMAND vibe-image-layer-test --media-collection)
    set_tests_properties(native_media_collection PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy")

    add_executable(vibe-playback-test tests/playback_test.cpp)
    target_include_directories(vibe-playback-test PRIVATE src)
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(vibe-playback-test PRIVATE
            -O2 -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME native_ping_pong_playback COMMAND vibe-playback-test)

    add_executable(vibe-movie-mode-test tests/movie_mode_test.cpp)
    target_include_directories(vibe-movie-mode-test PRIVATE src)
    target_link_libraries(vibe-movie-mode-test PRIVATE
        nlohmann_json::nlohmann_json)
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(vibe-movie-mode-test PRIVATE
            -O2 -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME native_movie_mode_selection COMMAND vibe-movie-mode-test)

    add_executable(vibe-native-audio-test
        src/native_audio.cpp
        tests/native_audio_test.cpp
    )
    target_include_directories(vibe-native-audio-test PRIVATE src)
    target_link_libraries(vibe-native-audio-test PRIVATE
        PkgConfig::SDL2
        PkgConfig::FFMPEG
        nlohmann_json::nlohmann_json
        Threads::Threads
    )
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(vibe-native-audio-test PRIVATE
            -O2 -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME native_audio_master_clock COMMAND vibe-native-audio-test)
    set_tests_properties(native_audio_master_clock PROPERTIES
        ENVIRONMENT "SDL_AUDIODRIVER=dummy")

    add_executable(vibe-media-cache-test
        src/media_decoder.cpp
        tests/media_decoder_cache_test.cpp
    )
    target_include_directories(vibe-media-cache-test PRIVATE src)
    target_link_libraries(vibe-media-cache-test PRIVATE
        PkgConfig::FFMPEG
        Threads::Threads
    )
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-media-cache-test PRIVATE
            VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-media-cache-test PRIVATE PkgConfig::AVFILTER)
    endif()
    if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
        target_compile_options(vibe-media-cache-test PRIVATE
            -O2 -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME native_media_reverse_cache COMMAND vibe-media-cache-test)

    if(AVFILTER_FOUND)
        add_executable(vibe-media-subtitle-test
            src/media_decoder.cpp
            tests/media_decoder_subtitle_test.cpp
        )
        target_include_directories(vibe-media-subtitle-test PRIVATE src)
        target_compile_definitions(vibe-media-subtitle-test PRIVATE
            VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-media-subtitle-test PRIVATE
            PkgConfig::FFMPEG
            PkgConfig::AVFILTER
            Threads::Threads
        )
        if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
            target_compile_options(vibe-media-subtitle-test PRIVATE
                -O2 -Wall -Wextra -Wpedantic)
        endif()
        add_test(NAME native_embedded_subtitle_sync
            COMMAND vibe-media-subtitle-test)
        set_tests_properties(native_embedded_subtitle_sync PROPERTIES
            SKIP_RETURN_CODE 77)
    endif()
endif()

# Live texture transport is optional by platform, with an explicit Linux stub.
include(cmake/Syphon.cmake)
if(APPLE)
    add_dependencies(vibe-native-render vibe-syphon-discovery)
endif()
foreach(target vibe-native-render vibe-webcam-layer-test vibe-image-layer-test)
    if(TARGET ${target})
        target_link_libraries(${target} PRIVATE vibe_syphon_input)
    endif()
endforeach()
if(APPLE AND BUILD_TESTING)
    add_executable(vibe-syphon-layer-test tests/syphon_layer_test.mm
        src/native_render_graph.cpp src/media_decoder.cpp src/native_audio.cpp src/live_capture.cpp)
    set_target_properties(vibe-syphon-layer-test PROPERTIES OBJCXX_STANDARD 20)
    target_compile_options(vibe-syphon-layer-test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>" -Wno-deprecated-declarations)
    target_include_directories(vibe-syphon-layer-test PRIVATE src)
    target_link_libraries(vibe-syphon-layer-test PRIVATE vibe_syphon_input
        OpenGL::GL PkgConfig::SDL2 PkgConfig::FFMPEG JPEG::JPEG
        nlohmann_json::nlohmann_json Threads::Threads)
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-syphon-layer-test PRIVATE VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-syphon-layer-test PRIVATE PkgConfig::AVFILTER)
    endif()
    add_test(NAME native_syphon_layer COMMAND vibe-syphon-layer-test)
    set_tests_properties(native_syphon_layer PROPERTIES
        ENVIRONMENT "SDL_AUDIODRIVER=dummy" TIMEOUT 45)
endif()

include(cmake/NDI.cmake)
