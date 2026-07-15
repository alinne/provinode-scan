#!/usr/bin/env bash
set -euo pipefail

PROJECT="ProvinodeScan.xcodeproj"
SCHEME="ProvinodeScan"

DESTINATION_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
  | awk '/platform:iOS Simulator/ && /name:iPhone/ && /id:[A-F0-9-]+/ {print}' \
  | sed -E 's/.*id:([^, ]+).*/\1/' \
  | head -n 1)

if [[ -z "${DESTINATION_ID:-}" ]]; then
  SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
  RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-${SDK_VERSION//./-}"
  DEVICE_TYPE_ID=$(xcrun simctl list devicetypes \
    | awk '/^iPhone 16 Pro / {value=$NF; gsub(/[()]/, "", value); print value; exit}')

  if [[ -z "${DEVICE_TYPE_ID:-}" ]]; then
    DEVICE_TYPE_ID=$(xcrun simctl list devicetypes \
      | awk '/^iPhone / {value=$NF; gsub(/[()]/, "", value); print value; exit}')
  fi

  if ! xcrun simctl list runtimes | grep -Fq "$RUNTIME_ID" || [[ -z "${DEVICE_TYPE_ID:-}" ]]; then
    echo "No compatible iPhone simulator destination or runtime found" >&2
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations >&2
    exit 1
  fi

  DESTINATION_ID=$(xcrun simctl create "ProvinodeScan CI" "$DEVICE_TYPE_ID" "$RUNTIME_ID")
  trap 'xcrun simctl delete "$DESTINATION_ID" >/dev/null 2>&1 || true' EXIT
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$DESTINATION_ID" test
