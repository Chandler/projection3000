# Pinned official Wasmtime C API; sets vibe_wasmtime_SOURCE_DIR.
include(FetchContent)
set(VIBE_WASMTIME_VERSION "45.0.0")
if(CMAKE_SYSTEM_NAME STREQUAL "Linux"
   AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
    set(VIBE_WASMTIME_ARCHIVE
        "wasmtime-v${VIBE_WASMTIME_VERSION}-x86_64-linux-c-api.tar.xz")
    set(VIBE_WASMTIME_SHA256
        "95959e7a4cc4bfc12bbe45c9dea82cf45dd5b4321d9163e66343c50728429129")
elseif(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    set(VIBE_WASMTIME_ARCHIVE
        "wasmtime-v${VIBE_WASMTIME_VERSION}-aarch64-macos-c-api.tar.xz")
    set(VIBE_WASMTIME_SHA256
        "43cd87ec7d398f2e799e81c7d4e143d930e0139953d3c5d2a9c4055789f29851")
else()
    message(FATAL_ERROR
        "No pinned Wasmtime C API archive for ${CMAKE_SYSTEM_NAME}/${CMAKE_SYSTEM_PROCESSOR}")
endif()
FetchContent_Declare(vibe_wasmtime
    URL
      "https://github.com/bytecodealliance/wasmtime/releases/download/v${VIBE_WASMTIME_VERSION}/${VIBE_WASMTIME_ARCHIVE}"
    URL_HASH "SHA256=${VIBE_WASMTIME_SHA256}"
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(vibe_wasmtime)
