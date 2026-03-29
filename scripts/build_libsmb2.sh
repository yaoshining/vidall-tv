#!/usr/bin/env bash
# build_libsmb2.sh - Cross-compile libsmb2 for HarmonyOS aarch64 (arm64-v8a)
#
# Target:   aarch64-none-linux-ohos (HarmonyOS musl libc, ELF64 LE)
# Output:   entry/libs/arm64-v8a/libsmb2.so
# libsmb2:  https://github.com/sahlberg/libsmb2 (tag v6.1.0 or HEAD)
#
# ── 前提条件 ────────────────────────────────────────────────────────────────
#   方案 A（推荐）: DevEco Studio 已安装，使用 OHOS NDK toolchain
#   方案 B（macOS 无 Studio）: Homebrew LLVM + 自编译 aarch64-elf-binutils
#     1. brew install llvm
#     2. 从 musl 源码生成 sysroot headers:
#        curl -O https://musl.libc.org/releases/musl-1.2.5.tar.gz
#        tar xzf musl-1.2.5.tar.gz && cd musl-1.2.5
#        CC=/usr/local/opt/llvm/bin/clang ./configure --target=aarch64-linux-musl
#        make install-headers DESTDIR=/tmp/ohos-sysroot
#     3. 编译 aarch64-elf-ld:
#        curl -O https://ftp.gnu.org/gnu/binutils/binutils-2.46.tar.bz2
#        tar xjf binutils-2.46.tar.bz2
#        mkdir build-aarch64 && cd build-aarch64
#        ../binutils-2.46/configure --target=aarch64-elf --prefix=/tmp/aarch64-elf-tools \
#          --disable-nls --disable-gas --disable-gprofng --disable-gdb --enable-ld=yes
#        make all-ld -j8

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/entry/libs/arm64-v8a"
SMB2_VERSION="v6.1.0"

die() { echo "ERROR: $1" >&2; exit 1; }
info() { echo "INFO: $1"; }

# ── 检测构建方案 ─────────────────────────────────────────────────────────────
DEVECO_NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
USE_OHOS_NDK=0
if [ -d "$DEVECO_NDK/llvm/bin" ]; then
  USE_OHOS_NDK=1
  CLANG="$DEVECO_NDK/llvm/bin/clang"
  TARGET="aarch64-linux-ohos"
  SYSROOT="$DEVECO_NDK/sysroot"
  info "使用 OHOS NDK: $DEVECO_NDK"
else
  CLANG="${LLVM_CLANG:-/usr/local/opt/llvm/bin/clang}"
  TARGET="aarch64-linux-musl"
  MUSL_SYSROOT="${MUSL_SYSROOT:-/tmp/ohos-sysroot/usr/local/musl}"
  LD_BIN="${AARCH64_LD:-/tmp/binutils-build-aarch64/ld/ld-new}"
  info "使用 Homebrew LLVM + aarch64-elf-ld"
  [ -x "$CLANG" ] || die "clang 不存在: $CLANG"
  [ -x "$LD_BIN" ] || die "aarch64-elf-ld 不存在: $LD_BIN (请先运行 make all-ld)"
fi

[ -x "$CLANG" ] || die "clang 不可执行: $CLANG"

# ── 克隆 / 更新 libsmb2 源码 ─────────────────────────────────────────────────
SMB2_SRC="/tmp/libsmb2-src"
if [ ! -d "$SMB2_SRC/.git" ]; then
  info "克隆 libsmb2 $SMB2_VERSION..."
  git clone --depth=1 --branch "$SMB2_VERSION" https://github.com/sahlberg/libsmb2.git "$SMB2_SRC"
else
  info "复用已有 libsmb2 源码: $SMB2_SRC"
fi

# ── 兼容 header（处理 _U_ 宏、musl 头文件差异）──────────────────────────────
CONFIG_H="/tmp/smb2_cross_config.h"
printf '%s\n' \
  '#ifndef SMB2_CROSS_CONFIG_H' \
  '#define SMB2_CROSS_CONFIG_H' \
  '#define _U_ __attribute__((unused))' \
  '#include <sys/uio.h>' \
  '#include <netinet/tcp.h>' \
  '#define HAVE_LINGER 1' \
  '#define HAVE_STRUCT_LINGER 1' \
  '#endif' \
  > "$CONFIG_H"

# ── 编译 ──────────────────────────────────────────────────────────────────────
OBJ_DIR="/tmp/libsmb2-objs"
mkdir -p "$OBJ_DIR"
cd "$OBJ_DIR"

if [ "$USE_OHOS_NDK" -eq 1 ]; then
  BASE_FLAGS="-target $TARGET --sysroot=$SYSROOT"
else
  BASE_FLAGS="-target $TARGET -isystem ${MUSL_SYSROOT}/include"
fi

CFLAGS="$BASE_FLAGS \
  -include $CONFIG_H \
  -I$SMB2_SRC/include \
  -I$SMB2_SRC/include/smb2 \
  -I$SMB2_SRC/lib \
  -I$SYSROOT/usr/include \
  -D__OHOS__=1 \
  -DHAVE_STDINT_H -DHAVE_STDLIB_H -DHAVE_STRING_H -DSTDC_HEADERS \
  -DHAVE_TIME_H -DHAVE_SYS_TIME_H -DHAVE_UNISTD_H -DHAVE_SYS_TYPES_H \
  -DHAVE_SYS_SOCKET_H -DHAVE_NETINET_IN_H -DHAVE_ARPA_INET_H \
  -DHAVE_POLL_H -DHAVE_NETDB_H -DHAVE_FCNTL_H \
  -fPIC -O2 -Wno-error -Wno-implicit-function-declaration"

COMPILED=0
FAILED=0

for src in $(find "$SMB2_SRC/lib" -maxdepth 1 -name "*.c" | sort); do
  fname=$(basename "$src")
  # 跳过 Apple 和 Kerberos 平台特定文件
  case "$fname" in
    aes_apple.c|krb5-wrapper.c) continue ;;
  esac
  obj="${fname%.c}.o"
  if $CLANG $CFLAGS -c "$src" -o "$obj" 2>/dev/null; then
    COMPILED=$((COMPILED + 1))
  else
    echo "WARNING: 编译失败 $fname"
    FAILED=$((FAILED + 1))
  fi
done

info "编译完成: $COMPILED 成功, $FAILED 失败"
[ "$FAILED" -eq 0 ] || echo "WARNING: 有文件编译失败，.so 可能不完整"

# ── 链接 ──────────────────────────────────────────────────────────────────────
OUT_SO="$OBJ_DIR/libsmb2.so"

if [ "$USE_OHOS_NDK" -eq 1 ]; then
  $CLANG -target "$TARGET" --sysroot="$SYSROOT" \
    -shared -fPIC -Wl,-soname,libsmb2.so -o "$OUT_SO" *.o \
    -L$SYSROOT/usr/lib/aarch64-linux-ohos -lhilog_ndk.z
else
  "$LD_BIN" -shared -soname libsmb2.so -o "$OUT_SO" *.o
fi

file "$OUT_SO"
info "复制到 $OUT_DIR/libsmb2.so ..."
cp "$OUT_SO" "$OUT_DIR/libsmb2.so"
ls -lh "$OUT_DIR/libsmb2.so"
info "libsmb2.so 构建完成"
