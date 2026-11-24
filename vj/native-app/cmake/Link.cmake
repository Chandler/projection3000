# SDK matches the Link submodule of the installed original aalink v0.2.3.
# Fetching/building never starts a Link session. OFF keeps a portable stub.
option(VJ_ENABLE_LINK "Compile Ableton Link session support" OFF)
set(VJ_LINK_SDK "" CACHE PATH "Existing Ableton Link SDK with Asio submodule")
function(vj_configure_link target)
  target_sources(${target} PRIVATE ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src/link_runtime.cpp)
  if(NOT VJ_ENABLE_LINK)
    target_sources(${target} PRIVATE ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src/link_stub.cpp)
    return()
  endif()
  if(VJ_LINK_SDK)
    set(link_source "${VJ_LINK_SDK}")
  else()
    include(FetchContent)
    FetchContent_Declare(vj_ableton_link
      URL https://codeload.github.com/Ableton/link/tar.gz/902aef95bf94af49746fdda5369b42cdcfa1e6d2
      URL_HASH SHA256=8fe89e953388a987d8fec88207e0e06cb3a169c7dbf64e021286d1f0c3887261
      SOURCE_SUBDIR vj_no_subproject)
    FetchContent_Declare(vj_link_asio
      URL https://codeload.github.com/chriskohlhoff/asio/tar.gz/231cb29bab30f82712fcd54faaea42424cc6e710
      URL_HASH SHA256=5def09efbd4be199dd6ddca53a2c99b9eef696f6b430910d896594b04ff59108
      SOURCE_SUBDIR vj_no_subproject)
    FetchContent_MakeAvailable(vj_ableton_link vj_link_asio)
    set(link_source "${vj_ableton_link_SOURCE_DIR}")
    if(NOT EXISTS "${link_source}/modules/asio-standalone/asio/include/asio.hpp")
      file(REMOVE_RECURSE "${link_source}/modules/asio-standalone")
      file(CREATE_LINK "${vj_link_asio_SOURCE_DIR}" "${link_source}/modules/asio-standalone" SYMBOLIC COPY_ON_ERROR)
    endif()
  endif()
  if(NOT EXISTS "${link_source}/include/ableton/Link.hpp" OR
     NOT EXISTS "${link_source}/modules/asio-standalone/asio/include/asio.hpp")
    message(FATAL_ERROR "VJ_LINK_SDK needs Ableton Link headers and initialized Asio submodule")
  endif()
  # Keep SDK's C++ standard setting local to this function.
  include("${link_source}/AbletonLinkConfig.cmake")
  target_sources(${target} PRIVATE ${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../src/link_sdk.cpp)
  target_link_libraries(${target} PUBLIC Ableton::Link)
endfunction()
