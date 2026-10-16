#!/bin/bash
# Configure (first time) and build the ARM64EC FEX module (libarm64ecfex.dll,
# shipped as xtajit64.dll). Options mirror the development build's CMakeCache.
set -eu
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLVM_MINGW_BIN="${LLVM_MINGW_BIN:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
export PATH="$LLVM_MINGW_BIN:$PATH"
B="$R/FEX/build-arm64ec"
if [ ! -f "$B/CMakeCache.txt" ]; then
    cmake -S "$R/FEX" -B "$B" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
        -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
        -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
        -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
        -DTUNE_CPU=none \
        -DENABLE_FEX_ALLOCATOR=ON -DENABLE_JEMALLOC_GLIBC_ALLOC=ON -DENABLE_OFFLINE_RUNTIME=ON \
        -DBUILD_FEXCONFIG=ON -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
        -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DENABLE_ASSERTIONS=OFF
fi
echo "ARM64EC C++ runtime symbol check:"
for runtime in libc++.a libc++abi.a libunwind.a; do
    archive="$LLVM_MINGW_BIN/../arm64ec-w64-mingw32/lib/$runtime"
    test -s "$archive"
    echo "--- $archive"
    "$LLVM_MINGW_BIN/llvm-nm" --demangle --defined-only "$archive" | grep -Ei 'mutex|condition_variable|sleep_for|gxx_personality' | head -n 40 || true
done
echo "FEX link libraries response file:"
cat "$B/Source/Windows/ARM64EC/CMakeFiles/arm64ecfex.dir/linkLibs.rsp"
cmake --build "$B" --target arm64ecfex --verbose
cp "$B/Bin/libarm64ecfex.dll" "$R/app/Madeira/arm64ec-windows/xtajit64.dll" && ls -l "$R/app/Madeira/arm64ec-windows/xtajit64.dll"
