#!/usr/bin/env bash
# Read-only prerequisite audit for the Madeira iOS app. This does not build,
# download, stage files, or modify the checkout.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0

REPORT=()
BLOCKERS=0

pass() {
    REPORT+=("- **PASS** — $1")
}

block() {
    BLOCKERS=$((BLOCKERS + 1))
    REPORT+=("- **BLOCKED** — $1")
}

note() {
    REPORT+=("- **NOTE** — $1")
}

echo "Madeira iOS app preflight — AUDIT ONLY (no app build will run)"
echo "Repository: $ROOT"

if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
    pass "Running on macOS."
else
    block "This audit requires macOS; the current host is $(uname -s 2>/dev/null || echo unknown)."
fi

for tool in git find awk; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "Required audit utility is available: $tool."
    else
        block "Required audit utility is missing: $tool."
    fi
done

if command -v xcodebuild >/dev/null 2>&1; then
    XCODE_VERSION="$(xcodebuild -version 2>&1 || true)"
    echo "$XCODE_VERSION"
    if [[ -n "$XCODE_VERSION" ]]; then
        pass "xcodebuild is available."
    else
        block "xcodebuild is installed but did not report a version."
    fi
else
    block "Xcode command-line tools are missing (xcodebuild not found)."
fi

PROJECTS="$(find app -type d -name '*.xcodeproj' -print 2>/dev/null | sort)"
PROJECT_COUNT="$(printf '%s\n' "$PROJECTS" | awk 'NF { n++ } END { print n+0 }')"
PROJECT=""
if [[ "$PROJECT_COUNT" == "1" ]]; then
    PROJECT="${PROJECTS%%$'\n'*}"
    echo "Discovered Xcode project: $PROJECT"
    if command -v xcodebuild >/dev/null 2>&1; then
        PROJECT_LIST="$(xcodebuild -list -project "$PROJECT" 2>&1)"
        PROJECT_LIST_STATUS=$?
        echo "$PROJECT_LIST"
        if [[ "$PROJECT_LIST_STATUS" -eq 0 ]]; then
            SCHEMES="$(printf '%s\n' "$PROJECT_LIST" | awk '
                /^[[:space:]]*Schemes:[[:space:]]*$/ { in_schemes=1; next }
                in_schemes && NF { sub(/^[[:space:]]+/, ""); print; next }
                in_schemes && !NF { in_schemes=0 }
            ')"
            if [[ -n "$SCHEMES" ]]; then
                echo "Discovered scheme(s):"
                printf '%s\n' "$SCHEMES"
                pass "Xcode can inspect the discovered project and found at least one scheme."
            else
                block "Xcode listed the project but did not report any schemes."
            fi
        else
            block "xcodebuild could not inspect $PROJECT."
        fi
    else
        block "Cannot inspect the discovered Xcode project because xcodebuild is missing."
    fi
elif [[ "$PROJECT_COUNT" == "0" ]]; then
    block "No Xcode project was found under app/."
else
    block "Found $PROJECT_COUNT Xcode projects; the audit cannot choose one unambiguously: $PROJECTS"
fi

if command -v xcrun >/dev/null 2>&1; then
    for sdk in iphoneos iphonesimulator; do
        SDK_VERSION="$(xcrun --sdk "$sdk" --show-sdk-version 2>&1)"
        SDK_STATUS=$?
        echo "$sdk SDK: $SDK_VERSION"
        SDK_MAJOR="$(printf '%s' "$SDK_VERSION" | awk -F. 'NF { print $1; exit }')"
        if [[ "$SDK_STATUS" -eq 0 && "$SDK_MAJOR" =~ ^[0-9]+$ && "$SDK_MAJOR" -ge 26 ]]; then
            pass "$sdk SDK $SDK_VERSION meets the iOS 26 minimum required by the JIT helper target."
        elif [[ "$SDK_STATUS" -eq 0 ]]; then
            block "$sdk SDK $SDK_VERSION is older than the project's iOS 26 helper-target minimum."
        else
            block "$sdk SDK is unavailable: $SDK_VERSION"
        fi
    done
