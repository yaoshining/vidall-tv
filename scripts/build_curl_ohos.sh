#!/usr/bin/env zsh
# =============================================================================
# build_curl_ohos.sh — 为 HarmonyOS 交叉编译 libcurl（HTTP-only，无 TLS 依赖）
#
# 用法：
#   cd /path/to/VidAll_TV
#   zsh scripts/build_curl_ohos.sh [arm64-v8a|x86_64|all]
#
# 前置条件：
#   curl 源码解压到  ~/Downloads/curl-8.19.0  （或修改 CURL_SRC 变量）
#
# 产出：
#   entry/libs/arm64-v8a/libcurl.so
#   entry/libs/x86_64/libcurl.so
#   entry/src/main/cpp/third_party/curl/include/curl/*.h
#
# 备注：
#   编译为 HTTP-only（无 SSL），HTTPS WebDAV 请求由 ArkTS TLS 通道处理。
#   libcurl.so 放入 libs 目录后，CMake 自动激活 VIDALL_HAS_LIBCURL=1。
# =============================================================================

set -euo pipefail

# ── 路径配置 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR=${0:a:h}
PROJECT_ROOT=${SCRIPT_DIR:h}

CURL_SRC=${CURL_SRC:-$HOME/Downloads/curl-8.19.0}
BUILD_DIR=/tmp/curl_ohos_build
INSTALL_DIR=/tmp/curl_ohos_install

NDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native
CMAKE_BIN=${NDK_HOME}/build-tools/cmake/bin/cmake
NINJA_BIN=${NDK_HOME}/build-tools/cmake/bin/ninja
TOOLCHAIN=${NDK_HOME}/build/cmake/ohos.toolchain.cmake
SYSROOT=${NDK_HOME}/sysroot

TARGET_ARCH=${1:-all}   # arm64-v8a | x86_64 | all

# ── 检查前置 ─────────────────────────────────────────────────────────────────
if [[ ! -d "$CURL_SRC" ]]; then
  echo "错误: curl 源码目录不存在: $CURL_SRC"
  echo "      请设置环境变量 CURL_SRC 指向正确路径。"
  exit 1
fi
if [[ ! -f "$CMAKE_BIN" ]]; then
  echo "错误: 未找到 NDK cmake: $CMAKE_BIN"
  exit 1
fi

echo "curl 源码: $CURL_SRC"
echo "目标架构: $TARGET_ARCH"
echo ""

# ── 构建单个架构的函数 ────────────────────────────────────────────────────────
build_arch() {
  local arch=$1          # arm64-v8a 或 x86_64
  local build_sub=${BUILD_DIR}/${arch}
  local install_sub=${INSTALL_DIR}/${arch}

  # 架构对应的 ABI 目录名
  local lib_dir="${PROJECT_ROOT}/entry/libs/${arch}"

  echo "============================================================"
  echo "  构建 libcurl for ${arch}"
  echo "============================================================"

  mkdir -p "${build_sub}" "${install_sub}" "${lib_dir}"

  # cmake configure
  ${CMAKE_BIN} \
    -S "${CURL_SRC}" \
    -B "${build_sub}" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="${NINJA_BIN}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DOHOS_ARCH="${arch}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install_sub}" \
    \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    \
    -DCURL_USE_OPENSSL=OFF \
    -DCURL_USE_MBEDTLS=OFF \
    -DCURL_USE_BEARSSL=OFF \
    -DCURL_USE_WOLFSSL=OFF \
    -DCURL_USE_GNUTLS=OFF \
    -DCURL_USE_NSS=OFF \
    -DCURL_USE_SECTRANSP=OFF \
    \
    -DZLIB_INCLUDE_DIR="${SYSROOT}/usr/include" \
    -DZLIB_LIBRARY="${SYSROOT}/usr/lib/${arch/arm64-v8a/aarch64-linux-ohos}/libz.so" \
    \
    -DUSE_LIBIDN2=OFF \
    -DUSE_UNIX_SOCKETS=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_DICT=ON \
    -DCURL_DISABLE_FILE=ON \
    -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_SMTP=ON \
    -DCURL_DISABLE_POP3=ON \
    -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_FTP=ON \
    -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_GOPHER=ON \
    -DCURL_DISABLE_SMB=ON \
    -DCURL_DISABLE_MQTT=ON \
    -DCURL_DISABLE_WEBSOCKETS=OFF \
    \
    -DCURL_CA_BUNDLE=none \
    -DCURL_CA_PATH=none \
    -DCURL_CA_FALLBACK=OFF \
    2>&1

  # build
  ${CMAKE_BIN} --build "${build_sub}" -- -j4 2>&1

  # install
  ${CMAKE_BIN} --install "${build_sub}" 2>&1

  # 把 .so 复制到项目 libs 目录
  local so_src="${install_sub}/lib/libcurl.so"
  if [[ ! -f "$so_src" ]]; then
    # 有些版本输出为 libcurl.so.4 或带版本号
    so_src=$(find "${install_sub}/lib" -name "libcurl.so*" | head -1)
  fi

  if [[ -z "$so_src" ]]; then
    echo "错误: 找不到编译产出的 libcurl.so"
    exit 1
  fi

  cp "${so_src}" "${lib_dir}/libcurl.so"
  echo "✓ 已复制: ${lib_dir}/libcurl.so"

  echo ""
}

