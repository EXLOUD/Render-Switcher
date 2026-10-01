cmake_minimum_required(VERSION 3.18)
project(render_switcher_zygisk)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# compile_commands.json у build/<ABI>/ - вхід для статичного аналізу PVS-Studio
# (analyze-pvs.bat). Працює з генераторами Ninja/Makefiles.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

add_library(render_switcher_zygisk SHARED src/main.cpp)
target_include_directories(render_switcher_zygisk PRIVATE src)

target_compile_options(render_switcher_zygisk PRIVATE
    -fno-rtti -fno-exceptions -Os -fvisibility=hidden
)
target_link_options(render_switcher_zygisk PRIVATE -Wl,--exclude-libs,ALL)
target_link_libraries(render_switcher_zygisk log)

# Magisk wants zygisk/<abi>.so — build.sh renames; here keep ABI in name when possible
if(ANDROID_ABI)
    set(_out "${ANDROID_ABI}")
else()
    set(_out "arm64-v8a")
endif()

set_target_properties(render_switcher_zygisk PROPERTIES
    PREFIX ""
    OUTPUT_NAME "${_out}"
)
