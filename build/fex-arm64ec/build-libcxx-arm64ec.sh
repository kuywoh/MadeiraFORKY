#!/bin/bash
# Build the C++ runtime for ARM64EC. llvm-mingw's release toolchain does not
# include ARM64EC libc++ archives, so build these from its matching LLVM tag.
set -euo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLVM_MINGW_BIN="${LLVM_MINGW_BIN:-$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin}"
LLVM_SOURCE_DIR="${LLVM_SOURCE_DIR:-$RUNNER_TEMP/llvm-project}"
BUILD_DIR="${RUNNER_TEMP}/llvm-runtimes-arm64ec"
INSTALL_PREFIX="$(cd "$LLVM_MINGW_BIN/.." && pwd)"
TRIPLE=arm64ec-w64-mingw32

if [ ! -d "$LLVM_SOURCE_DIR/runtimes" ]; then
    git clone --depth 1 --branch llvmorg-22.1.4 \
        https://github.com/llvm/llvm-project.git "$LLVM_SOURCE_DIR"
fi

cmake -S "$LLVM_SOURCE_DIR/runtimes" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX/$TRIPLE" \
    -DCMAKE_C_COMPILER="$LLVM_MINGW_BIN/$TRIPLE-clang" \
    -DCMAKE_CXX_COMPILER="$LLVM_MINGW_BIN/$TRIPLE-clang++" \
    -DCMAKE_CXX_COMPILER_TARGET=arm64ec-w64-windows-gnu \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_C_COMPILER_WORKS=TRUE \
    -DCMAKE_CXX_COMPILER_WORKS=TRUE \
    -DCMAKE_AR="$LLVM_MINGW_BIN/llvm-ar" \
    -DCMAKE_RANLIB="$LLVM_MINGW_BIN/llvm-ranlib" \
    '-DCMAKE_C_ARCHIVE_CREATE=<CMAKE_AR> --format=coff qc <TARGET> <LINK_FLAGS> <OBJECTS>' \
    '-DCMAKE_CXX_ARCHIVE_CREATE=<CMAKE_AR> --format=coff qc <TARGET> <LINK_FLAGS> <OBJECTS>' \
    -DCMAKE_RC_COMPILER="$LLVM_MINGW_BIN/$TRIPLE-windres" \
    -DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
    -DLIBUNWIND_USE_COMPILER_RT=TRUE \
    -DLIBUNWIND_ENABLE_SHARED=OFF \
    -DLIBUNWIND_ENABLE_STATIC=ON \
    -DLIBCXX_USE_COMPILER_RT=ON \
    -DLIBCXX_ENABLE_SHARED=OFF \
    -DLIBCXX_ENABLE_STATIC=ON \
    -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=TRUE \
    -DLIBCXX_CXX_ABI=libcxxabi \
    -DLIBCXX_LIBDIR_SUFFIX="" \
    -DLIBCXX_INCLUDE_TESTS=FALSE \
    -DLIBCXX_ENABLE_ABI_LINKER_SCRIPT=FALSE \
    -DLIBCXXABI_USE_COMPILER_RT=ON \
    -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
    -DLIBCXXABI_ENABLE_SHARED=OFF \
    -DLIBCXXABI_LIBDIR_SUFFIX=""

cmake --build "$BUILD_DIR" --parallel 3
cmake --install "$BUILD_DIR"

for runtime in libc++.a libc++abi.a libunwind.a; do
    archive="$INSTALL_PREFIX/$TRIPLE/lib/$runtime"
    test -s "$archive"
    if ! grep --binary-files=text --quiet --fixed-strings '/<ECSYMBOLS>/' "$archive"; then
        echo "ARM64EC archive is missing its required EC symbol map: $archive" >&2
        exit 1
    fi
    echo "Verified ARM64EC COFF archive has EC symbol map: $archive"
    echo "Relevant entries in archive symbol maps: $runtime"
    "$LLVM_MINGW_BIN/llvm-nm" --print-armap "$archive" \
        | grep --after-context=2 --before-context=2 -E 'recursive_mutex|shared_mutex_base|gxx_personality_seh0' \
        | head -n 32 || true
done

# LLD does not lazily resolve the EC personality symbol from libc++abi's
# archive index in this ARM64EC link. Extract only that member so it can be
# linked directly without whole-archiving libc++abi (which duplicates libc++).
RUNTIME_LIB_DIR="$INSTALL_PREFIX/$TRIPLE/lib"
mkdir -p "$RUNTIME_LIB_DIR/objects"
(
    cd "$RUNTIME_LIB_DIR/objects"
    "$LLVM_MINGW_BIN/llvm-ar" x "$RUNTIME_LIB_DIR/libc++abi.a" cxa_personality.cpp.obj
)
test -s "$RUNTIME_LIB_DIR/objects/cxa_personality.cpp.obj"
"$LLVM_MINGW_BIN/llvm-objcopy" \
    --redefine-sym '#__gxx_personality_seh0=__gxx_personality_seh0' \
    "$RUNTIME_LIB_DIR/objects/cxa_personality.cpp.obj"
if ! "$LLVM_MINGW_BIN/llvm-nm" --defined-only \
    "$RUNTIME_LIB_DIR/objects/cxa_personality.cpp.obj" \
    | grep --quiet --fixed-strings 'T __gxx_personality_seh0'; then
    echo "Failed to add the undecorated ARM64EC C++ personality alias" >&2
    exit 1
fi