# ── 复制头文件（arch 无关，只做一次） ─────────────────────────────────────────
copy_headers() {
  local install_sub=${INSTALL_DIR}/arm64-v8a
  local header_dst="${PROJECT_ROOT}/entry/src/main/cpp/third_party/curl/include"

  mkdir -p "${header_dst}"

  if [[ -d "${install_sub}/include/curl" ]]; then
    cp -r "${install_sub}/include/curl" "${header_dst}/"
    echo "✓ 头文件已复制到 entry/src/main/cpp/third_party/curl/include/curl/"
  else
    echo "警告: 未找到 include/curl，请手动复制头文件"
  fi
}

# ── 修复 ZLIB_LIBRARY 路径：x86_64 不需要替换 ─────────────────────────────────
build_arch_fixed() {
  local arch=$1
  if [[ "$arch" == "arm64-v8a" ]]; then
    ZLIB_LIB="${SYSROOT}/usr/lib/aarch64-linux-ohos/libz.so"
  else
    ZLIB_LIB="${SYSROOT}/usr/lib/x86_64-linux-ohos/libz.so"
  fi

  local build_sub=${BUILD_DIR}/${arch}
  local install_sub=${INSTALL_DIR}/${arch}
  local lib_dir="${PROJECT_ROOT}/entry/libs/${arch}"

  echo "============================================================"
  echo "  构建 libcurl for ${arch}"
  echo "============================================================"

  mkdir -p "${build_sub}" "${install_sub}" "${lib_dir}"

  ${CMAKE_BIN} \
    -S "${CURL_SRC}" \
    -B "${build_sub}" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="${NINJA_BIN}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DOHOS_ARCH="${arch}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${install_sub}" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCURL_USE_OPENSSL=OFF \
    -DCURL_USE_MBEDTLS=OFF \
    -DCURL_USE_BEARSSL=OFF \
    -DCURL_USE_WOLFSSL=OFF \
    -DCURL_USE_GNUTLS=OFF \
    -DCURL_USE_NSS=OFF \
    -DCURL_USE_SECTRANSP=OFF \
    -DCURL_ENABLE_SSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DUSE_NGHTTP2=OFF \
    -DUSE_NGHTTP3=OFF \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_LIBRTMP=OFF \
    -DZLIB_INCLUDE_DIR="${SYSROOT}/usr/include" \
    -DZLIB_LIBRARY="${ZLIB_LIB}" \
    -DHAVE_SYS_SOCKIO_H=0 \
    -DHAVE_IFADDRS_H=0 \
    -DUSE_LIBIDN2=OFF \
    -DUSE_UNIX_SOCKETS=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_DICT=ON \
    -DCURL_DISABLE_FILE=ON \
    -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_SMTP=ON \
    -DCURL_DISABLE_POP3=ON \
    -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_FTP=ON \
    -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_GOPHER=ON \
    -DCURL_DISABLE_SMB=ON \
    -DCURL_DISABLE_MQTT=ON \
    -DCURL_DISABLE_WEBSOCKETS=OFF \
    -DCURL_CA_BUNDLE=none \
    -DCURL_CA_PATH=none \
    -DCURL_CA_FALLBACK=OFF \
    2>&1

  ${CMAKE_BIN} --build "${build_sub}" -- -j4 2>&1
  ${CMAKE_BIN} --install "${build_sub}" 2>&1

  # 找到并复制 .so
  local so_src
  so_src=$(find "${install_sub}/lib" -name "libcurl.so" 2>/dev/null | head -1)
  if [[ -z "$so_src" ]]; then
    so_src=$(find "${install_sub}/lib" -name "libcurl.so.*" 2>/dev/null | head -1)
  fi
  if [[ -z "$so_src" ]]; then
    echo "ERROR: 未找到 libcurl.so 产出，请检查构建日志"
    exit 1
  fi

  cp "${so_src}" "${lib_dir}/libcurl.so"
  echo "✓ 已复制: -> ${lib_dir}/libcurl.so  (源: ${so_src})"
  file "${lib_dir}/libcurl.so"
  echo ""
}

