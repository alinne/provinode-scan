# provinode-scan

Native iOS app for Provinode room scanning (M1):
- LiDAR-gated ARKit capture
- secure LAN pairing + QUIC streaming
- local-first `RoomCaptureSession` recording/export

## Requirements
- iPhone Pro with LiDAR (`iPhone 12 Pro` or newer Pro line)
- iOS 17.0+
- Xcode 16+

## Generate project
```bash
brew install xcodegen
xcodegen generate
```

## Build
```bash
xcodebuild \
  -project ProvinodeScan.xcodeproj \
  -scheme ProvinodeScan \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Test
```bash
./scripts/test.sh
```

## M1 data output
Recorded sessions are stored in app support with this layout:
- `session.manifest.json`
- `samples.log`
- `blobs/sha256/<hash>`
- `integrity.json`

See `docs` in the desktop repo for Vault mapping and reconstruction linkage.
