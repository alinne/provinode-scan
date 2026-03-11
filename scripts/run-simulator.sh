#!/usr/bin/env bash
set -euo pipefail

PROJECT="ProvinodeScan.xcodeproj"
SCHEME="ProvinodeScan"
BUNDLE_ID="${BUNDLE_ID:-com.provinode.scan}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-}"
SIMULATOR_ID="${SIMULATOR_ID:-}"
QR_PAYLOAD_PATH="${QR_PAYLOAD_PATH:-}"
QR_PAYLOAD_JSON="${QR_PAYLOAD_JSON:-}"
AUTO_PAIR="${AUTO_PAIR:-0}"
AUTO_CAPTURE_SECONDS="${AUTO_CAPTURE_SECONDS:-}"
AUTO_EXPORT="${AUTO_EXPORT:-0}"
SESSION_ID_OVERRIDE="${SESSION_ID_OVERRIDE:-}"
DISABLE_ENGINE_SECURE_CHANNEL="${DISABLE_ENGINE_SECURE_CHANNEL:-0}"
WAIT_FOR_EXPORT="${WAIT_FOR_EXPORT:-0}"
EXPORT_TIMEOUT_SECONDS="${EXPORT_TIMEOUT_SECONDS:-90}"
SUMMARY_JSON="${SUMMARY_JSON:-}"

usage() {
  cat <<EOF
Usage: ./scripts/run-simulator.sh [options]

Options:
  --simulator-id <udid>      Use specific iOS simulator device id.
  --qr-payload-path <path>   Auto-import pairing QR payload JSON from file.
  --qr-payload-json <json>   Auto-import pairing QR payload JSON string.
  --bundle-id <bundle-id>    Override app bundle id (default: com.provinode.scan).
  --derived-data <path>      Override Xcode derived data output path.
  --auto-pair                Run pairing automatically on launch (simulator only).
  --auto-capture-seconds <n> Auto-start capture and stop after N seconds.
  --auto-export              Export captured session after auto-stop.
  --session-id <id>          Override session id for auto-capture run.
  --disable-engine-secure-channel
                             Use plaintext sample/control channels over mTLS transport.
  --wait-for-export          Wait for exported session files in simulator container.
  --export-timeout-seconds <n>
                             Timeout when waiting for exported session files.
  --summary-json <path>      Write simulator/export summary JSON.
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
    --auto-pair)
      AUTO_PAIR=1
      shift 1
      ;;
    --auto-capture-seconds)
      AUTO_CAPTURE_SECONDS="${2:-}"
      shift 2
      ;;
    --auto-export)
      AUTO_EXPORT=1
      shift 1
      ;;
    --session-id)
      SESSION_ID_OVERRIDE="${2:-}"
      shift 2
      ;;
    --disable-engine-secure-channel)
      DISABLE_ENGINE_SECURE_CHANNEL=1
      shift 1
      ;;
    --wait-for-export)
      WAIT_FOR_EXPORT=1
      shift 1
      ;;
    --export-timeout-seconds)
      EXPORT_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --summary-json)
      SUMMARY_JSON="${2:-}"
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
  if [[ -z "$QR_PAYLOAD_JSON" ]]; then
    QR_PAYLOAD_JSON="$(cat "$QR_PAYLOAD_PATH")"
  fi
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

DATA_CONTAINER="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [[ -n "$DATA_CONTAINER" ]]; then
  echo "Simulator data container: $DATA_CONTAINER"
fi

# Ensure launch environment variables are applied to a fresh app process.
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Launching app ..."
launch_env=()
if [[ -n "$QR_PAYLOAD_JSON" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_QR_PAYLOAD_JSON=$QR_PAYLOAD_JSON")
fi
if [[ "$AUTO_PAIR" == "1" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_AUTOPAIR=1")
fi
if [[ -n "$AUTO_CAPTURE_SECONDS" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_AUTO_CAPTURE_SECONDS=$AUTO_CAPTURE_SECONDS")
fi
if [[ "$AUTO_EXPORT" == "1" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_AUTO_EXPORT=1")
fi
if [[ -n "$SESSION_ID_OVERRIDE" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_SESSION_ID=$SESSION_ID_OVERRIDE")
fi
if [[ "$DISABLE_ENGINE_SECURE_CHANNEL" == "1" ]]; then
  launch_env+=("SIMCTL_CHILD_PROVINODE_SCAN_DISABLE_ENGINE_SECURE_CHANNEL=1")
fi

if [[ ${#launch_env[@]} -gt 0 ]]; then
  env "${launch_env[@]}" xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
else
  xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null
fi

echo "Provinode Scan launched on simulator $SIMULATOR_ID."

if [[ "$WAIT_FOR_EXPORT" == "1" ]]; then
  [[ "$AUTO_EXPORT" == "1" ]] || { echo "--wait-for-export requires --auto-export" >&2; exit 1; }
  [[ -n "$SESSION_ID_OVERRIDE" ]] || { echo "--wait-for-export requires --session-id" >&2; exit 1; }
  [[ -n "$DATA_CONTAINER" ]] || { echo "Simulator data container unavailable for export polling" >&2; exit 1; }
  if [[ -n "$SUMMARY_JSON" ]]; then
    command -v jq >/dev/null 2>&1 || { echo "jq is required when using --summary-json" >&2; exit 1; }
  fi

  SESSION_DIR="$DATA_CONTAINER/Library/Application Support/ProvinodeScan/Sessions/$SESSION_ID_OVERRIDE"
  EXPORT_DIR="$DATA_CONTAINER/Documents/RoomCaptureExports/$SESSION_ID_OVERRIDE.roomcapture"
  TRUST_STORE_PATH="$DATA_CONTAINER/Library/Application Support/ProvinodeScan/trust-records.json"
  EXPORTED_MANIFEST="$EXPORT_DIR/session.manifest.json"
  EXPORTED_INTEGRITY="$EXPORT_DIR/integrity.json"

  deadline=$((SECONDS + EXPORT_TIMEOUT_SECONDS))
  until [[ -f "$EXPORTED_MANIFEST" && -f "$EXPORTED_INTEGRITY" ]]; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for exported session files in $EXPORT_DIR" >&2
      exit 1
    fi
    sleep 2
  done

  echo "Exported session directory: $EXPORT_DIR"
  if [[ -n "$SUMMARY_JSON" ]]; then
    mkdir -p "$(dirname "$SUMMARY_JSON")"
    jq -n \
      --arg simulator_id "$SIMULATOR_ID" \
      --arg bundle_id "$BUNDLE_ID" \
      --arg data_container "$DATA_CONTAINER" \
      --arg session_id "$SESSION_ID_OVERRIDE" \
      --arg session_directory "$SESSION_DIR" \
      --arg export_directory "$EXPORT_DIR" \
      --arg exported_manifest "$EXPORTED_MANIFEST" \
      --arg exported_integrity "$EXPORTED_INTEGRITY" \
      --arg trust_store_path "$TRUST_STORE_PATH" \
      '{
        simulator_id: $simulator_id,
        bundle_id: $bundle_id,
        data_container: $data_container,
        session_id: $session_id,
        session_directory: $session_directory,
        export_directory: $export_directory,
        exported_manifest: $exported_manifest,
        exported_integrity: $exported_integrity,
        trust_store_path: $trust_store_path
      }' > "$SUMMARY_JSON"
    echo "Summary: $SUMMARY_JSON"
  fi
fi
