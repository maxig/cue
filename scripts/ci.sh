#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="$PROJECT_DIR/build/ci-derived-data"
SOURCE_PACKAGES_PATH="$PROJECT_DIR/build/SourcePackages"
MAC_ARCH="$(uname -m)"

COMMON_ARGS=(
    -quiet
    -project "$PROJECT_DIR/Cue.xcodeproj"
    -scheme Cue
    -destination "platform=macOS,arch=$MAC_ARCH"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH"
    CODE_SIGNING_ALLOWED=NO
)

xcodebuild "${COMMON_ARGS[@]}" -configuration Debug build
xcodebuild "${COMMON_ARGS[@]}" -configuration Release build
xcodebuild "${COMMON_ARGS[@]}" -configuration Release analyze
