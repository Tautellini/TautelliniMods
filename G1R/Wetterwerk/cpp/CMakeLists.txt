# Top-level CMake for the Wetterwerk C++ UE4SS mod.
#
# It builds the RE-UE4SS framework as a dependency, then the mod. This matches the
# layout in the bundled UE4SS guide "creating-a-c++-mod.md": RE-UE4SS lives in a
# sibling subfolder and is added first so the mod can link `UE4SS`.
#
# RE-UE4SS is NOT vendored in this repo (it is large and needs Unreal Engine source
# access to clone). See BUILD.md: clone it to `cpp/RE-UE4SS` (with submodules), then
# configure from this directory. The recommended alternative is the official
# UE4SSCPPTemplate, into which the `Wetterwerk/` folder drops unchanged.

cmake_minimum_required(VERSION 3.22)
project(WetterwerkMods)

if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/RE-UE4SS/CMakeLists.txt")
    message(FATAL_ERROR
        "RE-UE4SS not found at ${CMAKE_CURRENT_SOURCE_DIR}/RE-UE4SS.\n"
        "Clone it there first (see cpp/BUILD.md), e.g.:\n"
        "  git clone https://github.com/UE4SS-RE/RE-UE4SS RE-UE4SS\n"
        "  cd RE-UE4SS && git submodule update --init --recursive")
endif()

add_subdirectory(RE-UE4SS)
add_subdirectory(Wetterwerk)