else
    block "xcrun is missing, so installed iOS SDK versions cannot be checked."
fi

if command -v git >/dev/null 2>&1; then
    SUBMODULE_STATUS="$(git submodule status --recursive 2>&1)"
    SUBMODULE_EXIT=$?
    if [[ -n "$SUBMODULE_STATUS" ]]; then
        echo "Recursive submodule status:"
        printf '%s\n' "$SUBMODULE_STATUS"
    fi
    if [[ "$SUBMODULE_EXIT" -ne 0 ]]; then
        block "Git could not inspect recursive submodule status: $SUBMODULE_STATUS"
    elif [[ -z "$SUBMODULE_STATUS" ]]; then
        pass "No submodules are declared."
    else
        SUBMODULES_OK=1
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            marker="${line:0:1}"
            case "$marker" in
                ' ')
                    ;;
                '-')
                    block "Submodule is not initialized: ${line#?}"
                    SUBMODULES_OK=0
                    ;;
                '+')
                    block "Submodule checkout does not match the pinned gitlink: ${line#?}"
                    SUBMODULES_OK=0
                    ;;
                U)
                    block "Submodule has an unresolved merge conflict: ${line#?}"
                    SUBMODULES_OK=0
                    ;;
                *)
                    block "Unrecognized submodule status: $line"
                    SUBMODULES_OK=0
                    ;;
            esac
        done <<< "$SUBMODULE_STATUS"
        if [[ "$SUBMODULES_OK" -eq 1 ]]; then
            pass "All recursive submodules are initialized at the pinned commits."
        fi
    fi
fi

REQUIRED_FILES=(
    "app/Madeira/libgmp.a"
    "app/Madeira/libnettle.a"
    "app/Madeira/libhogweed.a"
    "app/Madeira/libgnutls.a"
    "app/Madeira/libwineserver.a"
    "app/Madeira/libntdll_unix.a"
    "app/Madeira/libwin32u_unix.a"
    "app/Madeira/libdxmt_combined.a"
    "app/Madeira/libmadeira_rppairing.a"
    "app/Madeira/libavformat.a"
    "app/Madeira/libavcodec.a"
    "app/Madeira/libswresample.a"
    "app/Madeira/libavutil.a"
    "app/Madeira/arm64ec-windows/dxva2.dll"
    "app/Madeira/arm64ec-windows/evr.dll"
    "app/Madeira/d3d12/libmetalirconverter.dylib"
    "app/Madeira/prefix-template.tar.gz"
    "app/Frameworks/StikJIT.xcframework/Info.plist"
    "app/Frameworks/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT"
    "FEX/build-ios/FEXCore/Source/libFEXCore.a"
    "FEX/build-ios/FEXCore/Source/libFEXCore_Base.a"
    "FEX/build-ios/FEXCore/Source/libJemallocLibs.a"
    "FEX/build-ios/External/fmt/libfmt.a"
    "FEX/build-ios/External/cephes/libcephes_128bit.a"
    "FEX/build-ios/External/xxhash/cmake_unofficial/libxxhash.a"
    "FEX/build-ios/External/SoftFloat-3e/libsoftfloat_3e.a"
)

for path in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$path" ]]; then
        pass "Required app input exists: $path"
    else
        block "Required app input is missing: $path"
    fi
done

REQUIRED_DIRS=(
    "app/Madeira/arm64ec-windows"
    "app/Madeira/aarch64-windows"
    "app/Madeira/i386-windows"
    "app/Madeira/d3d12"
)
for path in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$path" ]]; then
        pass "Required app resource directory exists: $path"
    else
        block "Required app resource directory is missing: $path"
    fi
done

