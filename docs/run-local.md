# Run Local (M1)

Simulator-first launch (no physical iPhone required):
```bash
./scripts/run-simulator.sh
```

With automatic QR payload import on launch:
```bash
./scripts/run-simulator.sh --qr-payload-path /absolute/path/to/pairing_qr_payload.json
```

Unattended simulator run (pair + capture + stop):
```bash
./scripts/run-simulator.sh \
  --qr-payload-path /absolute/path/to/pairing_qr_payload.json \
  --auto-pair \
  --auto-capture-seconds 10 \
  --session-id simscan-demo-001
```

The simulator app accepts bootstrap env vars:
- `PROVINODE_SCAN_QR_PAYLOAD_PATH` (path to QR payload JSON file)
- `PROVINODE_SCAN_QR_PAYLOAD_JSON` (raw QR payload JSON string)
- `PROVINODE_SCAN_AUTOPAIR` (`1|true`) auto-calls pair on launch
- `PROVINODE_SCAN_AUTO_CAPTURE_SECONDS` (number) auto-capture duration before stop
- `PROVINODE_SCAN_AUTO_EXPORT` (`1|true`) auto-export after auto-stop
- `PROVINODE_SCAN_SESSION_ID` fixed session id override for auto-capture

1. Build and install `provinode-scan` on iPhone Pro (LiDAR-capable).
2. Start `provinode-room` AppHost on the same LAN.
3. In Scan app:
   - tap `Start Pairing` in desktop shell or call `POST https://<host>:7448/pairing/start` so receiver is advertised on mDNS
   - approve Local Network access on first launch (required for Bonjour discovery)
   - discover/select desktop endpoint (preferred, includes TLS fingerprint metadata)
   - or enter manual host (desktop LAN IP) + pairing port + desktop pairing TLS fingerprint
   - pair using short code + nonce
   - scanner mTLS identity is provisioned automatically from pairing response
   - start stream (secure hello is signed automatically using persisted scanner identity key)
   - start capture
4. Stop capture to finalize local `RoomCaptureSession` artifact.
