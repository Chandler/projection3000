# Headers are vendored under their MIT terms. Runtime remains optional and is
# loaded from the executable directory, VIBE_NDI_LIBRARY, or a system install.
add_library(vibe_ndi_input STATIC src/ndi_runtime.cpp src/ndi_input.cpp src/ndi_output.cpp)
target_include_directories(vibe_ndi_input PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/ndi/include")
target_link_libraries(vibe_ndi_input PUBLIC nlohmann_json::nlohmann_json
    Threads::Threads ${CMAKE_DL_LIBS})
add_executable(vibe-ndi-discovery src/ndi_discovery.cpp)
target_link_libraries(vibe-ndi-discovery PRIVATE vibe_ndi_input)
add_dependencies(vibe-native-render vibe-ndi-discovery)
foreach(target vibe-native-render vibe-webcam-layer-test vibe-image-layer-test vibe-syphon-layer-test)
    if(TARGET ${target})
        target_link_libraries(${target} PRIVATE vibe_ndi_input)
    endif()
endforeach()
if(BUILD_TESTING)
    add_executable(vibe-ndi-layer-test tests/ndi_layer_test.cpp
        src/native_render_graph.cpp src/media_decoder.cpp src/native_audio.cpp src/live_capture.cpp)
    target_include_directories(vibe-ndi-layer-test PRIVATE src)
    target_link_libraries(vibe-ndi-layer-test PRIVATE vibe_ndi_input vibe_syphon_input
        OpenGL::GL PkgConfig::SDL2 PkgConfig::FFMPEG JPEG::JPEG
        nlohmann_json::nlohmann_json Threads::Threads)
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-ndi-layer-test PRIVATE VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-ndi-layer-test PRIVATE PkgConfig::AVFILTER)
    endif()
    add_test(NAME native_ndi_layer COMMAND vibe-ndi-layer-test)
    set_tests_properties(native_ndi_layer PROPERTIES
        ENVIRONMENT "SDL_AUDIODRIVER=dummy" SKIP_RETURN_CODE 77 TIMEOUT 60)
endif()
if(BUILD_TESTING)
    add_executable(vibe-ndi-output-test tests/ndi_output_test.cpp
        src/native_render_graph.cpp src/media_decoder.cpp src/native_audio.cpp src/live_capture.cpp)
    target_include_directories(vibe-ndi-output-test PRIVATE src)
    target_link_libraries(vibe-ndi-output-test PRIVATE vibe_ndi_input vibe_syphon_input
        OpenGL::GL PkgConfig::SDL2 PkgConfig::FFMPEG JPEG::JPEG nlohmann_json::nlohmann_json Threads::Threads)
    if(AVFILTER_FOUND)
        target_compile_definitions(vibe-ndi-output-test PRIVATE VIBE_HAS_AVFILTER=1)
        target_link_libraries(vibe-ndi-output-test PRIVATE PkgConfig::AVFILTER)
    endif()
    add_test(NAME native_ndi_output COMMAND vibe-ndi-output-test)
    set_tests_properties(native_ndi_output PROPERTIES ENVIRONMENT "SDL_AUDIODRIVER=dummy" SKIP_RETURN_CODE 77 TIMEOUT 60)
endif()
