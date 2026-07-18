#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/Cue.app /path/to/Cue.dmg" >&2
    exit 64
fi

APP_PATH="$1"
OUTPUT_PATH="$2"

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 66
fi

if [[ -e "$OUTPUT_PATH" ]]; then
    echo "Refusing to overwrite existing output: $OUTPUT_PATH" >&2
    exit 73
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cue-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

ditto "$APP_PATH" "$STAGING_DIR/Cue.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname Cue \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_PATH"
