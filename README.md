# provinode-scan

Native iOS app for Provinode room scanning (M1):
- LiDAR-gated ARKit capture
- secure LAN pairing + QUIC streaming
- QR-first pairing (camera scan on device, JSON import fallback on simulator)
- local-first `RoomCaptureSession` recording/export
- recorded session library with integrity/export status
- trusted desktop management with revoke/reset
- persistent scanner identity key for signed secure-channel hello proof
- simulator synthetic capture mode for end-to-end validation without physical LiDAR
- capture coaching tuned for better virtual twin quality, not just minimum readiness
- richer simulator room geometry (floor, walls, furniture plane) for pre-device reconstruction and viewport-match validation

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

## Run In iOS Simulator
```bash
./scripts/run-simulator.sh
```

Optional QR bootstrap (imports payload automatically on launch):
```bash
./scripts/run-simulator.sh --qr-payload-path /absolute/path/to/pairing_qr_payload.json
```

Autonomous simulator run (auto pair + auto capture + fixed session id):
```bash
./scripts/run-simulator.sh \
  --qr-payload-path /absolute/path/to/pairing_qr_payload.json \
  --auto-pair \
  --auto-capture-seconds 24 \
  --session-id simscan-demo-001
```

Autonomous simulator export assertion (wait for offline export and emit summary):
```bash
./scripts/run-simulator.sh \
  --qr-payload-path /absolute/path/to/pairing_qr_payload.json \
  --auto-pair \
  --auto-capture-seconds 24 \
  --auto-export \
  --session-id simscan-demo-001 \
  --wait-for-export \
  --summary-json ./artifacts/simscan-export-summary.json
```

## M1 data output
Recorded sessions are stored in app support with this layout:
- `session.manifest.json`
- `samples.log`
- `blobs/sha256/<hash>`
- `integrity.json`

The UI exposes:
- capture state: `unpaired|paired|ready|streaming|recording|exported|error`
- capture coaching and `safe to stop` guidance
- recorded sessions list with duration, sample/blob counts, integrity state, export state
- trusted desktop list with fingerprint summary, revoke, and reset

Twin-quality guidance now reacts to:
- low depth density relative to keyframes
- weak mesh coverage for walls/furniture edges
- unstable pose confidence over longer capture windows
- overall virtual twin quality score derived from keyframes, depth, mesh, duration, and pose stability

## LAN discovery
- Bonjour service browse type: `_provinode-room._tcp`
- Discovery metadata includes endpoint identity, ports, and pairing TLS cert fingerprint.
- Manual host entry remains available with explicit pairing TLS fingerprint input.

## Simulator workflow
- Start `provinode-room` in simulation mode (`--simulation-mode true --webcam-source synthetic --calibration-source synthetic`).
- Call `POST /pairing/start` on desktop and copy `pairing_qr_payload` JSON.
- Paste payload into the iOS simulator QR import panel and tap `Import QR payload`.
- Import validates endpoint security and freshness (`https`, non-expired token, supported wire major, valid desktop fingerprint, Base64 HMAC-SHA256 signature payload, valid QUIC endpoint host:port).
- Pair, start capture, and stream synthetic samples to desktop receiver.

See `docs` in the desktop repo for Vault mapping and reconstruction linkage.
