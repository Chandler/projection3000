# Patch and VJ normally live side by side. Worktrees can override VJ_PATCH_ROOT.
set(VJ_PATCH_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../patch" CACHE PATH "Sibling Patch checkout")
get_filename_component(VJ_PATCH_ROOT "${VJ_PATCH_ROOT}" ABSOLUTE)
if(NOT EXISTS "${VJ_PATCH_ROOT}/Package.swift")
  message(FATAL_ERROR "PatchKit requires the sibling patch checkout; set VJ_PATCH_ROOT for other layouts")
endif()
find_program(VJ_SWIFT swift REQUIRED)
# The Command Line Tools' default macOS 27 SDK lacks SwiftUI's macro plugins; PatchKit builds with the 26 SDK.
execute_process(COMMAND xcrun --sdk macosx26.5 --show-sdk-path OUTPUT_VARIABLE VJ_PATCH_SDK OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT VJ_PATCH_SDK)
  execute_process(COMMAND xcrun --sdk macosx26.4 --show-sdk-path OUTPUT_VARIABLE VJ_PATCH_SDK OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
endif()
set(VJ_PATCH_ENV)
if(VJ_PATCH_SDK)
  set(VJ_PATCH_ENV "${CMAKE_COMMAND}" -E env "SDKROOT=${VJ_PATCH_SDK}")
endif()
set(VJ_PATCH_BUILD "${CMAKE_CURRENT_BINARY_DIR}/patch-build")
set(VJ_PATCH_LIBRARY "${VJ_PATCH_BUILD}/release/libPatchKit.dylib")
file(GLOB_RECURSE VJ_PATCH_INPUTS CONFIGURE_DEPENDS "${VJ_PATCH_ROOT}/Sources/*" "${VJ_PATCH_ROOT}/include/*")
add_custom_command(OUTPUT "${VJ_PATCH_LIBRARY}"
  COMMAND ${VJ_PATCH_ENV} "${VJ_SWIFT}" build --package-path "${VJ_PATCH_ROOT}" --scratch-path "${VJ_PATCH_BUILD}" -c release --product PatchKit -j 2
  DEPENDS ${VJ_PATCH_INPUTS} "${VJ_PATCH_ROOT}/Package.swift"
  COMMENT "Building shared Patch editor and render runtime" VERBATIM)
add_custom_target(vj-patch-build DEPENDS "${VJ_PATCH_LIBRARY}")
add_library(vj_patch SHARED IMPORTED)
set_target_properties(vj_patch PROPERTIES IMPORTED_LOCATION "${VJ_PATCH_LIBRARY}" INTERFACE_INCLUDE_DIRECTORIES "${VJ_PATCH_ROOT}/include")
add_dependencies(vj_patch vj-patch-build)
target_link_libraries(VJNative PRIVATE vj_patch)
# PatchKit loads Loopmother and the VST3 host from Contents/Frameworks at run time.
find_program(VJ_PYTHON python3 REQUIRED)
set(VJ_PLUGIN_HOST "${VJ_PATCH_ROOT}/.build/plugin-host/libPatchAudioPluginHost.dylib")
file(GLOB_RECURSE VJ_PLUGIN_HOST_INPUTS CONFIGURE_DEPENDS "${VJ_PATCH_ROOT}/Native/AudioPluginHost/*")
add_custom_command(OUTPUT "${VJ_PLUGIN_HOST}"
  COMMAND "${VJ_PYTHON}" "${VJ_PATCH_ROOT}/scripts/build-plugin-host.py"
  DEPENDS ${VJ_PLUGIN_HOST_INPUTS}
  COMMENT "Building Patch audio plugin host (Loopmother, VST3)" VERBATIM)
add_custom_target(vj-plugin-host DEPENDS "${VJ_PLUGIN_HOST}")
add_dependencies(VJNative vj-plugin-host)
# Relink when the host changes so the bundle copy below is refreshed.
set_property(TARGET VJNative APPEND PROPERTY LINK_DEPENDS "${VJ_PLUGIN_HOST}")
add_custom_command(TARGET VJNative POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:VJNative>/Frameworks"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${VJ_PLUGIN_HOST}" "$<TARGET_BUNDLE_CONTENT_DIR:VJNative>/Frameworks/libPatchAudioPluginHost.dylib"
  COMMAND /usr/bin/codesign --force --sign - "$<TARGET_BUNDLE_CONTENT_DIR:VJNative>/Frameworks/libPatchAudioPluginHost.dylib"
  VERBATIM)
target_include_directories(VJNative PRIVATE "${VJ_PATCH_ROOT}/Sources/OutputBridge/include")
target_include_directories(vj_preview_engine PRIVATE "${VJ_PATCH_ROOT}/Sources/OutputBridge/include")
set_property(TARGET VJNative APPEND PROPERTY BUILD_RPATH "${VJ_PATCH_BUILD}/release" "/usr/lib/swift")
add_custom_command(TARGET VJNative POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${VJ_PATCH_BUILD}/release/Patch_PatchKit.bundle" "$<TARGET_BUNDLE_CONTENT_DIR:VJNative>/Resources/PatchResources.bundle"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${VJ_PATCH_ROOT}/User Nodes" "$<TARGET_BUNDLE_CONTENT_DIR:VJNative>/Resources/User Nodes"
  VERBATIM)
