#!/bin/bash
# Build the pinned LLVM 15 static libraries required by DXMT/airconv for iOS.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLCHAINS="$REPO_ROOT/toolchains"
LLVM_COMMIT="8dfdcc7b7bf66834a761bd8de445840ef68e4d1a"
LLVM_REPO="https://github.com/llvm/llvm-project.git"
LLVM_CHECKOUT="$TOOLCHAINS/llvm-project"
LLVM_SRC="$LLVM_CHECKOUT/llvm"
HOST_BUILD="$TOOLCHAINS/llvm-host-build"
IOS_BUILD="$TOOLCHAINS/llvm-ios-build"

mkdir -p "$TOOLCHAINS"
if [ ! -d "$LLVM_CHECKOUT/.git" ]; then
    git init "$LLVM_CHECKOUT"
    git -C "$LLVM_CHECKOUT" remote add origin "$LLVM_REPO"
fi
git -C "$LLVM_CHECKOUT" sparse-checkout init --cone
git -C "$LLVM_CHECKOUT" sparse-checkout set llvm cmake
if [ "$(git -C "$LLVM_CHECKOUT" rev-parse HEAD 2>/dev/null || true)" != "$LLVM_COMMIT" ]; then
    git -C "$LLVM_CHECKOUT" fetch --filter=blob:none --depth=1 origin "$LLVM_COMMIT"
    git -C "$LLVM_CHECKOUT" checkout --detach FETCH_HEAD
fi
test "$(git -C "$LLVM_CHECKOUT" rev-parse HEAD)" = "$LLVM_COMMIT"

# LLVM 15 does not recognize iOS as Darwin in this link-option condition.
# Apple ld rejects GNU --gc-sections; iOS needs ld64's -dead_strip.
python3 - "$LLVM_SRC/cmake/modules/AddLLVM.cmake" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = 'if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin")'
new = 'if(${CMAKE_SYSTEM_NAME} MATCHES "Darwin|iOS")'
count = text.count(old)
already_patched = text.count(new)
if count + already_patched != 2:
    raise SystemExit(
        f"Expected two LLVM 15 Darwin checks (original or patched), found "
        f"{count} original and {already_patched} patched; refusing an unknown patch context"
    )
if count:
    path.write_text(text.replace(old, new))
PY

JOBS="${LLVM_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"

if [ ! -x "$HOST_BUILD/bin/llvm-tblgen" ]; then
    cmake -S "$LLVM_SRC" -B "$HOST_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_TARGETS_TO_BUILD=Native \
        -DLLVM_ENABLE_PROJECTS= \
        -DLLVM_BUILD_TOOLS=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF
    cmake --build "$HOST_BUILD" --target llvm-tblgen --parallel "$JOBS"
fi

test -x "$HOST_BUILD/bin/llvm-tblgen"

cmake -S "$LLVM_SRC" -B "$IOS_BUILD" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TABLEGEN="$HOST_BUILD/bin/llvm-tblgen" \
    -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
    -DLLVM_TARGET_ARCH=host \
    -DLLVM_TARGETS_TO_BUILD= \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_PIC=ON \
    -DBUILD_SHARED_LIBS=OFF

cmake --build "$IOS_BUILD" --parallel "$JOBS"

test -d "$IOS_BUILD/include/llvm"
test -n "$(find "$IOS_BUILD/lib" -maxdepth 1 -name '*.a' -print -quit)"
echo "Built LLVM for iOS ARM64 at $IOS_BUILD"
find "$IOS_BUILD/lib" -maxdepth 1 -name '*.a' -print | sort
