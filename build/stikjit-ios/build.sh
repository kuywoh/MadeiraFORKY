#!/bin/bash
# Rebuild the pinned StikJIT XCFramework with the active Xcode toolchain.
# The checked-in framework was emitted by Swift 6.4 and may not be readable by
# older Xcode toolchains. This leaves the vendored source/binary untouched by
# default; set STIKJIT_INSTALL_IN_APP=1 to replace the app's tracked XCFramework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="${STIKJIT_SOURCE_DIR:-$REPO_ROOT/build/_deps/StikJIT}"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/build/stikjit-ios/out/StikJIT.xcframework"
OUTPUT_DIR="${STIKJIT_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
EXPECTED_COMMIT="32287268fa5824f9edce4cb359f5833ce0cf7b00"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "StikJIT source checkout not found: $SOURCE_DIR" >&2
  echo "Check out StikDebug/StikJIT at $EXPECTED_COMMIT and set STIKJIT_SOURCE_DIR." >&2
  exit 1
fi
if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$EXPECTED_COMMIT" ]]; then
  echo "StikJIT source is not the pinned upstream commit $EXPECTED_COMMIT." >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "XcodeGen is required (brew install xcodegen)." >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required to build StikJIT." >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/madeira-stikjit.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

(
  cd "$SOURCE_DIR"
  xcodegen generate --spec project.yml
)
xcodebuild \
  -project "$SOURCE_DIR/StikJIT.xcodeproj" \
  -scheme StikJIT \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK_DIR/StikJIT.xcarchive" \
  -derivedDataPath "$WORK_DIR/DerivedData" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  PRODUCT_MODULE_NAME=StikJITSDK \
  PRODUCT_NAME=StikJITSDK \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO \
  archive
FRAMEWORK_PATH="$WORK_DIR/StikJIT.xcarchive/Products/Library/Frameworks/StikJITSDK.framework"
if [[ ! -d "$FRAMEWORK_PATH/Modules/StikJITSDK.swiftmodule" ]]; then
  echo "Rebuilt framework does not expose the expected StikJITSDK Swift module: $FRAMEWORK_PATH" >&2
  find "$WORK_DIR/StikJIT.xcarchive/Products/Library/Frameworks" -maxdepth 4 -type d -name '*.swiftmodule' -print >&2
  exit 1
fi
xcodebuild -create-xcframework \
  -framework "$FRAMEWORK_PATH" \
  -output "$WORK_DIR/StikJIT.xcframework"

if [[ -e "$OUTPUT_DIR" ]]; then
  if [[ "$OUTPUT_DIR" == "$DEFAULT_OUTPUT_DIR" ]]; then
    rm -rf "$OUTPUT_DIR"
  else
    echo "Refusing to overwrite existing output: $OUTPUT_DIR" >&2
    echo "Choose a new STIKJIT_OUTPUT_DIR or remove that generated output first." >&2
    exit 1
  fi
fi
mkdir -p "$(dirname "$OUTPUT_DIR")"
ditto "$WORK_DIR/StikJIT.xcframework" "$OUTPUT_DIR"

if [[ "${STIKJIT_INSTALL_IN_APP:-0}" == "1" ]]; then
  APP_FRAMEWORK="$REPO_ROOT/app/Frameworks/StikJIT.xcframework"
  if [[ -e "$APP_FRAMEWORK" ]]; then
    rm -rf "$APP_FRAMEWORK"
  fi
  ditto "$OUTPUT_DIR" "$APP_FRAMEWORK"
  echo "Installed rebuilt StikJIT into $APP_FRAMEWORK"
fi

echo "Built StikJIT XCFramework at $OUTPUT_DIR"
