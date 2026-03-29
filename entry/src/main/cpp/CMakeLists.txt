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
# libsmb2 集成（SMB2/3 协议支持）
#
# 选型：libsmb2 (https://github.com/sahlberg/libsmb2)
#   - 零系统依赖，纯 C (C99)，支持 SMB2/3 协议
#   - ARM64 兼容，HarmonyOS NDK 无障碍
#
# 使用方式：
#   默认 OFF（libsmb2.so 尚未交叉编译）。
#   完成交叉编译后，将 libsmb2.so 放入 entry/libs/<abi>/，
#   再以 -DVIDALL_ENABLE_LIBSMB2=ON 启用。
#
#   交叉编译参考：
#     export CC=<NDK_PATH>/llvm/bin/clang
#     export CFLAGS="-target aarch64-none-linux-ohos --sysroot=<NDK_PATH>/sysroot"
#     cmake libsmb2/ -DCMAKE_C_COMPILER=$CC -DCMAKE_C_FLAGS="$CFLAGS"
#     make -j4
# ---------------------------------------------------------------------------
set(LIBSMB2_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
set(LIBSMB2_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/libsmb2/include)

option(VIDALL_ENABLE_LIBSMB2 "Enable libsmb2 for SMB2/3 protocol support" OFF)

if(VIDALL_ENABLE_LIBSMB2)
  if(NOT EXISTS ${LIBSMB2_LIB_DIR}/libsmb2.so)
    message(FATAL_ERROR
      "VIDALL_ENABLE_LIBSMB2=ON but libsmb2.so not found at:\n"
      "  ${LIBSMB2_LIB_DIR}/libsmb2.so\n"
      "Place the compiled library or pass -DVIDALL_ENABLE_LIBSMB2=OFF to disable."
    )
  endif()

  add_library(smb2 SHARED IMPORTED)
  set_target_properties(smb2 PROPERTIES
    IMPORTED_LOCATION ${LIBSMB2_LIB_DIR}/libsmb2.so
  )

  target_include_directories(vidall_core_player_napi PRIVATE
    ${LIBSMB2_INCLUDE_DIR}
  )

  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBSMB2=1)
  target_link_libraries(vidall_core_player_napi PUBLIC smb2)
  message(STATUS "VIDALL_ENABLE_LIBSMB2=ON — libsmb2 enabled for SMB2/3 support")
else()
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_LIBSMB2=0)
  message(STATUS "VIDALL_ENABLE_LIBSMB2=OFF — SMB2/3 support disabled")
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
  )
else()
  message(STATUS "VIDALL_ENABLE_OH_AVPLAYER=OFF — OH_AVPlayer C API disabled")
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_OH_AVPLAYER=0)
endif()

# VPE (Video Processing Engine) — AI 画质增强（Detail Enhancer）
# libvideo_processing.so 在 HarmonyOS API 12+ 上存在（我们 minSdk=API19 ≥ API12，始终可用）
# 定义 VIDALL_HAS_VPE 宏让 IDE 知道这段代码是有意为之的条件编译，消除"API not supported"警告
option(VIDALL_ENABLE_VPE "Enable VPE (Video Processing Engine) AI enhancement" ON)
if(VIDALL_ENABLE_VPE)
  target_compile_definitions(vidall_core_player_napi PRIVATE VIDALL_HAS_VPE=1)
  target_link_libraries(vidall_core_player_napi PUBLIC
      libvideo_processing.so
  )
  message(STATUS "VIDALL_ENABLE_VPE=ON — VPE Detail Enhancer enabled")
else()
  message(STATUS "VIDALL_ENABLE_VPE=OFF — VPE Detail Enhancer disabled (stub stubs will be used)")
endif()

target_link_libraries(vidall_core_player_napi PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    ffmpeg
)