# ── 关键：移除 Host 端 autoconf 生成的 curl_config.h ─────────────────────────
# curl 源码中若存在 configure 生成的 lib/curl_config.h（如 macOS 本机跑过
# ./configure），由于 curl C 文件用 #include "curl_config.h"（带引号），
# 编译器优先找源码目录版本而非 cmake 构建目录版本，导致宿主机配置污染
# 交叉编译结果（例如 #define USE_LIBPSL 1 会引起 psl.h 找不到错误）。
HOST_CFG="${CURL_SRC}/lib/curl_config.h"
if [[ -f "$HOST_CFG" ]]; then
  echo "⚠ 检测到源码目录存在 lib/curl_config.h（Host 端构建残留），重命名备份..."
  mv "$HOST_CFG" "${HOST_CFG}.host_bak"
  echo "  已备份为: ${HOST_CFG}.host_bak"
fi

# ── 主流程 ────────────────────────────────────────────────────────────────────
case "$TARGET_ARCH" in
  arm64-v8a)
    build_arch_fixed arm64-v8a
    copy_headers
    ;;
  x86_64)
    build_arch_fixed x86_64
    # 头文件从 x86_64 也可以，架构无关
    INSTALL_DIR_BACKUP=${INSTALL_DIR}
    INSTALL_DIR=${INSTALL_DIR}
    copy_headers
    ;;
  all)
    build_arch_fixed arm64-v8a
    build_arch_fixed x86_64
    copy_headers   # 用 arm64 产出的头文件（架构无关）
    ;;
  *)
    echo "用法: $0 [arm64-v8a|x86_64|all]"
    exit 1
    ;;
esac

echo "============================================================"
echo "  全部完成！"
echo "  产出文件："
ls -lh "${PROJECT_ROOT}/entry/libs/arm64-v8a/libcurl.so" 2>/dev/null || true
ls -lh "${PROJECT_ROOT}/entry/libs/x86_64/libcurl.so" 2>/dev/null || true
ls "${PROJECT_ROOT}/entry/src/main/cpp/third_party/curl/include/curl/" 2>/dev/null | head -5 || true
echo ""
echo "  下一步：在 DevEco Studio 中重新构建 HAP，CMake 将自动激活 VIDALL_HAS_LIBCURL=1"
echo "============================================================"
