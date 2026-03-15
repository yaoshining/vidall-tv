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

# ---------------------------------------------------------------------------
# 预编译 FFmpeg 共享库
# so 文件放在: entry/libs/<abi>/libffmpeg.so
# 头文件放在: entry/src/main/cpp/include/ (如有)
# ---------------------------------------------------------------------------
set(FFMPEG_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
set(FFMPEG_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/include)
set(CURL_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
set(CURL_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/curl/include)

add_library(ffmpeg SHARED IMPORTED)
set_target_properties(ffmpeg PROPERTIES
    IMPORTED_LOCATION ${FFMPEG_LIB_DIR}/libffmpeg.so
)

target_include_directories(vidall_core_player_napi PRIVATE
    ${FFMPEG_INCLUDE_DIR}
)

# ---------------------------------------------------------------------------
# 可选 libcurl（阶段性接入骨架）
# 若存在 entry/libs/<abi>/libcurl.so，则自动启用并定义 VIDALL_HAS_LIBCURL=1
# ---------------------------------------------------------------------------
if(EXISTS ${CURL_LIB_DIR}/libcurl.so)
  add_library(curl SHARED IMPORTED)
  set_target_properties(curl PROPERTIES
    IMPORTED_LOCATION ${CURL_LIB_DIR}/libcurl.so
  )
  target_include_directories(vidall_core_player_napi PRIVATE
    ${CURL_INCLUDE_DIR}
  )
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBCURL=1)
  target_link_libraries(vidall_core_player_napi PUBLIC
    curl
  )
else()
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBCURL=0)
endif()

target_link_libraries(vidall_core_player_napi PUBLIC
    libace_napi.z.so
    ffmpeg
)
