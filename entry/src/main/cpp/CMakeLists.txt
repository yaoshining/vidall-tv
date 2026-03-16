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
# 头文件放在: entry/src/main/cpp/third_party/ffmpeg/include/
# ---------------------------------------------------------------------------
set(FFMPEG_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
set(FFMPEG_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffmpeg/include)
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
# B1：FFmpeg demux/decode 路径编译开关
# 默认 ON；可通过 cmake -DVIDALL_ENABLE_FFMPEG=OFF 关闭（仅保留 OH_AVPlayer 路径）。
# ---------------------------------------------------------------------------
option(VIDALL_ENABLE_FFMPEG "Enable FFmpeg demux/decode path" ON)
if(VIDALL_ENABLE_FFMPEG)
    target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_ENABLE_FFMPEG=1)
    message(STATUS "VIDALL_ENABLE_FFMPEG=ON — FFmpeg demux path enabled")
    # B3：OpenGL ES YUV 渲染管线需要 EGL 上下文与 GLES2 库
    # B4：OH_AudioRenderer PCM 送显需要 libohaudio
    target_link_libraries(vidall_core_player_napi PRIVATE
        libEGL.so      # EGL 上下文（创建 window surface / context）
        libGLESv2.so   # OpenGL ES 2.0（shader / texture / draw）
        libohaudio.so  # B4：OH_AudioRenderer（PCM 音频送显）
    )
else()
    target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_ENABLE_FFMPEG=0)
    message(STATUS "VIDALL_ENABLE_FFMPEG=OFF — FFmpeg demux path disabled")
endif()

# ---------------------------------------------------------------------------
# libcurl 集成（HTTPS WebDAV 支持）
#
# 使用方式：
#   默认 ON。若目标环境无 libcurl.so，可显式关闭：
#     cmake -DVIDALL_ENABLE_LIBCURL=OFF ...
#   CI 中建议固定传参，避免构建结果随环境漂移。
# ---------------------------------------------------------------------------
option(VIDALL_ENABLE_LIBCURL "Enable libcurl for HTTPS WebDAV support" ON)

if(VIDALL_ENABLE_LIBCURL)
  if(NOT EXISTS ${CURL_LIB_DIR}/libcurl.so)
    message(FATAL_ERROR
      "VIDALL_ENABLE_LIBCURL=ON but libcurl.so not found at:\n"
      "  ${CURL_LIB_DIR}/libcurl.so\n"
      "Place the library or pass -DVIDALL_ENABLE_LIBCURL=OFF to disable."
    )
  endif()
  add_library(curl SHARED IMPORTED)
  set_target_properties(curl PROPERTIES
    IMPORTED_LOCATION ${CURL_LIB_DIR}/libcurl.so
  )
  target_include_directories(vidall_core_player_napi PRIVATE
    ${CURL_INCLUDE_DIR}
  )
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBCURL=1)
  target_link_libraries(vidall_core_player_napi PUBLIC curl)
else()
  message(STATUS "VIDALL_ENABLE_LIBCURL=OFF — HTTPS WebDAV support disabled")
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBCURL=0)
endif()

# ---------------------------------------------------------------------------
# OH_AVPlayer 系统 C API（libaudio_renderer / OH_AVPlayer）
#
# libnative_window.so — OHNativeWindow* 操作（Surface/XComponent 侧）
# libavplayer.so      — OH_AVPlayer C API（媒体播放核心）
# libace_ndk.z.so     — OH_NativeXComponent_GetNativeWindow() 及 XComponent Native C API
#                       （注意：NDK sysroot 中不存在 libace_xcomponent.z.so，
#                         XComponent Native 接口由 libace_ndk.z.so 统一提供；
#                         libace_napi.z.so 已提供 NAPI 侧，此库补充 Native C 侧）
#
# 以上三库均为 HarmonyOS 系统库，链接器通过 NDK sysroot 自动寻址，
# 无需将 .so 文件放入 libs/ 目录，也无需 add_library(IMPORTED)。
#
# 使用方式：
#   默认 ON。若只需要 FFmpeg 路径而不启用 OH_AVPlayer，可显式关闭：
#     cmake -DVIDALL_ENABLE_OH_AVPLAYER=OFF ...
# ---------------------------------------------------------------------------
option(VIDALL_ENABLE_OH_AVPLAYER "Enable OH_AVPlayer system C API (libnative_window + libavplayer + libace_ndk)" ON)

if(VIDALL_ENABLE_OH_AVPLAYER)
  # XComponent Native 头文件路径
  # HarmonyOS NDK sysroot 通常由 DevEco 工具链注入 CMAKE_SYSROOT 或 OHOS_SDK_NATIVE_ROOT。
  # 若变量未定义，需在 local.properties / CMakePresets 中手动指定 OHOS_SDK_NATIVE_ROOT。
  if(DEFINED OHOS_SDK_NATIVE_ROOT)
    target_include_directories(vidall_core_player_napi PRIVATE
      ${OHOS_SDK_NATIVE_ROOT}/sysroot/usr/include
    )
  elseif(DEFINED CMAKE_SYSROOT)
    target_include_directories(vidall_core_player_napi PRIVATE
      ${CMAKE_SYSROOT}/usr/include
    )
  else()
    message(WARNING
      "VIDALL_ENABLE_OH_AVPLAYER=ON but neither OHOS_SDK_NATIVE_ROOT nor CMAKE_SYSROOT is defined.\n"
      "XComponent native header (native_interface_xcomponent.h) may not be found.\n"
      "Pass -DOHOS_SDK_NATIVE_ROOT=<ndk-root> or rely on DevEco toolchain injection."
    )
  endif()

  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_OH_AVPLAYER=1)
  target_link_libraries(vidall_core_player_napi PUBLIC
    libnative_window.so
    libavplayer.so
    libace_ndk.z.so
    libnative_media_core.so  # A4：OH_AVFormat_GetIntValue（avplayer new-style info callback）
    libnative_media_codecbase.so
    libnative_media_acodec.so
  )
else()
  message(STATUS "VIDALL_ENABLE_OH_AVPLAYER=OFF — OH_AVPlayer C API disabled")
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_OH_AVPLAYER=0)
endif()

target_link_libraries(vidall_core_player_napi PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    ffmpeg
)
