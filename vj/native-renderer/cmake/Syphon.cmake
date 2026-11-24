# Official Syphon OpenGL transport, pinned and built with Command Line Tools.
# Metal senders interoperate through the same IOSurface protocol.
if(APPLE)
    enable_language(C OBJC OBJCXX)
    include(FetchContent)
    FetchContent_Declare(vibe_syphon
        GIT_REPOSITORY https://github.com/Syphon/Syphon-Framework.git
        GIT_TAG f4761677a45b8034a3c2069ec0f3d2553da81fba)
    FetchContent_MakeAvailable(vibe_syphon)
    file(GLOB syphon_sources "${vibe_syphon_SOURCE_DIR}/*.m" "${vibe_syphon_SOURCE_DIR}/*.c")
    list(FILTER syphon_sources EXCLUDE REGEX "(SyphonMetal|SyphonServerRendererMetal)")
    file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/syphon-include")
    file(CREATE_LINK "${vibe_syphon_SOURCE_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}/syphon-include/Syphon" SYMBOLIC)
    add_library(vibe_syphon_framework STATIC ${syphon_sources})
    target_include_directories(vibe_syphon_framework PUBLIC
        "${CMAKE_CURRENT_BINARY_DIR}/syphon-include")
    target_compile_options(vibe_syphon_framework PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>" -fblocks
        -include "${vibe_syphon_SOURCE_DIR}/Syphon_Prefix.pch"
        -Wno-deprecated-declarations)
    target_compile_definitions(vibe_syphon_framework PRIVATE SYPHON_CORE_SHARE)
    target_link_libraries(vibe_syphon_framework PUBLIC
        "-framework Cocoa" "-framework OpenGL" "-framework IOSurface")
    configure_file("${vibe_syphon_SOURCE_DIR}/License.txt"
        "${CMAKE_CURRENT_BINARY_DIR}/Syphon-LICENSE.txt" COPYONLY)
    add_library(vibe_syphon_input STATIC src/syphon_input.mm)
    set_target_properties(vibe_syphon_input PROPERTIES OBJCXX_STANDARD 20)
    target_compile_options(vibe_syphon_input PRIVATE -fobjc-arc -Wno-deprecated-declarations)
    target_link_libraries(vibe_syphon_input PUBLIC vibe_syphon_framework
        nlohmann_json::nlohmann_json OpenGL::GL)
    add_executable(vibe-syphon-discovery src/syphon_discovery.cpp)
    target_link_libraries(vibe-syphon-discovery PRIVATE vibe_syphon_input)
else()
    add_library(vibe_syphon_input STATIC src/syphon_input_stub.cpp)
    target_link_libraries(vibe_syphon_input PUBLIC nlohmann_json::nlohmann_json)
endif()
