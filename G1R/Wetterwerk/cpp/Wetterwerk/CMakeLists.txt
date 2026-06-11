# The Wetterwerk mod target. Mirrors the bundled UE4SS guide's mod CMakeLists.
#
# Builds a SHARED library (the mod DLL). After building, the output DLL is renamed
# to main.dll and placed at <game>/.../Mods/Wetterwerk/dlls/main.dll (see BUILD.md;
# the optional POST_BUILD copy below automates that once you set the path).

set(TARGET Wetterwerk)

add_library(${TARGET} SHARED
    dllmain.cpp
    WeatherControl.cpp
)

target_include_directories(${TARGET} PRIVATE .)
target_link_libraries(${TARGET} PUBLIC UE4SS)

# Optional: copy + rename to the game's mod folder after a successful build. Set
# GAME_MODS_DIR (or edit the path) and uncomment to enable.
#
# set(GAME_MODS_DIR "C:/Program Files (x86)/Steam/steamapps/common/Gothic 1 Remake/G1R/Binaries/Win64/ue4ss/Mods")
# add_custom_command(TARGET ${TARGET} POST_BUILD
#     COMMAND ${CMAKE_COMMAND} -E make_directory "${GAME_MODS_DIR}/${TARGET}/dlls"
#     COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:${TARGET}>" "${GAME_MODS_DIR}/${TARGET}/dlls/main.dll"
#     COMMENT "Installed ${TARGET} -> ${GAME_MODS_DIR}/${TARGET}/dlls/main.dll")
