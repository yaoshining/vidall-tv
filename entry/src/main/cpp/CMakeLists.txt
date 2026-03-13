cmake_minimum_required(VERSION 3.5.0)
project(vidall_core_player_napi)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(vidall_core_player_napi SHARED
  vidall_core_player_napi.cpp
)

target_include_directories(vidall_core_player_napi PUBLIC
  ${NATIVERENDER_ROOT_PATH}
)

target_link_libraries(vidall_core_player_napi PUBLIC
  libace_napi.z.so
)