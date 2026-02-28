#!/usr/bin/env bash
set -euo pipefail

PROJECT="ProvinodeScan.xcodeproj"
SCHEME="ProvinodeScan"
BUNDLE_ID="${BUNDLE_ID:-com.provinode.scan}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-}"
SIMULATOR_ID="${SIMULATOR_ID:-}"
QR_PAYLOAD_PATH="${QR_PAYLOAD_PATH:-}"
QR_PAYLOAD_JSON="${QR_PAYLOAD_JSON:-}"

usage() {
  cat <<EOF
Usage: ./scripts/run-simulator.sh [options]

Options:
  --simulator-id <udid>      Use specific iOS simulator device id.
  --qr-payload-path <path>   Auto-import pairing QR payload JSON from file.
  --qr-payload-json <json>   Auto-import pairing QR payload JSON string.
  --bundle-id <bundle-id>    Override app bundle id (default: com.provinode.scan).
  --derived-data <path>      Override Xcode derived data output path.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator-id)
      SIMULATOR_ID="${2:-}"
      shift 2
      ;;
    --qr-payload-path)
      QR_PAYLOAD_PATH="${2:-}"
      shift 2
      ;;
    --qr-payload-json)
      QR_PAYLOAD_JSON="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
    | awk '/platform:iOS Simulator/ && /name:iPhone/ && /id:[A-F0-9-]+/ {print}' \
    | sed -E 's/.*id:([^, ]+).*/\1/' \
    | head -n 1)
fi

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "No iPhone simulator destination found." >&2
  exit 1
fi

if [[ -n "$QR_PAYLOAD_PATH" ]]; then
  QR_PAYLOAD_PATH="$(cd "$(dirname "$QR_PAYLOAD_PATH")" && pwd)/$(basename "$QR_PAYLOAD_PATH")"
  [[ -f "$QR_PAYLOAD_PATH" ]] || { echo "QR payload file not found: $QR_PAYLOAD_PATH" >&2; exit 1; }
fi

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "id=$SIMULATOR_ID"
)

if [[ -n "$DERIVED_DATA_PATH" ]]; then
  mkdir -p "$DERIVED_DATA_PATH"
  BUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA_PATH")
fi

echo "Booting simulator $SIMULATOR_ID ..."
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_ID" >/dev/null 2>&1 || true

echo "Building app for simulator ..."
xcodebuild "${BUILD_ARGS[@]}" build

if [[ -n "$DERIVED_DATA_PATH" ]]; then
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/ProvinodeScan.app"
else
  TARGET_BUILD_DIR=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/TARGET_BUILD_DIR = / {print $2; exit}')
  WRAPPER_NAME=$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '/WRAPPER_NAME = / {print $2; exit}')
  APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
fi

[[ -d "$APP_PATH" ]] || { echo "Built app bundle not found at $APP_PATH" >&2; exit 1; }

echo "Installing app ..."
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH"

echo "Launching app ..."
if [[ -n "$QR_PAYLOAD_PATH" && -n "$QR_PAYLOAD_JSON" ]]; then
  SIMCTL_CHILD_PROVINODE_SCAN_QR_PAYLOAD_PATH="$QR_PAYLOAD_PATH" \
  SIMCTL_CHILD_PROVINODE_SCAN_QR_PAYLOAD_JSON="$QR_PAYLOAD_JSON" \
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
elif [[ -n "$QR_PAYLOAD_PATH" ]]; then
  SIMCTL_CHILD_PROVINODE_SCAN_QR_PAYLOAD_PATH="$QR_PAYLOAD_PATH" \
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
elif [[ -n "$QR_PAYLOAD_JSON" ]]; then
  SIMCTL_CHILD_PROVINODE_SCAN_QR_PAYLOAD_JSON="$QR_PAYLOAD_JSON" \
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
else
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
fi

echo "Provinode Scan launched on simulator $SIMULATOR_ID."
