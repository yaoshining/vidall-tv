#!/bin/bash
# 编译 libijkplayer_napi.so（含 FFP_MSG_TIMED_TEXT 字幕支持）
# 用法：./scripts/build_ijk_napi.sh [IJK源码路径]
# 要求：已安装 DevEco Studio，IJK 源码默认在 ~/Downloads/ohos_ijkplayer-master

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IJK_SRC="${1:-$HOME/Downloads/ohos_ijkplayer-master/ijkplayer/src/main/cpp}"
IJK_LIBS="$PROJECT_ROOT/oh_modules/.ohpm/@ohos+ijkplayer@2.0.7/oh_modules/@ohos/ijkplayer/libs"
DEVECO_NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
FFMPEG_INC="$PROJECT_ROOT/entry/src/main/cpp/third_party/ffmpeg/include"
BUILD_DIR="$PROJECT_ROOT/build/ijk_napi_build"

echo "=== 编译 libijkplayer_napi.so ==="
echo "IJK 源码: $IJK_SRC"
echo "OHOS NDK: $DEVECO_NDK"

mkdir -p "$BUILD_DIR"

# 写入 CMakeLists.txt
cat > "$BUILD_DIR/CMakeLists.txt" << 'CMEOF'
cmake_minimum_required(VERSION 3.5)
project(ijkplayer_napi)
add_definitions(-DOHOS_PLATFORM)

add_library(ijkplayer_imp SHARED IMPORTED)
set_target_properties(ijkplayer_imp PROPERTIES
    IMPORTED_LOCATION ${IJK_LIBS_DIR}/arm64-v8a/libijkplayer.so)
add_library(ijksdl_imp SHARED IMPORTED)
set_target_properties(ijksdl_imp PROPERTIES
    IMPORTED_LOCATION ${IJK_LIBS_DIR}/arm64-v8a/libijksdl.so)

add_library(ijkplayer_napi SHARED
    ${IJK_SRC_DIR}/napi/ijkplayer_napi_init.cpp
    ${IJK_SRC_DIR}/napi/ijkplayer_napi.cpp
    ${IJK_SRC_DIR}/napi/ijkplayer_napi_manager.cpp
    ${IJK_SRC_DIR}/proxy/ijkplayer_napi_proxy.cpp
    ${IJK_SRC_DIR}/utils/hashmap/data_struct.c
    ${IJK_SRC_DIR}/utils/ffmpeg/custom_ffmpeg_log.c
    ${IJK_SRC_DIR}/utils/napi/napi_utils.cpp
)

target_include_directories(ijkplayer_napi PRIVATE
    ${IJK_SRC_DIR}
    ${IJK_SRC_DIR}/ijkplayer
    ${IJK_SRC_DIR}/ijksdl
    ${IJK_SRC_DIR}/proxy
    ${IJK_SRC_DIR}/napi
    ${IJK_SRC_DIR}/utils/napi
    ${IJK_SRC_DIR}/third_party/ffmpeg
    ${FFMPEG_INC_DIR}
    ${OHOS_NDK_DIR}/sysroot/usr/include
)
target_link_libraries(ijkplayer_napi PUBLIC
    ijkplayer_imp ijksdl_imp EGL GLESv3
    hilog_ndk.z ace_ndk.z ace_napi.z uv native_window)
CMEOF

mkdir -p "$BUILD_DIR/cmake_build"
cmake -S "$BUILD_DIR" -B "$BUILD_DIR/cmake_build" \
  -DCMAKE_TOOLCHAIN_FILE="$DEVECO_NDK/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a \
  -DCMAKE_BUILD_TYPE=Release \
  -DOHOS_SDK_NATIVE="$DEVECO_NDK" \
  -DIJK_SRC_DIR="$IJK_SRC" \
  -DIJK_LIBS_DIR="$IJK_LIBS" \
  -DFFMPEG_INC_DIR="$FFMPEG_INC" \
  -DOHOS_NDK_DIR="$DEVECO_NDK"

make -C "$BUILD_DIR/cmake_build" -j4

# 备份并替换（仅首次备份）
DEST="$IJK_LIBS/arm64-v8a/libijkplayer_napi.so"
if [ -f "$DEST" ] && [ ! -f "$DEST.bak" ]; then
  cp "$DEST" "$DEST.bak"
  echo "已备份: $DEST.bak"
fi
cp "$BUILD_DIR/cmake_build/libijkplayer_napi.so" "$DEST"
echo "已替换: $DEST"
echo "=== 完成 ==="
