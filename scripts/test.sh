#!/usr/bin/env bash
set -euo pipefail

PROJECT="ProvinodeScan.xcodeproj"
SCHEME="ProvinodeScan"

DESTINATION_ID=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showdestinations 2>/dev/null \
  | awk '/platform:iOS Simulator/ && /name:iPhone/ && /id:[A-F0-9-]+/ {print}' \
  | sed -E 's/.*id:([^, ]+).*/\1/' \
  | head -n 1)

if [[ -z "${DESTINATION_ID:-}" ]]; then
  echo "No iPhone simulator destination found" >&2
  exit 1
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "id=$DESTINATION_ID" test