VCRUNTIME_FILES=(
    "concrt140.dll"
    "msvcp140.dll"
    "msvcp140_1.dll"
    "msvcp140_2.dll"
    "msvcp140_atomic_wait.dll"
    "msvcp140_codecvt_ids.dll"
    "vcamp140.dll"
    "vccorlib140.dll"
    "vcomp140.dll"
    "vcruntime140.dll"
    "vcruntime140_1.dll"
    "vcruntime140_threads.dll"
)
OPTIONAL_VCRUNTIME_MISSING=0
for name in "${VCRUNTIME_FILES[@]}"; do
    path="app/Madeira/x86_64-vcruntime/$name"
    if [[ -f "$path" ]]; then
        pass "Optional Microsoft runtime override exists: $path"
    else
        OPTIONAL_VCRUNTIME_MISSING=$((OPTIONAL_VCRUNTIME_MISSING + 1))
    fi
done
if [[ "$OPTIONAL_VCRUNTIME_MISSING" -gt 0 ]]; then
    note "$OPTIONAL_VCRUNTIME_MISSING optional Microsoft VC++ runtime override(s) are absent. This does not block compilation; Wine's bundled ARM64EC built-ins remain the default, but Windows-app runtime compatibility is not established. See tools/fetch-vcruntime.md."
fi

LICENSE_INPUTS=("COPYING" "LICENSE-EXCEPTION.md")
for path in "${LICENSE_INPUTS[@]}"; do
    if [[ -f "$path" ]]; then
        pass "License source exists: $path"
    else
        block "License source is missing: $path"
    fi
done
LICENSE_COPIES=(
    "app/Madeira/licenses/LICENSE-MADEIRA-GPL-3.0.txt"
    "app/Madeira/licenses/LICENSE-MADEIRA-EXCEPTION.txt"
)
for path in "${LICENSE_COPIES[@]}"; do
    if [[ -f "$path" ]]; then
        pass "Staged license copy exists: $path"
    else
        block "Staged license copy is missing: $path (after review, generate with bash build/stage-licenses.sh)."
    fi
done

REBUILD_ONLY_DIRS=(
    "toolchains/llvm-mingw-20260421-ucrt-macos-universal"
    "toolchains/llvm-project"
    "toolchains/llvm-ios-build"
    "toolchains/llvm-host-build"
)
for path in "${REBUILD_ONLY_DIRS[@]}"; do
    if [[ -d "$path" ]]; then
        pass "Dependency-rebuild input exists: $path"
    else
        note "Missing rebuild-only input: $path (needed by documented dependency build steps; the preflight will not fetch or build it)."
    fi
done

if [[ -f "app/Madeira/d3d12/libmetalirconverter.dylib" ]]; then
    note "The Metal Shader Converter runtime library is present; Apple's installer is only needed to regenerate that library, not for the direct app build."
fi
note "Wine Mono is optional: its build phase intentionally omits it when unavailable; .NET Framework software then will not run."
note "This audit does not build the app, sign it, launch a simulator, or prove runtime compatibility."

if [[ "$BLOCKERS" -eq 0 ]]; then
    if [[ "$OPTIONAL_VCRUNTIME_MISSING" -gt 0 ]]; then
        RESULT="PREFLIGHT INCOMPLETE — required build prerequisites checked; $OPTIONAL_VCRUNTIME_MISSING optional Microsoft runtime override(s) absent; no app build was run and runtime compatibility remains unverified."
    else
        RESULT="PREFLIGHT CLEAR — prerequisites checked; no app build was run."
    fi
else
    RESULT="PREFLIGHT BLOCKED — $BLOCKERS required build prerequisite(s) missing or unavailable; $OPTIONAL_VCRUNTIME_MISSING optional Microsoft runtime override(s) absent; no app build was run."
fi
printf '%s\n' "${REPORT[@]}"
echo
echo "$RESULT"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '# Madeira iOS app preflight (audit only)\n\n'
        printf '**%s**\n\n' "$RESULT"
        printf 'This job does not compile, sign, launch, download, or stage app inputs.\n\n'
        printf '%s\n' "${REPORT[@]}"
    } >> "$GITHUB_STEP_SUMMARY"
fi

# Missing required inputs are expected in an incomplete build checkout. Keep
# the audit job green so its summary is visible; neither CLEAR nor INCOMPLETE
# means the app has been built, signed, or runtime-tested.
exit 0
